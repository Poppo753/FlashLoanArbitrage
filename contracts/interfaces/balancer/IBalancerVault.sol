// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IFlashLoanRecipient
 * @notice Interface for contracts receiving Balancer V2 flash loans
 * @dev Must be implemented by any contract calling flashLoan
 */
interface IFlashLoanRecipient {
    /**
     * @notice Called by Balancer Vault during flash loan execution
     * @param tokens Array of tokens being borrowed
     * @param amounts Array of amounts being borrowed
     * @param feeAmounts Array of fees (always 0 for Balancer V2!)
     * @param userData Arbitrary data passed from initiator
     */
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}

/**
 * @title IBalancerVault
 * @notice Interface for Balancer V2 Vault flash loans
 * @dev Balancer Vault address is the same on all chains: 0xBA12222222228d8Ba445958a75a0704d566BF2C8
 *
 * KEY FEATURES:
 * - 0% fee flash loans (completely free!)
 * - Multi-token flash loans in single transaction
 * - Large liquidity pool (billions of dollars)
 *
 * USAGE:
 * 1. Contract calls flashLoan() with desired tokens/amounts
 * 2. Vault transfers tokens to recipient
 * 3. Vault calls receiveFlashLoan() on recipient
 * 4. Recipient must repay exact amounts before function returns
 * 5. If not repaid, entire transaction reverts
 *
 * @author Balancer Labs
 */
interface IBalancerVault {
    /**
     * @notice Execute a flash loan
     * @param recipient Contract that will receive the flash loan and be called back
     * @param tokens Array of token addresses to borrow
     * @param amounts Array of amounts to borrow (must match tokens length)
     * @param userData Arbitrary data to pass to recipient's receiveFlashLoan
     *
     * @dev Requirements:
     * - recipient must implement IFlashLoanRecipient
     * - recipient must repay all borrowed amounts before returning
     * - tokens and amounts arrays must have same length
     *
     * @dev Security:
     * - msg.sender to receiveFlashLoan will be the Vault
     * - Always verify msg.sender == vault in receiveFlashLoan
     */
    function flashLoan(
        IFlashLoanRecipient recipient,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}
