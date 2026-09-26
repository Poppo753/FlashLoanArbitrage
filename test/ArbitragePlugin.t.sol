// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ArbitragePlugin} from "../contracts/ArbitragePlugin.sol";
import {FlashLoanService} from "../contracts/services/FlashLoanService.sol";
import {MockERC20} from "../helpers/Mocks.sol";
import {IUniswapV2Router02} from "../contracts/interfaces/IUniswapV2Router02.sol";
import {IUniswapV3Router} from "../contracts/interfaces/IUniswapV3Router.sol";
import {IUniswapV3Pool} from "../contracts/interfaces/IUniswapV3Pool.sol";
import {IFlashLoanRecipient} from "../contracts/interfaces/balancer/IBalancerVault.sol";

/* ============================================================================
 * TEST DOUBLES - canonical definitions live here
 * ============================================================================
 * `MockV3Pool`, `MockV3Factory`, `MockBalancerVault`, `MockV2Router` and
 * `MockV3Router` are defined in this file and nowhere else, so there is a single
 * source of truth and no risk of the suite and a helper drifting apart.
 *
 * They are deliberately not in `helpers/`: that directory is outside `src`, so
 * forge never compiles it unless a test imports it, and a latent error there
 * stays invisible until someone does. Keeping them next to their only consumer
 * makes the build cover them unconditionally.
 *
 * `MockV2Router.getAmountsOut` is `public` (not `external`) because
 * `swapExactTokensForTokens` calls it internally; Solidity rejects a bare call to
 * an `external` function. This matches the real `UniswapV2Router02`, where it is
 * likewise declared `public view`. Its constructor parameters are `factory_` and
 * `weth_` because a parameter named `factory` shadows the `factory()` getter.
 * ========================================================================= */

/// @notice Read-only Uniswap V3 pool stand-in: `slot0()` and `liquidity()` only.
contract MockV3Pool {
    uint160 internal _sqrtPriceX96;
    uint128 internal _liquidity;

    function setSqrtPriceX96(uint160 newSqrtPriceX96) external {
        _sqrtPriceX96 = newSqrtPriceX96;
    }

    function setLiquidity(uint128 newLiquidity) external {
        _liquidity = newLiquidity;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (_sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function liquidity() external view returns (uint128) {
        return _liquidity;
    }
}

/// @notice Returns a pool address, mirroring `UniswapV3Factory.getPool`.
contract MockV3Factory {
    mapping(uint24 => mapping(address => mapping(address => address))) internal _pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        _pools[fee][tokenA][tokenB] = pool;
        _pools[fee][tokenB][tokenA] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return _pools[fee][tokenA][tokenB];
    }
}

/// @notice Simulates the Balancer V2 vault flash loan: lend, call back, then require solvency.
contract MockBalancerVault {
    using SafeERC20 for IERC20;

    event FlashLoanCalled(address indexed recipient, address indexed token, uint256 amount);

    error VaultNotSolvent(address token, uint256 required, uint256 available);

    function flashLoan(IFlashLoanRecipient recipient, IERC20[] memory tokens, uint256[] memory amounts, bytes memory)
        external
    {
        uint256[] memory feeAmounts = new uint256[](amounts.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i].safeTransfer(address(recipient), amounts[i]);
            emit FlashLoanCalled(address(recipient), address(tokens[i]), amounts[i]);
        }

        recipient.receiveFlashLoan(tokens, amounts, feeAmounts, "");

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 required = amounts[i] + feeAmounts[i];
            uint256 available = tokens[i].balanceOf(address(this));
            if (available < required) revert VaultNotSolvent(address(tokens[i]), required, available);
        }
    }
}

/// @notice Constant-product Uniswap V2 compatible router (the subset the plugin uses).
/// @dev `getAmountsOut` is `public`, not `external`: it is called internally below, which
///      Solidity only permits for `public`/`internal` functions. See the header comment.
contract MockV2Router {
    using SafeERC20 for IERC20;

    address internal _factory;
    address internal _WETH;

    mapping(address => uint256) internal _reserves;

    event Swap(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    constructor(address factory_, address weth) {
        _factory = factory_;
        _WETH = weth;
    }

    function setReserve(address token, uint256 amount) external {
        _reserves[token] = amount;
    }

    function reserve(address token) external view returns (uint256) {
        return _reserves[token];
    }

    function factory() external view returns (address) {
        return _factory;
    }

    function WETH() external view returns (address) {
        return _WETH;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) public view returns (uint256[] memory amounts) {
        require(path.length == 2, "MockV2Router: only two-token paths");
        require(amountIn > 0, "MockV2Router: INSUFFICIENT_INPUT_AMOUNT");
        (uint256 reserveIn, uint256 reserveOut) = (_reserves[path[0]], _reserves[path[1]]);
        require(reserveIn > 0 && reserveOut > 0, "MockV2Router: INSUFFICIENT_LIQUIDITY");

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997);
        require(amounts[1] > 0, "MockV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
    }

    /// @dev Fires a one-shot external call in the middle of a swap, so a test can simulate a
    ///      venue re-entering the contract under test mid-cycle. The result is recorded rather
    ///      than bubbled: the caller decides whether the re-entrancy mattered.
    address public reentryTarget;
    bytes public reentryData;
    bool public reentrySucceeded;
    bytes public reentryReturnData;

    function setReentryHook(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(block.timestamp <= deadline, "MockV2Router: EXPIRED");

        if (reentryTarget != address(0)) {
            (reentrySucceeded, reentryReturnData) = reentryTarget.call(reentryData);
            reentryTarget = address(0);
        }

        amounts = getAmountsOut(amountIn, path);
        require(amounts[1] >= amountOutMin, "MockV2Router: INSUFFICIENT_OUTPUT_AMOUNT");

        address tokenIn = path[0];
        address tokenOut = path[1];
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(to, amounts[1]);

        _reserves[tokenIn] += amountIn;
        _reserves[tokenOut] -= amounts[1];

        emit Swap(tokenIn, tokenOut, amountIn, amounts[1]);
    }
}

/// @notice Uniswap V3 SwapRouter stand-in for the `exactInputSingle` leg.
/// @dev Prices off the same `MockV3Pool` the plugin quotes from, using the identical
///      spot-price formula and the same 0.05% pool fee, so the plugin's
///      `amountOutMinimum` (quote minus its slippage budget) is always satisfiable
///      while the executed amount stays realistic.
contract MockV3Router {
    using SafeERC20 for IERC20;

    uint256 internal constant SQRT_PRICE_SCALE = 1 << 96;
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;

    address public immutable pool;

    event Swap(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    constructor(address pool_) {
        pool = pool_;
    }

    function exactInputSingle(IUniswapV3Router.ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut)
    {
        require(params.sqrtPriceLimitX96 == 0, "MockV3Router: LIMIT_NOT_SUPPORTED");
        require(params.amountIn > 0, "MockV3Router: INSUFFICIENT_INPUT_AMOUNT");
        require(block.timestamp <= params.deadline, "MockV3Router: EXPIRED");

        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        require(sqrtPriceX96 != 0, "MockV3Router: POOL_NOT_INITIALIZED");

        uint256 priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) / SQRT_PRICE_SCALE;
        amountOut = params.tokenIn < params.tokenOut
            ? (params.amountIn * priceX96) / SQRT_PRICE_SCALE
            : (params.amountIn * SQRT_PRICE_SCALE) / priceX96;

        // The pool retains `fee` bps; the plugin's own quote subtracts the same fee.
        amountOut = (amountOut * (FEE_DENOMINATOR - params.fee)) / FEE_DENOMINATOR;
        require(amountOut >= params.amountOutMinimum, "MockV3Router: TOO_LITTLE_RECEIVED");

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);

        emit Swap(params.tokenIn, params.tokenOut, params.amountIn, amountOut);
    }
}

