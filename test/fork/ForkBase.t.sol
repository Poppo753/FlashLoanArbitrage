// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ArbitragePlugin} from "../../contracts/ArbitragePlugin.sol";
import {FlashLoanService} from "../../contracts/services/FlashLoanService.sol";
import {IUniswapV2Factory} from "../../contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "../../contracts/interfaces/IUniswapV2Router02.sol";
import {IUniswapV3Pool} from "../../contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Router} from "../../contracts/interfaces/IUniswapV3Router.sol";

/* ============================================================================
 * FORK-SUITE RULES
 * ============================================================================
 * 1. THE PIN IS MANDATORY. Always run these suites with
 *
 *        forge test --match-path "test/fork/*" --fork-url arbitrum --fork-block-number <PIN>
 *
 *    `FORK_BLOCK` below is the block every number in this suite was measured at. Without
 *    `--fork-block-number` forge forks at `latest`, and the whole point of this suite is
 *    that the numbers are reproducible: the WETH/USDC V2 pair holds only ~10.3 WETH, so a
 *    single block of real trading moves every figure in these tests. `test_PinIsHonoured`
 *    in every concrete suite fails loudly if the run does not sit on the pin.
 *
 * 2. PLAIN `forge test` STAYS GREEN. Every concrete test opens with
 *    `if (!forkEnabled()) { vm.skip(true); return; }`, and `setUp()` performs no RPC read
 *    (it only deploys and wires contracts), so a non-fork run touches no network at all.
 *    This is the same "this.skip()" pattern the reference Hardhat suite uses.
 *
 * 3. `forkEnabled()` is true when `FORK_ENABLED=true` is exported OR when forge is already
 *    running against a fork (`vm.activeFork() > 0`), so the documented command in (1) works
 *    with or without the environment variable. It is false for a bare `forge test`.
 *
 * 4. `FORK_BLOCK_NUMBER` overrides the pin without editing code. The pin is the
 *    authoritative default; the env var exists so a block can be re-pinned for a
 *    re-measurement and every suite follows the same number.
 * ========================================================================= */

/* ============================================================================
 * LOCAL INTERFACE SLICES
 * ============================================================================
 * `contracts/interfaces/` intentionally holds only what the contracts under test need, so the
 * two read-only members the TESTS need - the V2 pair's reserves and the V3 pool's token
 * ordering - are declared here rather than widening the production interface set.
 * ========================================================================= */

/// @notice Read-only slice of a Uniswap V2 pair: reserves and token ordering.
interface IV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
}

/// @notice Read-only slice of a Uniswap V3 pool: token ordering, to make decimal assumptions explicit.
interface IV3PoolOrder {
    function token0() external view returns (address);
}

/**
 * @title ForkBase
 * @notice Shared setup for the Arbitrum-mainnet fork suites.
 *
 * WHY A FORK AT ALL
 *   The production architecture hardcodes three things that cannot be deployed locally: the
 *   Balancer V2 vault address, the Uniswap V3 factory address and - through them - the CREATE2
 *   address of the WETH/USDC 0.05% pool. `test/ArbitragePlugin.t.sol` installs bytecode at
 *   those addresses with `vm.etch`, which proves the contract's logic but proves nothing about
 *   the real deployments. These fork suites run the SAME contracts against the SAME addresses
 *   with the REAL bytecode behind them: the real vault really holds the liquidity, the real
 *   V3 pool really holds the liquidity, and the real routers really enforce their own
 *   `amountOutMinimum` and `deadline`.
 *
 * WHAT SETUP DOES
 *   Deploys the real `ArbitragePlugin` and the real `FlashLoanService` on the fork, wires them
 *   in the only legal order (plugin first, because the service needs `address(plugin)` at ITS
 *   construction), and asserts the wiring. No RPC read happens here, so a skipped test costs
 *   nothing on a non-fork run.
 */
