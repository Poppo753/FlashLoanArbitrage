# CHECKLIST — Implementazione Balancer + Arbitrum fork

**Data:** 2026-09-26
**Stato:** PASSO 4 del metodo — checklist su base del piano (`ARBITRAGE_ARBITRUM_PLAN.md`)
**Branch:** `feat/integrating`

Legenda: `[ ]` da fare · `[x]` fatto · `⚠️` decisione presa in fase di esecuzione

---

## Fase 0 — Fondamenta (bloccante tutto il resto)

- [ ] **T0.1** `foundry.toml`: `solc = "0.8.27"` (prerequisito `FlashLoanService`), aggiungere `[rpc_endpoints] arbitrum = "${ARBITRUM_RPC_URL}"`, profilo `fork` con `--fork-block-number`. Verifica: `forge build` verde.
- [ ] **T0.2** Copiare `ARBITRUM_RPC_URL` (Alchemy) dal `.env` di TSC al **nostro** `.env` (gitignored, mai committato). ⚠️ Dichiarato all'utente: key Alchemy di TSC, solo lettura, ruotabile.
- [ ] **T0.3** Copiare da TSC (verbatim) `contracts/interfaces/balancer/IBalancerVault.sol` e `contracts/interfaces/IFlashLoanCallback.sol`. Verifica: `forge build` verde.

## Fase 1 — Servizio flash loan (Balancer)

- [ ] **T1.1** Copiare `contracts/services/FlashLoanService.sol` da TSC. Adattare: import OZ v5 (`utils/ReentrancyGuard.sol` invece di `security/`), rimuovere `swap()`/`getExpectedOutput()`/`estimateFromTokenManager()` e relativi import (`ISimpleSwap`, `ITokenManagerForModules`).
- [ ] **T1.2** Applicare **D11**: `authorizedCaller` immutabile in costruzione al posto di `_isRegisteredPlugin(beacon)`; errore `NotAuthorizedCaller(address)`. Conservare `nonReentrant`, `_inFlashLoan`, `NotBalancerVault`, `NotInFlashLoan`, `InsufficientRepayment`, `InvalidAddress`.
- [ ] **T1.3** Verifica build + `forge fmt`. Commit: `feat(contract): port Balancer flash loan service from proven reference (single-caller auth)`.

## Fase 2 — Interfacce di swap

- [ ] **T2.1** Creare `contracts/interfaces/IUniswapV2Router02.sol` (interfaccia **completa**: `swapExactTokensForTokens`, `getAmountsOut`, `factory`, `WETH`). Attenzione: il nostro `IUniswapV2Router.sol` attuale è minimal.
- [ ] **T2.2** Copiare `contracts/interfaces/IUniswapV3Router.sol` da TSC (struct `ExactInputSingleParams`, `exactInputSingle`) + minima `IUniswapV3QuoterV2` per i preventivi.
- [ ] **T2.3** Verifica build + fmt. Commit: `feat(contract): add complete V2 router and V3 router/quoter interfaces`.

## Fase 3 — Il plugin di arbitraggio (cuore)

- [ ] **T3.1** `contracts/ArbitragePlugin.sol`: implements `IFlashLoanCallback`, `Ownable(msg.sender)`, `Pausable`. Campi: `flashLoanService` (lazy: `initialize(address)` `onlyOwner`, una volta sola, `require != address(0)` — ⚠️ serve perché il servizio al deploy vuole già `address(plugin)`, vedi T7.1), `venueA` (V2 router), `venueB` (V3 router+pool fee), `baseToken` (USDC), `quoteToken` (WETH), `minProfitUsdc`, `maxSlippageBps`, `deadlineWindow`.
- [ ] **T3.2** `startArbitrage(uint256 usdcAmount) external onlyOwner whenNotPaused`: chiama `service.executeFlashLoan([USDC],[amount],abi.encode(route,minOut,deadline))`; calcola profitto atteso, verifica `amount + profit >= usdcAmount` **prima** di invocare (fail-fast, risparmio gas).
- [ ] **T3.3** `onFlashLoanReceived(...)`: verifica `msg.sender == service`; snapshot saldo USDC; **swap A** (V2, `swapExactTokensForTokens` con `amountOutMinimum`); **swap B** (V3, `exactInputSingle` con `amountOutMinimum`); slippage via **balance-delta** (pattern SwapManager L698-705); verifica `block.timestamp <= deadline`; profitto = `balanceAfter - balanceBefore`; `require(profit >= minProfitUsdc)`.
- [ ] **T3.4** Sicurezza: callback con token/importi inattesi → `UnexpectedFlashLoan`; doppia esecuzione impedita dal `nonReentrant` del service; `withdrawToken` (pull, non push — vedi audit C2); pausa/kill-switch.
- [ ] **T3.5** `getExpectedProfit(usdcAmount) external view`: stima off-chain per il bot (V2 `getAmountsOut` + V3 quoter, stessa formula del test).
- [ ] **T3.6** Verifica build + fmt + lint. Commit: `feat(contract): add ArbitragePlugin with Balancer flash loan, V2+V3 atomic cycle`.

