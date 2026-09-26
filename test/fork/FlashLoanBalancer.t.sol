// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {FlashLoanService} from "../../contracts/services/FlashLoanService.sol";
import {IBalancerVault, IFlashLoanRecipient} from "../../contracts/interfaces/balancer/IBalancerVault.sol";

/**
 * @title RoundTripper
 * @notice Minimal `IFlashLoanRecipient` that borrows and repays in the same callback.
 *
 *      Its ONLY job is to isolate the Balancer V2 vault from `FlashLoanService` and from
 *      `ArbitragePlugin`, so a test can assert the two things the arbitrage tests cannot:
 *      that the vault really hands out the principal, and that every `feeAmounts` entry is
 *      exactly zero. It performs no swaps, so the round trip is a pure loan: whatever comes out
 *      goes straight back in.
 */
contract RoundTripper is IFlashLoanRecipient {
    using SafeERC20 for IERC20;

    /// @dev The real Balancer V2 vault address (same on every chain). Not a parameter: the whole
    ///      point is to hit the deployed vault, so it is hardcoded exactly as the service does.
    address private constant VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    /// @dev Circle native USDC on Arbitrum.
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    /// @notice Vault balance of the last borrowed token, observed DURING the callback.
    uint256 public observedBalance;
    /// @notice Sum of every `feeAmounts` entry of the last loan. Must be 0 on Balancer V2.
    uint256 public observedFeeSum;
    /// @notice Number of tokens in the last loan.
    uint256 public observedTokenCount;

    event RoundTrip(address indexed caller, uint256 balanceDuring, uint256 feeSum);

    /// @notice Requests a single-token USDC loan from the real Balancer V2 vault.
    function borrow(uint256 amount) external {
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(USDC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        IBalancerVault(VAULT).flashLoan(IFlashLoanRecipient(address(this)), tokens, amounts, "");
    }

    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory
    ) external override {
        for (uint256 i = 0; i < tokens.length; i++) {
            observedBalance = tokens[i].balanceOf(address(this));
            observedFeeSum += feeAmounts[i];
            // Repay principal + fee in the same callback; a vault that requires more will revert.
            tokens[i].forceApprove(msg.sender, amounts[i] + feeAmounts[i]);
            tokens[i].safeTransfer(msg.sender, amounts[i] + feeAmounts[i]);
        }
        observedTokenCount = tokens.length;
        emit RoundTrip(msg.sender, observedBalance, observedFeeSum);
    }
}

/**
 * @title FlashLoanBalancerForkTest
 * @notice Proves the Balancer V2 leg of the architecture against the REAL vault on Arbitrum.
 *
 * WHAT IS ACTUALLY PROVEN HERE (and not in `test/ArbitragePlugin.t.sol`)
 *   The mock suite etches a `MockBalancerVault` at `0xBA12...` and therefore proves nothing about
 *   Balancer. These tests run against the deployed vault bytecode and prove:
 *     1. the hardcoded vault address is a live contract, not an empty account;
 *     2. `flashLoan` really transfers the principal to the recipient and really calls back with
 *        `feeAmounts == 0` - the 0% fee the whole profitability argument rests on;
 *     3. the vault ends the transaction exactly whole;
 *     4. `FlashLoanService`'s three access guards hold against a real EOA caller.
 */
