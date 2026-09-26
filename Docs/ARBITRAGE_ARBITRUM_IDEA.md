# IDEA — Rcostruzione del cuore arbitraggio su Balancer + Arbitrum fork

**Data:** 2026-09-26
**Stato:** PASSO 1 del metodo (idea dettagliata) — le decisioni definitive sono nel passo 2 (`ARBITRAGE_ARBITRUM_PLAN.md`)
**Branch:** `feat/integrating` (stato precedente preservato su `Dev`)

---

## 1. Problema

Il progetto attuale (contratto `FlashArbExecutor` su **Aave** + bot Uniswap V2 + test su **mock**) è tecnicamente corretto (audit 2026-09-26: 14/14 test) ma **mai validato contro la blockchain reale**: Aave è fonte di problemi per l'utente, i mock non provano nulla su rete, e non esiste un solo test che tocchi un DEX vero.

## 2. L'idea

Ricostruire il cuore dell'arbitraggio **riusando componenti già provati** dalla repo di riferimento `E:\Documents\Crypto\Defi\Arbitrum\Coding\Project4\TestSmartContract` (da ora: **TSC**), dove flash loan e swap **funzionano davvero**, testandoli su **fork di Arbitrum mainnet**.

In sintesi:

| Componente | Oggi (no) | Domani (si, preso da TSC) |
|---|---|---|
| Flash loan | Aave V3 (`IPool.flashLoan`, 7 arg, **fee 0.5% nel mock test**, 0.05% reale) | **Balancer V2 Vault, 0% fee** — `FlashLoanService.sol` di TSC copiato quasi pari pari |
| Swap venue | Router mock in test / solo V2-style | **V2 reale + V3 reale su Arbitrum**, logica swap adattata da TSC |
| Test | Mock locali | **Fork Arbitrum** (Alchemy, blocco pinnato) con whale funding — pattern esatto di TSC |
| Chain | Ethereum mainnet (Aave) | **Arbitrum One (42161)** — Balancer Vault `0xBA12…F2C8` presente, stessi indirizzi di TSC |

## 3. Perché da TSC funziona (ecco cosa copiamo)

Dalla ricerca (3 agenti, 2026-09-26) risulta:

1. **`contracts/services/FlashLoanService.sol` (425 righe)** — flash loan Balancer V2, 0% fee, doppio strato di sicurezza (Beacon check + trust-the-revert). Dipendenze di compile minime: 5 interfacce del progetto (`IBeacon`, `IFlashLoanCallback`, `ISimpleSwap`, `ITokenManagerForModules`, `balancer/IBalancerVault`) + OZ. **È già il pattern esatto che serve a noi**: chi chiede il prestito deve essere autorizzato → il nostro nuovo `ArbitragePlugin` riceve il prestito implementando `IFlashLoanCallback`. (Nella sua versione originale l'autorizzazione passa da un registro di nomi; noi la semplifichiamo — vedi piano D11.)
2. **Swappare su Arbitrum** — TSC prova due ricette funzionanti in fork:
   - V3 diretto: `UniswapV3PluginDirect` chiama `exactInputSingle` sul router ufficiale `0xE592427A0AEce92De3Edee1F18E0157C05861564` (test `Withdraw.AutomaticSwap.fork.test.ts`);
   - il nostro codice usa `IUniswapV2Router` (**minimal**, manca interfaccia completa) → **va creato `IUniswapV2Router02.sol`**; su Arbitrum esiste il **V2 ufficiale**: router `0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24`, factory `0xf1D7CC64Fb4452F05c498126312eBE29f30Fbcf9` (deploy ufficiale Uniswap).
3. **Test su fork** — TSC: `FORK_ENABLED=true` + `ARBITRUM_RPC_URL` (endpoint **Alchemy** nel loro `.env`, autorizzato dall'utente), whale `0x489ee077994B6658eAfA855C308275EAd8097C4A` (GMX vault: WETH/USDC/WBTC/USDT/ARB), impersonation 4 step, `FORK_BLOCK_NUMBER` pinnato per determinismo, test che si autoskippano senza fork.
4. **Sicurezza flash loan** — `FlashLoan.selfAttack.test.ts`: spoofing del callback Balancer → `NotBalancerVault`, callback fuori prestito → `NotInFlashLoan`, caller non registrato → `NotRegisteredPlugin`. Da portare come suite Foundry.

## 4. Come funzionerà il nostro arbitraggio (flusso)

```
1. Bot rileva disallineamento prezzo WETH/USDC tra venue A (V2) e venue B (V3)
2. Contratto chiama FlashLoanService.executeFlashLoan([USDC], [N])   ← Balancer, 0% fee
3. Balancer → receiveFlashLoan → service trasferisce N USDC al nostro executor (plugin)
4. Executor: compra WETH sulla venue dove costa meno (swap V2 o V3)
5. Executor: vende WETH sulla venue dove costa di più (swap V3 o V2)
6. Saldo USDC >= N  →  service ripaga Balancer  →  profitti restano nell'executor
   Saldo USDC <  N  →  revert esplicito (InsufficientRepayment) → tx intera annullata
```

Ciclo che chiude sempre sull'asset prestato (lezione C1 dell'audit), slippage e deadline protetti (pattern SwapManager), profitto minimo configurabile.

## 5. Strategia di test (il punto chiave)

Su fork reale gli arbitraggi spontanei rariamente esistono al blocco X → i test **creano** il disallineamento come farebbe il mercato:

1. Fork Arbitrum a blocco pinnato (Alchemy, `FORK_BLOCK_NUMBER`).
2. Setup: deploy `Beacon` + `FlashLoanService` + nostro executor, registrazione plugin (Pattern B di TSC, niente impersonamento del beacon live).
3. Whale (GMX `0x489e…7C4A`) fa un grande swap sulla venue A → prezzo si sposta.
4. Eseguiamo l'arb → assert: profitto > 0, Balancer ripagato, profitti nella nostra mainnet state.
5. Test negativi di sicurezza (spoof callback, non-registered, fuori prestito).
6. I test mock attuali restano come suite locale veloce (non fork) — tutto verde.

## 6. Vincoli e note operative

- **Non si tocca mai nulla in `TestSmartContract`** (lettura soltanto).
- RPC: usare l'`ARBITRUM_RPC_URL` di TSC (Alchemy) — lo dichiaro esplicitamente all'utente con quale key/file lo uso; il valore va copiato nel **nostro** `.env` (mai committato).
- OZ: TSC usa v4.9 (`security/ReentrancyGuard.sol`), noi v5.x → riscrittura import/constructor durante la copia.
- Solidity: `FlashLoanService` è `^0.8.27` → alzare `solc` del progetto da 0.8.20 a 0.8.27.
- SwapManager completo NON viene copiato come intero (ha il modello custody di ProxyGeneral+TokenManager pensato per il vault protocol, non per arb atomici) → se ne copiano le **primitive** (slippage via balance-delta, deadline, minOut, quote). Da confermare/espandere nel passo 2.
- Bot TS: fase finale, riconfigurare indirizzi Arbitrum; il monitoraggio V3 (eventi log diversi) è candidato a scope ridotto — da decidere nel passo 2.
- Script/deploy: `Deploy.s.sol` adattato (Beacon + FlashLoanService + executor + registrazione), rete Arbitrum.

## 7. Cosa NON facciamo (in questo giro)

- Non copiamo il megasistema TSC (Vault, LiquidityManager, Governance, plugin lending…): serve solo il perimetro flash-loan + swap.
- Non usiamo più Aave (contratto Aave-based messo in disparte, non cancellato — resta su `Dev`/storico).
- Non facciamo trading live: obiettivo = tutto testato e verde su fork, mai soldi veri in questa fase.