## Fase 4 — Rimozione perimetro Aave

- [ ] **T4.1** Rimuovere `contracts/FlashArbExecutor.sol`, interfacce Aave, mock Aave da `helpers/Mocks.sol`, `test/FlashArbExecutor.t.sol`. ⚠️ Preservati su branch `Dev` e nella storia git.
- [ ] **T4.2** Commit: `refactor(contract): remove Aave-based executor superseded by Balancer plugin`.

## Fase 5 — Test mock locali (veloci, senza fork)

- [ ] **T5.1** `test/helpers/Mocks.sol`: `MockBalancerVault` (simula `flashLoan`: transfer → callback → `require(balance >= amount)`), `MockV2Router` (prezzi programmabili), `MockV3Router`.
- [ ] **T5.2** `test/ArbitragePlugin.t.sol` (unit, mock): ciclo profittevole ✓, profitto insufficiente → `MinProfitNotMet`, slippage eccessivo → `SlippageExceeded`, deadline scaduto → `DeadlineExpired`, callback non autorizzato → `NotFlashLoanService`, caller non owner → `Unauthorized`, pausa → `EnforcedPause`, callback token inattesi → `UnexpectedFlashLoan`, ritiro token funzionante.
- [ ] **T5.3** `forge test` verde (suite mock). Commit: `test(contract): add local mock suite for ArbitragePlugin (no fork)`.

## Fase 6 — Test su fork Arbitrum (il vero banco di prova)

- [ ] **T6.1** `test/fork/ForkBase.t.sol`: base comune — gate `vm.envOr("FORK_ENABLED", false)` (skip se assente), `FORK_BLOCK_NUMBER` pinnato, costanti indirizzi Arbitrum (Balancer `0xBA12…F2C8`, WETH `0x82aF…Ba1`, USDC `0xaf88…5831`, V2 router `0x4752…d24`, V2 factory `0xf1D7…cf9`, V3 router `0xE592…1564`), whale `0x489e…7C4A`, helper `fundToken()`.
- [ ] **T6.2** `test/fork/FlashLoanBalancer.t.sol`: verifica che il Vault Balancer **esiste sul fork** (`code.length > 0`), che il servizio è deployabile, che un flash loan USDC reale va e torna con fee 0, che `NotBalancerVault`/`NotInFlashLoan` reggono, che `authorizedCaller` è il plugin.
- [ ] **T6.3** `test/fork/Arbitrage.e2e.t.sol` (il test chiave):
  1. deploy servizio + plugin su fork reale;
  2. **whale manipola** la venue A (grande swap WETH→USDC) per creare il disallineamento;
  3. `startArbitrage(...)` sullo stesso blocco;
  4. assert: **profitto > 0**, saldo USDC del plugin cresciuto, Balancer ripagato, nessun revert.
  ⚠️ Se il fork non produce disallineamento sufficiente: dimensionare il trade della whale in base alle riserve lette (`getReserves`) e iterare.
- [ ] **T6.4** `test/fork/Security.t.sol`: `NotAuthorizedCaller` da EOA, `NotBalancerVault` impersonando il Vault, `NotInFlashLoan` fuori prestito, doppio avvio, `Ownable` reale.
- [ ] **T6.5** Suite fork verde sul blocco pinnato. Commit: `test(fork): add Arbitrum fork suite - real Balancer flash loan and forced-displacement arbitrage (pinned block)`.

