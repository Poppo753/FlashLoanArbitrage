# Flash Loan Arbitrage — Balancer on Arbitrum

This project borrows USDC from the **Balancer V2 Vault at a 0% fee**, buys WETH on
**Uniswap V2**, sells that WETH on **Uniswap V3 (0.05% pool)**, repays the USDC principal
and keeps the spread — all inside a single atomic transaction. On a fork of Arbitrum One
pinned at block **509,000,000** the cycle is measured end to end: a large WETH sale had
pushed the thin V2 pair from **2,688** down to **2,235 USDC/WETH** while the deep V3 pool
still quoted **2,685**, and borrowing **2,000 USDC** then bought **0.8269 WETH** on V2 and
sold for **2,219.50 USDC** — **219.50 USDC of profit (10.98%)** for roughly 472k gas. With
no such dislocation the very same cycle loses ~7% to the 35 bps round-trip venue fee and
reverts, which the test suite proves on purpose (the control test).

> **Status: measured on a real Arbitrum fork, never traded live.** The contracts compile,
> the mock suite is green, and the 29 fork tests pass against Arbitrum mainnet state at the
> pinned block. Nothing has ever been deployed to a public network and no real trade has been
> placed: the bot has no execution path to `startArbitrage` (see [Limitations](#limitations--security-posture)).

---

## Architecture

Three on-chain pieces plus the tests that prove them:

| Piece | File | Role |
|---|---|---|
| **Arbitrage core** | `contracts/ArbitragePlugin.sol` | Implements `IFlashLoanCallback`. Builds the route, runs both swap legs, does the profit accounting, enforces the guards. Holds retained profit (never the loan). |
| **Flash-loan service** | `contracts/services/FlashLoanService.sol` | Balancer V2 flash loans, 0% fee. Authorizes exactly one caller (`authorizedCaller`, immutable), forwards the principal to the plugin, repays the vault. |
| **Deploy script** | `script/Deploy.s.sol` | Deploys plugin → service → `initialize(...)`, all parameters from env. |

```
ArbitragePlugin.startArbitrage(amount, buyOnVenueA)      [onlyOwner, whenNotPaused]
  └─> FlashLoanService.executeFlashLoan([baseToken],[amount], routeData)
        └─> Balancer V2 Vault.flashLoan(recipient = service)      (0% fee)
              └─> FlashLoanService.receiveFlashLoan(...)
                    ├─ transfers the principal to the plugin
                    ├─> ArbitragePlugin.onFlashLoanReceived(...)
                    │     ├─ leg 1: buy  quoteToken  (V2 or V3, chosen by the owner)
                    │     ├─ leg 2: sell quoteToken 100% on the OTHER venue
                    │     ├─ accounting: repay principal+fee, keep the surplus
                    │     └─ repay the service
                    └─ repays the vault (principal + feeAmounts)   ("trust the revert")
```

The cycle always opens **and** closes in the borrowed asset (USDC → WETH → USDC), so no
intermediate token can be stranded and retained profit from a previous cycle can never be
spent on repaying the current loan.

### One cycle, step by step

1. The owner calls `startArbitrage(amount, buyOnVenueA)` — `onlyOwner` and `whenNotPaused`.
   `amount` is in `baseToken` wei and must be at least `MIN_FLASH_LOAN` (a dust floor).
2. The plugin calls `service.executeFlashLoan([baseToken], [amount], abi.encode(RouteData))`,
   where `RouteData = { buyOnVenueA, deadline }` and `deadline = block.timestamp + deadlineWindow`.
3. `FlashLoanService` checks `msg.sender == authorizedCaller`, then asks the Balancer V2 Vault
   for the loan, registering itself as the `IFlashLoanRecipient`.
4. Balancer transfers the principal to the service and calls back
   `service.receiveFlashLoan(tokens, amounts, feeAmounts, userData)`. The service verifies the
   caller is the vault, transfers the principal to the plugin, and calls
   `plugin.onFlashLoanReceived(tokens, amounts, feeAmounts, callbackData)`.
5. The plugin validates the callback: caller is the configured service, exactly one token and
   it is `baseToken`, `callbackData` is exactly `abi.encode(RouteData)`, and
   `block.timestamp <= route.deadline`. It then snapshots its own `baseToken` balance.
6. **Leg 1 — buy the quote token** on the venue the owner selected: Uniswap V2
   `swapExactTokensForTokens` when `buyOnVenueA` is true, otherwise Uniswap V3
   `exactInputSingle` (fee tier 500). Each leg's `amountOutMinimum` is the venue quote minus
   `maxSlippageBps` — the V2 quote is the router's own exact `getAmountsOut`, the V3 quote is
   derived from `pool.slot0()`.
7. **Leg 2 — sell 100% of what leg 1 produced**, always on the *other* venue, so no quote-token
   dust survives the cycle.
8. **Accounting and repayment**: `available = balanceAfter − preExisting` (the balance held
   before the principal arrived), `required = principal + feeAmounts[0]` (Balancer V2 charges 0,
   so `required == amount`). If `available < required` → `InsufficientRepayment`; if
   `profit = available − required < minProfit` → `MinProfitNotMet`. Otherwise the plugin
   approves and transfers `required` back to the service, which repays the vault.
9. The surplus stays as the plugin's `baseToken` balance and is announced with
   `ArbitrageExecuted(principal, profit, buyOnVenueA)`. It is withdrawable with
   `withdrawToken(token, to, amount)` (owner-only, pull pattern).

`getExpectedProfit(amount, buyOnVenueA)` is the off-chain quote (a `view` function, not a
guard): the V2 leg uses the exact router quote, the V3 leg uses the `slot0` spot price
discounted by the pool fee and by `maxSlippageBps`. The on-chain guard is `minProfit`.

Admin surface: `initialize(address)` (one-shot, owner), `setMinProfit(uint256)`,
`pause()` / `unpause()`, `withdrawToken(address,address,uint256)`. All `onlyOwner`.

## Addresses — Arbitrum One (chainId 42161)

| Contract | Address |
|---|---|
| Balancer V2 Vault (flash-loan source, 0% fee) | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` |
| Uniswap V2 Factory | `0xf1D7CC64Fb4452F05c498126312eBE29f30Fbcf9` |
| Uniswap V2 Router02 (**venue A**) | `0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24` |
| Uniswap V3 Factory | `0x1F98431c8aD98523631AE4a59f267346ea31F984` |
| Uniswap V3 SwapRouter (**venue B**) | `0xE592427A0AEce92De3Edee1F18E0157C05861564` |
| Uniswap V3 WETH/USDC 0.05% pool | `0xC6962004f452bE9203591991D15f6b388e09E8D0` |
| WETH (quote token, 18 decimals) | `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` |
| USDC (base token, 6 decimals) | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |

Only two addresses are hardcoded in the contracts, both canonical and cross-checked at
runtime: the Balancer Vault inside `FlashLoanService` (`BALANCER_VAULT`) and the Uniswap V3
factory inside `ArbitragePlugin` (`V3_FACTORY`, needed together with the V3 pool init-code
hash to derive the pool address by CREATE2 — the result is verified against the factory's own
`getPool`, so a stale constant can only cause a revert, never a misrouted swap). Token and
router addresses are constructor parameters. The V2 pair address
(`0xF64Dfe17C8b87F012FCf50FbDA1D62bfA148366a`) is only referenced by the fork tests.

## Repository layout

```
contracts/                        ArbitragePlugin.sol (the arbitrage core)
contracts/services/               FlashLoanService.sol (Balancer V2, single-caller auth)
contracts/interfaces/             IFlashLoanCallback, balancer/IBalancerVault,
                                  IUniswapV2Router02, IUniswapV3Router, IUniswapV3Pool,
                                  IUniswapV3QuoterV2, IUniswapV2Factory
script/Deploy.s.sol               plugin -> service -> initialize, env-driven
test/ArbitragePlugin.t.sol        21 mock-based behavioural tests (fast, no network)
test/fork/                        29 tests against real Arbitrum state, pinned block
helpers/Mocks.sol                 MockERC20 used by the mock suite
bot/src/                          TypeScript bot: pool monitor, opportunity detection,
                                  profit calculator, simulator, execution engine,
                                  Flashbots module — **not wired to the plugin**
Docs/                             plan, checklist, audit log, this project's docs
```

`lib/` is gitignored, so a fresh clone has to install the two Solidity dependencies declared
in the `foundry.toml` remappings. The pins below mirror the versions currently vendored in
`lib/` (read from each package's `package.json`); skip the step if `lib/` is already populated.

```bash
forge install foundry-rs/forge-std@v1.16.2 OpenZeppelin/openzeppelin-contracts@v5.7.0
forge build
```

## Running the tests

Prerequisite: Foundry. The fork suite additionally needs an **Arbitrum mainnet RPC URL in
`.env`** (the file is gitignored); the `arbitrum` RPC alias in `foundry.toml` reads
`ARBITRUM_RPC_URL` from it.

```bash
# .env  (gitignored) - required only for the fork suite
ARBITRUM_RPC_URL=https://arb-mainnet.g.alchemy.com/v2/<KEY>
```

### Mock suite — no network, seconds

```bash
forge test --match-path "test/ArbitragePlugin.t.sol" -vv
```

21 tests. They run the production `ArbitragePlugin` and the production `FlashLoanService`
against etched mocks: `MockBalancerVault` at the Balancer address, `MockV3Factory` at the V3
factory address and `MockV3Pool` at the CREATE2-derived V3 pool address. This proves the
control flow, the accounting and every guard — **and nothing about real liquidity**. The V2
mock pool, handed a hand-picked price, always repays with interest.

A bare `forge test` also works: the 29 fork tests then skip themselves (see below).

### Fork suite — real Arbitrum state, pinned block

```bash
forge test --match-path "test/fork/*" --fork-url arbitrum --fork-block-number 509000000 -vv
```

`--fork-block-number 509000000` is **mandatory for reproducibility**: without it forge forks
at `latest`, and every number in these tests moves, because the V2 pair holds only ~10.3 WETH.
`FORK_ENABLED=true` may also be exported, but it is optional: the suites enable themselves
whenever real Arbitrum state is loaded.

| Suite | Tests | What it proves |
|---|---|---|
| `test/fork/FlashLoanBalancer.t.sol` | 6 | The real Balancer vault is at the hardcoded address, really lends USDC, really reports `feeAmounts == 0`, and ends the transaction whole. Plus the service's three access guards. |
| `test/fork/Arbitrage.e2e.t.sol` | 7 | The two-venue cycle makes real profit on real liquidity, in both directions; the wrong direction and the no-displacement case are rejected; the quote agrees with execution; the pin is honoured. |
| `test/fork/Security.t.sol` | 16 | Access control, initialization, callback validation and post-cycle integrity against real state rather than mocks. |

Nothing is etched or stubbed in these suites: the real routers, the real pool and the real
vault run the real plugin bytecode.

## Deploying

All parameters are read from the environment by `script/Deploy.s.sol`:

| Variable | Required | Meaning |
|---|---|---|
| `BASE_TOKEN_ADDRESS` | yes | Borrowed/profit asset (USDC on Arbitrum) |
| `QUOTE_TOKEN_ADDRESS` | yes | Intermediate asset (WETH on Arbitrum) |
| `VENUE_A_ROUTER` | yes | Uniswap V2 compatible router |
| `VENUE_B_ROUTER` | yes | Uniswap V3 SwapRouter |
| `MIN_PROFIT` | no (default `0`) | Minimum cycle profit, in base-token wei. `0` is only ever set when the variable is absent, and it disables the guard — set a real value. |
| `MAX_SLIPPAGE_BPS` | no (default `50`) | Per-leg `amountOutMinimum` haircut. The contract rejects values above `2000`. |
| `DEADLINE_WINDOW` | no (default `60`) | Route/router deadline lifetime in seconds. The contract accepts `[30, 3600]`. |
| `PRIVATE_KEY` | for `--broadcast` | Deployer key. The plugin's owner is the broadcasting account. |
| `ARBITRUM_RPC_URL` | yes | Read through the `arbitrum` alias in `foundry.toml`. |

```bash
# .env  (gitignored)
PRIVATE_KEY=0x...
ARBITRUM_RPC_URL=https://arb-mainnet.g.alchemy.com/v2/<KEY>
BASE_TOKEN_ADDRESS=0xaf88d065e77c8cC2239327C5EDb3A432268e5831   # USDC
QUOTE_TOKEN_ADDRESS=0x82aF49447D8a07e3bd95BD0d56f35241523fBab1 # WETH
VENUE_A_ROUTER=0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24      # Uniswap V2 Router02
VENUE_B_ROUTER=0xE592427A0AEce92De3Edee1F18E0157C05861564      # Uniswap V3 SwapRouter
MIN_PROFIT=1000000        # 1 USDC, in 6-decimal wei
MAX_SLIPPAGE_BPS=50
DEADLINE_WINDOW=60
```

```bash
forge script script/Deploy.s.sol --rpc-url arbitrum --broadcast
```

Order is forced by the design: the plugin is deployed first, then
`new FlashLoanService(address(plugin))`, then `plugin.initialize(address(service))`, then
`setMinProfit(MIN_PROFIT)` when it is non-zero. Add `--verify` only if you have a block
explorer API key configured for Arbitrum.

**No live deployment has been made.** The script has only been simulated (a local dry-run
against chain 42161 is in `broadcast/`, which is gitignored).

## Measured results (Arbitrum fork, block 509,000,000)

| Quantity | Measured value |
|---|---|
| Balancer vault USDC balance | 13,275.06 USDC |
| V2 WETH/USDC pair reserves | 10.3357 WETH / 27,784.98 USDC |
| V2 mid price before any trade | 2,688.248784 USDC/WETH |
| V3 `slot0` spot before any trade | 2,685.443451 USDC/WETH |
| Pre-trade gap | ~10 bps (V2 the dearer side) — nothing to arbitrage |
| Whale trade | sells 1 WETH into V2 → V2 mid falls to 2,235.462589; V3 untouched at 2,685.443451 |
| Leg 1 (direction A) | 2,000 USDC → 0.826916761 WETH on V2 |
| Leg 2 (direction A) | 0.826916761 WETH → 2,219.500276 USDC on V3 |
| Repayment | 2,000.000000 USDC (Balancer fee 0) |
| **Profit (direction A)** | **219.500276 USDC = 10.975% of the principal** |
| **Profit (direction B, reverse)** | **128.361241 USDC = 6.418%** |
| Gas for one `startArbitrage` | ~472k |
| **Control — no whale trade** | cycle produces 1,856.76 USDC against a 2,000 USDC loan → reverts `InsufficientRepayment` (~7.16% loss against a 10 bps gap and a 35 bps round-trip fee) |

The control case is the important one: the profit is a property of the market state, not of
the test harness. `getExpectedProfit` also proves the point off-chain — with the venues
aligned it reports zero profit before the transaction is ever sent.

## Limitations & security posture

What is **not** implemented, stated plainly:

- **No live trading.** There is no deployed contract, no private transaction flow and no
  Flashbots integration wired to `ArbitragePlugin.startArbitrage`. `bot/src/main.ts` still
  passes placeholder calldata (`"0x"`, audit item B6) and the Flashbots bundle builder is a
  stub whose bundles are rejected rather than sent (B8). The system has never placed a trade.
- **The bot is not the strategy.** It monitors Uniswap V2 pairs, detects two-way price gaps,
  sizes a loan and computes a profit estimate. It does not drive the V3 venue, and it assumes
  an 18-decimal base token while Arbitrum USDC has 6 — the top follow-up, deliberately left
  unfixed rather than half-fixed. The contracts do not have this problem: they are
  decimal-agnostic, all amounts are raw token units.
- **V3 monitoring is out of scope.** The V3 pool is read on-chain (`slot0`) but not monitored
  off-chain; the detection universe is Uniswap V2 only.
- **The V2 pool is thin** (~10.3 WETH / ~27.8k USDC at the pin), so realistic sizes are
  small, the V2 leg carries a lot of price impact, and the profitable window only exists
  immediately after a large trade moves V2.
- **The 0% fee is a property of Balancer V2**, not of this code. If the vault is ever
  substituted, `required` changes and the profitability math changes with it.
- **`minProfit` defaults to 0** after deployment, which accepts any non-negative profit. Set
  it explicitly.
- **No third-party audit.** All reviews recorded in `Docs/AUDIT_LOG.md` are internal.

What the contracts do implement (and what the tests therefore cover):

- `onlyOwner` on `startArbitrage` and on every admin function; `whenNotPaused` kill switch
  with an owner-only `pause()`/`unpause()` pair.
- One-shot `initialize(address)`: the callback can only come from the address the owner
  recorded, and only once (`AlreadyInitialized`).
- The service authorizes a single immutable `authorizedCaller`, is `nonReentrant`, checks the
  callback caller is the Balancer vault, checks `_inFlashLoan`, and reverts rather than
  under-repaying ("trust the revert").
- Three independent guards on every cycle: per-leg `amountOutMinimum`, the absolute route
  `deadline`, and `minProfit`. The V3 pool address is derived by CREATE2 and cross-checked
  against the factory, so it can only revert, never route funds to a wrong address.
- Profit accounting subtracts the pre-existing balance, so retained profit can never be
  consumed to service the next loan.
- `SafeERC20` throughout; `withdrawToken` is a pull, not a push.

This is a working prototype, not a production system: single-owner control with no timelock
or multisig, a test-only economic assumption (a dislocation appears right after a large
trade), and no independent review. Treat the fork numbers as evidence that the cycle
*mechanically* works and is profitable under a measured condition — not as evidence that it
is safe to run unattended with money.

## Documentation

| Document | Contents |
|---|---|
| [`Docs/IMPLEMENTATION_REPORT.md`](Docs/IMPLEMENTATION_REPORT.md) | Dated engineering record of the Balancer/Arbitrum migration: what was ported and how it was adapted, every bug found, the measured numbers, and what is explicitly not done. |
| [`Docs/ARBITRAGE_ARBITRUM_PLAN.md`](Docs/ARBITRAGE_ARBITRUM_PLAN.md) | The plan the migration was built from, with decisions D1–D13 and their rationale (in Italian, as written). |
| [`Docs/ARBITRAGE_CHECKLIST.md`](Docs/ARBITRAGE_CHECKLIST.md) | Phase-by-phase execution checklist (phases 0–10). |
| [`Docs/ARBITRAGE_ARBITRUM_IDEA.md`](Docs/ARBITRAGE_ARBITRUM_IDEA.md) | The original scoping note that started the rebuild. |
| [`Docs/AUDIT_LOG.md`](Docs/AUDIT_LOG.md) | Dated audit rounds. **Round 1 covers the older Aave/Ethereum system**; the findings table there (C1–C6, T1–T2, B1–B24) predates the migration, though several lessons carried over (see the implementation report). |
| `Docs/V1/` | Original design documents of the Aave-on-Ethereum version. Historical. |

## Bot (optional, not part of the proven path)

Prerequisite: Node.js 18+.

```bash
cd bot
cp .env.example .env      # Arbitrum endpoints and thresholds
npm install
npm run typecheck         # tsc --noEmit
npm start
```

The bot is type-clean and configured for Arbitrum One, but as stated above it is not
connected to the contracts. Running it will not trade.

## License

MIT

