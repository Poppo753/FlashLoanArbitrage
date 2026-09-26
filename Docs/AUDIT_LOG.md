# Audit Log — FlashLoanArbitrage

Registro degli audit, fix e decisioni aperte. **Ogni fix ha un commit, ogni voce ha una data.**

- **Ultimo aggiornamento:** 2026-09-26
- **Round 1 — audit completo repository (sistema Aave/Ethereum):** 2026-09-26
- **Round 2 — migrazione a Balancer/Arbitrum:** 2026-09-26 (vedi `IMPLEMENTATION_REPORT.md`)

> **Come leggere questo file.** Il Round 1 riguarda il sistema *Aave su Ethereum*, che il Round 2
> ha **sostituito**. I finding `C1-C6`, `T1-T2` e `D1-D5` descrivono codice che non esiste più su
> questo branch: è preservato sul branch `Dev` e nella storia git, e resta consultabile. I
> finding `B1-B24` (bot TypeScript) invece sono ancora attuali e il Round 2 li ha in parte
> ereditati. Per lo stato corrente del sistema vedi `README.md` e `IMPLEMENTATION_REPORT.md`.

---

## Methodology

- Static review of all contracts, tests, deploy script, docs and the full TypeScript bot (14 modules).
- Tooling: `forge build`, `forge test`, `forge lint`, `forge fmt --check`, `npx tsc --noEmit` (bot/).
- Every finding got its own commit (ID referenced in the commit message, e.g. `(C1)`, `(B4)`).
- Status legend: **FIXED** (committed), **PARTIAL** (partially fixed, remainder open), **OPEN** (documented, not fixed), **ACCEPTED** (reviewed, no change by design).

## Final verification — 2026-09-26

| Check | Result |
|---|---|
| `forge build` (solc 0.8.20, optimizer) | OK, zero compiler warnings |
| `forge test` | **14/14 passed** |
| `forge lint` | 0 warnings |
| `forge fmt --check` | clean |
| `npx tsc --noEmit` (bot/) | 0 errors |
| `npm run typecheck` (bot/) | passes |

---

## Summary of findings

### Smart contracts

| ID | Sev | Finding | Status | Commit | Date |
|----|-----|---------|--------|--------|------|
| C1 | HIGH | Profit check measured output in `buyToken` while the pool pulled repayment in `borrowAsset`: a cycle not ending in the borrowed asset could drain retained profits | FIXED | `1dc97e8` | 2026-09-26 |
| C2 | MED | `withdrawETH` used `.transfer` (2300 gas): contract owners (Safe/multisig, storage-writing `receive()`) could never withdraw | FIXED | `1ca6cb7` | 2026-09-26 |
| C3 | LOW | `ArbitrageFailed` emitted immediately before `revert` — logs are rolled back, event was dead code (event removed) | FIXED | `03a371e` | 2026-09-26 |
| C4 | LOW | `initiator` param not validated in `executeOperation` | ACCEPTED | — | 2026-09-26 |
| C5 | LOW | Compiler + forge lint warnings (unused params, `view`→`pure`, unused return, reentrancy-events) | FIXED | `01db8dd` | 2026-09-26 |
| C6 | LOW | Circuit breaker only blocked the callback: `executeArbitrage` still started flash loans while paused | FIXED | `023ab8a` | 2026-09-26 |

### Tests

| ID | Sev | Finding | Status | Commit | Date |
|----|-----|---------|--------|--------|------|
| T1 | HIGH | Reentrancy test was a false positive: `flashLoanDouble` made two *sequential* calls and the second reverted only on arithmetic underflow — `nonReentrant` was never exercised. Rewritten with a router callback hook asserting `ReentrancyGuardReentrantCall` | FIXED | `1dc97e8` | 2026-09-26 |
| T2 | LOW | Missing regression tests: wrong-buy-asset revert, contract-owner ETH withdrawal, paused `executeArbitrage` | FIXED | `1dc97e8`, `1ca6cb7`, `023ab8a` | 2026-09-26 |