## Fase 7 — Deploy script

- [ ] **T7.1** `script/Deploy.s.sol`: ⚠️ **dipendenza circolare** — il servizio vuole `authorizedCaller = address(plugin)`, ma il plugin vuole `address(service)`. Soluzione: deploy del **plugin con servizio zero** (lazy init `initialize(service)` protetto da `onlyOwner` + `require(service != address(0))` e check "già inizializzato"), poi `new FlashLoanService(address(plugin))`, poi `plugin.initialize(service)`. Tutti i parametri da env (`ARB_V2_ROUTER`, `ARB_V3_ROUTER`, `ARB_V3_FEE`, `MIN_PROFIT_USDC`, `MAX_SLIPPAGE_BPS`, `OWNER`).
- [ ] **T7.2** Test del deploy script in dry-run su fork. Commit: `feat(script): rewrite Deploy.s.sol for Balancer+Arbitrum with env-driven params`.

## Fase 8 — Bot TypeScript (scope ridotto)

- [ ] **T8.1** `bot/src/config.ts`: chain Arbitrum 42161, WETH/USDC Arbitrum, factory V2 `0xf1D7…cf9`, Balancer `0xBA12…F2C8`, router V2, `MONITOR_TOKENS=WETH,USDC`, rimozione riferimenti Aave/Ethereum.
- [ ] **T8.2** `bot/.env.example` + `.env.example` root: allineati alle nuove variabili. Verifica `npx tsc --noEmit`.
- [ ] **T8.3** ⚠️ **Fuori scope dichiarato**: monitoraggio pool V3, wiring esecuzione/Flashbots (open B6/B8/B24), deploy live. Documentato.
- [ ] **T8.4** Commit: `feat(bot): retarget bot configuration to Arbitrum Balancer setup`.

## Fase 9 — Documentazione post-implementazione

- [ ] **T9.1** `README.md`: architettura nuova (Balancer + V2/V3), comandi (build, test mock, test fork), setup `.env` con `ARBITRUM_RPC_URL`, indirizzi Arbitrum, **quale RPC key usiamo** (tracciabilità), avvertenze (test su fork ≠ trading live).
- [ ] **T9.2** `Docs/IMPLEMENTATION_REPORT.md`: cosa è stato fatto, mapping finding→file, risultati test (con numeri e blocco pinnato), scelte e motivazioni, limiti noti.
- [ ] **T9.3** Aggiornamento `Docs/AUDIT_LOG.md` (nuovo round) + questa checklist marcata `[x]`. Commit: `docs: post-implementation documentation for Balancer/Arbitrum migration`.

## Fase 10 — Verifiche finali (gate di chiusura)

- [ ] **T10.1** `forge build` → 0 errori, **0 warning**
- [ ] **T10.2** `forge lint` → 0 warning
- [ ] **T10.3** `forge fmt --check` → pulito
- [ ] **T10.4** `forge test` (mock, senza fork) → **tutto verde**
- [ ] **T10.5** `forge test --fork-url arbitrum --fork-block-number <PIN>` → **tutto verde**
- [ ] **T10.6** `npx tsc --noEmit` (bot/) → 0 errori
- [ ] **T10.7** `git status` pulito; `git log` leggibile con un commit per milestone
- [ ] **T10.8** Verifica finale indipendente (agente) sui contratti: nessun bug di logica/security, nessun TODO risolto a metà

---

## Note di esecuzione

1. **Mai toccare** `E:\…\TestSmartContract` (sola lettura).
2. **Parallelismo**: le fasi 1-3 toccano file diversi ma F1 (Fase 1) è prerequisito di F3 (Fase 3, perché il plugin usa il servizio). Si parallelizzano: (F1, F2) insieme, poi (F3, F5) insieme, poi (F6) da sola perché tocca tutto, poi (F7, F8) in parallelo.
3. **Ogni fase = commit** con messaggio esplicativo.
4. Se un test fork fallisce: **non** si allarga il contratto per farlo passare. Si corregge la logica o si documenta il limite.
