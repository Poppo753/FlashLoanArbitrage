# ✅ FLASH LOAN ARBITRAGE — CHECKLIST DI IMPLEMENTAZIONE COMPLETA

> **Versione**: 1.0  
> **Data**: 26/09/2026  
> **Scope**: Implementazione completa del sistema Flash Loan Arbitrage  
> **Status**: Da completare fase per fase

---

## INDICE

- [FASE 0: PREPARAZIONE E PIANIFICAZIONE](#fase-0-preparazione-e-pianificazione)
- [FASE 1: SETUP INFISETTRUCTURE E SVILUPPO](#fase-1-setup-infrastruttura-e-sviluppo)
- [FASE 2: CONTRATTO SMART — SVILUPPO CORE](#fase-2-contratto-smart--sviluppo-core)
- [FASE 3: TESTING E VALIDAZIONE](#fase-3-testing-e-validAZIONE)
- [FASE 4: OFF-CHAIN SCANNER E INFRASTRUCTURE](#fase-4-off-chain-scanner-e-infrastructure)
- [FASE 5: INTEGRAZIONE MEV/FLASHBOTS](#fase-5-integRAZIONE-mevflashbots)
- [FASE 6: DEPLOYMENT PRODUZIONE](#fase-6-deployment-produzione)
- [FASE 7: OPERAZIONALITÀ E MONITORAGGIO](#fase-7-operazionalità-e-monitoraggio)
- [FASE 8: OTTIMIZZAZIONE E SCALING](#fase-8-ottimizzazione-e-scaling)
- [FASE 9: MANUTENZIONE E EVOLUZIONE](#fase-9-manutenzione-e-evoluzione)

---

## FASE 0: PREPARAZIONE E PIANIFICAZIONE

### Fase 0.1: Definizione del Progetto

- [ ] **0.1.1** Definire l'obiettivo principale del progetto
  - [ ] Obiettivo: "Eseguire flash loan arbitrage su Ethereum L2 (Base/Arbitrum)"
  - [ ] Obiettivo alternativo: "Deploy multi-chain (Ethereum + Base + Polygon)"
  - [ ] Definire il KPI di successo (es. profitto netto mensile > $1,000)
- [ ] **0.1.2** Definire il budget totale del progetto
  - [ ] Budget setup iniziale: $2,000-$5,000
  - [ ] Budget operativo mensile: $200-$1,000
  - [ ] Budget contingenza (imprevisti): $1,000
  - [ ] Confermare disponibilità fondi
- [ ] **0.1.3** Definire il timeline del progetto
  - [ ] Settimana 1-2: Setup infrastruttura + sviluppo contratto base
  - [ ] Settimana 3-4: Testing + scanner base
  - [ ] Settimana 5-6: Integrazione Flashbots + deployment testnet
  - [ ] Settimana 7-8: Mainnet deployment + live testing
  - [ ] Settimana 9-12: Ottimizzazione + scaling
  - [ ] Milestone documentata e condivisa con il team

### Fase 0.2: Analisi Competitiva

- [ ] **0.2.1** Ricerca sui competitor esistenti
  - [ ] Identificare i principali bot MEV attivi (Flashbots analytics, EigenPhi)
  - [ ] Analizzare i loro profitti stimati (Dune Analytics dashboards)
  - [ ] Valutare il livello di competizione su Ethereum mainnet
  - [ ] Valutare il livello di competizione su L2 (Base, Arbitrum, Polygon)
- [ ] **0.2.2** Analisi delle opportunità
  - [ ] Identificare quali DEX e pool hanno più opportunità
  - [ ] Verificare le fee di flash loan per ogni protocollo (Aave, Maker, Euler)
  - [ ] Confrontare gas costs tra Ethereum mainnet e L2
  - [ ] Documentare le findings in un report interno
- [ ] **0.2.3** Definire la strategia differenziale
  - [ ] Perché il nostro bot sarà vincente?
  - [ ] Opzioni: costi più bassi, L2 deployment, multi-chain, algoritmo superiore
  - [ ] Documentare il vantaggio competitivo scelto

### Fase 0.3: Studio Legale e Regolamentare

- [ ] **0.3.1** Verificare la legalità del flash loan arbitrage
  - [ ] Consultare un avvocato specializzato in cripto/DeFi (se possibile)
  - [ ] Verificare regolamentazione nel paese di residenza
  - [ ] Verificare se MEV extraction è considerata legale
  - [ ] Documentare le conclusioni
- [ ] **0.3.2** Compliance fiscale
  - [ ] Capire come vengono tassati i profitti MEV/arbitraggio
  - [ ] Configurare un sistema di tracking delle transazioni fiscali
  - [ ] Consultare un commercialista se necessario
- [ ] **0.3.3** Terms of Service
  - [ ] Verificare i ToS di Aave, Uniswap, e altri protocolli
  - [ ] Verificare che i flash loan non siano vietati
  - [ ] Verificare i ToS dei RPC provider

### Fase 0.4: Acquisizione Conoscenze

- [ ] **0.4.1** Studio Solidity avanzato
  - [ ] Leggere il codice sorgente di Aave V3
  - [ ] Comprendere la libreria `IFlashLoanSimpleReceiver`
  - [ ] Studiare la sicurezza dei contratti DeFi (reentrancy, oracle manipulation)
  - [ ] Risorsa: Solidity by Example, CryptoZombies, CryptoMatex
- [ ] **0.4.2** Studio AMM e Pricing
  - [ ] Comprendere il modello x*y=k in dettaglio
  - [ ] Studiare Uniswap V3 concentrated liquidity
  - [ ] Comprendere l'impatto di slippage e price impact
  - [ ] Risorsa: whitepaper Uniswap, blog di Vitalik Buterin
- [ ] **0.4.3** Studio MEV e Flashbots
  - [ ] Leggere la documentazione Flashbots MEV-Share
  - [ ] Comprendere PBS (Proposer-Builder Separation)
  - [ ] Studiare il funzionamento dei bundle privati
  - [ ] Risorsa: docs.flashbots.net, blog Flashbots
- [ ] **0.4.4** Studio di Game Theory e Economia MEV
  - [ ] Leggere l'articolo arXiv 2606.00720
  - [ ] Comprendere il Nash equilibrium nei mercati MEV
  - [ ] Studiare il paper NUS AIDF su flash loans
  - [ ] Risorsa: marketmaker.cc blog
- [ ] **0.4.5** Studio di Node.js/Rust (per scanner)
  - [ ] Se usare Rust: studiare ethers-rs, tokio, serde
  - [ ] Se usare TypeScript: studiare ethers.js v6, wss
  - [ ] Imparare a fare WebSocket subscription ai blocchi
  - [ ] Imparare a fare chiamate `eth_call` per simulazione

---

## FASE 1: SETUP INFRASTRUTTURA E SVILUPPO

### Fase 1.1: Setup Ambiente di Sviluppo

- [ ] **1.1.1** Installare Node.js e npm/yarn
  - [ ] Versione richiesta: Node.js 18+
  - [ ] Verificare con `node --version` e `npm --version`
  - [ ] Installare package manager (npm o yarn)
- [ ] **1.1.2** Installare Foundry (alternativa a Hardhat)
  - [ ] Installare `foundryup`: `curl -L https://foundry.paradigm.xyz | bash`
  - [ ] Verificare con `forge --version`
  - [ ] Testare la compilazione con un progetto di esempio
- [ ] **1.1.3** Installare Hardhat (alternativa a Foundry)
  - [ ] `npm install --save-dev hardhat`
  - [ ] Inizializzare progetto: `npx hardhat init`
  - [ ] Verificare la configurazione
- [ ] **1.1.4** Configurare l'editor e gli strumenti
  - [ ] Installare VS Code con estensioni Solidity (Solidity extension)
  - [ ] Configurare Prettier per formattazione del codice
  - [ ] Configurare ESLint per JavaScript/TypeScript
  - [ ] Installare Git per versionamento
- [ ] **1.1.5** Creare la struttura del progetto
  - [ ] Creare repository Git
  - [ ] Creare struttura directory:
    ```
    /flashloan-arb/
    ├── contracts/
    │   ├── FlashArbExecutor.sol
    │   ├── interfaces/
    │   └── lib/
    ├── script/
    │   ├── Deploy.s.sol
    │   └── Test.s.sol
    ├── test/
    │   ├── FlashArbExecutor.t.sol
    │   └── helpers/
    ├── bot/
    │   ├── src/
    │   ├── Cargo.toml (se Rust)
    │   └── config.toml
    ├── deploy/
    │   └── addresses.json
    ├── docs/
    ├── .env.example
    ├── .gitignore
    └── README.md
    ```
  - [ ] Creare `.gitignore` con entry per `.env`, `cache`, `artifacts`
  - [ ] Creare `README.md` con setup instructions
- [ ] **1.1.6** Configurare i file di configurazione
  - [ ] Creare `.env.example` con tutte le variabili necessarie
  - [ ] Creare `.env` con valori reali (mai committare!)
  - [ ] Variabili necessarie:
    - `PRIVATE_KEY`: chiave privata del wallet
    - `RPC_URL`: URL del nodo RPC (Alchemy/Infura)
    - `FLASHBOTS_SECRET`: segreti per MEV-Share
    - `ETHERSCAN_API_KEY`: per verifica contratti
    - `ALCHEMY_API_KEY`: per accesso RPC

### Fase 1.2: Setup Wallet e Fondi

- [ ] **1.2.1** Creare un wallet dedicatedo
  - [ ] Usare hardware wallet (Ledger/Trezor) per produzione
  - [ ] Per testnet: creare un wallet con chiave privata sicura
  - [ ] Mai condividere la chiave privata
  - [ ] Salvare il seed phrase in luogo sicuro (fisico, non digitale)
- [ ] **1.2.2** Ottenere fondi per testnet
  - [ ] Richiedere ETH di testnet da Goerli faucet
  - [ ] Richiedere USDC/MATIC da Mumbai faucet
  - [ ] Verificare che i fondi siano nel wallet
- [ ] **1.2.3** Ottenere fondi per mainnet (fase di deploy)
  - [ ] Depositare ETH per gas (~0.5-1 ETH per deploy + test)
  - [ ] Considerare un multi-sig wallet per fondi grandi
  - [ ] Configurare il wallet come owner del contratto

### Fase 1.3: Setup Nodo RPC

- [ ] **1.3.1** Scegliere il provider RPC
  - [ ] Opzione A: Alchemy (raccomandato, 100K+ rpm)
  - [ ] Opzione B: Infura (alternativa solida)
  - [ ] Opzione C: QuickNode (buono per multi-chain)
  - [ ] Opzione D: Nodo proprio (costoso ma massima controllo)
- [ ] **1.3.2** Configurare l'accesso WebSocket
  - [ ] Creare un endpoint WSS per subscription agli eventi
  - [ ] Testare la connessione WebSocket
  - [ ] Configurare reconnection automatica
  - [ ] Verificare la latenza del RPC (ping < 100ms)
- [ ] **1.3.3** Setup multi-chain RPC
  - [ ] Ethereum Mainnet RPC URL
  - [ ] Base RPC URL
  - [ ] Arbitrum RPC URL
  - [ ] Polygon RPC URL
  - [ ] Testare ogni connessione

### Fase 1.4: Setup Database e Storage

- [ ] **1.4.1** Configurare il database PostgreSQL
  - [ ] Installare PostgreSQL (locale o cloud: Supabase, Neon, Railway)
  - [ ] Creare il database `flashloan_arb`
  - [ ] Creare le tabelle: `opportunities`, `executions`, `pool_states`
  - [ ] Configurare gli indici appropriati
  - [ ] Testare la connessione
- [ ] **1.4.2** Configurare Redis (cache)
  - [ ] Installare Redis (locale o cloud: Upstash, Redis Cloud)
  - [ ] Configurare caching per dati di pool
  - [ ] Configurare rate limiting
  - [ ] Testare la connessione
- [ ] **1.4.3** Configurare il file storage
  - [ ] Configurare storage per log e backup
  - [ ] Opzione: AWS S3, GCP Cloud Storage, o locale
  - [ ] Configurare il retention policy
  - [ ] Testare upload/download

### Fase 1.5: Setup Alerting e Comunicazioni

- [ ] **1.5.1** Configurare Discord Webhook
  - [ ] Creare un server Discord dedicato
  - [ ] Creare un canale #alerts
  - [ ] Configurare un webhook URL
  - [ ] Testare l'invio di un messaggio tramite webhook
- [ ] **1.5.2** Configurare Telegram Bot (opzionale)
  - [ ] Creare un bot con BotFather
  - [ ] Ottenere il token del bot
  - [ ] Ottenere il chat ID
  - [ ] Testare l'invio di un messaggio
- [ ] **1.5.3** Configurare Email Alerts (opzionale)
  - [ ] Configurare SMTP (SendGrid, Mailgun, o SMTP personale)
  - [ ] Configurare l'indirizzo email di destinazione
  - [ ] Testare l'invio di un'email

---

## FASE 2: CONTRATTO SMART — SVILUPPO CORE

### Fase 2.1: Interfacce e Dipendenze

- [ ] **2.1.1** Installare le dipendenze del progetto
  - [ ] `npm install @aave/core-v3` (interfacce Aave V3)
  - [ ] `npm install @openzeppelin/contracts` (librerie di sicurezza)
  - [ ] `npm install @uniswap/v2-periphery` (interfacce Uniswap V2)
  - [ ] Verificare che tutte le dipendenze siano installate e compilabili
- [ ] **2.1.2** Creare le interfacce personalizzate
  - [ ] `IFlashLoanSimpleReceiver.sol` — interfaccia callback Aave
  - [ ] `IUniswapV2Router.sol` — interfaccia router Uniswap
  - [ ] `IPool.sol` — interfaccia Aave Pool
  - [ ] `IERC20.sol` — interfaccia token ERC20
  - [ ] `ISwapRouter.sol` — interfaccia router Uniswap V3 (opzionale)
- [ ] **2.1.3** Verificare le interfacce installate
  - [ ] Controllare che `@aave/core-v3` esporti `IFlashLoanSimpleReceiver`
  - [ ] Controllare che `@uniswap/v2-periphery` esporti `IUniswapV2Router`
  - [ ] Verificare la compatibilità delle versioni

### Fase 2.2: Sviluppo Contratto Base

- [ ] **2.2.1** Scrivere il contratto `FlashArbExecutor.sol`
  - [ ] Definire lo stato del contratto (owner, pool, minProfit)
  - [ ] Implementare `IFlashLoanSimpleReceiver`
  - [ ] Scrivere la funzione `executeOperation()`
  - [ ] Scrivere la funzione `executeArbitrage()`
  - [ ] Implementare `withdrawToken()` e `withdrawETH()`
  - [ ] Aggiungere il modificatore `onlyOwner`
  - [ ] Aggiungere eventi per ogni azione significativa
- [ ] **2.2.2** Implementare la logica di swap
  - [ ] Funzione `_executeSwap()` — esegue uno swap su Uniswap V2
  - [ ] Validare `amountOutMin` (slippage protection)
  - [ ] Impostare `deadline` (tempo massimo di validità)
  - [ ] Approvare il router per il token da scambiare
  - [ ] Chiamare `swapExactTokensForTokens()`
  - [ ] Verificare l'output dello swap
- [ ] **2.2.3** Implementare il check di profitto
  - [ ] Calcolare `totalOwed = amount + premium`
  - [ ] Verificare `balanceOf(address(this)) >= totalOwed + minProfit`
  - [ ] `require` con messaggio chiaro se fallisce
  - [ ] Approvare il rimborso al pool Aave
  - [ ] Restituire `true` per successo
- [ ] **2.2.4** Implementare `withdrawToken()` e `withdrawETH()`
  - [ ] `withdrawToken(address token)` — trasferisci ERC20 stuck
  - [ ] `withdrawETH()` — trasferisci ETH stuck
  - [ ] Aggiungere modificatore `onlyOwner`
  - [ ] Aggiungere evento `Withdrawal`
- [ ] **2.2.5** Aggiungere `ReentrancyGuard`
  - [ ] Importare `ReentrancyGuard` da OpenZeppelin
  - [ ] Aggiungere `nonReentrant` a `executeOperation()`
  - [ ] Verificare che previene attacchi di reentrancy

### Fase 2.3: Sviluppo Contratto Avanzato (V2)

- [ ] **2.3.1** Supporto multi-hop arbitrage
  - [ ] Modificare `executeOperation()` per supportare N swap
  - [ ] Ricevere un array di percorsi nei `params`
  - [ ] Iterare su ogni percorso eseguendo gli swap
  - [ ] Verificare il profitto finale dopo tutti gli swap
- [ ] **2.3.2** Supporto multi-token flash loan
  - [ ] Implementare `executeFlashLoan()` multi-asset (Aave V3)
  - [ ] Gestire arrays di assets e amounts
  - [ ] Calcolare premiums multipli
  - [ ] Verificare il rimborso totale
- [ ] **2.3.3** Circuit breaker
  - [ ] Aggiungere `paused` boolean state
  - [ ] Aggiungere `pause()` e `unpause()` funzioni
  - [ ] Bloccare le operazioni quando `paused = true`
  - [ ] Verificare che nessuno possa eseguire quando pausato
- [ ] **2.3.4** Max transaction size limit
  - [ ] Aggiungere `maxLoanAmount` costante
  - [ ] Verificare `amount <= maxLoanAmount` prima del flash loan
  - [ ] Prevenire flash loan troppo grandi per la liquidity pool
- [ ] **2.3.5** Cooldown tra esecuzioni
  - [ ] Aggiungere `lastExecutionTimestamp` state
  - [ ] Verificare `block.timestamp - lastExecution >= cooldown`
  - [ ] Prevenire spam del contratto

### Fase 2.4: Upgrade Pattern

- [ ] **2.4.1** Implementare UUPS Proxy
  - [ ] Installare OpenZeppelin `@openzeppelin/contracts-upgradeable`
  - [ ] Creare `FlashArbExecutorProxy.sol`
  - [ ] Creare `FlashArbExecutorUpgradeable.sol` (versione upgradeable)
  - [ ] Configurare il proxy con il logic contract
  - [ ] Testare l'upgrade su testnet
- [ ] **2.4.2** Configurare l'ownership del proxy
  - [ ] Trasferire la ownership del proxy a un multi-sig (opzionale)
  - [ ] Configurare il admin del proxy
  - [ ] Testare il processo di upgrade

### Fase 2.5: Sicurezza del Contratto

- [ ] **2.5.1** Implementare tutti i controlli di sicurezza
  - [ ] `require(msg.sender == address(POOL)` in `executeOperation()`
  - [ ] `require(initiator == address(this))` in `executeOperation()`
  - [ ] `nonReentrant` modificatore su `executeOperation()`
  - [ ] `onlyOwner` modificatore su `executeArbitrage()`
  - [ ] `safeApprove` e `safeTransfer` di OpenZeppelin
  - [ ] `block.timestamp + 300` deadline nei swap
- [ ] **2.5.2** Prevenire overflow/underflow
  - [ ] Usare `SafeMath` o Solidity >= 0.8.0 (built-in overflow protection)
  - [ ] Verificare che non ci siano operazioni aritmetiche pericolose
  - [ ] Aggiungere `require` espliciti dove necessario
- [ ] **2.5.3** Protezione contro token malevoli
  - [ ] Verificare che il token restituito sia lo stesso del token preso in prestito
  - [ ] Non accettare token con tax sul trasferimento (o gestirli)
  - [ ] Validare l'indirizzo del token ≠ address(0)
- [ ] **2.5.4** Prevenire front-running del contratto
  - [ ] `onlyOwner` su `executeArbitrage()`
  - [ ] Nessun modo per un terzo di chiamare la funzione di esecuzione
  - [ ] Verificare che solo il owner possa inizializzare il flash loan

---

## FASE 3: TESTING E VALIDAZIONE

### Fase 3.1: Test Unitari (Solidity)

- [ ] **3.1.1** Testare il contratto base
  - [ ] Test: `test_ExecuteOperation_Success()` — l'arbitraggio funziona
  - [ ] Test: `test_ExecuteOperation_NoProfit_Reverts()` — se non c'è profitto, revert
  - [ ] Test: `test_ExecuteOperation_OnlyPool_Caller()` — solo Aave può chiamare
  - [ ] Test: `test_ExecuteOperation_NotInitiator()` — solo il contratto può iniziare
  - [ ] Test: `test_WithdrawToken_OwnerOnly()` — solo owner può ritirare
  - [ ] Test: `test_FlashLoanRepayment_Exact()` — rimborso = amount + premium
- [ ] **3.1.2** Testare la sicurezza
  - [ ] Test: `test_ReentrancyProtection()` — nessun attacco di reentrancy
  - [ ] Test: `test_OverflowProtection()` — nessun overflow/underflow
  - [ ] Test: `test_ZeroAddressProtection()` — nessun token a address(0)
  - [ ] Test: `test_UnauthorizedAccess()` — nessun accesso non autorizzato
- [ ] **3.1.3** Testare i casi limite
  - [ ] Test: `test_AmountZero()` — amount = 0 → fail
  - [ ] Test: `test_MaxUint256Amount()` — amount = max uint256 → fail
  - [ ] Test: `test_MinProfitThreshold()` — profit = minProfit esattamente → success
  - [ ] Test: `test_ProfitBelowThreshold()` — profit < minProfit → revert
- [ ] **3.1.4** Verificare la copertura
  - [ ] Eseguire `forge test --coverage` o `hardhat coverage`
  - [ ] Verificare che la copertura sia ≥ 95%
  - [ ] Aggiungere test per eventuali linee non coperte
  - [ ] Verificare che tutti i branch siano coperti

### Fase 3.2: Test di Integrazione (Mainnet Fork)

- [ ] **3.2.1** Setup del mainnet fork con Hardhat/Anvil
  - [ ] `anvil --fork-url $RPC_URL --fork-block-number <latest>`
  - [ ] Verificare che il fork è aggiornato all'ultimo blocco
  - [ ] Importare fondi di test nel fork per il wallet
- [ ] **3.2.2** Deployare il contratto sul fork
  - [ ] Eseguire lo script di deploy su Anvil
  - [ ] Verificare che il contratto sia deployato correttamente
  - [ ] Verificare gli indirizzi del pool Aave e dei router
- [ ] **3.2.3** Testare l'arbitraggio reale sul fork
  - [ ] Trovare un'opportunità di arbitraggio reale sul fork
  - [ ] Eseguire `executeArbitrage()` con i parametri trovati
  - [ ] Verificare che la transazione ha successo
  - [ ] Verificare che il profitto sia corretto
  - [ ] Ripetere con diversi percorsi e dimensioni
- [ ] **3.2.4** Testare scenari di failure
  - [ ] Test: simulare reserves cambiate (stale state) → deve revertire
  - [ ] Test: simulare profit < threshold → deve revertire
  - [ ] Test: simulare gas price alto → verificare che il calcolo è corretto
  - [ ] Test: simulare liquidità insufficiente → verificare che non si blocca

### Fase 3.3: Property-Based Testing e Fuzzing

- [ ] **3.3.1** Invariant Testing (Foundry)
  - [ ] Scrivere l'invariante: `balanceAfter >= balanceBefore - gasCost`
  - [ ] Eseguire il test con `forge test --match-test testInvariant`
  - [ ] Verificare che l'invariante sia sempre rispettato
  - [ ] Se fallisce → trovare e correggere il bug
- [ ] **3.3.2** Fuzz Testing
  - [ ] Usare `forge test --fuzz-runs 10000`
  - [ ] Fuzzare `executeArbitrage()` con amounts casuali
  - [ ] Fuzzare `setMinProfitBps()` con valori casuali
  - [ ] Verificare che nessun input causi un comportamento inatteso
- [ ] **3.3.3** Verificare proprietà specifiche
  - [ ] Proprietà: `flashLoan always repays amount + premium`
  - [ ] Proprietà: `profit is always >= 0 when executeOperation returns true`
  - [ ] Proprietà: `only owner can call executeArbitrage`
  - [ ] Proprietà: `totalOwed never exceeds available balance`

### Fase 3.4: Audit di Sicurezza Interno

- [ ] **3.4.1** Prima revisione del codice
  - [ ] Un sviluppatore rilegge tutto il codice
  - [ ] Controllare ogni `require`, `revert`, `transfer`
  - [ ] Verificare che non ci siano path di codice non gestiti
  - [ ] Documentare eventuali dubbi
- [ ] **3.4.2** Seconda revisione del codice
  - [ ] Un altro sviluppatore rilegge il codice
  - [ ] Verificare che le correzioni della prima revisione siano corrette
  - [ ] Cercare vulnerabilità aggiuntive
  - [ ] Confermare che il codice è sicuro
- [ ] **3.4.3** Strumenti di analisi automatica
  - [ ] Eseguire `slither` sul contratto
  - [ ] Eseguire `mythril` sul contratto
  - [ ] Eseguire `echidna` per property testing
  - [ ] Risolvere tutti i warning di sicurezza
- [ ] **3.4.4** Verifica finale pre-deploy
  - [ ] Tutti i test passano
  - [ ] La copertura è ≥ 95%
  - [ ] Nessun warning di Slither/MyThril
  - [ ] Il codice è stato revisionato da almeno 2 persone
  - [ ] Documentare l'audit interno

---

## FASE 4: OFF-CHAIN SCANNER E INFRASTRUTTURA

### Fase 4.1: Sviluppo Scanner Base

- [ ] **4.1.1** Setup del progetto scanner
  - [ ] Inizializzare progetto Rust (`cargo init`) o TypeScript (`npm init`)
  - [ ] Aggiungere dipendenze:
    - Rust: `ethers`, `tokio`, `serde`, `reqwest`, `sqlx`
    - TypeScript: `ethers`, `pg`, `redis`, `dotenv`, `winston`
  - [ ] Configurare il file `Cargo.toml` o `package.json`
  - [ ] Creare la struttura del progetto
- [ ] **4.1.2** Implementare il Pool Monitor
  - [ ] Sottoscrivere eventi `Sync` sui Uniswap V2 pairs
  - [ ] Mantenere una tabella in-memory delle riserve
  - [ ] Aggiornare le riserve ad ogni evento
  - [ ] Testare che gli aggiornamenti siano corretti
- [ ] **4.1.3** Implementare il Block Listener
  - [ ] Sottoscrivere nuovi blocchi via WebSocket
  - [ ] Ad ogni nuovo blocco, scansionare tutti i pool monitorati
  - [ ] Aggiornare la cache delle riserve
  -   - Testare che il listener è tempestivo
- [ ] **4.1.4** Implementare la logica di rilevamento opportunità
  - [ ] Per ogni coppia di token: calcolare se esiste arbitraggio 2-way
  - [ ] Per ogni tripla di token: calcolare se esiste arbitraggio triangolare
  - [ ] Usare la formula AMM per calcolare gli output
  - [ ] Verificare che il profitto netto > threshold
  - [ ] Loggare le opportunità trovate

### Fase 4.2: Sviluppo Scanner Avanzato

- [ ] **4.2.1** Implementare Bellman-Ford per cicli negativi
  - [ ] Costruire il grafo da tutte le pool monitorate
  - [ ] Implementare l'algoritmo Bellman-Ford
  - [ ] Trovare tutti i cicli negativi nel grafo
  - [ ] Verificare la correttezza con casi di test noti
- [ ] **4.2.2** Implementare l'ottimizzazione della dimensione del loan
  - [ ] Binary search sulla dimensione del loan
  - [ ] Per ogni L candidato: simulare tutti gli swap
  - [ ] Calcolare il profitto netto
  - [ ] Selezionare L* che massimizza il profitto
  - [ ] Verificare con casi noti
- [ ] **4.2.3** Implementare il Profit Calculator
  - [ ] Calcolare il profitto lordo (output - input)
  - [ ] Sottrarre il premium del flash loan
  - [ ] Sottrarre il costo gas stimato
  - [ ] Restituire il profitto netto e la raccomandazione
- [ ] **4.2.4** Implementare il Simulation Engine
  - [ ] Usare `eth_call` per simulare la transazione
  - [ ] Se il call fallisce → scartare l'opportunità
  - [ ] Se il call succeede → verificare il profitto
  - [ ] Stima del gas con `estimateGas`
  - [ ] Calcolo del costo gas con `getFeeData`

### Fase 4.3: Database e Persistenza

- [ ] **4.3.1** Implementare il salvataggio delle opportunità
  - [ ] Salvare ogni opportunità rilevata nel database PostgreSQL
  - [ ] Campi: timestamp, route, gross_profit, gas_cost, net_profit, status
  - [ ] Aggiornare lo status quando la transazione viene inviata
- [ ] **4.3.2** Implementare il salvataggio delle esecuzioni
  - [ ] Salvare ogni esecuzione con tx_hash, block_number, gas_used
  - [ ] Salvare il risultato (successo/fallimento) e il profitto netto
  - [ ] Aggiornare il record se la tx viene confermata o si revertisce
- [ ] **4.3.3** Implementare il caching delle pool states
  - [ ] Usare Redis per cache delle riserve dei pool
  - [ ] TTL di 1-2 secondi (per dati freschi)
  - [ ] Invalidare la cache ad ogni evento Sync
  - [ ] Testare che il cache non serva dati stale

### Fase 4.4: Sistema di Logging e Monitoring

- [ ] **4.4.1** Configurare il logging strutturato
  - [ ] Usare `winston` (TS) o `tracing` (Rust)
  - [ ] Loggare: opportunità trovate, transazioni inviate, risultati
  - [ ] Logganti errori con stack trace completo
  - [ ] Logganti warning per situazioni anomale
- [ ] **4.4.2** Configurare il logging su file
  - [ ] Salvare i log in `/var/log/flashloan-arb/`
  - [ ] Rotazione dei log (daily rotation, compress old logs)
  - [ ] Retention policy: 30 giorni
  - [ ] Verificare che i log siano leggibili e completi
- [ ] **4.4.3** Configurare il logging remoto
  - [ ] Opzione A: Invio a Datadog/Splunk
  - [ ] Opzione B: Invio a un servizio log aggregato
  - [ ] Verificare che i log remoti arrivano correttamente

---

## FASE 5: INTEGRAZIONE MEV/FLASHBOTS

### Fase 5.1: Setup Flashbots MEV-Share

- [ ] **5.1.1** Registrarsi presso Flashbots
  - [ ] Creare un account su flashbots.net
  - [ ] Ottenere le credenziali per MEV-Share
  - [ ] Configurare il wallet address per ricevere i kickback
  - [ ] Verificare l'accesso al dashboard
- [ ] **5.1.2** Installare le dipendenze Flashbots
  - [ ] Rust: `flashbots-receiver` crate
  - [ ] TypeScript: `@flashbots/flashbots-wallet` o ethers direct
  - [ ] Verificare che le dipendenze siano installate
- [ ] **5.1.3** Testare l'invio di bundle privati
  - [ ] Usare l'API di MEV-Share per inviare un bundle di test
  - [ ] Verificare che il bundle viene accettato
  - [ ] Verificare che il bundle è incluso nel blocco
  - [ ] Verificare che il kickback viene ricevuto

### Fase 5.2: Implementazione del Bundle Builder

- [ ] **5.2.1** Costruire la transazione dell'arbitraggio
  - [ ] Creare il dictato `to`, `data`, `value`
  - [ ] Impostare `gasLimit`, `maxFeePerGas`, `maxPriorityFeePerGas`
  - [ ] Impostare `nonce` corretto
  - [ ] Firmare la transazione con il wallet privato
- [ ] **5.2.2** Costruire il bundle Flashbots
  - [ ] Aggiungere la transazione di arbitraggio al bundle
  - [ ] Opzionale: aggiungere una transazione front-end (se backrunning)
  - [ ] Impostare `validity` parameters (block number, timestamp)
  - [ ] Impostare `coinbase` transfer per il tip
- [ ] **5.2.3** Configurare il tip ottimale
  - [ ] Implementare il calcolo del `percentageToPayToCoinbase`
  - [ ] Inizio: 90% del profitto come tip
  - [ ] Monitorare il win rate con diversi tip
  - [ ] A/B testing: provare tip tra 50% e 95%
  - [ ] Ottimizzare per il massimo profitto netto
- [ ] **5.2.4** Implementare il fallback a mempool pubblico
  - [ ] Se MEV-Share non risponde → inviare al mempool pubblico
  - [ ] Usare `wallet.sendTransaction()` per invio pubblico
  - [ ] Loggare la differenza di risultati tra private e public

### Fase 5.3: Test e Validazione MEV

- [ ] **5.3.1** Testare l'inclusione del bundle
  - [ ] Inviare un bundle su testnet (se supportato) o mainnet fork
  - [ ] Verificare che il bundle è incluso nel blocco
  - [ ] Verificare che il kickback è corretto
  - [ ] Verificare che il bundle non viene rifiutato
- [ ] **5.3.2** Testare lo scenario di competizione
  - [ ] Inviare un bundle con un tip basso
  - [ ] Verificare che il bundle NON è incluso (battuto dal competitor)
  - [ ] Inviare un bundle con un tip alto
  - [ ] Verificare che il bundle è incluso
- [ ] **5.3.3** Testare lo scenario di stale state
  - [ ] Inviare un bundle con simulazione stale
  - [ ] Verificare che il bundle viene incluso ma REVERTE
  - [ ] Verificare che non si perde capitale (solo gas del bundle)
  - [ ] Implementare il tracking dei revert rate
- [ ] **5.3.4** Misurare le performance reali
  - [ ] Registrare il tempo dal rilevamento all'inclusione
  - [ ] Registrare il win rate
  - [ ] Registrare il profitto medio per bundle
  - [ ] Confrontare con le simulazioni

---

## FASE 6: DEPLOYMENT PRODUZIONE

### Fase 6.1: Pre-Deploy Checklist

- [ ] **6.1.1** Verifica finale del codice
  - [ ] Tutti i test unitari passano
  - [ ] Tutti i test di integrazione passano
  - [ ] Copertura ≥ 95%
  - [ ] Nessun warning di Slither/MyThril
  - [ ] Il codice è stato revisionato da almeno 2 persone
- [ ] **6.1.2** Verifica delle configurazioni
  - [ ] `.env` configurato correttamente con tutti i valori
  - [ ] Gli indirizzi dei contratti sono corretti per la target chain
  - [ ] Il `owner` è il wallet corretto
  - [ ] Il `minProfitBps` è impostato a un valore ragionevole
  - [ ] Le RPC URLs sono funzionanti
  - [ ] I segreti sono salvati in luogo sicuro (non nel codice)
- [ ] **6.1.3** Verifica del budget
  - [ ] Il wallet ha abbastanza ETH per il deploy (~0.1-0.5 ETH)
  - [ ] Il wallet ha abbastanza ETH per il gas operativo (~0.01-0.1 ETH/giorno)
  - [ ] Il budget di contingenza è disponibile
- [ ] **6.1.4** Backup e disaster recovery
  - [ ] Backup del codice sorgente su GitHub/GitLab
  - [ ] Backup del database
  - [ ] Backup delle chiavi private (hardware wallet / vault)
  - [ ] Piano di emergenza scritto e condiviso
  - [ ] Contatti di emergenza definiti

### Fase 6.2: Deploy del Contratto

- [ ] **6.2.1** Deploy su testnet (se non già fatto)
  - [ ] Deploy su Goerli (Ethereum testnet) o Mumbai (Polygon testnet)
  - [ ] Verificare che il contratto funzioni su testnet
  - [ ] Testare ogni funzione con fondi reali di testnet
  - [ ] Verificare che l'upgrade (se proxy) funziona
- [ ] **6.2.2** Deploy su mainnet
  - [ ] Eseguire lo script `Deploy.s.sol` con Foundry/Hardhat
  - [ ] Verificare la transazione di deploy su Etherscan
  - [ ] Verificare che il contratto sia verificato su Etherscan
  - [ ] Salvare l'indirizzo del contratto in un file sicuro
  - [ ] Verificare che il `owner` sia correttamente impostato
- [ ] **6.2.3** Verifica post-deploy
  - [ ] Controllare il codice del contratto su Etherscan
  - [ ] Verificare che tutte le funzioni sono come previsto
  - [ ] Verificare che `owner` è impostato correttamente
  - [ ] Verificare che `minProfitBps` è impostato correttamente
  - [ ] Verificare che `ReentrancyGuard` funziona

### Fase 6.3: Deploy dello Scanner

- [ ] **6.3.1** Configurare il server di produzione
  - [ ] Opzione A: VPS (DigitalOcean, AWS EC2, Hetzner)
  - [ ] Opzione B: Server dedicato (Hetzner, OVH)
  - [ ] Opzione C: Cloud run (AWS Lambda, Google Cloud Functions)
  - [ ] Configurare firewall e sicurezza
  - [ ] Installare Docker per containerizzazione
- [ ] **6.3.2** Containerizzare lo scanner
  - [ ] Creare `Dockerfile` per il scanner Rust/TypeScript
  - [ ] Creare `docker-compose.yml` per tutti i servizi
  - [ ] Configurare health check e restart policy
  - [ ] Testare il container localmente
- [ ] **6.3.3** Configurare CI/CD
  - [ ] Setup GitHub Actions/GitLab CI per build automatica
  - [ ] Test automatici su ogni push
  - [ ] Deploy automatico su testnet (per test)
  - [ ] Deploy manuale su mainnet (per produzione)
  - [ ] Notifica su fallimento del CI/CD
- [ ] **6.3.4** Deploy dello scanner su server
  - [ ] Copiare il container sul server
  - [ ] Configurare le variabili d'ambiente
  - [ ] Avviare i servizi con `docker-compose up -d`
  - [ ] Verificare che lo scanner sia attivo
  - [ ] Verificare che i log siano generati correttamente

### Fase 6.4: Deploy del Monitoraggio

- [ ] **6.4.1** Configurare il dashboard Grafana (opzionale)
  - [ ] Installare Grafana (locale o cloud: Grafana Cloud)
  - [ ] Connettere il datasource (PostgreSQL o Prometheus)
  - [ ] Creare dashboard per metriche chiave
  - [ ] Configurare alert su metriche anomale
- [ ] **6.4.2** Configurare il monitoring uptime
  - [ ] Uptime Robot o similare per check dell'endpoint
  - [ ] Monitoraggio del database (connessione, spazio)
  - [ ] Monitoraggio del server (CPU, RAM, disco)
  - [ ] Alert se il server è down > 5 minuti

---

## FASE 7: OPERAZIONALITÀ E MONITORAGGIO

### Fase 7.1: Primi Test in Produzione (Live Testing)

- [ ] **7.1.1** Iniziare con capitale minimo
  - [ ] Impostare `minProfitBps` a un valore molto alto (es. 100 bps = 1%)
  - [ ] Il bot eseguirà solo opportunità molto profittevoli
  - [ ] Monitorare le prime 24-48 ore di operatività
  - [ ] Confrontare i risultati con le simulazioni
- [ ] **7.1.2** Verificare il flusso completo end-to-end
  - [ ] Il bot rileva un'opportunità? ✅
  - [ ] Il bot simula correttamente? ✅
  - [ ] Il bundle viene inviato? ✅
  - [ ] Il bundle è incluso nel blocco? ✅
  - [ ] Il profitto è corretto? ✅
  - [ ] I log sono completi? ✅
  - [ ] Gli alert funzionano? ✅
- [ ] **7.1.3** Calibrare i parametri
  - [ ] Se win rate < 30% → aumentare `minProfitBps`
  - [ ] Se win rate > 80% → diminuire `minProfitBps`
  - [ ] Se gas cost troppo alto → aumentare threshold
  - [ ] Se revert rate troppo alto → migliorare simulazione
  - [ ] Documentare ogni modifica e il suo impatto

### Fase 7.2: Monitoraggio Giornaliero

- [ ] **7.2.1** Checklist mattutina (ogni giorno)
  - [ ] Il server è attivo? (`docker ps`, `systemctl status`)
  - [ ] Lo scanner è connesso al RPC? (ping, log)
  - [ ] Il database è raggiungibile? (query di test)
  - [ ] Gli alert funzionano? (test manuale)
  - [ ] Il P&L cumulativo è positivo? (check dashboard)
- [ ] **7.2.2** Checklist serale (ogni giorno)
  - [ ] Riepilogo delle operazioni del giorno
  - [ ] Numero di opportunità rilevate
  - [ ] Numero di operazioni eseguite
  - [ ] Win rate del giorno
  - [ ] P&L del giorno
  - [ ] Gas medio per operazione
  - [ ] Eventuali anomalie segnalate
- [ ] **7.2.3** Checklist settimanale
  - [ ] P&L settimanale
  - [ ] Trend di win rate (↑/↓)
  - [ ] Confronto con la settimana precedente
  - [ ] Aggiornamento del competitor analysis
  - [ ] Revisione dei log per anomalie
  - [ ] Backup del database

### Fase 7.3: Gestione degli Alert

- [ ] **7.3.1** Configurare gli alert automatici
  - [ ] Alert se win rate < 30% per 24h → invia Discord/Telegram
  - [ ] Alert se P&L negativo per 7 giorni → invia email urgente
  - [ ] Alert se il server è down → invia SMS/Discord
  - [ ] Alert se gas cost > $30/trade → avvisare
  - [ ] Alert se revert rate > 50% → avvisare
  - [ ] Alert se il contratto è stato chiamato con parametro inatteso → avvisare
- [ ] **7.3.2** Definire i protocolli di risposta
  - [ ] Se ricevi un alert CRITICAL:
    - Verifica immediata del server
    - Se il contratto è compromesso → pause immediato
    - Se il server è down → riavvio o failover
    - Comunicare al team
  - Se ricevi un alert WARNING:
    - Investigare la causa
    - Se necessario, aggiustare i parametri
    - Documentare l'incidente
- [ ] **7.3.3** Mantenere un registro degli incidenti
  - [ ] Ogni incidente ha un ID univoco
  - [ ] Data, ora, descrizione, azioni prese, risultato
  - [ ] Lezioni apprese
  - [ ] Miglioramenti implementati per prevenire il ripetersi

---

## FASE 8: OTTIMIZZAZIONE E SCALING

### Fase 8.1: Ottimizzazione del Bot

- [ ] **8.1.1** A/B testing dei parametri
  - [ ] Testare diversi `minProfitBps` (10, 20, 50, 100)
  - [ ] Testare diversi `percentageToCoinbase` (50%, 70%, 90%)
  - [ ] Testare diversi gas strategies (base_fee + 10%, 20%, 30%)
  - [ ] Registrare i risultati di ogni test
  - [ ] Selezionare i parametri ottimali
- [ ] **8.1.2** Ottimizzazione dello scanner
  - [ ] Ridurre la latenza di rilevamento
  - [ ] Ottimizzare le chiamate RPC (batch, caching)
  - [ ] Ridurre il numero di pool monitorati a quelli più profittevoli
  - [ ] Implementare l'early exit nei calcoli
  - [ ] Considerare l'uso di Rust se attualmente usi TypeScript (o viceversa)
- [ ] **8.1.3** Ottimizzazione del gas del contratto
  - [ ] Analizzare il gas usage per ogni funzione
  - [ ] Identificare le funzioni più costose
  - [ ] Applicare le tecniche di gas optimization
  - [ ] Misurare il miglioramento
- [ ] **8.1.4** Implementare tecniche avanzate
  - [ ] Multi-thread scanning (se non già implementato)
  - [ ] Pre-computazione dei percorsi comuni
  - [ ] Sistema di priorità per le opportunità
  - [ ] Batch di opportunity in un singolo blocco

### Fase 8.2: Espansione Multi-Chain

- [ ] **8.2.1** Deploy su Base
  - [ ] Verificare che Aave V3 sia deployato su Base
  - [ ] Deploy del contratto esecutore su Base
  - [ ] Configurare lo scanner per Base
  - [ ] Testare con capitale minimo
  - [ ] Monitorare le performance
- [ ] **8.2.2** Deploy su Arbitrum
  - [ ] Stessa procedura di Base
  - [ ] Verificare compatibilità con Arbitrum
  - [ ] Monitorare le performance
- [ ] **8.2.3** Deploy su Polygon e altre chain (opzionale)
  - [ ] Stessa procedura
  - [ ] Verificare che Aave sia deployato
  - [ ] Monitorare le performance
- [ ] **8.2.4** Centralizzare il monitoraggio multi-chain
  - [ ] Un unico dashboard per tutte le chain
  - [ ] Un unico database con `chain_id` come campo
  - [ ] Alert che includano la chain
  - [ ] P&L aggregato su tutte le chain

### Fase 8.3: Scaling del Capitale

- [ ] **8.3.1** Aumento graduale del capitale operativo
  - [ ] Non aumentare il capitale di più del 20-30% a settimana
  - [ ] Monitorare se il win rate e il P&L sono stabili
  - [ ] Se il win rate cala → rallentare l'aumento
  - [ ] Se il P&L è crescente → continuare ad aumentare
- [ ] **8.3.2** Diversificazione delle strategie
  - [ ] Oltre al flash loan arb, considerare altre strategie:
    - Liquidation front-running
    - Stablecoin depeg trading
    - Funding rate carry trade
  - [ ] Ogni strategia con il proprio contratto e scanner
  - [ ] Dashboard separata per ogni strategia
- [ ] **8.3.3** Gestione dei profitti
  - [ ] Decidere quanto reinvestire vs quanto ritirare
  - [ ] Regola suggerita: 50% reinvestimento, 50% ritiro
  - [ ] Se il mercato è competitivo → aumentare il ritiro
  - [ ] Se il mercato è poco competitivo → aumentare il reinvestimento

### Fase 8.4: Advanced MEV Strategies

- [ ] **8.4.1** Backrunning avanzato
  - [ ] Oltre all'arbitraggio classico, implementare il backrunning
  - [ ] Monitorare le transazioni pending nel mempool
  - [ ] Inserire il bundle DOPO la transazione vittima
  - [ ] Catturare il profit del cambiamento di prezzo
- [ ] **8.4.2** Cross-DEX arbitrage avanzato
  - [ ] Non solo Uniswap ↔ SushiSwap
  - [ ] Includere Curve, Balancer, Uniswap V3, PancakeSwap
  - [ ] Supportare token con fee tier diversi
  - [ ] Supportare L2 DEX specifici
- [ ] **8.4.3** Triangular e Multi-hop arbitrage
  - [ ] Oltre al 2-way arbitrage, implementare 3-way e N-way
  - [ ] Usare Bellman-Ford per trovare cicli negativi
  - [ ] Implementare l'ottimizzazione della dimensione del loan
  - [ ] Gestire il rischio di intermedi token bloccato

---

## FASE 9: MANUTENZIONE E EVOLUZIONE

### Fase 9.1: Manutenzione Regolare

- [ ] **9.1.1** Aggiornamento del codice
  - [ ] Monitorare gli upgrade dei protocolli (Aave, Uniswap)
  - [ ] Aggiornare il contratto se le interfacce cambiano
  - [ ] Aggiornare le dipendenze (npm, Cargo)
  - [ ] Testare ogni aggiornamento su testnet prima di mainnet
- [ ] **9.1.2** Monitoraggio delle performance del protocollo
  - [ ] Verificare che Aave V3 sia operativo
  - [ ] Verificare che i router Uniswap siano operativi
  - [ ] Monitorare le fee del flash loan (possono cambiare)
  - [ ] Se un protocollo cambia le fee → aggiornare i calcoli
- [ ] **9.1.3** Manutenzione dell'infrastruttura
  - [ ] Aggiornare il sistema operativo del server
  - [ ] Aggiornare Docker e i container
  - [ ] Monitorare lo spazio disco del database
  - [ ] Backup regolare del database
  - [ ] Verificare che i certificati SSL (se usati) siano validi
- [ ] **9.1.4** Revisione della sicurezza
  - [ ] Ogni 6 mesi: ri-validare il codice del contratto
  - [ ] Eseguire `slither`, `mythril` regolarmente
  - [ ] Monitorare eventuali CVE nelle dipendenze
  - [ ] Aggiornare le protezioni di sicurezza

### Fase 9.2: Evoluzione e Miglioramento

- [ ] **9.2.1** Adattamento ad Aave V4
  - [ ] Quando Aave V4 è disponibile:
    - Studiare le nuove interfacce
    - Adattare il contratto esecutore
    - Testare su testnet
    - Migrare su mainnet
- [ ] **9.2.2** Adattamento ad Uniswap V4
  - [ ] Quando Uniswap V4 è disponibile:
    - Studiare il nuovo hook system
    - Potenziale integrazione di flash accounting nativo
    - Aggiornare il contratto e lo scanner
- [ ] **9.2.3** Miglioramento dell'algoritmo
  - [ ] Integrare ML/AI per predire opportunità
  - [ ] Migliorare il grafo di routing
  - [ ] Implementare predizione del gas price
  - [ ] Implementare predizione del win rate per ogni opportunità
- [ ] **9.2.4** Espansione geografica
  - [ ] Monitorare regolamentazioni in altri paesi
  - [ ] Adattarsi a eventuali cambiamenti normativi
  - [ ] Considerare l'espansione in mercati emergenti (Asia, Sud America)

### Fase 9.3: Documentazione e Knowledge Management

- [ ] **9.3.1** Mantenere la documentazione aggiornata
  - [ ] Aggiornare questo README con ogni modifica significativa
  - [ ] Documentare ogni deploy con indirizzi e parametri
  - [ ] Aggiornare la checklist con le lezioni apprese
  - [ ] Salvare i report di performance mensili
- [ ] **9.3.2** Condividere la conoscenza
  - [ ] Se hai un team: documentare tutto per i nuovi membri
  - [ ] Creare una guida operativa (runbook)
  - [ ] Salvare le procedure di emergenza
  - [ ] Organizzare sessioni di debriefing dopo ogni incidente

---

## APPENDICE: RIFERIMENTI TECNICI

### A. Indirizzi Principali (Ethereum Mainnet)

```
Aave V3 Pool Addresses Provider:
  - Ethereum: 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9
  - Base: [verificare su docs.aave.com]
  - Arbitrum: [verificare su docs.aave.com]

Uniswap V2 Router:
  - Ethereum: 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
  - Base: [verificare su docs.uniswap.org]

Uniswap V3 Router:
  - Ethereum: 0x68b3465833fb72A70ecF484E0b4C990D5
  - Base: [verificare su docs.uniswap.org]
```

### B. Comandi Utili

```bash
# Deploy con Foundry
forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY

# Test con Foundry
forge test --rpc-url $RPC_URL --ffi

# Test con copertura
forge test --coverage

# Analisi sicurezza con Slither
slither contracts/

# Fork mainnet con Anvil
anvil --fork-url $RPC_URL

# Deploy su Anvil (fork)
forge script script/Deploy.s.sol:Deploy --rpc-url http://localhost:8545 --broadcast

# Testare un bundle Flashbots
cast send $MEV_SHARE_URL "sendBundle(...)" --private-key $PRIVATE_KEY
```

### C. Tool Essenziali

```
DEVELOPMENT:
  - Foundry (forge, cast, anvil)
  - Hardhat (alternativa)
  - Slither (analisi sicurezza)
  - Mythril (analisi sicurezza)
  - Echidna (property testing)

INFRASTRUCTURE:
  - Alchemy/Infura (RPC)
  - PostgreSQL (database)
  - Redis (cache)
  - Grafana (dashboard)
  - Docker (containerizzazione)

MEV:
  - Flashbots MEV-Share (bundle privati)
  - Flashbots Protect (RPC privato)
  - EigenPhi (analytics MEV)
  - Blocknative (mempool monitoring)

MONITORING:
  - Blockscout/Etherscan (verifica contratti)
  - Dune Analytics (analytics on-chain)
  - Datadog/Splunk (monitoraggio server)
```

---

## GLOSSARIO

| Termine | Definizione |
|---------|-------------|
| **Flash Loan** | Prestito istantaneo senza garanzia, rimborsato nella stessa transazione |
| **AMM** | Automated Market Maker, protocollo di scambio decentralizzato |
| **Slippage** | Differenza tra prezzo atteso e prezzo reale di esecuzione |
| **MEV** | Maximal Extractable Value, valore estratto dal riordinamento delle tx |
| **Bundle** | Insieme di transazioni inviate insieme per atomicità |
| **PBS** | Proposer-Builder Separation, separazione tra costruttore e propostore del blocco |
| **Gas** | Unità di misura del costo computazionale su Ethereum |
| **Revert** | Annullamento di una transazione per errore o fallimento |
| **Fork** | Copia dello stato della blockchain per testing |
| **Oracle** | Fonte esterna di dati on-chain (prezzi, ecc.) |
| **Nash Equilibrium** | Stato del gioco dove nessun partecipante può migliorare unilateralmente |
| **Cointegrazione** | Relazione stazionaria tra serie temporali non stazionarie |
| **Bellman-Ford** | Algoritmo per trovare cammini minimi e rilevare cicli negativi |
| **L2** | Layer 2, soluzione di scaling per Ethereum |

---

*Checklist creata il 26/09/2026 per l'implementazione completa del sistema Flash Loan Arbitrage. Tutti i task devono essere completati in ordine, con verifica a ogni fase.*
