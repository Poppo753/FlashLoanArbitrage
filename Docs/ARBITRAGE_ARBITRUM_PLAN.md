# PIANO — Arbitraggio Balancer + Uniswap su fork Arbitrum

**Data:** 2026-09-26
**Stato:** PASSO 2 del metodo — espansione di `ARBITRAGE_ARBITRUM_IDEA.md` con **decisioni prese**
**Branch:** `feat/integrating`

---

## A. Decisioni prese (con motivazione)

### D1 — Flash loan: Balancer V2 via `FlashLoanService` copiato da TSC
- **Si copia** `contracts/services/FlashLoanService.sol` (TSC) adattandolo a OZ v5 + solc 0.8.27. **Niente Aave.**
- **Si copia anche il Beacon reale** (`contracts/Beacon.sol` + `interfaces/IBeacon.sol`): il FlashLoanService lo richiede per l'autorizzazione dei plugin. Copiare il Beacon (410 righe, collaudato) costa meno che riscrivere la logica di auth del servizio — e regala upgradability.
- Il nostro contratto diventa **plugin registrato** (implementa `IFlashLoanCallback.onFlashLoanReceived`), esattamente come i plugin di TSC.
- Fee 0% (contro 0.05% di Aave): il break-even dell'arb migliora.
- **Alternative rifiutate:** mantenere Aave (utente: problemi noti); riscrivere FlashLoanService senza Beacon (rompe "copiare pari pari", rischio bug introdotti).

### D2 — Le due venue: Uniswap **V2 ufficiale** + Uniswap **V3 (0.05%)**, router configurabili
- **Venue A — Uniswap V2 ufficiale su Arbitrum**: router `0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24`, factory `0xf1D7CC64Fb4452F05c498126312eBE29f30Fbcf9` (deploy ufficiale Uniswap, verificato 2026-09-26 su developers.uniswap.org). Interfaccia `IUniswapV2Router02` → **il nostro codice swap V2 già scritto e testato funziona quasi senza modifiche**.
- **Venue B — Uniswap V3 WETH/USDC fee 0.05%** (pool ~$50M TVL): swap `exactInputSingle` sul SwapRouter `0xE592427A0AEce92De3Edee1F18E0157C05861564`, **corpo swap copiato da `UniswapV3PluginDirect.sol`** (TSC, testato in fork) migliorato: `amountOutMinimum` calcolato dalla quote invece di 0.
- **Due AMM di natura diversa** (costant-product vs concentrated-liquidity) si disallineano per prime dopo uno trade grosso → perfetti per il test a disallineamento forzato.
- **Router/venue sono parametri (immutabili in costruzione), non hardcode**: se su fork la liquidità V2 risultasse scarsa, si può puntare la venue A a Camelot V2 (`0xc873fecbd354f5a56e00e710b90ef4201db2448d`, interfaccia V2-compatibile) senza toccare la logica.
- **Alternative rifiutate:** due pool V3 con fee tier diversi (buono, ma sprecherebbe il riuso del nostro codice V2 e droperebbe l'evidenza che "il nostro vecchio swap funziona su rete"); Camelot come venue primaria (indirizzo meno canonico).

### D3 — Asset di prestito: **USDC** (ciclo chiude in USDC)
- Balancer Vault su Arbitrum ha USDC profondo; il ciclo è `USDC → WETH (venue meno cara) → USDC (venue più cara) → ripaga USDC`.
- Profitto misurato in USDC (6 decimali) — riprende la lezione C1 dell'audit (chiudere sempre sull'asset prestato).
- **Alternative rifiutate:** WETH come prestito (funziona, ma il profitto in WETH espone al prezzo ETH durante il ciclo; USDC è l'unità di conto del profitto).

### D4 — Architettura contratti: nuovo `ArbitragePlugin`, vecchio `FlashArbExecutor` rimosso
- **Nuovo contratto `contracts/ArbitragePlugin.sol`**: implementa `IFlashLoanCallback`, contiene la logica di arbitraggio (swap venue A, swap venue B, minProfit, slippage, deadline) e viene registrato nel Beacon come `"ArbitragePlugin"`.
- **Il vecchio `FlashArbExecutor.sol` (Aave) e i suoi 14 test vengono rimossi da questo branch** — preservati su `Dev` e nella storia git. Tenere entrambi i sistemi significhica doppia manutenzione e suite confusa; Aave esce dal perimetro (D1).
- Flusso:`ArbitragePlugin.startArbitrage(params)` → chiama `FlashLoanService.executeFlashLoan([USDC],[N],data)` → callback `onFlashLoanReceived` → swapA → swapB → verifica saldo ≥ N → fine (il service ripaga Balancer).
- **Sicurezza ereditata:** solo l'owner può avviare (cambia il gate: `msg.sender == owner` sull'entry, non `onlyOwner` sul servizio); slippage `minAmountOut` per swap; `deadline`; `minProfitWei`; rientro dell'intero ciclo sotto `nonReentrant` già garantito dal service.
- **Alternative rifiutate:** estendere `FlashArbExecutor` esistente tenendo Aave come provider secondario (complessità inutile); executor che chiama Balancer Vault direttamente senza FlashLoanService (perde il pattern collaudato e il registro plugin).