/**
 * @title ArbitragePluginTest
 * @notice Behavioural test suite for `ArbitragePlugin`, driven through the real
 *         `FlashLoanService` and the real Balancer V2 vault address.
 *
 * TEST TOPOLOGY
 *   The plugin is the production contract, and so is `FlashLoanService`. Three
 *   addresses are canonical on-chain constants and cannot be deployed locally, so the suite
 *   installs bytecode at them with `vm.etch` (the "hardcode the address, mock the behaviour"
 *   pattern; nothing in the contract under test is relaxed):
 *
 *     0x1F98431c8aD98523631AE4a59f267346ea31F984  UniswapV3Factory -> MockV3Factory
 *     0xBA12222222228d8Ba445958a75a0704d566BF2C8  Balancer V2 Vault -> MockBalancerVault
 *     CREATE2(0x1F98.., salt, V3_POOL_INIT_CODE_HASH) UniswapV3Pool     -> MockV3Pool
 *
 *   The third one is the interesting one: `ArbitragePlugin._v3Pool` never takes a pool address
 *   from its caller. It re-derives the pool with CREATE2 from two hardcoded constants and
 *   cross-checks the result against `factory.getPool(...)` and against `pool.code.length`.
 *   `test_V3PoolCreate2Address_MatchesCanonicalFormula` therefore proves something real about
 *   the contract: that its derivation is byte-for-byte the canonical Uniswap V3 derivation.
 *
 * PRICING MODEL
 *   base  = USDC (6 decimals)   quote = WETH (18 decimals)
 *
 *   Venue A (V2) is a constant-product pool whose quote is
 *       out = in * 997 * reserveOut / (reserveIn * 1000 + in * 997)
 *   so the reserves set the price, and the 0.3% swap fee is a real haircut.
 *
 *   Venue B (V3) is priced from `slot0().sqrtPriceX96`, which is exactly what the plugin
 *   quotes from, so the plugin's `amountOutMinimum` (its own quote minus `maxSlippageBps`)
 *   is always satisfiable and the two mocks never disagree by accident.
 *
 *   A profitable cycle is created by making the two venues disagree: WETH is CHEAP on the
 *   venue we buy from and EXPENSIVE on the venue we sell to. Everything the two venues need
 *   to believe is configured from a single human number, "USDC per WETH", so the arithmetic
 *   is readable and the decimal scaling is explicit (see `_setV3Price`).
 */
