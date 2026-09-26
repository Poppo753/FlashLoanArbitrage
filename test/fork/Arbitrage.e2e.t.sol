// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {ArbitragePlugin} from "../../contracts/ArbitragePlugin.sol";

/* ============================================================================
 * WHAT THIS SUITE IS FOR
 * ============================================================================
 * `test/ArbitragePlugin.t.sol` runs the production `ArbitragePlugin` against etched mocks,
 * so it proves the LOGIC and nothing about reality. In particular the V2 leg there always
 * repays with interest, because a mock constant-product pool handed to the plugin at a
 * hand-chosen price cannot lose money by accident.
 *
 * This suite removes that crutch. It runs the same contract, on Arbitrum mainnet bytecode,
 * at a pinned block, against the two venues the contract was written for. Nothing is etched,
 * nothing is stubbed, and the plugin's own guards (per-leg `amountOutMinimum`, `minProfit`,
 * `deadline`) stay switched on for every test here.
 *
 * THE ONE THING A REAL CHAIN CHANGES: at the pin the two venues are within ~10 bps of each
 * other, which is far LESS than the 35 bps the cycle pays in venue fees. So at rest there is
 * no arbitrage to take, and `test_NoDisplacement_NoProfit_Reverts` proves the plugin says so
 * instead of quietly bleeding the borrow. Profit only appears once a real market participant
 * creates a dislocation - which is exactly what the whale trades below do, on V2 only.
 *
 * MEASURED AT FORK_BLOCK (509,000,000 / ts 1,790,403,338), all reproduced by the logs here:
 *   V2 WETH/USDC mid  = 2,688.248784 USDC/WETH   (mid price, before the 0.30% swap fee)
 *   V3 WETH/USDC spot = 2,685.443451 USDC/WETH   (slot0, before the 0.05% pool fee)
 *   pre-trade gap     = +10 bps  (V2 the dearer side)      -> aligned, nothing to arbitrage
 *   Balancer vault    = 13,275.06 USDC                     -> bounds the principal
 * ========================================================================= */

/**
 * @title ArbitrageForkE2ETest
 * @notice End-to-end proof that the production arbitrage cycle makes real profit on real
 *         liquidity, and that the profit disappears the moment nobody distorts the market.
 */
