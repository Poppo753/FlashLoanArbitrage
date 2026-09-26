// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IFlashLoanCallback
 * @notice Interface che ogni plugin deve implementare per ricevere callback dal FlashLoanService
 * @dev Il FlashLoanService chiama onFlashLoanReceived dopo aver trasferito i token flash loan.
 *      Il plugin deve eseguire la sua logica e restituire i token al FlashLoanService.
 *
 * FLUSSO:
 * 1. Plugin chiama FlashLoanService.executeFlashLoan(...)
 * 2. FlashLoanService richiede flash loan a Balancer
 * 3. Balancer chiama FlashLoanService.receiveFlashLoan()
 * 4. FlashLoanService trasferisce token al plugin
 * 5. FlashLoanService chiama plugin.onFlashLoanReceived()
 * 6. Plugin esegue logica (swap, deposit, borrow, etc.)
 * 7. Plugin trasferisce token di ritorno al FlashLoanService
 * 8. FlashLoanService ripaga Balancer
 *
 * @author Project4 Team
 */
interface IFlashLoanCallback {
    /**
     * @notice Callback chiamato dal FlashLoanService dopo aver ricevuto i token flash loan
     * @param tokens Array di token ricevuti dal flash loan
     * @param amounts Array di importi ricevuti
     * @param feeAmounts Array di fee (sempre 0 per Balancer V2!)
     * @param callbackData Dati arbitrari passati dal plugin in executeFlashLoan
     *
     * @dev IMPORTANTE:
     *      - I token sono GIA' nel plugin quando viene chiamato questo metodo
     *      - Il plugin DEVE trasferire (amounts[i] + feeAmounts[i]) di ogni token
     *        INDIETRO al FlashLoanService prima di ritornare
     *      - Se il plugin non restituisce abbastanza token, l'intera transazione reverta
     *
     * @dev SICUREZZA:
     *      - Verificare che msg.sender sia il FlashLoanService autorizzato
     *      - Non fidarsi di callbackData senza validazione
     */
    function onFlashLoanReceived(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory callbackData
    ) external;
}