### Deploy script & docs

| ID | Sev | Finding | Status | Commit | Date |
|----|-----|---------|--------|--------|------|
| D1 | MED | `Deploy.s.sol` hardcoded dummy routers `0x…0001/0x…0002` beside a real mainnet Aave pool — deploy would be unusable. Now fully env-driven (`AAVE_POOL_ADDRESS`, `OWNER_ADDRESS`, `ROUTER_0/1_ADDRESS`, `MIN_PROFIT_BPS`) | FIXED | `e4cd145` | 2026-09-26 |
| D2 | LOW | README described a Python bot, Uniswap V3/Balancer interfaces, a `libs/`+`deploy/` tree and a nonsense `cast create` deploy line | FIXED | `050f6b6` | 2026-09-26 |
| D3 | LOW | Root `package.json` with a single bogus `foundry` npm dependency, no scripts, no consumers | FIXED | `330c48b` | 2026-09-26 |
| D4 | LOW | One-off Foundry install helpers (`dl-*.js`, `download-*.js`, `extract-*.js`, `foundryup.ps1`) tracked at repo root | OPEN | — | 2026-09-26 |
| D5 | LOW | `MockFlashLoanReceiver` dead and broken (called `swapExactTokensForTokens` on the executor address) | FIXED | `fc665c4` | 2026-09-26 |

### Bot (TypeScript)

| ID | Sev | Finding | Status | Commit | Date |
|----|-----|---------|--------|--------|------|
| B1 | HIGH | `JsonRpcProvider` options passed in the network slot → ethers throws at import; bot crashed before `main()` | FIXED | `721820f` | 2026-09-26 |
| B2 | HIGH | `simulateFlashLoan` always returned `netProfitEstimate: null` → the execution gate could never pass | FIXED | `6894eda` | 2026-09-26 |
| B3 | HIGH | `opportunityDetector` used its own never-initialized `new PoolMonitor()` → every reserve lookup undefined, detection always empty | FIXED | `6ae4583` | 2026-09-26 |
| B4 | HIGH | Reserve keys inconsistent (pair address vs token address vs `A_B`) and no pair subscriptions → lookups always missed; canonical `pairKey()` convention + config-driven subscription added | FIXED | `ac42ca6` | 2026-09-26 |
| B5 | HIGH | Single `*_RPC_URL` (documented `wss://`) fed to both `JsonRpcProvider` and `WebSocketProvider` → startup impossible with any one URL; split into `rpcUrl` (https) + `wsRpcUrl` (wss) | FIXED | `460eabb` | 2026-09-26 |
| B6 | MED | Simulation called with mismatched `assets`/`amounts` lengths and empty calldata `"0x"` | PARTIAL | `b7e2106` | 2026-09-26 |
| B7 | MED | `BigInt(tipFraction)` on a fractional number → `RangeError` for any competitor count ≥ 1 | FIXED | `c44ffc2` | 2026-09-26 |
| B8 | MED | Bundles signed with `Wallet.createRandom()` and `nonce: 0`; backrun copied the victim tx | PARTIAL | `5e83d99` | 2026-09-26 |
| B9 | MED | `encodeRlp` fed decimal strings → `invalid BytesLike value`, `encodeBundle()` always threw | FIXED | `965f3fa` | 2026-09-26 |
| B10 | MED | Flashbots relay rejections (`error` in JSON-RPC body) logged as successful submission | FIXED | `c89227e` | 2026-09-26 |
| B11 | MED | Gas cost = gas × priority fee only (base fee ignored) → costs understated ~10×; `maxGasPriceGwei` never enforced | FIXED | `c957bdc` | 2026-09-26 |
| B12 | MED | Price impact computed from the same reserve before/after → always exactly 0 | FIXED | `c83d8f5` | 2026-09-26 |
| B13 | MED | `minProfitUsd`/`maxGasPriceGwei` thresholds loaded from env but never enforced | FIXED | `1f64dbb` | 2026-09-26 |
| B14 | MED | Bellman-Ford relaxation compared against the wrong node; `findNegativeCycles` always returned false | FIXED | `2c586d9` | 2026-09-26 |
| B15 | MED | Call success inferred from raw bytes — an encoded `false` counted as success | FIXED | `1441aad` | 2026-09-26 |
| B16 | MED | Receipt handler fabricated `isProfitable: true, profit: 0` instead of measuring | FIXED | `6e9a4b4` | 2026-09-26 |
| B17 | MED | Detection universe was only WETH across three chains (cross-chain arb impossible) | FIXED | `6c86feb`, `e38144f` | 2026-09-26 |
| B18 | MED | Un-awaited `getTransactionCount` → unhandled rejection shut the bot down | FIXED | `ad7024c` | 2026-09-26 |
| B19 | MED | Router calldata assumed arg0 = `amountIn` for every method; pair address derived from `keccak256(from,to)` instead of CREATE2 | FIXED | `74f8500` | 2026-09-26 |
| B20 | LOW | `npm run lint` invoked eslint, which is not a dependency | FIXED | `a0deb7f` | 2026-09-26 |
| B21 | LOW | `LOG_LEVEL`/`LOG_DIR` documented but ignored; all `logger.debug` discarded | FIXED | `5e314a3` | 2026-09-26 |
| B22 | LOW | Gas estimate hardcoded 5 bps premium instead of `config.flashLoanPremiumBps` | FIXED | `383d90e` | 2026-09-26 |
| B23 | LOW | `getProfitStats` fan-out JOIN counted opportunities N times and summed pending as realized; `avgProfitUsd` faked as 0 | FIXED | `76058cd` | 2026-09-26 |
| B24 | LOW | `database.save*`/`getProfitStats` and the whole `flashbots/` module have no callers | OPEN | — | 2026-09-26 |
| E1 | LOW | Follow-up: `FLASHBOTS_URL` vs `FLASHBOTS_RELAY_URL` duplication; undocumented env keys (`FLASHBOTS_PROTECT_URL`, `WS_RPC_URL`, `MONITOR_TOKENS`) | FIXED | `c81de20` | 2026-09-26 |

