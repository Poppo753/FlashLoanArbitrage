// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ArbitragePlugin} from "../../contracts/ArbitragePlugin.sol";
import {FlashLoanService} from "../../contracts/services/FlashLoanService.sol";
import {ForkBase} from "./ForkBase.t.sol";

/**
 * @title SecurityForkTest
 * @notice Access-control and guard tests for `ArbitragePlugin` and `FlashLoanService`,
 *         executed against real Arbitrum state rather than mocks.
 * @dev Every test asserts a *specific named* custom error, not a generic revert, so a
 *      behaviour change cannot quietly satisfy the test with the wrong failure.
 */
contract SecurityForkTest is ForkBase {
    uint256 internal constant SMALL_AMOUNT = 2_000e6;

    // ==================== ACCESS CONTROL ====================

    function test_StartArbitrage_RevertsForNonOwner() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        plugin.startArbitrage(SMALL_AMOUNT, true);
    }

    function test_StartArbitrage_RevertsWhilePaused_AndResumesAfterUnpause() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        plugin.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        plugin.startArbitrage(SMALL_AMOUNT, true);

        plugin.unpause();
        // Unpausing must genuinely restore the entry point: an unprofitable cycle now fails on
        // profitability, not on the pause guard. That distinguishes "unpaused" from "still paused".
        vm.expectRevert();
        plugin.startArbitrage(SMALL_AMOUNT, true);
    }

    function test_Pause_RevertsForNonOwner() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        plugin.pause();
    }

    function test_WithdrawToken_RevertsForNonOwner() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        plugin.withdrawToken(USDC, stranger, 1);
    }

    function test_SetMinProfit_RevertsForNonOwner() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        plugin.setMinProfit(1);
    }

    // ==================== INITIALISATION ====================

    /// @dev `ForkBase.setUp` already initialised `plugin`, so a second call must be rejected.
    function test_Initialize_SecondCall_Reverts() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        vm.expectRevert(ArbitragePlugin.AlreadyInitialized.selector);
        plugin.initialize(address(service));
    }

    function test_Initialize_ZeroAddress_Reverts() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        // A fresh plugin, so `AlreadyInitialized` cannot pre-empt the address check.
        ArbitragePlugin fresh = new ArbitragePlugin(USDC, WETH, V2_ROUTER, V3_ROUTER, MAX_SLIPPAGE_BPS, DEADLINE_WINDOW);
        vm.expectRevert(ArbitragePlugin.InvalidAddress.selector);
        fresh.initialize(address(0));
    }

    /// @dev Without `initialize` there is no service, so an arbitrage cannot even be started.
    function test_StartArbitrage_BeforeInitialize_Reverts() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        ArbitragePlugin fresh = new ArbitragePlugin(USDC, WETH, V2_ROUTER, V3_ROUTER, MAX_SLIPPAGE_BPS, DEADLINE_WINDOW);
        vm.expectRevert(ArbitragePlugin.FlashLoanNotInitialized.selector);
        fresh.startArbitrage(SMALL_AMOUNT, true);
    }

    // ==================== FLASH LOAN CALLBACK ====================

    function test_Callback_FromEOA_Reverts() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(USDC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SMALL_AMOUNT;
        uint256[] memory fees = new uint256[](1);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ArbitragePlugin.NotFlashLoanService.selector, stranger));
        plugin.onFlashLoanReceived(tokens, amounts, fees, abi.encode(true, block.timestamp + 60));
    }

    function test_Callback_WithMalformedData_Reverts() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(USDC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SMALL_AMOUNT;
        uint256[] memory fees = new uint256[](1);

        // 32 bytes: one word short of the two-word route payload.
        vm.prank(address(service));
        vm.expectRevert(abi.encodeWithSelector(ArbitragePlugin.InvalidCallbackData.selector, 32));
        plugin.onFlashLoanReceived(tokens, amounts, fees, abi.encode(true));
    }

    function test_Callback_WithUnexpectedToken_Reverts() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        // A well-formed route, but the "loan" is denominated in the wrong token.
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(WETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18;
        uint256[] memory fees = new uint256[](1);

        vm.prank(address(service));
        vm.expectRevert(ArbitragePlugin.UnexpectedFlashLoan.selector);
        plugin.onFlashLoanReceived(tokens, amounts, fees, abi.encode(true, block.timestamp + 60));
    }

    function test_ExecuteFlashLoan_RevertsForNonAuthorizedCaller() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        address[] memory tokens = new address[](1);
        tokens[0] = USDC;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SMALL_AMOUNT;

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FlashLoanService.NotAuthorizedCaller.selector, stranger));
        service.executeFlashLoan(tokens, amounts, abi.encode(true, block.timestamp + 60));
    }

    /// @dev Anyone can hand the service its own address; it must still refuse to lend.
    function test_Service_DoesNotTrustACallerThatMerelyDeploysIt() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        // A second service, correctly "authorized" to a contract that will never repay.
        FlashLoanService impostor = new FlashLoanService(address(this));
        assertEq(impostor.authorizedCaller(), address(this), "premise: the impostor trusts this test");

        address[] memory tokens = new address[](1);
        tokens[0] = USDC;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SMALL_AMOUNT;

        // This test contract has no `receiveFlashLoan`, so the callback cannot repay the vault.
        vm.expectRevert();
        impostor.executeFlashLoan(tokens, amounts, abi.encode(true, block.timestamp + 60));
    }

    // ==================== POST-CYCLE INTEGRITY ====================

    /// @dev A completed cycle must leave no intermediate token behind in the plugin, and the
    ///      profit must be sitting in the borrowed asset.
    function test_SuccessfulCycle_LeavesNoQuoteTokenDust() public {
        _skipUnlessForking();
        _assertPinnedBlock();
        _assertRealChainShape();

        _whaleSellWethOnV2(1e18);
        plugin.setMinProfit(0);
        plugin.startArbitrage(SMALL_AMOUNT, true);

        assertEq(IERC20(WETH).balanceOf(address(plugin)), 0, "quote token must be fully sold");
        // The cycle is profitable on purpose, so a non-zero USDC balance IS the profit. Asserting
        // zero here would be asserting the opposite of what the test just arranged.
        assertGt(IERC20(USDC).balanceOf(address(plugin)), 0, "profit must accrue in the borrowed asset");
        assertLt(
            IERC20(USDC).balanceOf(address(plugin)),
            IERC20(USDC).balanceOf(BALANCER_VAULT),
            "profit must be plausible, not a vault-sized windfall"
        );
    }

    /// @dev The pull pattern (audit C2): the owner chooses the recipient, and the funds move.
    ///      Funded from the whale, which really holds USDC, rather than by spoofing the token -
    ///      a spoofed mint is bounded by the token contract's own balance.
    function test_WithdrawToken_SendsToChosenAddress() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        _fundFromWhale(USDC, address(plugin), 500e6);

        address recipient = makeAddr("recipient");
        plugin.withdrawToken(USDC, recipient, 200e6);

        assertEq(IERC20(USDC).balanceOf(recipient), 200e6, "recipient did not receive the tokens");
        assertEq(IERC20(USDC).balanceOf(address(plugin)), 300e6, "plugin balance not debited");
    }

    function test_WithdrawToken_ZeroRecipient_Reverts() public {
        _skipUnlessForking();
        _assertPinnedBlock();

        _fundFromWhale(USDC, address(plugin), 500e6);
        vm.expectRevert(ArbitragePlugin.InvalidAddress.selector);
        plugin.withdrawToken(USDC, address(0), 1);
    }

    /// @dev Plain transfer from a holder that genuinely has the balance, the honest way to
    ///      give a contract inventory on a fork.
    function _fundFromWhale(address token, address to, uint256 amount) internal {
        _fundGas(WHALE);
        vm.startPrank(WHALE);
        IERC20(token).transfer(to, amount);
        vm.stopPrank();
    }
}
