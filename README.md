# Flash Loan Arbitrage Bot

A high-performance Flash Loan Arbitrage bot built on Ethereum, leveraging Foundry for smart contract development, Aave for flash loans, and MEV-Boost for block building.

## Architecture Overview

The bot consists of three core modules:

- **Contracts** — Solidity smart contracts that execute the flash loan logic, arbitrage settlement, and profit verification. Interfaces define integrations with Aave, Uniswap V3, and Balancer.
- **Bot** — A Python/TypeScript off-chain service that monitors the mempool, identifies arbitrage opportunities, and submits transactions via Flashbots.
- **Scripts & Deploy** — Foundry scripts for deploying contracts to mainnet/testnets and configuring the bot.

```
contracts/          # Core arbitrage smart contracts
  interfaces/       # External protocol interfaces (Aave, DEXs)
  libs/             # Shared libraries (SafeMath, Math)
bot/src/            # Off-chain bot service
script/             # Execution scripts (arbitrage, liquidation)
test/               # Foundry tests
  helpers/          # Test utilities and fixtures
deploy/             # Deployment scripts and configuration
docs/               # Documentation
```

## Quick Start

### Prerequisites

- Foundry installed ([foundry.book.sh](https://book.getfoundry.sh))
- Node.js 18+
- Docker (optional, for local development)

### Setup

1. Clone the repository and navigate to the project directory:
   ```bash
   cd D:\Documents\Projects\FlashLoanArbitrage
   ```

2. Copy the environment file and fill in your values:
   ```bash
   cp .env.example .env
   ```

3. Install dependencies and build:
   ```bash
   forge install
   forge build
   ```

4. Run tests:
   ```bash
   forge test --verbose
   ```

5. Deploy to a local network:
   ```bash
   cast --rpc-url localhost --private-key $PRIVATE_KEY create $DEPLOYED_BYTECODE
   forge script script/Deploy.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
   ```

### Development

- **Tests**: Write tests in `test/` using Foundry's testing framework.
- **Contracts**: Solidity source files go in `contracts/`.
- **Bot**: The bot service runs from `bot/src/` and connects to the RPC endpoint.

## Configuration

| Variable               | Description                              |
|------------------------|------------------------------------------|
| `PRIVATE_KEY`          | Wallet private key for transaction signing |
| `RPC_URL`              | Ethereum RPC endpoint                    |
| `FLASHBOTS_SECRET`     | Flashbots MEV relay secret               |
| `ETHERSCAN_API_KEY`    | Etherscan API key for verification       |
| `ALCHEMY_API_KEY`      | Alchemy API key for enhanced RPC         |
| `MIN_PROFIT_BPS`       | Minimum profit threshold in basis points |
| `OWNER_ADDRESS`        | Bot owner address for governance         |
| `AAVE_POOL_ADDRESS`    | Aave V3 Pool contract address            |

## License

MIT