abstract contract ForkBase is Test {
    using SafeERC20 for IERC20;

    // ==================== ARBITRUM MAINNET ADDRESSES (chainId 42161) ====================

    /// @dev Wrapped Ether, 18 decimals. The intermediate ("quote") asset of the cycle.
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    /// @dev Circle native USDC, 6 decimals. The borrowed ("base") and profit asset.
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    /// @dev Uniswap V2 Router02, official Arbitrum deployment. Venue A.
    address internal constant V2_ROUTER = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
    /// @dev Uniswap V2 Factory, official Arbitrum deployment.
    address internal constant V2_FACTORY = 0xf1D7CC64Fb4452F05c498126312eBE29f30Fbcf9;
    /// @dev V2 WETH/USDC pair. token0 = WETH. Thin: ~10.3 WETH / ~27.8k USDC at the pin.
    address internal constant V2_PAIR = 0xF64Dfe17C8b87F012FCf50FbDA1D62bfA148366a;

    /// @dev Uniswap V3 SwapRouter, official Arbitrum deployment. Venue B.
    address internal constant V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    /// @dev Uniswap V3 Factory. Hardcoded in `ArbitragePlugin`, identical on every chain.
    address internal constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    /// @dev Uniswap V3 WETH/USDC 0.05% pool. Deep. Resolved by the plugin itself via CREATE2,
    ///      so the plugin is never told this address; the tests read it for price assertions.
    address internal constant V3_POOL = 0xC6962004f452bE9203591991D15f6b388e09E8D0;

    /// @dev Balancer V2 Vault. Hardcoded in `FlashLoanService`, identical on every chain, 0% fee.
    address internal constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    /// @dev Impersonated market participant holding 6.575 WETH and 21,745 USDC at the pin.
    ///      It is a contract (a GMX vault) and holds no ETH, so every impersonation must
    ///      `vm.deal` gas to it first - the proven 4-step pattern from the reference suite.
    address internal constant WHALE = 0x489ee077994B6658eAfA855C308275EAd8097C4A;

    // ==================== FORK PIN ====================

    /**
     * @dev The block every measurement in this suite was taken at.
     *      Measured at this block: Balancer vault 13,275.062778 USDC; V2 pair
     *      10.335654869 WETH / 27,784.977544 USDC (token0 = WETH); V3 slot0
     *      sqrtPriceX96 = 4,105,095,974,261,713,632,500,101, tick = -197368, liquidity = 3.44e18;
     *      whale 6.575202304997872271 WETH + 21,745.487151 USDC.
     */
    uint256 internal constant FORK_BLOCK = 509_000_000;

    /**
     * @dev Unix timestamp of `FORK_BLOCK`, used as the pin witness (see `_assertPinnedBlock`).
     *      If you move the pin, update this too: `cast block <new> --field timestamp --rpc-url arbitrum`.
     */
    uint256 internal constant FORK_BLOCK_TIMESTAMP = 1_790_403_338;

    // ==================== PLUGIN CONSTRUCTION PARAMETERS ====================

    /**
     * @dev 0.5% slippage budget per leg. Not a free parameter:
     *      - the V2 leg's `amountOutMinimum` is the router's own exact `getAmountsOut` haircut
     *        by 50 bps, so it is satisfied by construction at any size;
     *      - the V3 leg's `amountOutMinimum` is a SLOT0 SPOT quote (no price-impact model)
     *        haircut by the same 50 bps, so it needs the real price impact of the V3 leg to
     *        stay under 50 bps. Measured at the pin it is ~5 bps (see `V3_IMPACT_TOLERANCE_BPS`),
     *        i.e. a 10x margin. Widening it would not help: `getExpectedProfit` subtracts the
     *        same number, so a loose budget is a loose quote.
     */
    uint256 internal constant MAX_SLIPPAGE_BPS = 50;
    /// @dev Route/router deadline lifetime in seconds; the contract accepts [30, 3600].
    uint256 internal constant DEADLINE_WINDOW = 300;

    // ==================== NUMERIC HELPERS ====================

    /// @dev `slot0().sqrtPriceX96` is `sqrt(token1/token0)` in Q64.96.
    uint256 internal constant SQRT_PRICE_SCALE = 1 << 96;
    /// @dev Uniswap V3 expresses the pool fee in 1e-6. The plugin only ever uses 500 (0.05%).
    uint24 internal constant V3_FEE = 500;
    uint256 internal constant V3_FEE_DENOMINATOR = 1_000_000;
    /// @dev Uniswap V2 charges 0.30% (997/1000). Only used in test-side arithmetic comments.
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    /// @dev Basis points per unit.
    uint256 internal constant UNIT_BPS = 10_000;

    // ==================== STATE ====================

    /// @dev The production plugin, deployed fresh in `setUp` and owned by this test contract.
    ArbitragePlugin internal plugin;
    /// @dev The production flash loan service, authorized to call this test's plugin only.
    FlashLoanService internal service;

    /// @dev An unrelated address, used for the access-control cases.
    address internal stranger;

    // ==================== GATING ====================

    /**
     * @dev True when the fork suites should actually run.
     *      `FORK_ENABLED=true` is the documented switch; `vm.activeFork() > 0` additionally
     *      auto-enables the suites whenever forge is already pointed at a fork, so
     *      `forge test --fork-url ... --fork-block-number ...` needs no env var at all.
     *      A bare `forge test` has neither, and every fork test skips.
     */
    function forkEnabled() public view returns (bool) {
        if (vm.envOr("FORK_ENABLED", false)) return true;
        // `vm.activeFork()` is NOT a usable signal here: with a CLI-level fork it returns 0,
        // so testing it against 0 makes the suites skip even while forking. The presence of
        // real bytecode at the canonical Balancer vault is a direct, honest witness that real
        // Arbitrum state is loaded - on a bare local EVM that address is empty.
        return BALANCER_VAULT.code.length > 0;
    }

    /// @dev The configured pin: the constant, overridable through `FORK_BLOCK_NUMBER`.
    function forkBlock() public view returns (uint256) {
        return vm.envOr("FORK_BLOCK_NUMBER", uint256(FORK_BLOCK));
    }

    /// @dev The single line every concrete fork test opens with.
    function _skipUnlessForking() internal {
        if (!forkEnabled()) {
            vm.skip(true);
        }
    }

    /**
     * @dev Proves the run really is on the configured pin.
     *
     *      IMPORTANT - it asserts on `block.timestamp`, NOT on `block.number`.
     *      Foundry 1.8.3 maps an Arbitrum block header's `l1BlockNumber` field onto the
     *      EVM's `block.number`: asking for L2 block 509,000,000 reports
     *      `block.number == 26,059,772`, which is that block's Ethereum counterpart.
     *      `block.timestamp` is taken from the pinned header correctly, so it is the
     *      only trustworthy witness that the requested pin is the one in use.
     */
    function _assertPinnedBlock() internal view {
        assertEq(block.timestamp, FORK_BLOCK_TIMESTAMP, "not on the pinned block; pass --fork-block-number");
    }

    // ==================== SETUP ====================

    function setUp() public virtual {
        // No RPC read in `setUp`: everything below is local deployment and local storage.
        // A skipped fork test therefore costs nothing on a non-fork run.
        plugin = new ArbitragePlugin(USDC, WETH, V2_ROUTER, V3_ROUTER, MAX_SLIPPAGE_BPS, DEADLINE_WINDOW);
        service = new FlashLoanService(address(plugin));
        plugin.initialize(address(service));

        stranger = makeAddr("stranger");

        // Wiring: the service trusts exactly this plugin, and the plugin points back at it.
        assertEq(service.authorizedCaller(), address(plugin), "service must trust the plugin");
        assertEq(service.getBalancerVault(), BALANCER_VAULT, "service must target the real Balancer vault");
        assertEq(plugin.flashLoanService(), address(service), "plugin must point back at the service");
        assertEq(plugin.owner(), address(this), "test contract must own the plugin");
        assertEq(plugin.baseToken(), USDC, "base token must be USDC");
        assertEq(plugin.quoteToken(), WETH, "quote token must be WETH");
    }

    // ==================== CHAIN-SHAPE ASSERTIONS ====================

    /// @dev Everything the suite assumes about the real deployments, in one place.
    function _assertRealChainShape() internal view {
        assertTrue(BALANCER_VAULT.code.length > 0, "Balancer vault must have code");
        assertTrue(V2_ROUTER.code.length > 0, "V2 router must have code");
        assertTrue(V3_ROUTER.code.length > 0, "V3 router must have code");
        assertTrue(V3_POOL.code.length > 0, "V3 pool must have code");

        assertEq(IUniswapV2Router02(V2_ROUTER).factory(), V2_FACTORY, "V2 router factory mismatch");
        assertEq(IUniswapV2Factory(V2_FACTORY).getPair(WETH, USDC), V2_PAIR, "V2 pair mismatch");
        // token0 = WETH fixes the decimal scaling of every V2 reserve read below.
        assertEq(IV2Pair(V2_PAIR).token0(), WETH, "V2 pair token0 must be WETH");
        // The plugin derives the V3 pool by CREATE2 and cross-checks the factory, so this
        // assert is the test-side confirmation that the pair (WETH, USDC, 500) is the pool
        // the plugin will really use.
        assertEq(IV3PoolOrder(V3_POOL).token0(), WETH, "V3 pool token0 must be WETH");
        assertEq(
            IUniswapV2Factory(V2_FACTORY).getPair(USDC, WETH),
            V2_PAIR,
            "V2 pair must be order-independent"
        );
    }

    // ==================== FUNDING ====================

    /**
     * @dev Mints `amount` of `token` into `to` by impersonating the token contract itself.
     *
     *      `vm.deal(token, balance + amount)` is NOT usable on a real ERC20: `vm.deal` moves the
     *      ACCOUNT balance (native ETH), never ERC20 storage, so the real USDC/WETH balances
     *      would not move. The working form is a single spoofed transfer FROM the token
     *      contract, which is exactly how a real ERC20 mints: the token is not blacklisted
     *      (Circle's native USDC blacklists users, not its own address) and the transfer
     *      succeeds only if `amount <= balanceOf(token)`, which the caller must respect.
     */
    function _fund(address token, address to, uint256 amount) internal {
        uint256 available = IERC20(token).balanceOf(token);
        require(amount <= available, "ForkBase: token contract cannot mint more than it holds");
        vm.prank(token);
        IERC20(token).safeTransfer(to, amount);
    }

    /// @dev Gives `who` enough native ETH to pay for the calls these suites impersonate.
    function _fundGas(address who) internal {
        vm.deal(who, 1 ether);
    }

    // ==================== MARKET SIMULATION ====================

    /**
     * @dev Impersonates the whale and sells `wethIn` WETH into the V2 pair for USDC.
     *      This is MARKET SIMULATION, not the code under test, so it deliberately uses a
     *      permissive `amountOutMin = 0` and the production router: it is exactly the trade a
     *      real participant would send, and it is the only way to create a dislocation between
     *      two venues that are otherwise within ~0.1% of each other.
     * @return usdcOut USDC received by the whale.
     */
    function _whaleSellWethOnV2(uint256 wethIn) internal returns (uint256 usdcOut) {
        _fundGas(WHALE);
        vm.startPrank(WHALE);
        IERC20(WETH).forceApprove(V2_ROUTER, wethIn);
        usdcOut = IUniswapV2Router02(V2_ROUTER).swapExactTokensForTokens(
            wethIn, 0, _path(WETH, USDC), WHALE, block.timestamp + DEADLINE_WINDOW
        )[1];
        vm.stopPrank();
    }

    /**
     * @dev Impersonates the whale and spends `usdcIn` USDC buying WETH on the V2 pair.
     *      The mirror image of `_whaleSellWethOnV2`, used to push V2 the other way.
     * @return wethOut WETH received by the whale.
     */
    function _whaleBuyWethOnV2(uint256 usdcIn) internal returns (uint256 wethOut) {
        _fundGas(WHALE);
        vm.startPrank(WHALE);
        IERC20(USDC).forceApprove(V2_ROUTER, usdcIn);
        wethOut = IUniswapV2Router02(V2_ROUTER).swapExactTokensForTokens(
            usdcIn, 0, _path(USDC, WETH), WHALE, block.timestamp + DEADLINE_WINDOW
        )[1];
        vm.stopPrank();
    }

    // ==================== PRICE READS ====================

    /// @dev `(wethReserve, usdcReserve)` of the V2 pair, in WETH wei and USDC micro-units.
    ///      `_assertRealChainShape` asserts token0 == WETH, so reserve0 is the WETH side.
    function _v2Reserves() internal view returns (uint256 wethReserve, uint256 usdcReserve) {
        (uint112 reserve0, uint112 reserve1,) = IV2Pair(V2_PAIR).getReserves();
        return (uint256(reserve0), uint256(reserve1));
    }

    /**
     * @dev V2 spot price of WETH in micro-USDC (1e-6 USDC) per WETH wei, i.e. the reserve ratio
     *      `reserve1/reserve0`. The value is the pool's mid price BEFORE the 0.30% swap fee,
     *      which is the number to compare against the V3 price on.
     */
    function _v2Price() internal view returns (uint256) {
        (uint256 wethReserve, uint256 usdcReserve) = _v2Reserves();
        return Math.mulDiv(usdcReserve, 1e18, wethReserve);
    }

    /**
     * @dev V3 spot price of WETH in micro-USDC per WETH wei, read from `slot0`.
     *      Same quantity as `_v2Price`, so the two are directly comparable.
     *      `sqrtPriceX96^2 / 2^96` is token1 per token0 in raw units; with token0 = WETH and
     *      token1 = USDC that is already micro-USDC per WETH wei. The inverted branch is kept
     *      so the helper stays correct if the pool's token ordering ever changes.
     */
    function _v3Price() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(V3_POOL).slot0();
        require(sqrtPriceX96 != 0, "ForkBase: V3 pool uninitialised");
        uint256 priceX96 = Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), SQRT_PRICE_SCALE);
        return IV3PoolOrder(V3_POOL).token0() == WETH ? priceX96 : Math.mulDiv(1e18, 1e18, priceX96);
    }

    /// @dev Signed relative distance between two prices, in basis points.
    function _priceGapBps(uint256 a, uint256 b) internal pure returns (int256) {
        require(b != 0, "ForkBase: zero reference price");
        // |a-b| * 1e4 / b, signed.
        int256 diff = int256(a) - int256(b);
        return (diff * int256(UNIT_BPS)) / int256(b);
    }

    // ==================== SMALL HELPERS ====================

    /// @dev Two-element router path.
    function _path(address tokenIn, address tokenOut) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
    }

    /// @dev Exact V2 router quote of `amountIn` of `tokenIn` for `tokenOut`.
    function _v2QuoteOut(uint256 amountIn, address tokenIn, address tokenOut) internal view returns (uint256) {
        return IUniswapV2Router02(V2_ROUTER).getAmountsOut(amountIn, _path(tokenIn, tokenOut))[1];
    }

    /// @dev `a` and `b` are micro-USDC prices; prints them as whole USDC per WETH for assertion messages.
    function _usdcPerWeth(uint256 microUsdcPerWei) internal pure returns (uint256) {
        return microUsdcPerWei / 1e6;
    }
}