### D5 — Primitive prese da `SwapManager.sol` (senza copiarlo intero)
`SwapManager` va bene per i suoi test su fork, ma il suo modello (fondi in `ProxyGeneral`, token codes via `TokenManager`, multi-plugin quotes) è il custody del vault protocol — non serve per arb atomici dove i fondi passano nell'executor durante il callback. **Si copiano le primitive:**
1. **Slippage via balance-delta**: `actualReceived = balanceAfter - balanceBefore; require ≥ minAcceptableOutput` (SwapManager L698–705);
2. **Deadline MEV**: `require(block.timestamp ≤ deadline)` + evento warning (L286–322);
3. **minOut da quote**: `minAmountOut = quote * (10000 - maxSlippageBps) / 10000` (pattern `scripts/operations/vault/swap.ts:28`);
4. **Quote V3**: lettura `slot0` + fee (pattern `UniswapV3PluginDirect.getExpectedOutput`) — usata sia per minOut sia off-chain dal bot.
- Vengono copiati in `ArbitragePlugin` (+ eventuale `libraries` se necessario).

### D6 — Test: Foundry + fork Arbitrum pinnato, suite locale mock conservata
- **Nuova suite fork** in `test/fork/*.t.sol`, gate `vm.envOr("FORK_ENABLED", false)` → skip se non configurato (stessa filosofia di `this.skip()` di TSC).
- `foundry.toml`: `[rpc_endpoints] arbitrum = "${ARBITRUM_RPC_URL}"`; comando tipo `forge test --fork-url arbitrum --fork-block-number <PIN>` (profilo/alias dedicato). **Blocco pinnato** per determinismo (TSC: `FORK_BLOCK_NUMBER=483105327` come riferimento; il valore esatto lo fissiamo alla prima esecuzione riuscita e lo documentiamo).
- **Pattern di setup copiati da TSC:** *Pattern B* (MockBeacon/Beacon deployato dal test, nessun impersonamento del beacon live), whale funding a 4 step (`vm.deal` + `vm.startPrank(whale)` + `transfer` + `stopPrank`), test negativi di sicurezza.
- **Test di disallineamento forzato:** whale swapa sulla venue A (grande size) → prezzo si sposta → `startArbitrage` → assert profitto > 0 e Balancer ripagato.
- **Suite mock locale attuale:** riscritta per `ArbitragePlugin` (mock Balancer/mock Vault già esistente in TSC: `MockFlashLoanService.sol` è un buon riferimento, ma costruiamo mock minimi nostri) così `forge test` senza fork resta veloce e verde.
- **Test finali obbligatori (fase 7):** `forge build` (0 errori/0 warning), `forge lint` (0), `forge fmt --check`, suite mock completa, **suite fork completa su blocco pinnato**, `npx tsc --noEmit` bot.

### D7 — RPC: endpoint Alchemy di TSC, dichiarato
- TSC usa **Alchemy** (`arb-mainnet.g.alchemy.com`) nella variabile `ARBITRUM_RPC_URL` del **suo `.env`** (E:\…\TestSmartContract\.env) — **non Infura** come si pensava.
- Lo copiamo nel **nostro `.env`** (gitignored) — **mai committato**. ⚠️ Nota per l'utente: *sta chiave è la tua Alchemy di TSC, usata solo per i test fork; puoi ruotarla quando vuoi.* La uso solo in lettura per `--fork-url`.
- Fallback pubblico `https://arb1.arbitrum.io/rpc` per giri senza key (rate-limitati).

### D8 — Toolchain: solc 0.8.27, OZ v5, import adattati
- `foundry.toml`: `solc = "0.8.27"` (prereq del FlashLoanService), optimizer on.
- Adattamenti obbligati durante la copia (OZ v4.9 → v5.x):
  - `@openzeppelin/contracts/security/ReentrancyGuard.sol` → `@openzeppelin/contracts/utils/ReentrancyGuard.sol`;
  - `Ownable()` no-arg → `Ownable(msg.sender)` (Beacon);
  - verificare `safeIncreaseAllowance` (presente in OZ v5 ✓).
- Pragma dei file copiati (`^0.8.19/^0.8.24/^0.8.27`) tutti soddisfatti da 0.8.27.