contract FlashLoanBalancerForkTest is ForkBase {
    /// @dev Mirrored from `RoundTripper` so `vm.expectEmit` has an event in scope.
    event RoundTrip(address indexed caller, uint256 balanceDuring, uint256 feeSum);

    /// @dev 2,000 USDC: ~15% of the 13,275.06 USDC the vault actually holds at the pin, so the
    ///      loan is unambiguously fundable from the vault's real balance, not from test credit.
    uint256 internal constant ROUND_TRIP_AMOUNT = 2_000e6;

    RoundTripper internal roundTripper;

    function setUp() public override {
        super.setUp();
        roundTripper = new RoundTripper();
    }

    // ==================== TEST 1 - THE VAULT IS REAL ====================

    function test_VaultAddressHasRealBalancerCode() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        // 49k bytes of deployed bytecode at the hardcoded address. `vm.etch` is not in play
        // anywhere in this suite: this is Arbitrum mainnet's own code.
        assertGt(BALANCER_VAULT.code.length, 1_000, "Balancer vault has no code");
        assertEq(service.getBalancerVault(), BALANCER_VAULT, "service targets a different vault");

        // The vault really is funded on the real chain, and that is what bounds the principal.
        uint256 vaultUsdc = IERC20(USDC).balanceOf(BALANCER_VAULT);
        assertGt(vaultUsdc, ROUND_TRIP_AMOUNT, "premise: vault must hold more than the loan");
        // The loan is a small fraction of the real balance, so no test credit is involved.
        assertLt(ROUND_TRIP_AMOUNT * 100 / vaultUsdc, 50, "premise: loan must be well under the vault balance");
    }

    // ==================== TEST 2 - DIRECT ROUND TRIP ====================

    function test_DirectFlashLoan_HandsOutPrincipal_WithZeroFee_AndVaultEndsWhole() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        uint256 vaultBefore = IERC20(USDC).balanceOf(BALANCER_VAULT);

        // The callback fires with the principal already in hand, with the fee array present and
        // every entry zero. This is the 0% fee claim, measured rather than assumed.
        // The emitter is the RoundTripper helper, not the vault: the vault is the *subject* of
        // the event (checked as data), the helper is what logs it.
        vm.expectEmit(true, false, false, true, address(roundTripper));
        emit RoundTrip(BALANCER_VAULT, ROUND_TRIP_AMOUNT, 0);
        roundTripper.borrow(ROUND_TRIP_AMOUNT);

        assertEq(roundTripper.observedBalance(), ROUND_TRIP_AMOUNT, "callback did not receive the principal");
        assertEq(roundTripper.observedFeeSum(), 0, "Balancer V2 must charge a 0% fee");
        assertEq(roundTripper.observedTokenCount(), 1, "exactly one token was lent");

        // The round trip gave everything back, so the vault's real balance is unchanged.
        assertEq(IERC20(USDC).balanceOf(BALANCER_VAULT), vaultBefore, "vault not made whole");
        assertEq(IERC20(USDC).balanceOf(address(roundTripper)), 0, "round tripper kept a balance");
    }

    // ==================== TEST 3 - SERVICE ACCESS CONTROL ====================

    function test_ExecuteFlashLoan_IsCallableOnlyByTheAuthorizedPlugin() public {
        _skipUnlessForking();

        assertTrue(service.isAuthorizedPlugin(address(plugin)), "plugin must be authorized");
        assertFalse(service.isAuthorizedPlugin(stranger), "stranger must not be authorized");
        assertEq(service.authorizedCaller(), address(plugin), "authorized caller mismatch");

        // Layer 1 of the service's two-layer model: a plain EOA is rejected before the vault is
        // ever contacted, so the real vault cannot be used as an entry point by a third party.
        address[] memory tokens = new address[](1);
        tokens[0] = USDC;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = ROUND_TRIP_AMOUNT;

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FlashLoanService.NotAuthorizedCaller.selector, stranger));
        service.executeFlashLoan(tokens, amounts, "");
    }

    function test_ReceiveFlashLoan_FromEOA_RevertsNotBalancerVault() public {
        _skipUnlessForking();

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(USDC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = ROUND_TRIP_AMOUNT;
        uint256[] memory fees = new uint256[](1);

        // `_inFlashLoan` is false here, but the vault check comes first, so this is rejected for
        // the RIGHT reason - a third party cannot forge the callback even without a loan open.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FlashLoanService.NotBalancerVault.selector, stranger));
        service.receiveFlashLoan(tokens, amounts, fees, "");
    }

    function test_ReceiveFlashLoan_OutsideALoan_RevertsNotInFlashLoan() public {
        _skipUnlessForking();

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(USDC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = ROUND_TRIP_AMOUNT;
        uint256[] memory fees = new uint256[](1);

        // Spoofing the vault address is the only way to get past the first check, and it still
        // fails: the service's own `_inFlashLoan` flag is false outside `executeFlashLoan`.
        // (This is a test-only impersonation; no EOA can be the vault on a real chain.)
        vm.prank(BALANCER_VAULT);
        vm.expectRevert(FlashLoanService.NotInFlashLoan.selector);
        service.receiveFlashLoan(tokens, amounts, fees, "");
    }

    // ==================== TEST 4 - THE PIN IS HONOURED ====================

    function test_PinIsHonoured() public {
        _skipUnlessForking();
        _assertPinnedBlock();
        // The whole fork suite is only reproducible because of this assertion: without
        // `--fork-block-number` the V2 reserves, the V3 price and the whale's balances all move.
        assertGt(block.number, 0, "not running against a fork");
    }
}