**Totale: 34 fix commit** in questa sessione d'audit (2026-09-26), più il commit di questo documento.

---

## Detail on key findings

### C1 — cycle must close in the borrowed asset (HIGH)

`executeOperation` approved `totalCost` in `borrowAsset` but measured profit as
`returned1` — the balance of `buyToken`. If `buyToken != assets[0]` the pool still
pulled `amount + premium` in `borrowAsset` from the contract's *existing* balance
(previous retained profits), while the "profit" sat in an unrelated token.
Fix: `revert InvalidBuyAsset()` unless `buyToken == assets[0]`; all tests now pass
params ending in the borrowed asset; new `test_ExecuteOperation_WrongBuyAsset_Reverts`.

### T1 — reentrancy test was a false positive (HIGH)

The old test used `flashLoanDouble` (two sequential `executeOperation` calls). The
second call reverted only because `0 - totalCost` underflowed — `nonReentrant` never
triggered, and after C1 the second call would even *succeed*. Rewritten: a
`setReentrancyHook` on the mock router performs a *nested* `executeOperation` during
the outer swap; the test asserts the inner call fails with
`ReentrancyGuardReentrantCall()`. Dead `flashLoanDouble` + `ReentrancyAttacker` removed.

### B5 — one URL for two incompatible providers (HIGH)

`.env.example` documented a single `*_RPC_URL` as `wss://…`, but `JsonRpcProvider`
fails on `wss` and `WebSocketProvider` fails on `https`: with any single value the
bot could not start. `ChainConfig` now has `rpcUrl` (http) + `wsRpcUrl` (wss),
`poolMonitor` validates the scheme with a clear error, and all consumers were routed.