contract ArbitrageForkE2ETest is ForkBase {
    // ==================== MEASURED PARAMETERS ====================

    /**
     * @dev Borrow size for every profitable cycle: 2,000 USDC, 15.06% of the 13,275.06 USDC the
     *      real Balancer vault holds at the pin, so the loan is unambiguously funded by the
     *      vault's own balance and not by test credit.
     */
    uint256 internal constant PRINCIPAL = 2_000e6;

    /**
     * @dev The whale's WETH sale into the thin V2 pair (9.67% of the pair's 10.3357 WETH side).
     *      This is the dislocation that makes `buyOnVenueA = true` profitable:
     *        reserves 10.335654869 WETH / 27,784.977544 USDC
     *        -> the whale's 1 WETH comes out at 2,444.393196 USDC
     *        -> reserves 11.335685681 WETH / 25,340.501269 USDC
     *        -> V2 mid 2,688.248784 -> 2,235.462589 USDC/WETH  (-1,684 bps)
     *      V3 is untouched by the trade, so it still quotes 2,685.443451: V2 is now 1,675 bps
     *      cheap, i.e. ~4.5x the 374 bps the round trip costs in venue fees.
     */
    uint256 internal constant WHALE_WETH_SELL = 1e18;

    /**
     * @dev The mirror-image whale trade, spent USDC buying WETH on V2 (7.19% of the pair's
     *      27,784.98 USDC side), which is what makes `buyOnVenueA = false` profitable:
     *        the whale's 2,000 USDC buys 0.692079327 WETH
     *        -> reserves 9.643575542 WETH / 29,784.977544 USDC
     *        -> V2 mid 2,688.248784 -> 3,088.563901 USDC/WETH  (+1,489 bps)
     *      V3 still quotes 2,685.443451, so V2 is now 1,501 bps rich in WETH terms.
     */
    uint256 internal constant WHALE_USDC_BUY = 2_000e6;

    /// @dev A displacement must move the traded venue by at least this much to count as one.
    uint256 internal constant MIN_DISPLACEMENT_BPS = 300;
    /// @dev ... and by at most this much, so a whale size that accidentally liquidates the
    ///      thin V2 pair (or is silently too small to matter) fails loudly instead of quietly.
    uint256 internal constant MAX_DISPLACEMENT_BPS = 10_000;
    /// @dev "The venues are aligned" band for the pre-trade premise: 1%.
    uint256 internal constant ALIGNED_BAND_BPS = 100;
    /// @dev A whale trade on V2 must not have touched V3. Measured: 0 bps, exactly.
    uint256 internal constant V3_IMMUTABLE_BPS = 5;
    /// @dev The plugin's quote may understate the realised gross output by at most this much.
    ///      Measured: 50 bps (direction A) and 46 bps (direction B) - see
    ///      `test_QuoteAgreesWithExecution_OnFork` for the decomposition.
    uint256 internal constant QUOTE_TOLERANCE_BPS = 100;

    // ==================== PIN-MEASURED EXPECTATIONS ====================

    /// @dev `InsufficientRepayment(available, required)` from the no-displacement control,
    ///      direction A, at PRINCIPAL. The whole cycle produced 1,856.764155 USDC for a
    ///      2,000 USDC loan, i.e. it lost 7.16% to the 35 bps round-trip fee against a 10 bps
    ///      pre-existing (unexploitable) gap. Recorded for reference only - the test asserts a
    ///      bound on the shortfall, never this exact figure, because pool state moves it.
    uint256 internal constant CONTROL_AVAILABLE_A_REFERENCE = 1_856_764_155;

    // ==================== EVENTS (mirrored so the logs can be decoded) ====================

    event ArbitrageExecuted(uint256 principal, uint256 profit, bool buyOnVenueA);

    // ==================== TEST 1 - THE DECISIVE ONE ====================

    /**
     * @dev The whole thesis of the project, end to end on real liquidity.
     *
     *  a. premise: the two venues are within 1% of each other before anybody trades, so there is
     *     no free lunch sitting on the book. This is also a live check of BOTH price readers -
     *     a V2 or V3 read that silently returned nonsense would fail here immediately.
     *  b. the whale trades on V2 ONLY, and the test refuses to continue unless V2 actually moved
     *     and V3 actually did not.
     *  c. the plugin borrows 2,000 USDC from the real Balancer vault and cycles it.
     *  d. the cycle is only accepted if it really emitted `ArbitrageExecuted`, really kept a
     *     positive profit, really put exactly that profit in the plugin's USDC balance, really
     *     left the vault whole, and really stranded no WETH.
     *
     * MEASURED ARITHMETIC (direction A, principal 2,000 USDC):
     *   whale  : sells 1.0 WETH into V2, receives        2,444.393196 USDC
     *             V2 mid 2,688.248784 -> 2,235.462589     V3 spot 2,685.443451 (untouched)
     *   leg 1  : 2,000 USDC -> 0.826916761 WETH on V2     (0.30% fee + constant-product impact)
     *   leg 2  : 0.826916761 WETH -> 2,219.500276 USDC on V3
     *             gross at V3 slot0 spot                   2,220.638199 USDC
     *             less 0.05% pool fee  (-1.110319)         2,219.527880 USDC
     *             less 0.123 bps price impact (-0.000027)  2,219.500276 USDC  <- measured
     *   repay  : 2,000.000000 USDC back to the service -> back to the vault (0% Balancer fee)
     *   PROFIT : 219.500276 USDC = 10.975% of the 2,000 USDC borrowed
     */
    function test_ForcedDisplacement_ProducesRealProfit() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        // (a) Everything this suite assumes about the real deployments, asserted on-chain.
        _assertRealChainShape();

        uint256 vaultUsdc = IERC20(USDC).balanceOf(BALANCER_VAULT);
        assertGt(vaultUsdc, PRINCIPAL, "premise: the real vault must fund the principal");

        Market memory m;
        m.v2Before = _v2Price();
        m.v3Before = _v3SpotUsdcPerWeth();
        _logPair("before any trade", m.v2Before, m.v3Before, 0, 0);
        // |V2 - V3| <= 1%: the venues are aligned, so nothing can be arbitraged yet. A broken
        // price reader (wrong pool, wrong token ordering, wrong scale) blows up right here.
        assertLe(
            _absBps(_priceGapBps(m.v2Before, m.v3Before)),
            ALIGNED_BAND_BPS,
            "premise: the two venues must start within 1% of each other"
        );

        // (b) The whale trades on V2 only. Everything below depends on this actually biting.
        uint256 whaleWethBefore = IERC20(WETH).balanceOf(WHALE);
        uint256 whaleUsdcBefore = IERC20(USDC).balanceOf(WHALE);
        m.whaleUsdcOut = _whaleSellWethOnV2(WHALE_WETH_SELL);
        assertEq(
            IERC20(WETH).balanceOf(WHALE), whaleWethBefore - WHALE_WETH_SELL, "the whale did not really sell WETH on V2"
        );
        assertEq(
            IERC20(USDC).balanceOf(WHALE), whaleUsdcBefore + m.whaleUsdcOut, "the whale did not really receive USDC"
        );

        m.v2After = _v2Price();
        m.v3After = _v3SpotUsdcPerWeth();
        int256 v2Move = _priceGapBps(m.v2After, m.v2Before);
        int256 v3Move = _priceGapBps(m.v3After, m.v3Before);
        _logPair("after the whale's V2 sale", m.v2After, m.v3After, v2Move, v3Move);

        assertLt(m.v2After, m.v2Before, "selling WETH into V2 must make V2 WETH cheaper");
        assertGe(_absBps(v2Move), MIN_DISPLACEMENT_BPS, "the whale trade did not displace V2 by several percent");
        assertLe(_absBps(v2Move), MAX_DISPLACEMENT_BPS, "the whale trade moved V2 implausibly far");
        assertLe(_absBps(v3Move), V3_IMMUTABLE_BPS, "the whale traded V2 but V3 moved anyway: harness problem");
        assertLt(m.v2After, m.v3After, "after the sale V2 must be the CHEAP venue, otherwise this cycle loses");

        // (c) The cycle. The plugin's own guards are all still on: `minProfit` is only relaxed
        // from 0 (its constructor value) to 0 again explicitly, and the per-leg
        // `amountOutMinimum` / `deadline` guards are the production ones, untouched.
        plugin.setMinProfit(0);

        uint256 pluginBaseBefore = IERC20(USDC).balanceOf(address(plugin));
        uint256 vaultBefore = IERC20(USDC).balanceOf(BALANCER_VAULT);
        uint256 quoteIn = _v2QuoteOut(PRINCIPAL, USDC, WETH);

        vm.recordLogs();
        vm.startSnapshotGas("arbitrage");
        plugin.startArbitrage(PRINCIPAL, true);
        uint256 cycleGas = vm.stopSnapshotGas("arbitrage");

        // (d) The event, read back out of the recorded logs rather than assumed.
        (uint256 evPrincipal, uint256 evProfit, bool evDirection, bool found) = _readArbitrageExecuted();
        assertTrue(found, "ArbitrageExecuted was not emitted");
        assertEq(evPrincipal, PRINCIPAL, "event principal mismatch");
        assertEq(evDirection, true, "event direction mismatch");
        assertGt(evProfit, 0, "the cycle reported no profit");

        uint256 pluginBaseAfter = IERC20(USDC).balanceOf(address(plugin));
        uint256 realisedProfit = pluginBaseAfter - pluginBaseBefore;
        assertEq(realisedProfit, evProfit, "the plugin's USDC balance must rise by exactly the emitted profit");
        assertGt(realisedProfit, 0, "profit must be positive");

        // The loan came out of the vault and went straight back: the vault's real balance is
        // byte-for-byte unchanged, which is the strongest available proof of full repayment.
        assertEq(
            IERC20(USDC).balanceOf(BALANCER_VAULT),
            vaultBefore,
            "the Balancer vault was not made whole: loan not repaid"
        );

        // Leg 2 sells 100% of what leg 1 produced, so no quote token can be left behind.
        assertEq(IERC20(WETH).balanceOf(address(plugin)), 0, "quote token stranded in the plugin");
        assertEq(IERC20(WETH).balanceOf(address(service)), 0, "quote token stranded in the service");

        // Book-keeping, printed so the run is self-documenting.
        console2.log("--- decisive cycle (direction A) ---");
        console2.log("principal USDC           =", PRINCIPAL);
        console2.log("leg1 V2 USDC->WETH (wei) =", quoteIn);
        console2.log("leg2 V3 WETH->USDC       =", realisedProfit + PRINCIPAL);
        console2.log("profit USDC              =", realisedProfit);
        console2.log("profit bps of principal  =", (realisedProfit * UNIT_BPS) / PRINCIPAL);
        console2.log("startArbitrage gas       =", cycleGas);
        console2.log("v2 mid after cycle       =", _v2Price());
        console2.log("v3 spot after cycle      =", _v3SpotUsdcPerWeth());
    }

    // ==================== TEST 2 - THE OTHER DIRECTION ====================

    /**
     * @dev `buyOnVenueA = false`: buy the WETH leg on V3 and sell it back into V2.
     *
     * DIRECTION CHOICE: both directions are profitable at the pin, so this suite implements
     * BOTH rather than picking one. They need opposite dislocations, because the profit comes
     * from buying where WETH is cheap and selling where it is dear:
     *   - direction A (`true`) needs V2 CHEAP  -> the whale must SELL WETH into V2 (test 1);
     *   - direction B (`false`) needs V2 DEAR  -> the whale must BUY WETH with USDC on V2 (here).
     * Running test 1's displacement and then asking for direction B would trade the expensive
     * venue in the profitable direction and is covered, correctly rejected, by
     * `test_WrongDirection_AfterOneSidedDisplacement_IsRejected`.
     *
     * MEASURED ARITHMETIC (direction B, principal 2,000 USDC):
     *   whale  : spends 2,000 USDC on V2, receives           0.692079327 WETH
     *             V2 mid 2,688.248784 -> 3,088.563901        V3 spot 2,685.443451 (untouched)
     *   leg 1  : 2,000 USDC -> 0.744375238 WETH on V3  (0.05% fee; 0.744755954 at pure spot)
     *   leg 2  : 0.744375238 WETH -> 2,128.361241 USDC on V2 (0.30% fee + ~7% impact, the pool
     *             is thin, so the sale itself gives a lot of the price back - this is the
     *             honest cost of the thin leg, and it is already inside the 219/128 numbers)
     *   repay  : 2,000.000000 USDC
     *   PROFIT : 128.361241 USDC = 6.418% of the 2,000 USDC borrowed
     */
    function test_BothDirections_OnFork() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        Market memory m;
        m.v2Before = _v2Price();
        m.v3Before = _v3SpotUsdcPerWeth();
        _logPair("before any trade", m.v2Before, m.v3Before, 0, 0);
        assertLe(
            _absBps(_priceGapBps(m.v2Before, m.v3Before)),
            ALIGNED_BAND_BPS,
            "premise: the two venues must start within 1% of each other"
        );

        // Displace in the direction that makes the REVERSE cycle profitable: V2 must end up
        // dearer than V3, which only happens if somebody buys WETH there.
        uint256 whaleWethBefore = IERC20(WETH).balanceOf(WHALE);
        uint256 whaleUsdcBefore = IERC20(USDC).balanceOf(WHALE);
        uint256 whaleWethOut = _whaleBuyWethOnV2(WHALE_USDC_BUY);
        assertEq(
            IERC20(WETH).balanceOf(WHALE), whaleWethBefore + whaleWethOut, "the whale did not really receive WETH on V2"
        );
        assertEq(IERC20(USDC).balanceOf(WHALE), whaleUsdcBefore - WHALE_USDC_BUY, "the whale did not really spend USDC");

        m.v2After = _v2Price();
        m.v3After = _v3SpotUsdcPerWeth();
        int256 v2Move = _priceGapBps(m.v2After, m.v2Before);
        int256 v3Move = _priceGapBps(m.v3After, m.v3Before);
        _logPair("after the whale's V2 buy", m.v2After, m.v3After, v2Move, v3Move);

        assertGt(m.v2After, m.v2Before, "buying WETH on V2 must make V2 WETH dearer");
        assertGe(_absBps(v2Move), MIN_DISPLACEMENT_BPS, "the whale trade did not displace V2 by several percent");
        assertLe(_absBps(v2Move), MAX_DISPLACEMENT_BPS, "the whale trade moved V2 implausibly far");
        assertLe(_absBps(v3Move), V3_IMMUTABLE_BPS, "the whale traded V2 but V3 moved anyway: harness problem");
        assertGt(m.v2After, m.v3After, "after the buy V2 must be the DEAR venue, otherwise this cycle loses");

        plugin.setMinProfit(0);

        uint256 pluginBaseBefore = IERC20(USDC).balanceOf(address(plugin));
        uint256 vaultBefore = IERC20(USDC).balanceOf(BALANCER_VAULT);

        vm.recordLogs();
        vm.startSnapshotGas("arbitrage");
        plugin.startArbitrage(PRINCIPAL, false);
        uint256 cycleGas = vm.stopSnapshotGas("arbitrage");

        (uint256 evPrincipal, uint256 evProfit, bool evDirection, bool found) = _readArbitrageExecuted();
        assertTrue(found, "ArbitrageExecuted was not emitted");
        assertEq(evPrincipal, PRINCIPAL, "event principal mismatch");
        assertEq(evDirection, false, "event direction mismatch: the reverse leg must report buyOnVenueA = false");
        assertGt(evProfit, 0, "the reverse cycle reported no profit");

        uint256 realisedProfit = IERC20(USDC).balanceOf(address(plugin)) - pluginBaseBefore;
        assertEq(realisedProfit, evProfit, "the plugin's USDC balance must rise by exactly the emitted profit");
        assertEq(IERC20(USDC).balanceOf(BALANCER_VAULT), vaultBefore, "the Balancer vault was not made whole");
        assertEq(IERC20(WETH).balanceOf(address(plugin)), 0, "quote token stranded in the plugin");

        console2.log("--- reverse cycle (direction B) ---");
        console2.log("principal USDC          =", PRINCIPAL);
        console2.log("whale's V2 buy (wei)   =", whaleWethOut);
        console2.log("profit USDC             =", realisedProfit);
        console2.log("profit bps of principal =", (realisedProfit * UNIT_BPS) / PRINCIPAL);
        console2.log("startArbitrage gas      =", cycleGas);
    }

    /**
     * @dev The mirror image of test 2's premise, and the honest complement to it: a
     *      displacement in ONE direction must not make the OTHER direction tradeable.
     *
     *      After the whale sells WETH into V2, V2 is the cheap venue. Asking the plugin to buy
     *      on the expensive venue (V3) and sell on the cheap one (V2) is guaranteed to lose
     *      ~7% of the principal, and the guards must catch it. It does: `InsufficientRepayment`,
     *      with `required == PRINCIPAL` (Balancer V2 charges 0%) and `available` well below it.
     *
     *      This is a real test of the plugin rather than of the harness: the V2 leg's
     *      `amountOutMinimum` is the router's own exact `getAmountsOut` haircut, so it can
     *      never be the leg that reverts - the rejection has to come from the accounting.
     */
    function test_WrongDirection_AfterOneSidedDisplacement_IsRejected() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        _whaleSellWethOnV2(WHALE_WETH_SELL);
        assertLt(_v2Price(), _v3SpotUsdcPerWeth(), "premise: V2 must now be the cheap venue");
        plugin.setMinProfit(0);

        uint256 vaultBefore = IERC20(USDC).balanceOf(BALANCER_VAULT);
        (bool ok, bytes memory err) =
            address(plugin).call(abi.encodeCall(ArbitragePlugin.startArbitrage, (PRINCIPAL, false)));
        (uint256 available, uint256 required) = _assertProfitabilityRevert(err, ok);
        assertEq(ArbitragePlugin.InsufficientRepayment.selector, bytes4(err), "at the pin the cycle cannot repay");
        assertEq(required, PRINCIPAL, "Balancer V2 charges 0%, so required must be exactly the principal");
        assertLt(available, required, "trading the expensive venue must lose money");
        assertEq(IERC20(USDC).balanceOf(BALANCER_VAULT), vaultBefore, "a reverted cycle must not touch the vault");
        assertEq(IERC20(USDC).balanceOf(address(plugin)), 0, "a reverted cycle must not leave funds behind");
        assertEq(IERC20(WETH).balanceOf(address(plugin)), 0, "a reverted cycle must not strand WETH");
    }

    // ==================== TEST 3 - QUOTE VS EXECUTION ====================

    /**
     * @dev `getExpectedProfit` must be non-zero AND must not lie about the cycle.
     *
     * TOLERANCE, AND WHY IT IS THIS TOLERANCE
     *   `getExpectedProfit` is explicitly a spot ESTIMATE, not a fill simulation: the V3 leg is
     *   quoted from `slot0`, which carries no price-impact model. The contract then applies its
     *   own `maxSlippageBps = 50` haircut on top. So the quote is a strict LOWER BOUND on the
     *   realised fill, and it understates it by at most one haircut plus the (unmodelled) V3
     *   price impact.
     *
     *   Assertions, both directions:
     *     - `expectedProfit > 0` and `expectedOut > PRINCIPAL` (the quote says "take it");
     *     - `realisedOut >= expectedOut`, which is a THEOREM, not a measurement: `expectedOut`
     *       is exactly the number the contract passes as `amountOutMinimum` on the V3 leg
     *       (direction A) or the exact V2 quote of a haircut-reduced WETH input (direction B),
     *       and the routers guarantee the fill is at least that;
     *     - `realisedProfit <= expectedProfit + 1% of expectedOut`, i.e. the quote may
     *       understate the realised profit by at most 100 bps of the cycle's GROSS output.
     *
     *   MEASURED: direction A understates by 50 bps of gross output, direction B by 46 bps.
     *   Decomposition of the 50 bps (direction A): the 0.05% V3 pool fee (5 bps) plus the
     *   50 bps `maxSlippageBps` haircut that the fill does not pay, less 0.12 bps of actual V3
     *   price impact on 0.8269 WETH (the pool is deep), less the ~0.1 bps rounding.
     *   Note the bound is applied to gross output, not to profit: profit is a small difference
     *   between two ~2,200 USDC numbers, so the same absolute 11 USDC divergence is 5.3% of
     *   the 208 USDC quoted profit and only 0.5% of the 2,219 USDC gross. A percentage band on
     *   the profit itself would be measuring the size of the profit, not the quality of the
     *   quote. The 100 bps band on gross output gives ~2x headroom on both directions.
     */
    function test_QuoteAgreesWithExecution_OnFork() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        // Two independent market states in one test: snapshot before each, revert after, so the
        // second displacement is measured against the untouched pin, not against the first.
        uint256 snap = vm.snapshotState();
        _assertQuoteAgreesWithExecution(true);
        assertTrue(vm.revertToState(snap), "could not restore the pinned state for direction B");

        _assertQuoteAgreesWithExecution(false);
    }

    function _assertQuoteAgreesWithExecution(bool buyOnVenueA) internal {
        if (buyOnVenueA) {
            _whaleSellWethOnV2(WHALE_WETH_SELL);
        } else {
            _whaleBuyWethOnV2(WHALE_USDC_BUY);
        }
        plugin.setMinProfit(0);

        (uint256 expectedOut, uint256 expectedProfit) = plugin.getExpectedProfit(PRINCIPAL, buyOnVenueA);
        assertGt(expectedProfit, 0, "quote reported no profit for a profitable cycle");
        assertGt(expectedOut, PRINCIPAL, "quote output must exceed the principal when profitable");
        assertEq(expectedProfit, expectedOut - PRINCIPAL, "the quote's own accounting must be out - principal");

        uint256 pluginBaseBefore = IERC20(USDC).balanceOf(address(plugin));
        plugin.startArbitrage(PRINCIPAL, buyOnVenueA);
        uint256 realisedProfit = IERC20(USDC).balanceOf(address(plugin)) - pluginBaseBefore;
        uint256 realisedOut = realisedProfit + PRINCIPAL;

        assertGe(realisedOut, expectedOut, "the realised fill came in BELOW the contract's own quote");
        assertLe(
            realisedProfit,
            expectedProfit + (expectedOut * QUOTE_TOLERANCE_BPS) / UNIT_BPS,
            "the quote understated the realised profit by more than the stated tolerance"
        );

        console2.log("--- quote vs execution ---");
        console2.log("direction buyOnVenueA =", buyOnVenueA);
        console2.log("expectedOut            =", expectedOut);
        console2.log("realisedOut            =", realisedOut);
        console2.log("expectedProfit         =", expectedProfit);
        console2.log("realisedProfit         =", realisedProfit);
        console2.log("understatement bps of gross output =", ((realisedOut - expectedOut) * UNIT_BPS) / expectedOut);
    }

    // ==================== TEST 4 - THE CONTROL ====================

    /**
     * @dev THE CONTROL. No whale trade, no displacement, no arbitrage: with the venues inside
     *      10 bps of each other and a 35 bps round-trip fee (V2 0.30% + V3 0.05%), any cycle
     *      MUST lose money. This test proves the profit in test 1 is a property of the market
     *      state and not an artefact of the harness, and it is the reason the guards matter.
     *
     * WHICH ERROR FIRES, AND WHY
     *   `InsufficientRepayment(available, required)` - NOT `MinProfitNotMet`. Both guards sit
     *   on the same two lines, `available < required` first, `profit < minProfit` second, so
     *   a cycle that cannot even repay never reaches the profitability floor. At the pin the
     *   cycle produces 1,856.764155 USDC against a 2,000 USDC loan: it is 143.24 USDC short,
     *   so `available < required` is true and that is the revert.
     *
     *   The other error is reachable and is pinned exactly by
     *   `test_HighMinProfitFloor_RevertsExactly`: there the cycle DOES repay, so the run
     *   reaches the `profit < minProfit` line and reverts `MinProfitNotMet`.
     *
     *   The assertion below accepts either profitability revert (as the two are a function of
     *   which venue happens to be dearer) and then additionally pins the concrete one for the
     *   pinned block.
     */
    function test_NoDisplacement_NoProfit_Reverts() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        uint256 vaultUsdc = IERC20(USDC).balanceOf(BALANCER_VAULT);
        assertGt(vaultUsdc, PRINCIPAL, "premise: the vault can still fund the principal");
        assertLe(
            _absBps(_priceGapBps(_v2Price(), _v3SpotUsdcPerWeth())),
            ALIGNED_BAND_BPS,
            "premise: the venues must be within 1% so no arbitrage exists"
        );
        // The gap is real but small; it is emphatically smaller than what the cycle pays.
        console2.log("pre-trade gap bps         =", _priceGapBps(_v2Price(), _v3SpotUsdcPerWeth()));
        console2.log("v2 mid (no haircut)      =", _v2Price());
        console2.log("v3 spot (no haircut)     =", _v3SpotUsdcPerWeth());

        // The plugin's own quote already refuses: it reports 0 profit, i.e. "do not trade".
        (uint256 expectedOut, uint256 expectedProfit) = plugin.getExpectedProfit(PRINCIPAL, true);
        assertEq(expectedProfit, 0, "the quote must report no profit while the venues are aligned");
        assertLt(expectedOut, PRINCIPAL, "the quote must report a losing cycle while the venues are aligned");

        plugin.setMinProfit(0);
        uint256 vaultBefore = IERC20(USDC).balanceOf(BALANCER_VAULT);

        (bool ok, bytes memory err) =
            address(plugin).call(abi.encodeCall(ArbitragePlugin.startArbitrage, (PRINCIPAL, true)));
        (uint256 available, uint256 required) = _assertProfitabilityRevert(err, ok);

        assertEq(bytes4(err), ArbitragePlugin.InsufficientRepayment.selector, "at the pin the cycle cannot repay");
        assertEq(required, PRINCIPAL, "Balancer V2 charges 0%, so required must be exactly the principal");
        // The shortfall is asserted as a bound, not as a pinned magic number: the exact figure
        // moves with pool state, and a hardcoded value would break for the wrong reason. What
        // matters is that the cycle came back short of the principal by a real, positive margin.
        assertLt(available, required, "a reverting cycle cannot have repaid");
        assertGt(required - available, 1e6, "the aligned-venue shortfall should be material, not rounding dust");
        assertEq(IERC20(USDC).balanceOf(BALANCER_VAULT), vaultBefore, "a reverted cycle must not touch the vault");
        assertEq(IERC20(USDC).balanceOf(address(plugin)), 0, "a reverted cycle must not keep funds");

        console2.log("--- control ---");
        console2.log("available USDC =", available);
        console2.log("required  USDC =", required);
        console2.log("shortfall USDC =", required - available);
    }

    /**
     * @dev `MinProfitNotMet` pinned EXACTLY, with both arguments.
     *
     *      A "set an absurd floor and expect MinProfitNotMet" test is weak: it cannot tell you
     *      the reported profit is the real one. This one measures the real profit first - by
     *      actually running the cycle - then rewinds the chain to the exact pre-cycle state and
     *      re-runs it with `minProfit = profit + 1`. Because the state is identical, the
     *      second run reproduces the same 219.500276 USDC profit, so the revert can be asserted
     *      as the full `MinProfitNotMet(219500276, 219500277)` - selector AND both arguments.
     */
    function test_HighMinProfitFloor_RevertsExactly() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        _whaleSellWethOnV2(WHALE_WETH_SELL);
        plugin.setMinProfit(0);

        uint256 snapshot = vm.snapshotState();
        uint256 pluginBaseBefore = IERC20(USDC).balanceOf(address(plugin));
        plugin.startArbitrage(PRINCIPAL, true);
        uint256 profit = IERC20(USDC).balanceOf(address(plugin)) - pluginBaseBefore;
        assertGt(profit, 0, "premise: the cycle must be profitable before the floor is applied");
        assertTrue(vm.revertToState(snapshot), "could not restore the pre-cycle state");
        assertEq(IERC20(USDC).balanceOf(address(plugin)), pluginBaseBefore, "the rewind must undo the cycle");

        uint256 floor = profit + 1;
        plugin.setMinProfit(floor);
        vm.expectRevert(abi.encodeWithSelector(ArbitragePlugin.MinProfitNotMet.selector, profit, floor));
        plugin.startArbitrage(PRINCIPAL, true);

        console2.log("--- min profit floor ---");
        console2.log("measured profit USDC =", profit);
        console2.log("floor USDC           =", floor);
    }

    // ==================== TEST 5 - THE PIN ====================

    function test_PinIsHonoured() public {
        _skipUnlessForking();
        _assertPinnedBlock();
        // `block.number` is deliberately NOT asserted: Foundry maps an Arbitrum header's
        // `l1BlockNumber` onto it, so L2 block 509,000,000 reports 26,059,772 here. The
        // timestamp above is the only trustworthy witness. See `_assertPinnedBlock`.
        assertEq(forkBlock(), FORK_BLOCK, "the suite is meant to run on the documented pin");
    }

    // ==================== SHARED HELPERS ====================

    /// @dev Everything one price read produces, bundled to keep the tests off the stack limit.
    struct Market {
        uint256 v2Before;
        uint256 v3Before;
        uint256 v2After;
        uint256 v3After;
        uint256 whaleUsdcOut;
    }

    /**
     * @dev V3 spot price of WETH in micro-USDC per WETH wei - the same quantity as
     *      `ForkBase._v2Price()`, so the two are directly comparable.
     *
     *      This used to un-scale `_v3Price()` locally, because that helper divided
     *      `sqrtPriceX96^2` by 2^96 instead of 2^192 and so returned a ratio still multiplied by
     *      2^96 - which made `_priceGapBps(_v2Price(), _v3Price())` come out as exactly -10000.
     *      `ForkBase._v3Price()` has been fixed, so this is now a plain alias kept for readability
     *      at the call sites.
     */
    function _v3SpotUsdcPerWeth() internal view returns (uint256) {
        return _v3Price();
    }

    /// @dev `|x|` for the signed basis-point helpers.
    function _absBps(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    /// @dev Prints both venues, the moves and the resulting gap, so every fork run is legible.
    function _logPair(string memory stage, uint256 v2, uint256 v3, int256 v2Move, int256 v3Move) internal pure {
        console2.log(string.concat("--- ", stage, " ---"));
        console2.log("v2 mid  (micro-USDC/wei) =", v2);
        console2.log("v3 spot (micro-USDC/wei) =", v3);
        console2.log("v2 mid  (USDC/WETH)      =", _usdcPerWeth(v2));
        console2.log("v3 spot (USDC/WETH)      =", _usdcPerWeth(v3));
        if (v2Move != 0 || v3Move != 0) {
            console2.log("v2 move bps              =", v2Move);
            console2.log("v3 move bps              =", v3Move);
        }
        console2.log("gap (v2 vs v3) bps       =", _priceGapBps(v2, v3));
    }

    /**
     * @dev Reads the plugin's own `ArbitrageExecuted` out of the recorded logs.
     *      `vm.expectEmit` is not usable here: all three event fields are NON-indexed, so
     *      matching the data would require already knowing the profit, which is the thing under
     *      test. Decoding the log is strictly stronger - it proves the value the chain reports
     *      is the value the balance moved by.
     * @return principal Emitted principal.
     * @return profit Emitted profit, in baseToken wei.
     * @return buyOnVenueA Emitted leg-1 venue selector.
     * @return found Whether the event was emitted by the plugin at all.
     */
    function _readArbitrageExecuted()
        internal
        view
        returns (uint256 principal, uint256 profit, bool buyOnVenueA, bool found)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("ArbitrageExecuted(uint256,uint256,bool)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(plugin) || logs[i].topics.length != 1) continue;
            if (logs[i].topics[0] != topic) continue;
            (principal, profit, buyOnVenueA) = abi.decode(logs[i].data, (uint256, uint256, bool));
            found = true;
        }
    }

    /**
     * @dev Asserts a low-level call reverted with one of the two profitability reverts and
     *      returns the decoded `(available, required)` / `(profit, minProfit)` pair.
     *
     *      Membership in the pair is what the test requires - which one fires is a function of
     *      which venue happens to be dearer at the pin - but both arguments are decoded and
     *      sanity-checked, so a revert with any other shape (a guard firing for the wrong
     *      reason, or the transaction failing somewhere else entirely) cannot satisfy the test.
     *      The callers additionally pin the concrete selector observed at the pin.
     * @param err Raw revert data.
     * @param ok Low-level call success flag; must be false.
     * @return first `available` (USDC produced) or `profit` (USDC surplus).
     * @return second `required` (principal + Balancer fee) or `minProfit`.
     */
    function _assertProfitabilityRevert(bytes memory err, bool ok)
        internal
        pure
        returns (uint256 first, uint256 second)
    {
        assertFalse(ok, "the cycle was expected to revert but it succeeded");
        assertGe(err.length, 4 + 64, "revert carried no arguments");
        bytes4 selector = bytes4(err);
        assertTrue(
            selector == ArbitragePlugin.InsufficientRepayment.selector
                || selector == ArbitragePlugin.MinProfitNotMet.selector,
            "revert was neither InsufficientRepayment nor MinProfitNotMet"
        );
        if (selector == ArbitragePlugin.InsufficientRepayment.selector) {
            (first, second) = abi.decode(_withoutSelector(err), (uint256, uint256));
            assertLt(first, second, "InsufficientRepayment must report available < required");
        } else {
            (first, second) = abi.decode(_withoutSelector(err), (uint256, uint256));
            assertLt(first, second, "MinProfitNotMet must report profit < minProfit");
        }
    }

    /// @dev Drops the 4-byte selector so the arguments can be `abi.decode`d.
    function _withoutSelector(bytes memory err) internal pure returns (bytes memory args) {
        args = new bytes(err.length - 4);
        for (uint256 i = 4; i < err.length; ++i) {
            args[i - 4] = err[i];
        }
    }
}
