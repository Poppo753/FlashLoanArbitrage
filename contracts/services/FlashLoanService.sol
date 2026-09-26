// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/balancer/IBalancerVault.sol";
import "../interfaces/IFlashLoanCallback.sol";

/**
 * @title FlashLoanService
 * @notice Servizio centralizzato per flash loans Balancer V2 (0% fee!)
 * @dev Deployato UNA sola volta, riutilizzato dal caller autorizzato.
 *
 * ARCHITETTURA:
 * - Implementa IFlashLoanRecipient per callback Balancer
 * - Usa un singolo caller autorizzato (address) per verificare chi puo' avviare il flash loan
 * - Double-layer security: authorized caller check + Trust The Revert
 *
 * SICUREZZA:
 * - Layer 1 (Authorized Caller Check): Solo authorizedCaller puo' avviare un flash loan
 * - Layer 2 (Trust The Revert): Se il caller non restituisce i token, tutto reverta
 *
 * FLUSSO:
 * 1. Caller autorizzato chiama executeFlashLoan(tokens, amounts, callbackData)
 * 2. Service verifica il caller
 * 3. Service richiede flash loan a Balancer
 * 4. Balancer chiama receiveFlashLoan()
 * 5. Service trasferisce token al caller
 * 6. Service chiama caller.onFlashLoanReceived()
 * 7. Il caller esegue logica e restituisce token al Service
 * 8. Service ripaga Balancer
 *
 * INDIRIZZI ARBITRUM:
 * - Balancer Vault: 0xBA12222222228d8Ba445958a75a0704d566BF2C8 (0% fee!)
 *
 * @author Project4 Team
 * @custom:version 1.0.0
 */
