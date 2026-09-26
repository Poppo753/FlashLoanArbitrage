// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IFlashLoanCallback} from "./interfaces/IFlashLoanCallback.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";
import {IUniswapV3Router} from "./interfaces/IUniswapV3Router.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";

/**
 * @title IUniswapV3Factory
 * @notice Minimal local slice of the Uniswap V3 factory, declared inline to avoid a new file.
 * @dev Only `getPool` is needed. `getPool` is permissionless and deterministic: it returns the
 *      address(0) when the (tokenA, tokenB, fee) pool was never initialised, which is why the
 *      CREATE2 pre-computation is cross-checked against it in `_v3Pool`.
 */
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/**
 * @title IFlashLoanServiceLike
 * @notice Minimal local slice of `FlashLoanService`, declared inline to avoid a new file.
 * @dev The canonical signature of `FlashLoanService.executeFlashLoan`; the plugin deliberately
 *      depends on the shape of the call and not on the concrete contract, so a mock service can
 *      be substituted in tests.
 */
interface IFlashLoanServiceLike {
    function executeFlashLoan(address[] calldata tokens, uint256[] calldata amounts, bytes calldata callbackData)
        external;
}

/**
 * @title ArbitragePlugin
 * @notice Two-venue (Uniswap V2 <-> Uniswap V3) atomic arbitrage funded by a Balancer V2 flash loan.
 *
 * ARCHITECTURE (plan D4 / D11 / D13):
 *   ArbitragePlugin.startArbitrage(amount, buyOnVenueA)
 *     -> FlashLoanService.executeFlashLoan([baseToken], [amount], routeData)
 *        -> Balancer Vault flashLoan (0% fee)
 *           -> FlashLoanService.receiveFlashLoan()      [transfers principal to this contract]
 *              -> ArbitragePlugin.onFlashLoanReceived() [buy leg, sell leg, repay, keep profit]
 *           -> FlashLoanService repays Balancer
 *
 * THE CYCLE (closes in the borrowed asset - audit finding C1):
 *   baseToken (USDC) --buy--> quoteToken (WETH) --sell--> baseToken (USDC)
 *   Leg 1 runs on the venue chosen by the caller, leg 2 always runs on the OTHER venue and sells
 *   100% of what leg 1 produced, so no intermediate dust can be stranded.
 *
 * VENUES:
 *   venueA = Uniswap V2 Router02  (constant product, exact `getAmountsOut` quote)
 *   venueB = Uniswap V3 SwapRouter (concentrated liquidity, quote derived from `pool.slot0()`)
 *   Neither router nor token address is hardcoded: both are constructor parameters.
 *
 * HARDCODED ADDRESSES (only two, both canonical Uniswap V3 constants, required to resolve pools):
 *   V3_FACTORY            0x1F98431c8aD98523631AE4a59f267346ea31F984 - the UniswapV3Factory,
 *                         identical on Arbitrum One, Ethereum, Polygon, Optimism and Base.
 *   V3_POOL_INIT_CODE_HASH 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54
 *                         - keccak256 of the UniswapV3Pool creation bytecode. The pool salt is
 *                         keccak256(abi.encode(token0, token1, fee)); the init code hash is the
 *                         suffix of the CREATE2 pre-image, and both are part of the CREATE2
 *                         address formula. The computed address is always cross-checked against
 *                         the factory's own `getPool`, so a wrong constant can never send funds
 *                         to an attacker-controlled address: it can only revert `V3PoolNotFound`.
 *
 * SECURITY:
 *   - `startArbitrage` is `onlyOwner` + `whenNotPaused`: nobody else can start a cycle.
 *   - `onFlashLoanReceived` accepts only the configured service; a direct call is impossible for
 *     anyone else because the owner is the only address able to set the service, once.
 *   - Retained profits are NEVER used to repay the loan: repayment is measured against the
 *     balance that existed before the principal was handed over (see the accounting block).
 *   - `minProfit` is the profitability guard; the V2/V3 `amountOutMinimum` values are the
 *     per-leg slippage guards; `route.deadline` is the MEV/stale-quote guard.
 *   - Reentrancy into `startArbitrage` is already impossible (`onlyOwner`) and, on the service
 *     side, `executeFlashLoan` is `nonReentrant`; no extra `ReentrancyGuard` state is needed here.
 *
 * @author Project4 Team
 * @custom:version 1.0.0
 */
