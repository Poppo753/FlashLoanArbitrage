# Flash Loan Arbitrage Bot

A flash-loan arbitrage project built on Ethereum: Foundry smart contracts (Aave V3 flash loans, Uniswap V2-style routers) plus a TypeScript off-chain bot that can submit opportunities via Flashbots.

## Architecture

Three modules:

- **Contracts** — `FlashArbExecutor.sol` executes flash-loan arbitrage: borrows a single asset from Aave V3, swaps it through two routers (borrow -> intermediate -> borrow), verifies minimum profit, repays and retains the profit. Access control via OpenZeppelin `Ownable`, reentrancy-guarded callback, owner circuit breaker (`pause`/`unpause`).
- **Bot** (`bot/src/`) — TypeScript service: monitors pools, detects opportunities, simulates and (when wired) executes transactions; includes a Flashbots module (`bot/src/flashbots/`).
- **Scripts** — `script/Deploy.s.sol` deploys the executor, fully parameterized via environment variables.

```
contracts/           # FlashArbExecutor + interfaces (Aave, Uniswap V2 router) + libraries/
helpers/             # Test helpers (mocks, constants)
script/              # Deploy script (env-driven)
test/                # Foundry tests (14 tests)
bot/src/             # Off-chain bot service (TypeScript)
bot/src/flashbots/   # Flashbots bundle/monitoring module
Docs/V1/             # Original design documents
Docs/AUDIT_LOG.md    # Audit log: findings, fixes, dates (updated every fix)
```

## Quick Start

### Prerequisites

- Foundry ([book.getfoundry.sh](https://book.getfoundry.sh))
- Node.js 18+ (for the bot)

### Contracts

1. Install dependencies and build:
   ```bash
   forge install
   forge build
   ```

2. Run tests:
   ```bash
   forge test -vv
   ```

3. Deploy (all values are required, see `.env.example`):
   ```bash
   cp .env.example .env   # fill in OWNER_ADDRESS, AAVE_POOL_ADDRESS, ROUTER_0_ADDRESS, ROUTER_1_ADDRESS, MIN_PROFIT_BPS
   forge script script/Deploy.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
   ```

### Bot

```bash
cd bot
cp .env.example .env   # bot has its own environment file
npm install
npm run build
npm start
```

## Configuration

Root `.env` (contracts / deploy):

| Variable              | Description                                  |
|-----------------------|----------------------------------------------|
| `PRIVATE_KEY`         | Deployer key for `forge script --broadcast`  |
| `RPC_URL`             | HTTPS RPC endpoint                           |
| `ETHERSCAN_API_KEY`   | Contract verification                        |
| `MIN_PROFIT_BPS`      | Minimum profit threshold in basis points     |
| `OWNER_ADDRESS`       | Executor owner (admin) address               |
| `AAVE_POOL_ADDRESS`   | Aave V3 Pool address                         |
| `ROUTER_0_ADDRESS`    | First router address                         |
| `ROUTER_1_ADDRESS`    | Second router address                        |

The bot uses its own `bot/.env.example` (RPC/WebSocket endpoints, thresholds, Flashbots, database).

## Audit

Findings and fixes are tracked in [`Docs/AUDIT_LOG.md`](Docs/AUDIT_LOG.md), one dated entry per fix.

## License

MIT