### D9 — Bot TS: solo riconfigurazione indirizzi in questo giro
- Le **fasi contratto+test hanno priorità** (obiettivo "funziona al 100%" = contratti + fork verdi).
- Bot: aggiornare `config` (chain 42161, WETH/USDC Arbitrum, factory V2 `0xf1D7…`, Balancer, router venue) + `MONITOR_TOKENS` = WETH/USDC. Il detection loop V2 continua a funzionare (stessa interfaccia factory).
- **Fuori scope dichiarato:** monitoraggio pool V3 (decodifica log diversa), wiring esecuzione/flashbots (open items B6/B8/B24 dell'audit restano aperti), Deploy mainnet. Documentato, non nascosto.

### D10 — Script di deploy
- `script/Deploy.s.sol` riscritto: deploy `Beacon` → `FlashLoanService(beacon)` → `ArbitragePlugin(beacon, …)` → `beacon.updateImplementation("ArbitragePlugin", …)` + `("FlashLoanService", …)`, parametri da env (`ARB_VENUE_A_ROUTER`, `ARB_VENUE_B_ROUTER`, `MIN_PROFIT_USDC`…).
- Rete: Arbitrum (`--rpc-url arbitrum`). Il deploy **live non viene eseguito** in questa fase (solo script pronto + testato in fork).

## B. Elenco file (cosa si copia / si crea / si rimuove)

### Copiati da TSC (adattati OZ v5)
| File TSC | Destinazione nostro | Note |
|---|---|---|
| `contracts/services/FlashLoanService.sol` | `contracts/services/FlashLoanService.sol` | ≈ pari pari; OZ import |
| `contracts/Beacon.sol` | `contracts/Beacon.sol` | OZ v5 `Ownable(msg.sender)` |
| `contracts/interfaces/IBeacon.sol` | `contracts/interfaces/IBeacon.sol` | verbatim |
| `contracts/interfaces/IFlashLoanCallback.sol` | idem | verbatim |
| `contracts/interfaces/ISimpleSwap.sol` | idem | serve a FlashLoanService |
| `contracts/interfaces/ITokenManagerForModules.sol` | idem | serve a FlashLoanService (fallback price) |
| `contracts/interfaces/balancer/IBalancerVault.sol` | idem | incl. `IFlashLoanRecipient` |
| `contracts/mocks/MockBeacon.sol` | idem | per test |
| (riferimento) `contracts/plugins/UniswapV3PluginDirect.sol` | non copiato: se ne estrae il corpo swap in `ArbitragePlugin` | |

### Nuovi (nostri)
- `contracts/ArbitragePlugin.sol` — cuore (callback + arb + primitive D5).
- `contracts/interfaces/IUniswapV2Router02.sol` — già presente/da verificare nel repo.
- `contracts/interfaces/IUniswapV3Router.sol` — copiato da TSC (struct `ExactInputSingleParams`).
- `script/Deploy.s.sol` — riscritto (D10).
- `test/fork/ForkSetup.t.sol`, `test/fork/FlashLoanBalancer.t.sol`, `test/fork/Arbitrage.e2e.t.sol`, `test/fork/Security.t.sol`.
- `test/ArbitragePlugin.t.sol` (+ eventuali mock dedicati: mock vault/mock router come da suite locale).

### Rimossi da questo branch (storico su Dev/git)
- `contracts/FlashArbExecutor.sol`, `contracts/interfaces/IAavePool*.sol` (o comunque tutto il perimetro Aave), `test/FlashArbExecutor.t.sol`, mock Aave (`MockAavePool`…), riferimenti Aave in `.env.example`/README/Deploy (rimpiazzati da Balancer/Arbitrum).

## C. Rischî e mitigazioni

| Rischio | Mitigazione |
|---|---|
| Liquidità V2 official WETH/USDC insufficiente su fork | Venue A parametrica (switch Camelot); dimensione trade adattata al pool; verify in fase setup (lettura `getReserves`) |
| Fork lento/rate-limit | Blocco pinnato + cache foundry; fallback RPC pubblico; giri mock senza fork |
| Copia con errori OZ v5 | Ogni file copiato: build immediata + test dedicato |
| Disallineamento forzato non sufficiente a coprire fee+slippage | Calcolo size di trade nel test per generare spread > fee V2+V3+buffer; assert con soglia reale |
| Ciclo che chiude sull'asset sbagliato (lezione C1) | Test esplicito `WrongAsset` + assert ripagamento Balancer |
| Beacon dimenticato nel deploy | Test fork verifica `isAuthorizedPlugin(plugin)==true` prima di tutto (Pattern B) |

## D. Criteri di "funziona al 100%" (gate di chiusura)

1. `forge build` 0 errori, 0 warning · `forge lint` 0 · `forge fmt --check` pulito
2. Suite mock (senza fork) tutta verde
3. Suite fork verde su blocco pinnato con la key Alchemy: flash loan reale Balancer, arb reale con profitto > 0, security negatives
4. `npx tsc --noEmit` bot verde
5. README + `Docs/` aggiornati (indirizzi Arbitrum, comandi fork, note RPC)
6. `git status` pulito, commit per milestone spiegati