contract ArbitragePlugin is IFlashLoanCallback, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ==================== CONSTANTS ====================

    /// @notice Fee tier of the V3 pool used by `venueB` (500 = 0.05%).
    uint24 public constant VENUE_B_FEE = 500;

    /// @notice Dust-level sanity floor for a borrow: rejects zero/garbage amounts (0.001 USDC).
    uint256 public constant MIN_FLASH_LOAN = 1_000;

    /// @notice Hard cap on the slippage tolerance accepted at construction (20%).
    uint256 private constant MAX_SLIPPAGE_BPS = 2_000;

    /// @notice Lower bound of the router deadline window accepted at construction.
    uint256 private constant MIN_DEADLINE_WINDOW = 30;

    /// @notice Upper bound of the router deadline window accepted at construction (1 hour).
    uint256 private constant MAX_DEADLINE_WINDOW = 3_600;

    /// @notice Denominator of the basis-point helpers.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Denominator of the Uniswap V3 pool fee (`fee` is expressed in 1e-6).
    uint256 private constant V3_FEE_DENOMINATOR = 1_000_000;

    /// @notice Q64.96 scale of `slot0().sqrtPriceX96`.
    uint256 private constant SQRT_PRICE_SCALE = 1 << 96;

    /// @notice ABI width of `abi.encode(RouteData)`: one bool slot + one uint256 slot.
    uint256 private constant ROUTE_DATA_LENGTH = 64;

    /// @notice Canonical Uniswap V3 factory (same address on every chain where it is deployed).
    address private constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    /// @notice keccak256 of the UniswapV3Pool creation code, used as CREATE2 init code hash.
    bytes32 private constant V3_POOL_INIT_CODE_HASH =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    // ==================== IMMUTABLES ====================

    /// @notice Borrowed / profit asset (USDC on Arbitrum).
    address public immutable baseToken;

    /// @notice Intermediate asset traded by both legs (WETH on Arbitrum).
    address public immutable quoteToken;

    /// @notice Venue A: Uniswap V2 Router02, used for one leg of the cycle.
    IUniswapV2Router02 public immutable venueA;

    /// @notice Venue B: Uniswap V3 SwapRouter, used for the other leg of the cycle.
    IUniswapV3Router public immutable venueB;

    /// @notice Slippage tolerance applied to every `amountOutMinimum` (basis points).
    uint256 public immutable maxSlippageBps;

    /// @notice Lifetime of the route deadline and of the router deadlines, in seconds.
    uint256 public immutable deadlineWindow;

    // ==================== STATE ====================

    /// @notice Flash loan service, set once through `initialize()` (plan D13).
    address public flashLoanService;

    /// @notice Minimum acceptable profit, denominated in `baseToken` wei.
    /// @dev Starts at 0 because the constructor takes no profit parameter: the owner MUST call
    ///      `setMinProfit()` after deployment, otherwise any non-negative profit is accepted.
    uint256 public minProfit;

    // ==================== TYPES ====================

    /// @notice Payload handed to the flash loan service and echoed back into the callback.
    struct RouteData {
        bool buyOnVenueA; // leg 1 venue selector
        uint256 deadline; // absolute unix deadline for the whole cycle
    }

    // ==================== ERRORS ====================

    /// @notice A required address was `address(0)`.
    error InvalidAddress();
    /// @notice `baseToken` and `quoteToken` are the same asset, which makes the cycle degenerate.
    error InvalidTokenPair();
    /// @notice `maxSlippageBps` above `MAX_SLIPPAGE_BPS`.
    error InvalidSlippage(uint256 maxSlippageBps);
    /// @notice `deadlineWindow` outside `[MIN_DEADLINE_WINDOW, MAX_DEADLINE_WINDOW]`.
    error InvalidDeadlineWindow(uint256 deadlineWindow);
    /// @notice Borrow amount is zero.
    error InvalidAmount(uint256 amount);
    /// @notice Borrow amount below the `MIN_FLASH_LOAN` sanity floor.
    error AmountBelowMinimum(uint256 amount, uint256 minimum);
    /// @notice `initialize()` called on an already initialized plugin.
    error AlreadyInitialized();
    /// @notice `startArbitrage` called before `initialize()`.
    error FlashLoanNotInitialized();
    /// @notice Callback caller is not the configured flash loan service.
    error NotFlashLoanService(address caller);
    /// @notice Loan shape differs from the single-`baseToken` request this plugin builds.
    error UnexpectedFlashLoan();
    /// @notice `callbackData` is not the exact `abi.encode(RouteData)` blob produced by `startArbitrage`.
    error InvalidCallbackData(uint256 length);
    /// @notice The route deadline has passed (stale quote / sandwich attempt).
    error DeadlineExpired(uint256 deadline, uint256 timestamp);
    /// @notice The service did not deliver the principal before invoking the callback.
    error PrincipalNotReceived(uint256 expected, uint256 actual);
    /// @notice The cycle produced less `baseToken` than the loan plus fee requires.
    error InsufficientRepayment(uint256 available, uint256 required);
    /// @notice The cycle was profitable but below the owner-configured `minProfit`.
    error MinProfitNotMet(uint256 profit, uint256 minProfit);
    /// @notice V3 pool not resolvable (unknown address, not deployed, or empty).
    error V3PoolNotFound();
    /// @notice A V2 router returned an `amounts` array of unexpected length.
    error InvalidSwapResult();

    // ==================== EVENTS ====================

    /// @notice Emitted once by `initialize()`.
    event FlashLoanServiceSet(address indexed service);
    /// @notice Emitted after a completed and repaid arbitrage cycle. `profit` stays in this contract.
    event ArbitrageExecuted(uint256 principal, uint256 profit, bool buyOnVenueA);
    /// @notice Emitted by `setMinProfit()`.
    event MinProfitUpdated(uint256 previousMinProfit, uint256 newMinProfit);

    // ==================== CONSTRUCTOR ====================

    /**
     * @notice Deploys the plugin with `flashLoanService` unset; call `initialize()` afterwards.
     * @param baseToken_ Borrowed and profit asset (USDC on Arbitrum).
     * @param quoteToken_ Intermediate asset (WETH on Arbitrum).
     * @param venueA_ Uniswap V2 Router02 address.
     * @param venueB_ Uniswap V3 SwapRouter address.
     * @param maxSlippageBps_ Slippage tolerance in basis points, at most 2000 (20%).
     * @param deadlineWindow_ Route/router deadline lifetime in seconds, within [30, 3600].
     *
     * @dev Plan D13: the service needs `address(this)` at ITS construction, so the plugin must be
     *      deployed first. Deploy order: plugin -> `new FlashLoanService(address(plugin))` ->
     *      `plugin.initialize(address(service))`.
     */
    constructor(
        address baseToken_,
        address quoteToken_,
        address venueA_,
        address venueB_,
        uint256 maxSlippageBps_,
        uint256 deadlineWindow_
    ) Ownable(msg.sender) {
        if (baseToken_ == address(0) || quoteToken_ == address(0) || venueA_ == address(0) || venueB_ == address(0)) revert InvalidAddress();
        if (baseToken_ == quoteToken_) revert InvalidTokenPair();
        if (maxSlippageBps_ > MAX_SLIPPAGE_BPS) revert InvalidSlippage(maxSlippageBps_);
        if (deadlineWindow_ < MIN_DEADLINE_WINDOW || deadlineWindow_ > MAX_DEADLINE_WINDOW) {
            revert InvalidDeadlineWindow(deadlineWindow_);
        }

        baseToken = baseToken_;
        quoteToken = quoteToken_;
        venueA = IUniswapV2Router02(venueA_);
        venueB = IUniswapV3Router(venueB_);
        maxSlippageBps = maxSlippageBps_;
        deadlineWindow = deadlineWindow_;
    }

    // ==================== ADMIN ====================

    /**
     * @notice Binds this plugin to its flash loan service. Callable exactly once (plan D13).
     * @param service Address of the `FlashLoanService` that will invoke `onFlashLoanReceived`.
     */
    function initialize(address service) external onlyOwner {
        if (flashLoanService != address(0)) revert AlreadyInitialized();
        if (service == address(0)) revert InvalidAddress();

        flashLoanService = service;
        emit FlashLoanServiceSet(service);
    }

    /**
     * @notice Sets the minimum acceptable profit of a cycle, in `baseToken` wei.
     * @param newMinProfit New threshold; 0 disables the profitability guard.
     */
    function setMinProfit(uint256 newMinProfit) external onlyOwner {
        uint256 previous = minProfit;
        minProfit = newMinProfit;
        emit MinProfitUpdated(previous, newMinProfit);
    }

    /**
     * @notice Sends `amount` of `token` to `to` (PULL pattern, no `.transfer` - audit finding C2).
     * @param token Token to withdraw.
     * @param to Recipient of the tokens.
     * @param amount Amount to withdraw; an excessive value reverts inside the ERC20 transfer.
     *
     * @dev Retained profits are withdrawable here; the loan itself is never custody.
     */
    function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    // ==================== ENTRY POINT ====================

    /**
     * @notice Borrows `amount` of `baseToken`, runs the two-venue cycle and repays the loan.
     * @param amount `baseToken` amount to borrow; must be `>= MIN_FLASH_LOAN`.
     * @param buyOnVenueA `true` buys on `venueA` (V2) and sells on `venueB` (V3),
     *        `false` buys on `venueB` (V3) and sells on `venueA` (V2).
     *
     * @dev DESIGN CHOICE - the function intentionally returns nothing.
     *      The profit only exists inside `onFlashLoanReceived`, which the service calls
     *      synchronously within this very call, so a `returns (uint256 profit)` signature would
     *      need a transient/storage slot written by the callback purely to shuttle one word back
     *      to this frame. The mandatory `ArbitrageExecuted` event plus the `baseToken` balance
     *      delta of this contract already expose the result (off-chain and on-chain tests read
     *      the balance delta, the bot reads the event). Extra state written during the callback
     *      would also be a reentrancy-visible scratch value for no functional gain, so the
     *      simplest correct design - no return value - is used.
     */
    function startArbitrage(uint256 amount, bool buyOnVenueA) external onlyOwner whenNotPaused {
        if (flashLoanService == address(0)) revert FlashLoanNotInitialized();
        if (amount == 0) revert InvalidAmount(amount);
        if (amount < MIN_FLASH_LOAN) revert AmountBelowMinimum(amount, MIN_FLASH_LOAN);

        address[] memory tokens = new address[](1);
        tokens[0] = baseToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        IFlashLoanServiceLike(flashLoanService)
            .executeFlashLoan(
                tokens, amounts, abi.encode(RouteData({buyOnVenueA: buyOnVenueA, deadline: deadlineForRouter()}))
            );
    }

    // ==================== CALLBACK ====================

    /**
     * @notice Flash loan callback: executes both legs and repays the service.
     * @param tokens Borrowed tokens; must be exactly `[baseToken]`.
     * @param amounts Borrowed amounts; must be `[amount]`.
     * @param feeAmounts Flash loan fees; must be `[fee]` (Balancer V2 charges 0%).
     * @param callbackData `abi.encode(RouteData)` produced by `startArbitrage`.
     *
     * @dev The principal is ALREADY in this contract when this runs. Profit accounting, with
     *      `preExisting` = balance held before the service transferred the principal in:
     *
     *        baseBefore = preExisting + principal
     *        baseAfter  = preExisting + (USDC produced by the cycle)
     *        available  = baseAfter - preExisting = USDC produced by the cycle
     *        required   = principal + fee
     *        profit     = available - required
     *
     *      Because `available` subtracts `preExisting`, retained profits from previous cycles can
     *      never be used to service the current loan, and `profit` is exactly the surplus of this
     *      cycle (audit finding C1: the cycle always closes in the borrowed asset).
     */
    function onFlashLoanReceived(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory callbackData
    ) external override {
        if (msg.sender != flashLoanService) revert NotFlashLoanService(msg.sender);
        if (tokens.length != 1 || amounts.length != 1 || feeAmounts.length != 1) revert UnexpectedFlashLoan();
        if (address(tokens[0]) != baseToken) revert UnexpectedFlashLoan();
        if (callbackData.length != ROUTE_DATA_LENGTH) revert InvalidCallbackData(callbackData.length);

        RouteData memory route = abi.decode(callbackData, (RouteData));
        // Intentional deadline guard (plan D5): the window is `deadlineWindow` (>= 30s) and its
        // only purpose is to reject stale quotes, so sub-second validator skew is irrelevant.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > route.deadline) revert DeadlineExpired(route.deadline, block.timestamp);

        // Snapshot taken AFTER the service transferred the principal in.
        uint256 baseBefore = IERC20(baseToken).balanceOf(address(this));
        uint256 principal = amounts[0];
        if (baseBefore < principal) revert PrincipalNotReceived(principal, baseBefore);

        // Leg 1: buy quoteToken, on the venue selected by the owner.
        uint256 quoteOut = route.buyOnVenueA ? _buyOnV2(principal) : _buyOnV3(principal);

        // Leg 2: sell 100% of what leg 1 produced, always on the other venue.
        if (route.buyOnVenueA) {
            _sellOnV3(quoteOut);
        } else {
            _sellOnV2(quoteOut);
        }

        uint256 baseAfter = IERC20(baseToken).balanceOf(address(this));
        uint256 required = principal + feeAmounts[0];
        // what we could hand back to the service
        uint256 available = baseAfter - (baseBefore - principal);
        if (available < required) revert InsufficientRepayment(available, required);
        uint256 profit = available - required;
        if (profit < minProfit) revert MinProfitNotMet(profit, minProfit);

        IERC20(baseToken).forceApprove(flashLoanService, required);
        IERC20(baseToken).safeTransfer(flashLoanService, required);

        // Safe: the whole cycle unwinds atomically on any failure and the only external callers
        // (the service, the two routers) are trusted and already called above, so this log can
        // never survive an inconsistent state.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ArbitrageExecuted(principal, profit, route.buyOnVenueA);
    }

    // ==================== OFF-CHAIN QUOTING ====================

    /**
     * @notice Off-chain estimate of the cycle result. Not a guard: the on-chain guard is `minProfit`.
     * @param amount `baseToken` amount that would be borrowed.
     * @param buyOnVenueA Venue selector for leg 1, as in `startArbitrage`.
     * @return expectedOut Conservative `baseToken` amount the cycle is expected to produce.
     * @return expectedProfit `expectedOut - amount`, floored at 0 (0 means "not profitable").
     *
     * @dev The V2 leg uses the router's exact `getAmountsOut` quote. The V3 leg uses the `slot0`
     *      spot price, which does NOT model price impact, discounted by the pool fee and by
     *      `maxSlippageBps` - the very same value the contract accepts as `amountOutMinimum`.
     *      The two values are therefore comparable: `expectedProfit >= minProfit` means the
     *      contract would accept a trade of this size at this state.
     */
    function getExpectedProfit(uint256 amount, bool buyOnVenueA)
        external
        view
        returns (uint256 expectedOut, uint256 expectedProfit)
    {
        if (amount == 0) return (0, 0);

        uint256 quoteOut;
        if (buyOnVenueA) {
            quoteOut = _v2QuoteOut(amount, baseToken, quoteToken);
            expectedOut = _minOutV3(quoteOut, quoteToken, baseToken);
        } else {
            quoteOut = _minOutV3(amount, baseToken, quoteToken);
            expectedOut = _v2QuoteOut(quoteOut, quoteToken, baseToken);
        }
        expectedProfit = expectedOut > amount ? expectedOut - amount : 0;
    }

    // ==================== SWAP HELPERS ====================

    /// @dev Venue A, leg 1: exact `baseToken` in, as much `quoteToken` out as possible.
    function _buyOnV2(uint256 baseIn) private returns (uint256 quoteOut) {
        address[] memory path = _path(baseToken, quoteToken);
        uint256 minOut = _applySlippage(_v2QuoteOut(baseIn, baseToken, quoteToken));

        IERC20(baseToken).forceApprove(address(venueA), baseIn);
        uint256[] memory amounts = IUniswapV2Router02(venueA)
            .swapExactTokensForTokens(baseIn, minOut, path, address(this), deadlineForRouter());
        if (amounts.length != 2) revert InvalidSwapResult();
        quoteOut = amounts[1];
    }

    /// @dev Venue A, leg 2: exact `quoteToken` in, as much `baseToken` out as possible.
    function _sellOnV2(uint256 quoteIn) private returns (uint256 baseOut) {
        address[] memory path = _path(quoteToken, baseToken);
        uint256 minOut = _applySlippage(_v2QuoteOut(quoteIn, quoteToken, baseToken));

        IERC20(quoteToken).forceApprove(address(venueA), quoteIn);
        uint256[] memory amounts = IUniswapV2Router02(venueA)
            .swapExactTokensForTokens(quoteIn, minOut, path, address(this), deadlineForRouter());
        if (amounts.length != 2) revert InvalidSwapResult();
        baseOut = amounts[1];
    }

    /// @dev Venue B, leg 1: exact `baseToken` in, as much `quoteToken` out as possible.
    function _buyOnV3(uint256 baseIn) private returns (uint256 quoteOut) {
        IERC20(baseToken).forceApprove(address(venueB), baseIn);
        quoteOut = venueB.exactInputSingle(
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: baseToken,
                tokenOut: quoteToken,
                fee: VENUE_B_FEE,
                recipient: address(this),
                deadline: deadlineForRouter(),
                amountIn: baseIn,
                amountOutMinimum: _minOutV3(baseIn, baseToken, quoteToken),
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @dev Venue B, leg 2: exact `quoteToken` in, as much `baseToken` out as possible.
    function _sellOnV3(uint256 quoteIn) private returns (uint256 baseOut) {
        IERC20(quoteToken).forceApprove(address(venueB), quoteIn);
        baseOut = venueB.exactInputSingle(
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: quoteToken,
                tokenOut: baseToken,
                fee: VENUE_B_FEE,
                recipient: address(this),
                deadline: deadlineForRouter(),
                amountIn: quoteIn,
                amountOutMinimum: _minOutV3(quoteIn, quoteToken, baseToken),
                sqrtPriceLimitX96: 0
            })
        );
    }

    // ==================== QUOTING PRIMITIVES (plan D5) ====================

    /// @dev Slippage via balance-delta style haircut: `quote * (10000 - bps) / 10000`.
    function _applySlippage(uint256 amount) private view returns (uint256) {
        return (amount * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
    }

    /// @dev Exact V2 router quote of `amountIn` along a two-token path.
    function _v2QuoteOut(uint256 amountIn, address tokenIn, address tokenOut) private view returns (uint256) {
        uint256[] memory amounts = IUniswapV2Router02(venueA).getAmountsOut(amountIn, _path(tokenIn, tokenOut));
        if (amounts.length != 2) revert InvalidSwapResult();
        return amounts[1];
    }

    /// @dev Conservative `amountOutMinimum` for the V3 leg: slot0 spot quote, fee, then slippage.
    function _minOutV3(uint256 amountIn, address tokenIn, address tokenOut) private view returns (uint256) {
        return _applySlippage(_v3Quote(amountIn, tokenIn, tokenOut));
    }

    /**
     * @dev V3 quote from `slot0()`, exactly the mechanism of the reference `UniswapV3PluginDirect`
     *      (spot price, pool fee, no price impact modelling), but overflow-safe.
     *
     *      `sqrtPriceX96` is `sqrt(token1/token0) * 2^96`, so
     *        `priceX96 = sqrtPriceX96^2 / 2^96` is `token1 per token0` in Q64.96,
     *        token0 -> token1: `amountIn * priceX96 / 2^96`,
     *        token1 -> token0: `amountIn * 2^96 / priceX96`.
     *      `Math.mulDiv` is used instead of the reference's `x * x` / `x << 192` arithmetic:
     *      the results are identical (same floor divisions) but a pathological
     *      `sqrtPriceX96` can never wrap a `uint256` into a silently wrong price.
     */
    function _v3Quote(uint256 amountIn, address tokenIn, address tokenOut) private view returns (uint256) {
        IUniswapV3Pool pool = IUniswapV3Pool(_v3Pool(tokenIn, tokenOut));

        // Only sqrtPriceX96 is needed; slot0 is a single SLOAD, so skipping the remaining
        // tuple slots is free.
        // forge-lint: disable-next-line(unused-return)
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        if (sqrtPriceX96 == 0 || pool.liquidity() == 0) revert V3PoolNotFound();

        uint256 priceX96 = Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), SQRT_PRICE_SCALE);
        uint256 amountOut = tokenIn < tokenOut
            ? Math.mulDiv(amountIn, priceX96, SQRT_PRICE_SCALE)
            : Math.mulDiv(amountIn, SQRT_PRICE_SCALE, priceX96);

        // The pool keeps `VENUE_B_FEE` of every swap out of the recipient's amount.
        return (amountOut * (V3_FEE_DENOMINATOR - VENUE_B_FEE)) / V3_FEE_DENOMINATOR;
    }

    /**
     * @dev Resolves and validates the V3 pool for (tokenIn, tokenOut, `VENUE_B_FEE`).
     *      The CREATE2 pre-computation is cross-checked against the factory's own `getPool` and
     *      against the deployed bytecode, so a stale constant degrades to `V3PoolNotFound`
     *      instead of routing funds to an arbitrary address.
     */
    function _v3Pool(address tokenIn, address tokenOut) private view returns (address) {
        address pool = _computeV3Pool(tokenIn, tokenOut);
        if (pool.code.length == 0) revert V3PoolNotFound();
        if (IUniswapV3Factory(V3_FACTORY).getPool(tokenIn, tokenOut, VENUE_B_FEE) != pool) revert V3PoolNotFound();
        return pool;
    }

    /**
     * @dev CREATE2 address of a Uniswap V3 pool:
     *      `keccak256(0xff ++ factory ++ salt ++ initCodeHash)` with
     *      `salt = keccak256(abi.encode(token0, token1, fee))` (32-byte padded, as the factory
     *      hashes it) and `token0 < token1` sorted by address.
     */
    function _computeV3Pool(address tokenIn, address tokenOut) private pure returns (address) {
        (address token0, address token1) = tokenIn < tokenOut ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            V3_FACTORY,
                            keccak256(abi.encode(token0, token1, VENUE_B_FEE)),
                            V3_POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
    }

    // ==================== SMALL HELPERS ====================

    /// @dev Two-element router path. Both legs are single-hop, so the array is always length 2.
    function _path(address tokenIn, address tokenOut) private pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
    }

    /**
     * @dev Deadline handed to the routers.
     *      The callback has already proved `block.timestamp <= route.deadline`, and both the
     *      route deadline and this value are `block.timestamp + deadlineWindow` computed in the
     *      same transaction, so this reproduces exactly the validated bound and cannot expire
     *      between the check and the swap.
     */
    function deadlineForRouter() private view returns (uint256) {
        return block.timestamp + deadlineWindow;
    }
}
