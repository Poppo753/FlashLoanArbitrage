# Implementation Report — Balancer flash loans on Arbitrum

**Date:** 2026-09-26
**Scope:** migration of the arbitrage core from Aave-on-Ethereum (mock-tested) to
Balancer-on-Arbitrum (tested against a real Arbitrum fork)
**Repository state at the time of writing:** HEAD `e894abf` ("chore: ignore foundry snapshot
artifacts")
**Related documents:** [`ARBITRAGE_ARBITRUM_IDEA.md`](ARBITRAGE_ARBITRUM_IDEA.md) (scoping),
[`ARBITRAGE_ARBITRUM_PLAN.md`](ARBITRAGE_ARBITRUM_PLAN.md) (plan, decisions D1–D13),
[`ARBITRAGE_CHECKLIST.md`](ARBITRAGE_CHECKLIST.md) (phases 0–10),
[`../README.md`](../README.md) (current system), [`AUDIT_LOG.md`](AUDIT_LOG.md)
(internal audit rounds — round 1 covers the *previous* Aave/Ethereum system).

---

## 1. Objective and starting state

**Objective.** Replace a flash-loan arbitrage core that had never touched a real
blockchain with one that is provably profitable against real liquidity, using a flash-loan
source with a **0% fee**, and prove it on a fork of the chain it is meant to trade on.

**Starting state (before this work).**

| Item | State on 2026-09-26, before |
|---|---|
| Flash-loan source | Aave V3 (`IPool.flashLoan`), Ethereum mainnet |
| Strategy contract | `contracts/FlashArbExecutor.sol` (removed in phase 4) |
| Venues | Uniswap V2-style routers only |
| Tests | 14 tests, 100% mock-based (`MockAavePool`, `MockUniswapRouter`) — a green suite that proved the logic and nothing about reality |
| Deploy script | env-driven, but wired to Aave (`AAVE_POOL_ADDRESS`) |
| Bot | TypeScript, Ethereum-flavoured, Flashbots module present but not functional (audit B6/B8/B24 open) |
| Documentation | `README.md` described a Python bot and a `libs/`+`deploy/` tree that did not exist (audit D2) |

The user supplied a reference repository (`E:\Documents\Crypto\Defi\Arbitrum\Coding\Project4\TestSmartContract`,
referred to below as **TSC**, read-only and never modified) whose Balancer V2 flash-loan
service and fork-test patterns already worked on Arbitrum. The migration was therefore a
port-and-prove exercise, not a from-scratch design.

**Result.** Two contracts (`ArbitragePlugin`, `FlashLoanService`), a three-step deploy
script, a 20-test mock suite and a 29-test Arbitrum fork suite pinned at block 509,000,000,
with a measured end-to-end profit of **219.500276 USDC (10.975%)** on a 2,000 USDC
flash loan. No live deployment, no live trade.

---

## 2. What was ported from TSC, and exactly how it was adapted

### 2.1 `FlashLoanService.sol` — ported, then simplified

The mechanism was kept verbatim in behaviour: check the caller, ask Balancer for the loan,
forward the principal, call back into the caller, repay the vault, revert rather than
underpay. Four things changed.

| # | Change | TSC (verified by reading the reference) | Here | Why |
|---|---|---|---|---|
| 1 | **Authorization: Beacon registry → single immutable caller** | `import "../interfaces/IBeacon.sol"`, `_isRegisteredPlugin(msg.sender)` looked the name up in a `Beacon` contract | `address public immutable authorizedCaller` set in the constructor; `_isAuthorizedCaller` compares to it; error `NotAuthorizedCaller(address)` | Plan D11. The name→address registry exists for a protocol with many modules; this project has exactly one executor. Drops 425 lines across three files (`Beacon.sol` 384, `IBeacon.sol` 7, `MockBeacon.sol` 34), and removes a mutable entry point that would have to be kept locked. |
| 2 | **Swap/pricing helpers dropped** | `function swap(...)`, `function getExpectedOutput(...)`, `function estimateFromTokenManager(...)`, plus `import "../interfaces/ISimpleSwap.sol"` and `"../interfaces/ITokenManagerForModules.sol"` | absent | The plugin performs the swaps itself, and the `TokenManager`/`ProxyGeneral` custody model belongs to the reference protocol, not to an atomic arb. Every route in the plugin is a two-hop single-pair swap. |
| 3 | **OpenZeppelin v4 → v5 import paths** | `import "@openzeppelin/contracts/security/ReentrancyGuard.sol"` (v4 path) | `import "@openzeppelin/contracts/utils/ReentrancyGuard.sol"` | This repo vendors OpenZeppelin **5.7.0** (verified: `lib/openzeppelin-contracts/package.json` → `5.7.0`); `security/` does not exist there. |
| 4 | **Compiler 0.8.20 → 0.8.27** | `pragma solidity ^0.8.27` | `foundry.toml` → `solc_version = "0.8.27"` (with `optimizer = true`, `optimizer_runs = 200`, `evm_version = "paris"`) | The service is `^0.8.27`; the whole project was moved up in phase 0 so a single compiler serves every file. |

Preserved on purpose, because they are the load-bearing parts: `nonReentrant` on
`executeFlashLoan`, the `_inFlashLoan` flag, `NotBalancerVault` and `NotInFlashLoan` in the
callback, the explicit `InsufficientRepayment` revert ("trust the revert"), and `safeTransfer`
everywhere. Result: 421 lines in TSC → 238 lines here.

One more import was dropped for a reason worth recording: TSC imports
`IERC20Metadata`, this port does not. **The contracts never read token decimals** — all
amounts are raw token units — so the decimals problem is confined to the bot (see §9).

### 2.2 Interfaces copied verbatim

| File | Note |
|---|---|
| `contracts/interfaces/IFlashLoanCallback.sol` | verbatim |
| `contracts/interfaces/balancer/IBalancerVault.sol` | verbatim, including `IFlashLoanRecipient` |

### 2.3 Swap bodies adapted, not copied

TSC's `UniswapV3PluginDirect` is the reference for the V3 leg. Two changes:

- `amountOutMinimum` is computed from a quote instead of being hardcoded to `0`. This is what
  turns the V3 leg from "whatever the pool gives" into a guarded leg.
- The quote arithmetic uses OpenZeppelin `Math.mulDiv` instead of the reference's raw
  `x * x` / `x << 192`. The results are identical (same floor divisions) but a pathological
  `sqrtPriceX96` can no longer wrap a `uint256` into a silently wrong price.

The V3 pool address is **not** a parameter: it is derived by CREATE2 from the factory
address, the pool init-code hash and `keccak256(abi.encode(token0, token1, fee))`, then
cross-checked against the factory's own `getPool` and against `pool.code.length`. A stale
constant can therefore only cause `V3PoolNotFound` — it can never route funds to an
attacker-controlled address. `test_V3PoolCreate2Address_MatchesCanonicalFormula` pins the
derivation in the mock suite.

### 2.4 Test patterns ported from TSC

`FORK_ENABLED` gating, a pinned `FORK_BLOCK_NUMBER`, and the four-step impersonation pattern
(`vm.deal` for gas → `vm.startPrank(whale)` → transfer → `vm.stopPrank`) were reimplemented in
Foundry in `test/fork/ForkBase.t.sol`. TSC's `Beacon`-based "Pattern B" is unnecessary after
decision D11: the test just does `new FlashLoanService(address(plugin))`.

---

## 3. The two-venue design, and why it is the right choice for this test

`ArbitragePlugin` takes two routers as immutable constructor parameters:

- **Venue A — Uniswap V2 Router02** (constant product, fee 0.30%). Priced by the router's own
  exact `getAmountsOut`.
- **Venue B — Uniswap V3 SwapRouter**, WETH/USDC 0.05% pool (concentrated liquidity, deep).
  Priced from `pool.slot0()` plus the pool fee, with no price-impact model.

Three reasons this pair:

1. **Different pricing models.** A constant-product pool and a concentrated-liquidity pool
   price the same pair differently, so a large trade moves one without moving the other. That
   is the dislocation the arbitrage exists to exploit — and, in a test, the dislocation has to
   be created deliberately.
2. **Fee asymmetry is what makes the test meaningful.** The round trip costs 35 bps
   (V2 0.30% + V3 0.05%). At the pinned block the two venues are only ~10 bps apart, i.e.
   *below* the round-trip cost, so with nobody trading there is nothing to take and a
   "profitable" test would have to fake it. The suite instead forces a real trade, and the
   control test proves the un-disturbed cycle loses ~7%.
3. **Both routers are parameterised.** If V2 liquidity were unusable, venue A could be
   pointed at another V2-compatible deployment (the plan named Camelot) without touching the
   logic.

**At the pinned block the V2 pair is thin**: 10.3357 WETH / 27,784.98 USDC. That is a feature
for the test (a modest trade moves the price a long way) and a hard constraint in production
(small sizes, large price impact on the V2 leg, and a window that only exists for a block or
two after a big trade).

---

## 4. The lazy-initialize pattern and the circular dependency it solves

There is a genuine cycle in the design:

- `FlashLoanService` must know the plugin's address **at its own construction**, because the
  service is the one that decides who may borrow (`authorizedCaller`).
- `ArbitragePlugin` must know the service's address to recognise a legitimate callback
  (`NotFlashLoanService`).

Neither address exists until the other is deployed.

**Solution (plan D13).** The plugin is deployed with no service, and the service is wired in
afterwards:

```solidity
// contracts/ArbitragePlugin.sol
constructor(...) Ownable(msg.sender) { ... }              // flashLoanService stays address(0)

function initialize(address service) external onlyOwner { // one-shot
    if (flashLoanService != address(0)) revert AlreadyInitialized();
    if (service == address(0)) revert InvalidAddress();
    flashLoanService = service;
    emit FlashLoanServiceSet(service);
}
```

Deploy order: `new ArbitragePlugin(...)` → `new FlashLoanService(address(plugin))` →
`plugin.initialize(address(service))`. The mutual trust is therefore established by
construction plus a single owner transaction, and neither contract needs a mutable setter
afterwards.

**Rejected alternative.** `setAuthorizedCaller` on the service. It would make the
authorization mutable after deployment — a second door that has to be kept shut.

**Cost of the pattern, stated honestly:** between deployment and `initialize`, the plugin is
inert (`FlashLoanNotInitialized` on any call to `startArbitrage`). The deploy script performs
the call in the same broadcast, and `ForkBase.setUp` asserts the wiring in every fork test.

**The accounting invariant that makes retained profit safe.** The callback snapshots
`baseBefore` *after* the principal has arrived, and computes
`available = baseAfter − (baseBefore − principal)`. Subtracting the pre-existing balance means
profit from earlier cycles can never be used to service the current loan — the cycle must
repay from what it produced. This carries forward lesson C1 from the previous audit round.
It is covered by `test_RetainedProfitCannotRepayALosingCycle` in the mock suite — that is the
test that actually exercises the invariant, by pre-funding the plugin and asserting a cycle that
returns less than the principal still reverts. The fork suite is weaker on this specific point:
`test_WrongDirection_AfterOneSidedDisplacement_IsRejected` shows a reverting cycle leaves the
plugin at zero USDC and never touches the vault, but it does not pre-fund the plugin first, so it
does not by itself prove retained profit cannot mask a bad cycle on real state. Closing that gap
on the fork is listed in the follow-ups.

---

## 5. Test strategy: mock for speed, fork for truth

| | Mock suite | Fork suite |
|---|---|---|
| Files | `test/ArbitragePlugin.t.sol` | `test/fork/{ForkBase,FlashLoanBalancer,Arbitrage.e2e,Security}.t.sol` |
| Tests | 20 | 29 |
| State | Etched mocks at the canonical addresses | Arbitrum mainnet state at block 509,000,000 |
| Runtime | seconds, no network | minutes, needs `ARBITRUM_RPC_URL` |
| Proves | Control flow, accounting, every guard, the CREATE2 derivation, both directions, the profit floor | That the addresses are real, the vault really lends at 0% fee, the cycle really makes money on real liquidity, and the guards fire on real state |

**The mock suite is not weakened to pass anything.** `MockBalancerVault` really lends, calls
back and reverts if it is not made whole; `MockV2Router` really charges 0.30% and enforces
`amountOutMinimum` and `deadline`; `MockV3Router` prices off the same `MockV3Pool` the plugin
quotes from, with the same spot formula and the same 0.05% fee. Only the contract under test
is the real one, and its guards are never disabled.

**What the mock suite cannot prove, and the fork suite therefore must:** a mock
constant-product pool handed a hand-picked price cannot lose money by accident, so the mock
suite always repays with interest. It says nothing about whether a real V2/V3 spread is worth
more than 35 bps of fees. The fork suite is the only thing in the repository that answers
that question, and its answer is measured, not asserted.

**Fork suite composition.**

| File | Tests | Focus |
|---|---|---|
| `FlashLoanBalancer.t.sol` | 6 | Vault is real (real deployed bytecode; the test asserts `code.length > 1_000` and its own comment records ~49k, and no `vm.etch` appears anywhere in the suite), principal really transferred, every `feeAmounts` entry is exactly 0, vault ends whole, service access guards |
| `Arbitrage.e2e.t.sol` | 7 | The decisive profit test, the reverse direction, wrong-direction rejection, quote-vs-execution, the no-displacement control, an exact `MinProfitNotMet(profit, floor)` pin, and the block pin |
| `Security.t.sol` | 16 | Non-owner on every admin function, pause/unpause, initialization, callback validation, service authorization, post-cycle integrity, withdrawal |

Every fork test opens with `_skipUnlessForking()` and every `setUp()` performs **no RPC read**,
so a plain `forge test` touches no network and the fork tests skip themselves.

---

## 6. Measured results on the fork (block 509,000,000, timestamp 1,790,403,338)

Market state at the pin:

| Quantity | Value |
|---|---|
| Balancer vault USDC balance | 13,275.06 USDC |
| V2 pair reserves | 10.335654869 WETH / 27,784.977544 USDC (`token0 = WETH`) |
| V2 mid price | 2,688.248784 USDC/WETH |
| V3 `slot0` spot | 2,685.443451 USDC/WETH |
| Pre-trade gap | ~10 bps, V2 the dearer side |
| Impersonated participant | 6.5752 WETH + 21,745.49 USDC, no ETH (so every impersonation needs `vm.deal` for gas) |

**Direction A (`buyOnVenueA = true`) — the decisive cycle.**

| Step | Amount |
|---|---|
| Whale sells 1 WETH into the V2 pair | receives 2,444.393196 USDC; V2 mid falls to 2,235.462589 (−1,684 bps) |
| V3 during all of this | unchanged at 2,685.443451 (0 bps, asserted) |
| Leg 1: 2,000 USDC → WETH on V2 | 0.826916761 WETH |
| Leg 2: WETH → USDC on V3 | 2,219.500276 USDC (gross at spot 2,220.638199, less 0.05% pool fee 1.110319, less 0.12 bps of price impact) |
| Repayment | 2,000.000000 USDC (Balancer fee 0) |
| **Profit** | **219.500276 USDC = 10.975% of the principal** |
| Gas for one `startArbitrage` | ~472k |

Post-conditions asserted: `ArbitrageExecuted` emitted and decoded from recorded logs, the
plugin's USDC balance rose by exactly the emitted profit, the vault's balance is
byte-for-byte unchanged, and no WETH is left in the plugin or the service.

**Direction B (`buyOnVenueA = false`, mirror-image displacement: a whale spends 2,000 USDC
buying WETH on V2, pushing the V2 mid to 3,088.563901):** leg 1 buys 0.744375238 WETH on V3,
leg 2 sells it back into V2 for 2,128.361241 USDC → **profit 128.361241 USDC = 6.418%**. The
V2 leg gives a lot of price back, which is the honest cost of the thin pool and is already
inside that number.

**The control (no whale trade).** `getExpectedProfit` reports zero profit, and
`startArbitrage` reverts `InsufficientRepayment`: the cycle produces 1,856.764155 USDC
against a 2,000 USDC loan, a 143.24 USDC (7.16%) shortfall. A ~10 bps gap cannot pay a 35 bps
round trip. This is what makes the profit in the direction-A test a property of the market
state rather than of the harness.

**Quote vs execution.** `getExpectedProfit` is a spot *estimate*: the V3 leg has no
price-impact model, and the contract then subtracts `maxSlippageBps = 50` on top, so the quote
is a strict lower bound on the realised fill. Measured understatement: **50 bps of gross
output** in direction A, **46 bps** in direction B (asserted bound: 100 bps). The bound is on
gross output, not on profit, because profit is a small difference between two ~2,200 USDC
numbers — the same 11 USDC divergence is 5.3% of the quoted profit but 0.5% of the gross.

---

## 7. Bugs and surprises found during the work

Every entry below was found and fixed while building the migration. "Where" states whether
the defect was in a contract or in a test.

| # | Symptom | Root cause | Fix | Where |
|---|---|---|---|---|
| 1 | The plugin inherited `Pausable` and `startArbitrage` was `whenNotPaused`, but there was **no way for the owner to pause** — the kill switch could not be pulled. | OpenZeppelin v5 keeps `_pause`/`_unpause` `internal`; nothing in the contract wrapped them. | Added owner-only `pause()` and `unpause()` calling `_pause()`/`_unpause()`; unpausing is deliberately a separate, explicit act. Covered by `test_StartArbitrage_WhenPaused_Reverts` (mock) and `test_StartArbitrage_RevertsWhilePaused_AndResumesAfterUnpause` + `test_Pause_RevertsForNonOwner` (fork). | **Contract** (`ArbitragePlugin.sol`) |
| 2 | `MockV2Router` did not compile. | `getAmountsOut` was declared `external` but `swapExactTokensForTokens` calls it internally, which Solidity only permits for `public`/`internal`. | Declared `public view` — which is also what the real `UniswapV2Router02` does. | **Test helper** (`test/ArbitragePlugin.t.sol`) |
| 3 | `test_PinIsHonoured` failed on the correct fork: `block.number` reported 26,059,772, not 509,000,000 (the figure recorded in `ForkBase._assertPinnedBlock`). | Foundry maps an Arbitrum block header's **`l1BlockNumber`** onto the EVM's `block.number`, so L2 block 509,000,000 reports its Ethereum counterpart. | The pin witness is now `block.timestamp == 1_790_403_338`, which *is* taken from the pinned header correctly. `block.number` is deliberately not asserted. | **Test** (`ForkBase.t.sol`, `Arbitrage.e2e.t.sol`) |
| 4 | The documented fork command ran 0 fork tests — all 29 skipped. | The gate was `FORK_ENABLED=true \|\| vm.activeFork() > 0`, and **`vm.activeFork()` returns 0 for a CLI-level fork** (`--fork-url`/`--fork-block-number`). | Replaced with a direct witness of real state: `BALANCER_VAULT.code.length > 0`. On a bare local EVM that address is empty, so the check is honest in both directions. | **Test** (`ForkBase.t.sol`) |
| 5 | The venue-gap arithmetic came out as exactly −10,000 bps, so the "venues are aligned" premise could never hold. | The test helper `_v3Price()` divided `sqrtPriceX96²` by `2^96` instead of `2^192`, leaving the ratio scaled by another 2^96. | `Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 2^192 / 1e18)`, which yields micro-USDC per WETH wei — the same unit as `_v2Price` — and the call sites no longer un-scale locally. Note the **production** contract was never affected: `_v3Quote` divides by 2^96 twice and multiplies by `amountIn`, which cancels the scale. | **Test** (`ForkBase.t.sol`) |
| 6 | `vm.deal(token, …)` could not mint USDC or WETH on the fork. | `vm.deal` moves an account's **native ETH** balance, never ERC20 storage. | `_fund()` performs a single spoofed transfer *from the token contract's own address*, bounded by the amount the token contract actually holds. This is how a real ERC20 mints. | **Test** (`ForkBase.t.sol`) |
| 7 | Fork runs left untracked files in the working tree. | Forge writes the output of the suite's `vm.startSnapshotGas("arbitrage")` calls to `snapshots/`. | Added `snapshots/` to `.gitignore` (commit `e894abf`, "chore: ignore foundry snapshot artifacts"). | **Test tooling** |
| 8 | A first, throwaway fork probe test was committed and then deleted in the very next commit (`afb4309`, "test: drop throwaway fork probe test"); the surviving suite covers the same ground properly. | A probe used while bringing the fork harness up. | Removed. | **Test** |

**Left as found, deliberately:** the header comment of `ForkBase.t.sol` (rule 3) still
describes the gate as "`vm.activeFork() > 0`", which bug #4 made obsolete; the implemented gate
uses `BALANCER_VAULT.code.length > 0`. The code is right and the comment above it is stale.

---

## 8. Test-harness gotchas, and the commands that actually work

```bash
# Build. lib/ is gitignored, so a fresh clone installs the deps first.
forge install foundry-rs/forge-std@v1.16.2 OpenZeppelin/openzeppelin-contracts@v5.7.0
forge build

# Mock suite: 20 tests, no network.
forge test --match-path "test/ArbitragePlugin.t.sol" -vv

# Fork suite: 29 tests. ARBITRUM_RPC_URL must be in .env (the `arbitrum` alias reads it).
# The pin is mandatory: without it forge forks at `latest` and every measured number moves.
forge test --match-path "test/fork/*" --fork-url arbitrum --fork-block-number 509000000 -vv

# Static checks
forge lint
forge fmt --check
cd bot && npx tsc --noEmit
```

Gotchas worth remembering:

- **The pin is not optional.** The V2 pair holds ~10.3 WETH, so a single block of real trading
  moves every figure in the fork suite. `FORK_ENABLED=true` is optional (the suites also
  enable themselves when real state is loaded); `--fork-block-number 509000000` is not.
- `FORK_BLOCK_NUMBER` in the environment overrides the pin constant without editing code, so
  the whole suite can be re-pinned together.
- Impersonated addresses that are **contracts** hold no ETH: `vm.deal(who, 1 ether)` before
  every `vm.prank`/`vm.startPrank` of theirs.
- `vm.expectEmit` is unusable for `ArbitrageExecuted` (all three fields are non-indexed, so
  matching the data would require already knowing the profit). The suite decodes the recorded
  log instead, which is strictly stronger: it proves the value the chain reports is the value
  the balance moved by.
- Market simulation in the tests deliberately uses `amountOutMin = 0` and the *production*
  router — that is what a real participant sends, and it is the only way to create the
  dislocation the cycle needs.
- `forge test` with no flags is safe: the fork tests skip and nothing touches the network.

---

## 9. Verification results

| Check | Command | Result |
|---|---|---|
| Build | `forge build` | 0 errors, **0 warnings** (solc 0.8.27, optimizer 200 runs, `evm_version = paris`) |
| Lint | `forge lint` | **0 warnings** |
| Format | `forge fmt --check` | clean |
| Mock suite | `forge test --match-path "test/ArbitragePlugin.t.sol"` | **20/20 passed** |
| Fork suite | `forge test --match-path "test/fork/*" --fork-url arbitrum --fork-block-number 509000000` | **29/29 passed** |
| Bot types | `npx tsc --noEmit` (in `bot/`) | 0 errors |
| Deploy script | `forge script script/Deploy.s.sol` | dry-run only (3 transactions simulated against chain 42161: plugin, service, `initialize` + `setMinProfit`). **No live deployment.** |
| Live trading | — | **never performed** |

*Provenance of this table:* the results were measured during implementation on 2026-09-26.
For this report the two test counts were re-verified statically — 20 `function test` in
`test/ArbitragePlugin.t.sol`, 29 across `test/fork/*.t.sol` — and the toolchain versions
(`solc_version`, OpenZeppelin 5.7.0, forge-std 1.16.2) were read from `foundry.toml` and
`lib/`. The documentation pass itself did not re-execute `forge`: Foundry is not installed in
the environment the documentation was written in, so treat the pass/fail rows as recorded
measurements and re-run the commands above to reproduce them.

---

## 10. Checklist phases → commits

| Phase | Commit | Subject | Delivered as |
|---|---|---|---|
| Pre-work, step 1 | `afa8ebc` | docs: idea for Balancer-based arbitrage rebuild on Arbitrum fork | `ARBITRAGE_ARBITRUM_IDEA.md` |
| Pre-work, step 2 | `ceb3fca` | docs: step 2 - expanded plan with decisions D1-D10 for Arbitrum rebuild | `ARBITRAGE_ARBITRUM_PLAN.md` |
| Pre-work, steps 4-5 | `5b51a9f` | docs: steps 4-5 - implementation checklist with review fixes | `ARBITRAGE_CHECKLIST.md` |
| 0 — foundations | `e4f8b98` | build: move to solc 0.8.27 and add Arbitrum fork endpoint (Phase 0) | solc 0.8.27, `[rpc_endpoints] arbitrum` |
| 1 — flash-loan service | `4e8af13` | feat(contract): port Balancer V2 flash loan service with single-caller auth (Phase 1) | D11 single-caller auth, helpers dropped, OZ v5 imports |
| 2 — swap interfaces | `ea889c4` | feat(contract): add V2 router/factory and V3 router/quoter interfaces (Phase 2) | `IUniswapV2Router02`, `IUniswapV3Router`, quoter slice |
| 3 — the plugin | `d1780aa` | feat(contract): add ArbitragePlugin - atomic two-venue arbitrage over Balancer flash loan (Phase 3) | `ArbitragePlugin.sol` |
| 4 — Aave removed | `35be67b` | refactor: remove Aave executor, rewrite deploy for Balancer/Arbitrum (Phase 4) | `FlashArbExecutor.sol` and its tests removed; **`script/Deploy.s.sol` rewrite also landed here** (phase 7 was not a separate commit) |
| 5 — mock suite | `aefd765` | test: add ArbitragePlugin suite, add missing pause kill-switch (Phase 5) | 20 tests; **the missing `pause()`/`unpause()` fix (bug #1) landed in this commit** |
| 6a — flash loan proven on fork | `3547f99` | test(fork): prove real Balancer 0% flash loan on Arbitrum fork (Phase 6a) | `FlashLoanBalancer.t.sol` |
| — cleanup | `afb4309` | test: drop throwaway fork probe test | bug #8 |
| 6b — arbitrage proven on fork | `511d241` | test(fork): real two-venue arbitrage on Arbitrum fork, plus security suite (Phase 6b) | `Arbitrage.e2e.t.sol`, `Security.t.sol`, `ForkBase.t.sol` |
| 8 — bot retarget | `9d8c342` | feat(bot): retarget bot configuration to Arbitrum and Balancer (Phase 8) | chain 42161, Arbitrum addresses, `MONITOR_TOKENS` |
| — cleanup | `e894abf` | chore: ignore foundry snapshot artifacts | bug #7 |
| 9 — documentation | *(this pass, uncommitted)* | README rewrite + this report | — |
| 10 — final verification | *(no commit)* | gates T10.1–T10.6 | see §9 |

**Deviations from the plan, and what shipped instead.**

| Plan / checklist | Shipped | Reason |
|---|---|---|
| D4/D10: register the plugin in a `Beacon`, deploy beacon → service → plugin → `updateImplementation` | No Beacon at all; 3-step deploy with a one-shot `initialize` | D11 removed the Beacon; D13 replaced the registry with the lazy init. Plan decision, applied consistently. |
| T3.2: `startArbitrage(uint256 usdcAmount)` with a fail-fast `amount + profit >= usdcAmount` pre-check before invoking the loan | `startArbitrage(uint256 amount, bool buyOnVenueA)`; profitability is decided inside the callback (`InsufficientRepayment` then `MinProfitNotMet`) | The pre-check would have to re-read and re-quote the venues immediately before the loan, duplicating the guards that the callback already applies on the same state. Consequence, stated honestly: **a losing cycle pays the flash-loan and swap gas before reverting.** The off-chain equivalent is `getExpectedProfit`. |
| T3.5: `getExpectedProfit(usdcAmount)` using the V3 quoter | `getExpectedProfit(amount, buyOnVenueA) → (expectedOut, expectedProfit)` using the `slot0` spot price | Keeps the quote a `view` function with no extra external call, and makes it exactly the number the contract passes as `amountOutMinimum`. `contracts/interfaces/IUniswapV3QuoterV2.sol` exists but is currently imported by nothing. |
| T6.3: whale swaps WETH→USDC on venue A | Implemented in **both** directions (WETH→USDC and USDC→WETH) | Both directions are profitable at the pin; each needs the opposite displacement, and the mirror test is the honest complement that proves a one-sided displacement does not make the other direction tradeable. |

---

## 11. What is NOT done

Explicit list. None of these is "in progress"; none is a bug.

| Item | Status |
|---|---|
| **Bot execution wiring** | Not implemented. `bot/src/main.ts` still hands `executionEngine.execute` placeholder calldata (`"0x"`, audit item B6) and points it at the Balancer vault address rather than the plugin. There is no code path from the bot to `ArbitragePlugin.startArbitrage`. |
| **V3 monitoring** | Out of scope (declared in the plan, D9). The detection universe is Uniswap V2 pairs only; the deep V3 0.05% pool is read on-chain by the contract but never monitored off-chain. |
| **Flashbots / private order flow** | Not wired. The Flashbots module exists but `buildBackrunCalldata` is a stub and invalid bundles are now rejected rather than sent (B8); the module itself has no callers in the main loop (B24). No bundle has been submitted. |
| **The decimals gap** | Deliberately left unfixed rather than half-fixed. `opportunityDetector` uses `WEI_MULTIPLIER = 10^18` and `main.ts` sizes a loan as `10^27` (1 WETH in wei), both of which assume an **18-decimal base token**, while the Arbitrum base token USDC has 6. This is the top follow-up. The contracts are unaffected — they are decimal-agnostic and work in raw token units throughout. |
| **Live deployment** | Not performed. `script/Deploy.s.sol` has been simulated (dry-run against chain 42161) and never broadcast. No contract exists on any public network. |
| **Any real trade** | **None has ever been placed.** Every profit figure in this report comes from a fork simulation at block 509,000,000. |
| **Third-party audit** | None. `Docs/AUDIT_LOG.md` round 1 is an internal review of the *previous* system. |
| **C1 invariant on real state** | The retained-profit invariant is proven by `test_RetainedProfitCannotRepayALosingCycle` in the mock suite only. The fork suite shows a reverting cycle leaves the plugin empty and the vault untouched, but never pre-funds the plugin first, so the invariant is not yet demonstrated on a fork. Add a fork test that pre-funds the plugin and asserts a sub-principal cycle still reverts. |
| **Audit-log round 2** | `Docs/AUDIT_LOG.md` still covers only round 1 (the Aave system). It has not been extended with a round for this migration. |
| **Open audit items carried over** | C4 (`initiator` validation), B6 (real execution calldata and the bot-to-plugin path), B8 (real backrun bundles), B24 (`database.save*` / `flashbots` module unwired), D4 (Foundry install helpers tracked at the repo root). |

---

## 12. Honest closing assessment

What is genuinely established: the two-venue cycle works mechanically on real Arbitrum
liquidity, it is profitable when a dislocation exists, it repays the loan exactly, it strands
no intermediate token, and every guard on it has been fired by a test — several against the
real deployments rather than mocks.

What is not established: that the system can find and capture such a dislocation in
production. Detecting it off-chain and landing the transaction ahead of everyone else is
exactly the part that is not implemented, and on a 250 ms chain it is the part that decides
whether any of this makes money. The fork result is evidence that the cycle is *correct and
economically viable under a measured condition*, not evidence that the strategy is
deployable.