contract FlashLoanService is IFlashLoanRecipient, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ==================== CONSTANTS ====================

    /// @notice Balancer V2 Vault (same on all chains, 0% fee!)
    address public constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    // ==================== IMMUTABLES ====================

    /// @notice Unico caller autorizzato a richiedere flash loan
    address public immutable authorizedCaller;

    // ==================== STATE ====================

    /// @notice Flag anti-reentrancy per callback flash loan
    bool private _inFlashLoan;

    /// @notice Contesto temporaneo durante flash loan
    FlashLoanContext private _context;

    // ==================== STRUCTS ====================

    /// @notice Contesto salvato durante flash loan
    struct FlashLoanContext {
        address caller; // Caller che ha richiesto il flash loan
        bytes callbackData; // Dati da passare al callback
    }

    // ==================== ERRORS ====================

    error NotAuthorizedCaller(address caller);
    error NotBalancerVault(address caller);
    error NotInFlashLoan();
    error ReentrantCall();
    error InsufficientRepayment(address token, uint256 required, uint256 available);
    error InvalidAddress();

    // ==================== EVENTS ====================

    event FlashLoanExecuted(address indexed caller, address indexed token, uint256 amount, uint256 fee);

    // ==================== CONSTRUCTOR ====================

    /**
     * @notice Costruttore del servizio
     * @param authorizedCaller_ Indirizzo dell'unico caller autorizzato
     */
    constructor(address authorizedCaller_) {
        require(authorizedCaller_ != address(0), InvalidAddress());
        authorizedCaller = authorizedCaller_;
    }

    // ==================== MAIN FUNCTIONS ====================

    /**
     * @notice Esegue un flash loan per conto del caller autorizzato
     * @param tokens Array di token da prendere in prestito
     * @param amounts Array di importi da prendere in prestito
     * @param callbackData Dati da passare al caller nel callback
     *
     * @dev SICUREZZA:
     *      - Layer 1: Verifica che msg.sender sia il caller autorizzato
     *      - Layer 2: Se il caller non restituisce i token, Balancer reverta tutto
     */
    function executeFlashLoan(address[] calldata tokens, uint256[] calldata amounts, bytes calldata callbackData)
        external
        nonReentrant
    {
        // ===============================================
        // LAYER 1: Authorized Caller Check
        // ===============================================
        if (!_isAuthorizedCaller(msg.sender)) {
            revert NotAuthorizedCaller(msg.sender);
        }

        // Prevent reentrant flash loans
        if (_inFlashLoan) revert ReentrantCall();

        // Store context for callback
        _context = FlashLoanContext({caller: msg.sender, callbackData: callbackData});

        // Set flash loan flag
        _inFlashLoan = true;

        // Convert to IERC20 array for Balancer
        IERC20[] memory ierc20Tokens = new IERC20[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            ierc20Tokens[i] = IERC20(tokens[i]);
        }

        // Request flash loan from Balancer
        // Safe: _inFlashLoan is already true (set above) and the entry point is nonReentrant,
        // so a reentrant executeFlashLoan is impossible; the callback path re-checks both flags.
        // Mechanics preserved verbatim from the proven reference implementation.
        // forge-lint: disable-start(reentrancy-no-eth)
        IBalancerVault(BALANCER_VAULT)
            .flashLoan(
                IFlashLoanRecipient(address(this)),
                ierc20Tokens,
                amounts,
                "" // userData not needed, we use storage
            );
        // forge-lint: disable-end(reentrancy-no-eth)

        // Clear state
        _inFlashLoan = false;
        delete _context;
    }

    /**
     * @notice Callback da Balancer Vault
     * @param tokens Array di token ricevuti
     * @param amounts Array di importi ricevuti
     * @param feeAmounts Array di fee (sempre 0!)
     *
     * @dev SICUREZZA: Verifica che msg.sender sia Balancer Vault
     */
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory
    ) external override {
        // Security: verify caller is Balancer Vault
        if (msg.sender != BALANCER_VAULT) revert NotBalancerVault(msg.sender);
        if (!_inFlashLoan) revert NotInFlashLoan();

        FlashLoanContext memory ctx = _context;

        // Step 1: Transfer flash loan tokens to the plugin
        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i].safeTransfer(ctx.caller, amounts[i]);
        }

        // Step 2: Call plugin callback
        // Plugin must execute its logic and transfer tokens back
        IFlashLoanCallback(ctx.caller).onFlashLoanReceived(tokens, amounts, feeAmounts, ctx.callbackData);

        // ===============================================
        // LAYER 2: Trust The Revert
        // ===============================================
        // Step 3: Repay Balancer (will revert if insufficient balance)
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 repayAmount = amounts[i] + feeAmounts[i];

            // Safe: read-only balanceOf on a token we already hold; the loop is
            // bounded by the caller-supplied array length, same as the source.
            // forge-lint: disable-next-line(calls-loop)
            uint256 balance = tokens[i].balanceOf(address(this));

            // Safe: reverting on underpayment is the "trust the revert" guarantee - the
            // whole transaction unwinds if the plugin returned less than it borrowed.
            // forge-lint: disable-start(require-revert-in-loop)
            if (balance < repayAmount) {
                revert InsufficientRepayment(address(tokens[i]), repayAmount, balance);
            }
            // forge-lint: disable-end(require-revert-in-loop)

            // Transfer to Balancer Vault
            tokens[i].safeTransfer(BALANCER_VAULT, repayAmount);

            // Safe: the whole transaction reverts atomically if repayment fails, so
            // this log cannot survive an inconsistent state.
            // forge-lint: disable-next-line(reentrancy-events)
            emit FlashLoanExecuted(ctx.caller, address(tokens[i]), amounts[i], feeAmounts[i]);
        }
    }

    // ==================== INTERNAL FUNCTIONS ====================

    /**
     * @notice Verifica se un indirizzo e' il caller autorizzato
     * @param plugin Indirizzo da verificare
     * @return isAuthorized True se e' il caller autorizzato
     */
    function _isAuthorizedCaller(address plugin) internal view returns (bool) {
        return plugin == authorizedCaller;
    }

    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Ritorna indirizzo Balancer Vault
     * @return Indirizzo del vault
     */
    function getBalancerVault() external pure returns (address) {
        return BALANCER_VAULT;
    }

    /**
     * @notice Verifica se un indirizzo e' autorizzato
     * @param plugin Indirizzo da verificare
     * @return True se autorizzato
     */
    function isAuthorizedPlugin(address plugin) external view returns (bool) {
        return _isAuthorizedCaller(plugin);
    }
}