contract ArbitragePluginTest is Test {
    using SafeERC20 for IERC20;

    // ==================== CANONICAL CONSTANTS (mirrors of the contract's own constants) ====================

    /// @dev Uniswap V3 factory, hardcoded in `ArbitragePlugin` and identical on every chain.
    address internal constant V3_FACTORY_ADDRESS = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    /// @dev keccak256 of the real UniswapV3Pool creation code, hardcoded in `ArbitragePlugin`.
    bytes32 internal constant V3_POOL_INIT_CODE_HASH =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    /// @dev Balancer V2 vault, hardcoded in `FlashLoanService` and identical on every chain.
    address internal constant BALANCER_VAULT_ADDRESS = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    /// @dev The single V3 fee tier the plugin ever touches (`ArbitragePlugin.VENUE_B_FEE`).
    uint24 internal constant V3_FEE = 500;
    /// @dev Uniswap V3 expresses `fee` in 1e-6.
    uint256 internal constant V3_FEE_DENOMINATOR = 1_000_000;

    // ==================== NUMERIC CONSTANTS ====================

    /// @dev `slot0().sqrtPriceX96` is sqrt(token1/token0) in Q64.96.
    uint256 internal constant SQRT_PRICE_SCALE = 1 << 96;
    /// @dev `sqrtPriceX96 = sqrt(ratio * 2^192)`, so the helper squares exactly once.
    uint256 internal constant SQRT_PRICE_SCALE_SQUARED = 1 << 192;
    /// @dev 10 ** (18 - 6): the raw-unit ratio between WETH wei and USDC micro-units.
    uint256 internal constant DECIMAL_SHIFT_18_6 = 1e12;

    uint8 internal constant BASE_DECIMALS = 6;
    uint8 internal constant QUOTE_DECIMALS = 18;

    /// @dev Plugin construction parameters used by the whole suite.
    uint256 internal constant MAX_SLIPPAGE_BPS = 50;
    uint256 internal constant DEADLINE_WINDOW = 300;

    /// @dev Borrow size: 10,000 USDC, comfortably above `MIN_FLASH_LOAN` (1,000 wei).
    uint256 internal constant PRINCIPAL = 10_000e6;
    /// @dev Balancer liquidity available to lend.
    uint256 internal constant VAULT_LIQUIDITY = 1_000_000e6;
    /// @dev Fixed WETH reserve on venue A. The USDC reserve is derived from the target price.
    uint256 internal constant V2_WETH_RESERVE = 10_000e18;
    /// @dev Venue A's USDC float, so a swapped-in principal never runs the router dry.
    uint256 internal constant V2_USDC_FLOAT = 100_000_000e6;
    /// @dev Venue B's WETH float, so the sell leg always has inventory to pay out.
    uint256 internal constant V3_FLOAT = 10_000e18;
    /// @dev Venue B's USDC float, so the sell leg can always pay out base token.
    uint256 internal constant V3_USDC_FLOAT = 100_000_000e6;

    /// @dev "WETH costs 3,000 USDC on venue A" - the cheap venue in the happy-path tests.
    uint256 internal constant PRICE_CHEAP = 3_000;
    /// @dev "WETH costs 3,300 USDC on venue B" - the rich venue in the happy-path tests.
    uint256 internal constant PRICE_RICH = 3_300;
    /// @dev A price only 0.67% above venue A: barely more than the fee round trip.
    uint256 internal constant PRICE_NEARLY_EQUAL = 3_020;

    /// @dev Far-future route deadline, so callback tests never have to touch the clock.
    uint256 internal constant ROUTE_DEADLINE = 1 << 40;

    // ==================== STATE ====================

    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockV2Router internal venueA;
    MockV3Router internal venueB;
    MockV3Pool internal v3Pool;
    MockBalancerVault internal vault;
    ArbitragePlugin internal plugin;
    FlashLoanService internal service;

    /// @dev The address the plugin is forced to use for the (USDC, WETH, 500) V3 pool.
    address internal v3PoolAddress;

    address internal stranger;

    // ==================== EVENTS (mirrored so `vm.expectEmit` has something to declare) ====================

    event ArbitrageExecuted(uint256 principal, uint256 profit, bool buyOnVenueA);
    event MinProfitUpdated(uint256 previousMinProfit, uint256 newMinProfit);

    // ==================== SETUP ====================

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", BASE_DECIMALS, 0);
        weth = new MockERC20("Wrapped Ether", "WETH", QUOTE_DECIMALS, 0);

        venueA = new MockV2Router(makeAddr("v2Factory"), address(weth));

        // The plugin's V3 pool is resolved by CREATE2 from the canonical factory and init code
        // hash, so the mock pool has to sit at exactly that address before any call is made.
        v3PoolAddress = _canonicalV3PoolAddress(address(usdc), address(weth), V3_FEE);
        vm.etch(v3PoolAddress, type(MockV3Pool).runtimeCode);
        v3Pool = MockV3Pool(v3PoolAddress);

        vm.etch(V3_FACTORY_ADDRESS, type(MockV3Factory).runtimeCode);
        MockV3Factory(V3_FACTORY_ADDRESS).setPool(address(usdc), address(weth), V3_FEE, v3PoolAddress);

        v3Pool.setSqrtPriceX96(_sqrtPriceX96(PRICE_RICH));
        v3Pool.setLiquidity(1e18);

        // Venue B prices off the same pool the plugin quotes from, keeping quote and
        // execution consistent by construction. It needs inventory in BOTH tokens:
        // the buy leg pays it USDC, the sell leg pays it out in USDC.
        venueB = new MockV3Router(v3PoolAddress);
        weth.mint(address(venueB), V3_FLOAT);
        usdc.mint(address(venueB), V3_USDC_FLOAT);

        // The real `FlashLoanService` calls the hardcoded Balancer vault, so the mock vault has
        // to live there. Same "install behaviour at the canonical address" trick.
        vm.etch(BALANCER_VAULT_ADDRESS, type(MockBalancerVault).runtimeCode);
        vault = MockBalancerVault(BALANCER_VAULT_ADDRESS);

        usdc.mint(BALANCER_VAULT_ADDRESS, VAULT_LIQUIDITY);
        weth.mint(address(venueA), 4 * V2_WETH_RESERVE);
        usdc.mint(address(venueA), V2_USDC_FLOAT);

        _setV2Price(PRICE_CHEAP);
        _setV3Price(PRICE_RICH);

        plugin = _deployPlugin();
        service = new FlashLoanService(address(plugin));
        plugin.initialize(address(service));

        stranger = makeAddr("stranger");
    }

    // ==================== TEST 1 - HAPPY PATH ====================

    function test_StartArbitrage_ProfitableCycle_RepaysLoanAndKeepsProfit() public {
        _requireProfitable(PRINCIPAL, true);

        uint256 vaultBefore = usdc.balanceOf(BALANCER_VAULT_ADDRESS);
        uint256 profitBefore = usdc.balanceOf(address(plugin));
        uint256 expectedProfit = _cycleOutput(PRINCIPAL, true) - PRINCIPAL;

        vm.expectEmit(false, false, false, true, address(plugin));
        emit ArbitrageExecuted(PRINCIPAL, expectedProfit, true);
        plugin.startArbitrage(PRINCIPAL, true);

        // The plugin kept exactly the emitted profit, in the borrowed asset.
        assertEq(usdc.balanceOf(address(plugin)), profitBefore + expectedProfit, "profit not retained");
        // The vault is whole again: principal + 0% Balancer fee came back in full.
        assertEq(usdc.balanceOf(BALANCER_VAULT_ADDRESS), vaultBefore, "vault not made whole");
        // Both legs sold 100% of leg 1, so no quote token is stranded in the plugin.
        assertEq(weth.balanceOf(address(plugin)), 0, "quote token dust stranded");
        // Venue A was paid for the principal it swapped, as any AMM would be.
        assertEq(usdc.balanceOf(address(venueA)), V2_USDC_FLOAT + PRINCIPAL, "venue A did not receive the principal");
    }

    // ==================== TEST 2 - REVERSE DIRECTION ====================

    function test_StartArbitrage_ReverseDirection_ProfitableCycle() public {
        // Inverted prices: WETH is cheap on venue B (V3) and rich on venue A (V2), and the
        // owner asks for leg 1 to run on venue B.
        _setV2Price(PRICE_RICH);
        _setV3Price(PRICE_CHEAP);
        _requireProfitable(PRINCIPAL, false);

        uint256 vaultBefore = usdc.balanceOf(BALANCER_VAULT_ADDRESS);
        uint256 expectedProfit = _cycleOutput(PRINCIPAL, false) - PRINCIPAL;

        vm.expectEmit(false, false, false, true, address(plugin));
        emit ArbitrageExecuted(PRINCIPAL, expectedProfit, false);
        plugin.startArbitrage(PRINCIPAL, false);

        assertEq(usdc.balanceOf(address(plugin)), expectedProfit, "profit not retained");
        assertEq(usdc.balanceOf(BALANCER_VAULT_ADDRESS), vaultBefore, "vault not made whole");
        assertEq(weth.balanceOf(address(plugin)), 0, "quote token dust stranded");
    }

    // ==================== TEST 3 - DIRECTION SYMMETRY ====================

    function test_StartArbitrage_BothDirections_AreSymmetric() public {
        // Direction A: buy cheap on V2, sell rich on V3.
        _setV2Price(PRICE_CHEAP);
        _setV3Price(PRICE_RICH);
        uint256 profitA = _requireProfitable(PRINCIPAL, true) - PRINCIPAL;

        vm.expectEmit(false, false, false, true, address(plugin));
        emit ArbitrageExecuted(PRINCIPAL, profitA, true);
        plugin.startArbitrage(PRINCIPAL, true);
        assertEq(usdc.balanceOf(address(plugin)), profitA, "direction A profit wrong");

        // Direction B: identical size, opposite venue ordering, prices swapped between venues.
        // The V2 reserves are rewound so the second cycle is quoted from a pristine pool.
        _setV2Price(PRICE_RICH);
        _setV3Price(PRICE_CHEAP);
        uint256 profitB = _requireProfitable(PRINCIPAL, false) - PRINCIPAL;

        vm.expectEmit(false, false, false, true, address(plugin));
        emit ArbitrageExecuted(PRINCIPAL, profitB, false);
        plugin.startArbitrage(PRINCIPAL, false);

        // Both directions kept their own profit; neither leg's sign or ordering is inverted.
        assertEq(usdc.balanceOf(address(plugin)), profitA + profitB, "direction B profit wrong");
        assertGt(profitA, 0, "direction A not profitable");
        assertGt(profitB, 0, "direction B not profitable");
        assertEq(weth.balanceOf(address(plugin)), 0, "quote token dust stranded");
        assertEq(usdc.balanceOf(BALANCER_VAULT_ADDRESS), VAULT_LIQUIDITY, "vault not made whole");
    }

    // ==================== TEST 4 - PROFITABILITY FLOOR ====================

    function test_StartArbitrage_ProfitBelowMinProfit_Reverts() public {
        // Venue B is only 0.67% above venue A. The cycle still clears Balancer's 0% fee, but
        // only by a sliver - far below the owner's floor.
        _setV2Price(PRICE_CHEAP);
        _setV3Price(PRICE_NEARLY_EQUAL);

        uint256 sliverProfit = _cycleOutput(PRINCIPAL, true) - PRINCIPAL;
        uint256 floor = 1_000e6;
        plugin.setMinProfit(floor);
        assertLt(sliverProfit, floor, "premise: the cycle must fall short of minProfit");

        vm.expectRevert(abi.encodeWithSelector(ArbitragePlugin.MinProfitNotMet.selector, sliverProfit, floor));
        plugin.startArbitrage(PRINCIPAL, true);

        assertEq(usdc.balanceOf(address(plugin)), 0, "a rejected cycle must leave no funds behind");
    }

    // ==================== TEST 5 - ACCESS CONTROL ====================

    function test_StartArbitrage_OnlyOwnerCanStart() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        plugin.startArbitrage(PRINCIPAL, true);

        // Even the address the service trusts is not the owner, so it is rejected too.
        vm.prank(address(service));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(service)));
        plugin.startArbitrage(PRINCIPAL, true);
    }

    // ==================== TEST 6 - PAUSE ====================

    function test_StartArbitrage_WhenPaused_Reverts() public {
        plugin.pause();
        assertTrue(plugin.paused(), "premise: the plugin must be paused");

        vm.expectRevert(Pausable.EnforcedPause.selector);
        plugin.startArbitrage(PRINCIPAL, true);

        // The owner can resume, and the same call then succeeds.
        plugin.unpause();
        _requireProfitable(PRINCIPAL, true);
        plugin.startArbitrage(PRINCIPAL, true);
    }

    // ==================== TEST 7 - UNINITIALIZED SERVICE ====================

    function test_StartArbitrage_BeforeInitialize_Reverts() public {
        ArbitragePlugin fresh = _deployPlugin();
        assertEq(fresh.flashLoanService(), address(0), "premise: the plugin must be uninitialized");

        vm.expectRevert(ArbitragePlugin.FlashLoanNotInitialized.selector);
        fresh.startArbitrage(PRINCIPAL, true);
    }

    // ==================== TEST 8 - BORROW SIZE FLOOR ====================

    function test_StartArbitrage_AmountBelowMinimum_Reverts() public {
        uint256 floor = plugin.MIN_FLASH_LOAN();
        assertEq(floor, 1_000, "MIN_FLASH_LOAN changed");

        vm.expectRevert(abi.encodeWithSelector(ArbitragePlugin.AmountBelowMinimum.selector, floor - 1, floor));
        plugin.startArbitrage(floor - 1, true);

        // Zero is rejected as a distinct, more specific error.
        vm.expectRevert(abi.encodeWithSelector(ArbitragePlugin.InvalidAmount.selector, uint256(0)));
        plugin.startArbitrage(0, true);
    }

    // ==================== TEST 9 - INITIALIZE IS ONE-SHOT ====================

    function test_Initialize_SecondCall_Reverts() public {
        vm.expectRevert(ArbitragePlugin.AlreadyInitialized.selector);
        plugin.initialize(address(service));

        vm.expectRevert(ArbitragePlugin.AlreadyInitialized.selector);
        plugin.initialize(makeAddr("anotherService"));

        // The binding is untouched by the rejected calls.
        assertEq(plugin.flashLoanService(), address(service), "service must be unchanged");
    }

    // ==================== TEST 10 - INITIALIZE VALIDATES ITS ARGUMENT ====================

    function test_Initialize_ZeroAddress_Reverts() public {
        ArbitragePlugin fresh = _deployPlugin();

        vm.expectRevert(ArbitragePlugin.InvalidAddress.selector);
        fresh.initialize(address(0));

        // A rejected initialize must not consume the one allowed call.
        fresh.initialize(address(service));
        assertEq(fresh.flashLoanService(), address(service), "initialize should still be available");
    }

    // ==================== TEST 11 - CALLBACK AUTHENTICATION ====================

    function test_Callback_FromUnauthorizedCaller_Reverts() public {
        (IERC20[] memory tokens, uint256[] memory amounts, uint256[] memory fees, bytes memory data) =
            _validFlashLoanShape(PRINCIPAL, true);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ArbitragePlugin.NotFlashLoanService.selector, stranger));
        plugin.onFlashLoanReceived(tokens, amounts, fees, data);

        // The owner is privileged for `startArbitrage` but not for the callback.
        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(ArbitragePlugin.NotFlashLoanService.selector, address(this)));
        plugin.onFlashLoanReceived(tokens, amounts, fees, data);
    }

    // ==================== TEST 12 - CALLBACK LOAN SHAPE ====================

    function test_Callback_WithWrongToken_Reverts() public {
        (,,, bytes memory data) = _validFlashLoanShape(PRINCIPAL, true);

        // Same service, same lengths, wrong asset.
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(weth));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = PRINCIPAL;
        uint256[] memory fees = new uint256[](1);

        vm.prank(address(service));
        vm.expectRevert(ArbitragePlugin.UnexpectedFlashLoan.selector);
        plugin.onFlashLoanReceived(tokens, amounts, fees, data);

        // The same error guards every malformed array shape the plugin was told to expect.
        IERC20[] memory twoTokens = new IERC20[](2);
        twoTokens[0] = IERC20(address(usdc));
        twoTokens[1] = IERC20(address(usdc));
        uint256[] memory twoAmounts = new uint256[](2);
        twoAmounts[0] = PRINCIPAL;
        twoAmounts[1] = PRINCIPAL;
        uint256[] memory twoFees = new uint256[](2);

        vm.prank(address(service));
        vm.expectRevert(ArbitragePlugin.UnexpectedFlashLoan.selector);
        plugin.onFlashLoanReceived(twoTokens, twoAmounts, twoFees, data);
    }

    // ==================== TEST 13 - CALLBACK PAYLOAD LENGTH ====================

    function test_Callback_WithMalformedCallbackData_Reverts() public {
        (IERC20[] memory tokens, uint256[] memory amounts, uint256[] memory fees,) =
            _validFlashLoanShape(PRINCIPAL, true);

        bytes memory tooShort = hex"1234";
        vm.prank(address(service));
        vm.expectRevert(abi.encodeWithSelector(ArbitragePlugin.InvalidCallbackData.selector, tooShort.length));
        plugin.onFlashLoanReceived(tokens, amounts, fees, tooShort);

        // Right concept, wrong width: three words instead of `abi.encode(RouteData)`.
        bytes memory tooLong = abi.encode(true, ROUTE_DEADLINE, uint256(0));
        vm.prank(address(service));
        vm.expectRevert(abi.encodeWithSelector(ArbitragePlugin.InvalidCallbackData.selector, tooLong.length));
        plugin.onFlashLoanReceived(tokens, amounts, fees, tooLong);

        // An empty payload is rejected as well.
        bytes memory empty = "";
        vm.prank(address(service));
        vm.expectRevert(abi.encodeWithSelector(ArbitragePlugin.InvalidCallbackData.selector, uint256(0)));
        plugin.onFlashLoanReceived(tokens, amounts, fees, empty);
    }

    // ==================== TEST 14 - UNPROFITABLE CYCLE CANNOT REPAY ====================

    function test_CycleThatCannotRepay_Reverts() public {
        // Both venues at the same price: the round trip loses exactly the difference between
        // venue A's 0.3% and venue B's 0.05%, so the cycle cannot even return the principal.
        _setV2Price(PRICE_CHEAP);
        _setV3Price(PRICE_CHEAP);

        uint256 produced = _cycleOutput(PRINCIPAL, true);
        assertLt(produced, PRINCIPAL, "premise: the cycle must produce less than the principal");

        // `InsufficientRepayment` is raised by the PLUGIN, inside the callback, before the
        // service or the vault get a chance to notice anything. The vault's `VaultNotSolvent`
        // is never reached, and the real service's own `InsufficientRepayment` is never reached
        // either - the plugin reverts first.
        vm.expectRevert(abi.encodeWithSelector(ArbitragePlugin.InsufficientRepayment.selector, produced, PRINCIPAL));
        plugin.startArbitrage(PRINCIPAL, true);

        assertEq(usdc.balanceOf(BALANCER_VAULT_ADDRESS), VAULT_LIQUIDITY, "vault must be untouched");
    }

    // ==================== TEST 15 - AUDIT C1 REGRESSION ====================

    function test_RetainedProfitCannotRepayALosingCycle() public {
        // Simulate a previous cycle that left a fat profit sitting in the plugin.
        uint256 retained = 10_000_000e6;
        usdc.mint(address(plugin), retained);

        _setV2Price(PRICE_CHEAP);
        _setV3Price(PRICE_CHEAP);

        uint256 produced = _cycleOutput(PRINCIPAL, true);
        assertLt(produced, PRINCIPAL, "premise: the cycle must produce less than the principal");

        // The retained profit is explicitly NOT counted towards repayment: the plugin measures
        // only what THIS cycle produced, so the cycle still fails.
        vm.expectRevert(abi.encodeWithSelector(ArbitragePlugin.InsufficientRepayment.selector, produced, PRINCIPAL));
        plugin.startArbitrage(PRINCIPAL, true);

        assertEq(usdc.balanceOf(address(plugin)), retained, "retained profit must be untouched");
    }

    // ==================== TEST 16 - WITHDRAWALS ====================

    function test_WithdrawToken_SendsToChosenAddress() public {
        uint256 profit = 5_000e6;
        usdc.mint(address(plugin), profit);
        address recipient = makeAddr("treasury");

        plugin.withdrawToken(address(usdc), recipient, profit);

        assertEq(usdc.balanceOf(recipient), profit, "recipient not paid");
        assertEq(usdc.balanceOf(address(plugin)), 0, "plugin balance not drained");

        // The zero recipient is rejected.
        vm.expectRevert(ArbitragePlugin.InvalidAddress.selector);
        plugin.withdrawToken(address(usdc), address(0), 1);

        // And nobody else may move retained profits.
        usdc.mint(address(plugin), profit);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        plugin.withdrawToken(address(usdc), stranger, profit);
    }

    /**
     * @dev While a cycle is mid-flight the principal is only on loan from the vault, so a
     *      withdrawal must be refused. Reached by having venue A re-enter the plugin during
     *      leg 1, which is the only way a call can land inside the callback: `venueA` is an
     *      immutable chosen by the owner at construction, so this exercises the trust boundary
     *      rather than an unprivileged attack path.
     */
    function test_WithdrawToken_RevertsDuringACycle() public {
        _setV2Price(PRICE_CHEAP);
        _setV3Price(PRICE_RICH);
        usdc.mint(address(venueA), V2_USDC_FLOAT);

        // Arm venue A to try to pull the principal out of the plugin during leg 1. The router is
        // NOT the owner, so this call would be rejected by `onlyOwner` on its own; routing the
        // withdrawal through the test contract (the owner) via a tiny trampoline is what
        // actually reaches the `CycleInProgress` guard.
        venueA.setReentryHook(address(this), abi.encodeCall(this.tryWithdrawDuringCycle, ()));

        plugin.startArbitrage(PRINCIPAL, true);

        // The cycle itself completed, but the re-entrant withdrawal did not: the mock recorded
        // the failure instead of bubbling it, so the cycle was unaffected.
        assertFalse(venueA.reentrySucceeded(), "mid-cycle withdrawal must not succeed");
        assertEq(
            bytes4(venueA.reentryReturnData()),
            ArbitragePlugin.CycleInProgress.selector,
            "mid-cycle withdrawal must fail with CycleInProgress"
        );

        // And the principal was repaid, so the vault came out whole.
        assertEq(usdc.balanceOf(address(vault)), VAULT_LIQUIDITY, "vault must end whole");
    }

    /// @dev Reached re-entrantly from the venue during a cycle. As the owner it clears `onlyOwner`,
    ///      so the only thing that can stop the withdrawal is the `CycleInProgress` guard.
    function tryWithdrawDuringCycle() external {
        plugin.withdrawToken(address(usdc), address(this), PRINCIPAL);
    }

    // ==================== TEST 17 - VIEW QUOTE VS REALISED PROFIT ====================

    function test_GetExpectedProfit_AgreesWithExecutedProfit() public {
        // The view applies `maxSlippageBps` to the V3 leg's quote, so it is deliberately
        // conservative. Tolerance: 1% of the expected cycle output, comfortably above the
        // 0.5% haircut the view itself applies plus the V2 marginal-rate effect it inherits.
        uint256 toleranceBps = 100;

        _setV2Price(PRICE_CHEAP);
        _setV3Price(PRICE_RICH);
        uint256 balanceBefore = usdc.balanceOf(address(plugin));
        (uint256 outA, uint256 quotedProfitA) = plugin.getExpectedProfit(PRINCIPAL, true);
        assertGt(outA, PRINCIPAL, "premise: direction A must look profitable in the view");

        plugin.startArbitrage(PRINCIPAL, true);
        uint256 realisedA = usdc.balanceOf(address(plugin)) - balanceBefore;
        assertGe(realisedA, quotedProfitA, "view quote must be conservative");
        assertLe(realisedA - quotedProfitA, (outA * toleranceBps) / 10_000, "view quote too far from reality");

        _setV2Price(PRICE_RICH);
        _setV3Price(PRICE_CHEAP);
        balanceBefore = usdc.balanceOf(address(plugin));
        (uint256 outB, uint256 quotedProfitB) = plugin.getExpectedProfit(PRINCIPAL, false);
        assertGt(outB, PRINCIPAL, "premise: direction B must look profitable in the view");

        plugin.startArbitrage(PRINCIPAL, false);
        uint256 realisedB = usdc.balanceOf(address(plugin)) - balanceBefore;
        assertGe(realisedB, quotedProfitB, "view quote must be conservative");
        assertLe(realisedB - quotedProfitB, (outB * toleranceBps) / 10_000, "view quote too far from reality");

        // A zero-size quote is reported as zero rather than as a negative number.
        (uint256 flatOut, uint256 flatProfit) = plugin.getExpectedProfit(0, true);
        assertEq(flatOut, 0, "zero size must quote zero");
        assertEq(flatProfit, 0, "zero size must quote zero profit");
    }

    // ==================== TEST 18 - ADMIN SURFACE ====================

    function test_SetMinProfit_OnlyOwner() public {
        vm.expectEmit(false, false, false, true, address(plugin));
        emit MinProfitUpdated(0, 250e6);
        plugin.setMinProfit(250e6);
        assertEq(plugin.minProfit(), 250e6, "minProfit not stored");

        vm.expectEmit(false, false, false, true, address(plugin));
        emit MinProfitUpdated(250e6, 0);
        plugin.setMinProfit(0);
        assertEq(plugin.minProfit(), 0, "minProfit not reset");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        plugin.setMinProfit(1);
    }

    function test_Constructor_RejectsInvalidParameters() public {
        address base = address(usdc);
        address quote = address(weth);
        address a = address(venueA);
        address b = address(venueB);

        // Every required address must be set.
        for (uint256 i = 0; i < 4; i++) {
            address[] memory broken = new address[](4);
            (broken[0], broken[1], broken[2], broken[3]) = (base, quote, a, b);
            broken[i] = address(0);
            vm.expectRevert(ArbitragePlugin.InvalidAddress.selector);
            new ArbitragePlugin(broken[0], broken[1], broken[2], broken[3], MAX_SLIPPAGE_BPS, DEADLINE_WINDOW);
        }

        // A degenerate cycle (base == quote) is rejected.
        vm.expectRevert(ArbitragePlugin.InvalidTokenPair.selector);
        new ArbitragePlugin(base, base, a, b, MAX_SLIPPAGE_BPS, DEADLINE_WINDOW);

        // Slippage cap is 2000 bps inclusive.
        vm.expectRevert(abi.encodeWithSelector(ArbitragePlugin.InvalidSlippage.selector, uint256(2001)));
        new ArbitragePlugin(base, quote, a, b, 2001, DEADLINE_WINDOW);

        // Deadline window is [30, 3600] inclusive.
        vm.expectRevert(abi.encodeWithSelector(ArbitragePlugin.InvalidDeadlineWindow.selector, uint256(29)));
        new ArbitragePlugin(base, quote, a, b, MAX_SLIPPAGE_BPS, 29);
        vm.expectRevert(abi.encodeWithSelector(ArbitragePlugin.InvalidDeadlineWindow.selector, uint256(3601)));
        new ArbitragePlugin(base, quote, a, b, MAX_SLIPPAGE_BPS, 3601);

        // The boundary values themselves are accepted and stored verbatim.
        ArbitragePlugin atCap = new ArbitragePlugin(base, quote, a, b, 2000, 3600);
        assertEq(atCap.maxSlippageBps(), 2000, "cap not stored");
        assertEq(atCap.deadlineWindow(), 3600, "window not stored");
        assertEq(atCap.baseToken(), base, "base token not stored");
        assertEq(atCap.quoteToken(), quote, "quote token not stored");
        assertEq(address(atCap.venueA()), a, "venue A not stored");
        assertEq(address(atCap.venueB()), b, "venue B not stored");
        assertEq(atCap.owner(), address(this), "deployer must own the plugin");
    }

    // ==================== TEST 19 - CREATE2 POOL DERIVATION ====================

    function test_V3PoolCreate2Address_MatchesCanonicalFormula() public {
        (address token0, address token1) =
            address(usdc) < address(weth) ? (address(usdc), address(weth)) : (address(weth), address(usdc));

        // The canonical Uniswap V3 derivation, computed here from first principles:
        //   salt = keccak256(abi.encode(token0, token1, fee))   (token0 < token1, fee in 1e-6)
        //   pool = keccak256(0xff ++ factory ++ salt ++ keccak256(UniswapV3Pool init code))
        // and the low 20 bytes of that hash are the address.
        bytes32 salt = keccak256(abi.encode(token0, token1, V3_FEE));
        address canonical = address(
            uint160(uint256(keccak256(abi.encodePacked(hex"ff", V3_FACTORY_ADDRESS, salt, V3_POOL_INIT_CODE_HASH))))
        );
        assertEq(v3PoolAddress, canonical, "test-side CREATE2 derivation disagrees with the contract");
        assertTrue(address(v3Pool).code.length > 0, "premise: bytecode must be installed at the derived address");

        // The plugin accepts that address: it quotes through it instead of `V3PoolNotFound`.
        (uint256 expectedOut,) = plugin.getExpectedProfit(PRINCIPAL, true);
        assertGt(expectedOut, 0, "plugin failed to quote through the canonical pool");

        // Negative control 1: the factory pointing anywhere else is rejected.
        address wrong = address(uint160(uint256(keccak256("not the canonical pool"))));
        vm.etch(wrong, type(MockV3Pool).runtimeCode);
        MockV3Factory(V3_FACTORY_ADDRESS).setPool(address(usdc), address(weth), V3_FEE, wrong);
        vm.expectRevert(ArbitragePlugin.V3PoolNotFound.selector);
        plugin.getExpectedProfit(PRINCIPAL, true);

        // Negative control 2: right address, no deployed bytecode.
        MockV3Factory(V3_FACTORY_ADDRESS).setPool(address(usdc), address(weth), V3_FEE, v3PoolAddress);
        vm.etch(v3PoolAddress, "");
        vm.expectRevert(ArbitragePlugin.V3PoolNotFound.selector);
        plugin.getExpectedProfit(PRINCIPAL, true);
    }

    // ==================== PRICING HELPERS ====================

    /**
     * @dev Sets venue A's price from a single human number: "1 WETH costs `usdcPerEth` USDC".
     *
     *      The V2 quote is `out = in * 997 * rOut / (rIn * 1000 + in * 997)`, so the *marginal*
     *      rate is `0.997 * rOut / rIn` and the pool's true ask is `usdcPerEth / 0.997`.
     *      Choosing `rUsdc = rWeth * usdcPerEth / 1e12` makes that marginal rate
     *      `0.997 * 1e12 / usdcPerEth` raw units - i.e. exactly the price the V3 pool is given -
     *      so both venues are configured from one number and stay directly comparable.
     */
    function _setV2Price(uint256 usdcPerEth) internal {
        uint256 rUsdc = (V2_WETH_RESERVE * usdcPerEth) / DECIMAL_SHIFT_18_6;
        venueA.setReserve(address(usdc), rUsdc);
        venueA.setReserve(address(weth), V2_WETH_RESERVE);
    }

    /**
     * @dev Sets venue B's price from a single human number: "1 WETH costs `usdcPerEth` USDC".
     *
     *      `sqrtPriceX96` is defined as `sqrt(token1 / token0) * 2^96` where the ratio is in RAW
     *      units, so the decimal scaling has to be undone before the price is encoded:
     *
     *        - USDC is token0 (6 decimals), WETH is token1 (18 decimals):
     *              raw WETH-wei per raw USDC-unit = 1e12 / usdcPerEth
     *          (one whole WETH is `usdcPerEth` whole USDC, so one raw USDC unit - worth
     *          `1e-6 / usdcPerEth` WETH - is worth `1e-6/usdcPerEth * 1e18 = 1e12/usdcPerEth`
     *          raw WETH units)
     *        - WETH is token0 (18 decimals), USDC is token1 (6 decimals):
     *              raw USDC-units per raw WETH-wei = usdcPerEth / 1e12
     *
     *      `sqrt(x * 2^192) == floor(sqrt(x) * 2^96)`, which is exactly the encoding wanted and
     *      costs a single `Math.sqrt`.
     */
    function _setV3Price(uint256 usdcPerEth) internal {
        v3Pool.setSqrtPriceX96(_sqrtPriceX96(usdcPerEth));
    }

    function _sqrtPriceX96(uint256 usdcPerEth) internal view returns (uint160) {
        // rawRatio is a fraction below 1 in the USDC-token0 case, so dividing first would
        // truncate to zero. Keep it as n/d and fold the scaling in before the sqrt:
        //   sqrtPriceX96 = floor(sqrt(n * 2^192 / d))
        // n*2^192 stays far below 2^256 (worst case ~1.9e67), and the single division
        // discards a relative error below 1e-18, which is irrelevant at 1e24 magnitudes.
        (uint256 n, uint256 d) = address(usdc) < address(weth)
            ? (10 ** QUOTE_DECIMALS, usdcPerEth * 10 ** BASE_DECIMALS)  // token0 = USDC
            : (usdcPerEth * 10 ** BASE_DECIMALS, 10 ** QUOTE_DECIMALS); // token0 = WETH
        assertGt(n, 0, "numerator must be positive");
        return uint160(Math.sqrt((n * SQRT_PRICE_SCALE_SQUARED) / d));
    }

    // ==================== QUOTE REPLICAS (test-side, exact) ====================

    /// @dev Exact venue A quote, i.e. what `MockV2Router.getAmountsOut` will return.
    function _v2Out(uint256 amountIn, address tokenIn, address tokenOut) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        return venueA.getAmountsOut(amountIn, path)[1];
    }

    /// @dev Exact venue B quote: the same slot0 spot price and the same 0.05% fee the plugin uses.
    function _v3Out(uint256 amountIn, address tokenIn, address tokenOut) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        uint256 priceX96 = Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), SQRT_PRICE_SCALE);
        uint256 out = tokenIn < tokenOut
            ? Math.mulDiv(amountIn, priceX96, SQRT_PRICE_SCALE)
            : Math.mulDiv(amountIn, SQRT_PRICE_SCALE, priceX96);
        return (out * (V3_FEE_DENOMINATOR - V3_FEE)) / V3_FEE_DENOMINATOR;
    }

    /// @dev The `baseToken` the cycle is expected to end with, before repayment.
    function _cycleOutput(uint256 amount, bool buyOnVenueA) internal view returns (uint256) {
        if (buyOnVenueA) {
            return _v3Out(_v2Out(amount, address(usdc), address(weth)), address(weth), address(usdc));
        }
        return _v2Out(_v3Out(amount, address(usdc), address(weth)), address(weth), address(usdc));
    }

    /// @dev Proves the configured prices really are arbitrageable before any call is made.
    function _requireProfitable(uint256 amount, bool buyOnVenueA) internal view returns (uint256) {
        uint256 out = _cycleOutput(amount, buyOnVenueA);
        assertGt(out, amount, "premise: the configured cycle is not profitable");
        return out;
    }

    // ==================== DEPLOYMENT HELPERS ====================

    function _deployPlugin() internal returns (ArbitragePlugin) {
        return new ArbitragePlugin(
            address(usdc), address(weth), address(venueA), address(venueB), MAX_SLIPPAGE_BPS, DEADLINE_WINDOW
        );
    }

    /// @dev A well-formed `[baseToken], [amount], [0 fee], abi.encode(RouteData)` flash loan.
    function _validFlashLoanShape(uint256 amount, bool buyOnVenueA)
        internal
        view
        returns (IERC20[] memory tokens, uint256[] memory amounts, uint256[] memory fees, bytes memory data)
    {
        tokens = new IERC20[](1);
        tokens[0] = IERC20(address(usdc));
        amounts = new uint256[](1);
        amounts[0] = amount;
        fees = new uint256[](1);
        data = abi.encode(buyOnVenueA, ROUTE_DEADLINE);
    }

    /// @dev Canonical Uniswap V3 CREATE2 pool address, derived independently of the contract.
    function _canonicalV3PoolAddress(address tokenA, address tokenB, uint24 fee) internal pure returns (address) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 salt = keccak256(abi.encode(token0, token1, fee));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(hex"ff", V3_FACTORY_ADDRESS, salt, V3_POOL_INIT_CODE_HASH))))
        );
    }
}