### B4 — reserves stored under keys nobody looks up (HIGH)

`PoolMonitor` keyed reserves by *pair address* (with `tokenIn === tokenOut === pairAddress`)
while the detector looked up `getReserve(tokenAddress)` and `getReserve("A_B")`, and
`profitCalculator` matched `reserve.tokenIn === tokenIn`. Every lookup missed.
Fix: canonical `pairKey(a,b)` (sorted lowercase) exported from `poolMonitor`,
`getReserveForPair()` with direction orientation, real `token0/token1` stored, all
three modules converted; pairs are subscribed at startup from `MONITOR_TOKENS`
(built-in mainnet fallback) via factory `getPair`.

---

## Open items (documented, not fixed)

| ID | Item | Why deferred | Next step |
|----|------|--------------|-----------|
| C4 | `initiator` not validated in `executeOperation` | `POOL` is immutable and trusted; the `msg.sender == POOL` check is the real boundary | Optional hardening: `require(initiator == address(this))` + update direct-call tests |
| B6 | Real execution calldata | No executor address in bot config; sim/execute still pass placeholder calldata (equal-length arrays + TODO) | Add `EXECUTOR_ADDRESS` to config, ABI-encode `executeArbitrage(borrowAsset, amount, params)` |
| B8 | Real backrun bundles | `BACKRUN_CONTRACT_ADDRESS` doesn't exist; `buildBackrunCalldata` is a stub — bundles are now honestly *rejected* instead of sent invalid | Add env/contract address, implement backrun calldata from decoded victim path |
| B24 | Wire `database.save*` + `flashbots/` module into the main loop | Design decision (wire vs remove), touches main loop | Decide integration point in `startMonitoring()`/`executionEngine` |
| D4 | Foundry install helpers tracked at repo root | May still be wanted for reference | Move to `scripts/foundry-install/` or delete |
| — | `maxSlippageBps`, `minProfitWei`, `minLoopProfitMargin` thresholds still unused | Only `minProfitUsd` + `maxGasPriceGwei` were wired (B13) | Enforce in `profitCalculator`/`main` gate |
| — | One venue per token pair | Reserves keyed by `pairKey` only — a second DEX for the same pair would overwrite | Key by `pairAddress` when multi-venue is needed |
| — | No fork/live integration tests | Suite is mock-based (`MockAavePool`, `MockUniswapRouter`) | Add `forge test --fork-url` tests against mainnet Aave + Uniswap V2 |
| — | `MONITOR_TOKENS` fallback list is hardcoded in `poolMonitor.ts` | Works, but hidden | Move to config/env-only with no silent fallback, or keep documented |

---

## Changelog (audit rounds)

### Round 1 — 2026-09-26 — Full repository audit

1. Inventory of all files; static review of contracts, tests, deploy script, docs; automated review of the 14-file TypeScript bot.
2. Fixes committed individually, contract suite re-verified after each (`14/14`), bot re-verified after each (`tsc` clean).
3. Parallel sub-agents fixed disjoint bot file sets (execution / detection / flashbots / data layer), each committing per finding.
4. Cross-cutting plumbing (B5 config split, B3 singleton) fixed centrally first to avoid conflicts; B17 detection-loop gap closed afterwards.
5. Final verification: all green (table above).

### Round 0 — 2026-09-26 — Build & test baseline (pre-audit)

| Commit | Description |
|---|---|
| `9aa33c9` | Build green on Foundry 1.8.3 + OpenZeppelin v5 (remappings, `forceApprove`, `Ownable(initialOwner)`, 7-arg `IPool.flashLoan`) |
| `3e2387a` | All 11 original tests passing (mock fixes, setUp funding, delta assertions, E2E flows) |
| `d12f90a` | `forge fmt` applied |
