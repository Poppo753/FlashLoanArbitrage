import dotenv from "dotenv";
import { logger } from "./logger";

dotenv.config();

/**
 * ACTIVE CHAIN: Arbitrum One (chainId 42161).
 *
 * The on-chain side of this project is a Balancer-funded, Uniswap V2 <-> V3 arbitrage on
 * Arbitrum (`contracts/ArbitragePlugin.sol` + `contracts/services/FlashLoanService.sol`).
 * There is no Ethereum deployment and no Aave deployment behind this bot any more, so no
 * Ethereum/Aave entry is exposed here: a single chain is configured, and every hardcoded
 * address below is a verified Arbitrum constant that env can override.
 *
 * Endpoints are NEVER hardcoded (no URL, no API key): `*_RPC_URL` (https) and
 * `*_WS_RPC_URL` (wss) must come from the environment. See `bot/.env.example`.
 */

/** Arbitrum One. */
export const ARBITRUM_CHAIN_ID = 42161;

/** WETH on Arbitrum One (18 decimals) - quote token of the cycle. */
export const ARBITRUM_WETH = "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1";

/** Native USDC on Arbitrum One (6 decimals) - borrowed/profit asset, cycle closes in it. */
export const ARBITRUM_USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";

/** Uniswap V2 Router02, official Uniswap deployment on Arbitrum One (venue A of the plugin). */
export const ARBITRUM_UNISWAP_V2_ROUTER = "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24";

/** UniswapV2Factory, official Uniswap deployment on Arbitrum One. Used to discover V2 pairs. */
export const ARBITRUM_UNISWAP_V2_FACTORY = "0xf1D7CC64Fb4452F05c498126312eBE29f30Fbcf9";

/** Balancer V2 Vault on Arbitrum One: the 0%-fee flash loan source used by FlashLoanService. */
export const BALANCER_V2_VAULT = "0xBA12222222228d8Ba445958a75a0704d566BF2C8";

/**
 * Balancer V2 flash loans carry NO premium (0 bps). The legacy Aave default of 5 bps is
 * factually wrong for this chain and was removed. Still overridable via
 * `FLASH_LOAN_PREMIUM_BPS` / `ARBITRUM_FLASH_LOAN_PREMIUM_BPS` if a fee-bearing source is
 * ever substituted for the Balancer Vault.
 */
export const BALANCER_FLASH_LOAN_PREMIUM_BPS = 0;

export interface ChainConfig {
  name: string;
  /** https endpoint. Supplied by env only - never defaulted to a literal URL. */
  rpcUrl: string;
  /** wss endpoint, kept separate from `rpcUrl`. Supplied by env only. */
  wsRpcUrl: string;
  chainId: number;
  /** Quote token of the cycle (WETH on Arbitrum). */
  wethAddress: string;
  /** Borrowed/profit asset; the cycle opens and closes in it (USDC on Arbitrum). */
  baseTokenAddress: string;
  /** Uniswap V2 Router02 (venue A of ArbitragePlugin). */
  uniswapV2Router: string;
  /** UniswapV2Factory, used by PoolMonitor to resolve pairs to subscribe to. */
  uniswapV2Factory: string;
  /** Balancer V2 Vault: the 0%-fee flash loan source behind contracts/services/FlashLoanService. */
  balancerVault: string;
  blockExplorer: string;
  /** Flash loan premium in basis points. 0 for Balancer V2. */
  flashLoanPremiumBps: number;
}

export interface ThresholdsConfig {
  minProfitWei: string;
  minProfitUsd: number;
  maxGasPriceGwei: number;
  maxSlippageBps: number;
  minLoopProfitMargin: number;
}

export interface BotConfig {
  chains: ChainConfig[];
  thresholds: ThresholdsConfig;
  flashLoanPremiumBps: number;
  gasLimit: number;
  priorityFeeWei: string;
  baseFeeMultiplier: number;
  redisUrl: string;
  postgresUrl: string;
  simulationBlockDelay: number;
  maxRetries: number;
  retryDelayMs: number;
}

/**
 * Verified Arbitrum One values used when the matching env var is absent. Endpoints are
 * deliberately absent: there is no safe literal to fall back to.
 */
const ARBITRUM_DEFAULTS = {
  name: "Arbitrum One",
  chainId: ARBITRUM_CHAIN_ID,
  wethAddress: ARBITRUM_WETH,
  baseTokenAddress: ARBITRUM_USDC,
  uniswapV2Router: ARBITRUM_UNISWAP_V2_ROUTER,
  uniswapV2Factory: ARBITRUM_UNISWAP_V2_FACTORY,
  balancerVault: BALANCER_V2_VAULT,
  blockExplorer: "https://arbiscan.io",
  flashLoanPremiumBps: BALANCER_FLASH_LOAN_PREMIUM_BPS,
} as const;

function loadChain(envPrefix: string, defaults: typeof ARBITRUM_DEFAULTS): ChainConfig {
  return {
    name: process.env[`${envPrefix}_NAME`] || defaults.name,
    rpcUrl: process.env[`${envPrefix}_RPC_URL`] || "",
    wsRpcUrl: process.env[`${envPrefix}_WS_RPC_URL`] || "",
    chainId: parseInt(process.env[`${envPrefix}_CHAIN_ID`] || `${defaults.chainId}`, 10),
    wethAddress: process.env[`${envPrefix}_WETH_ADDRESS`] || defaults.wethAddress,
    baseTokenAddress:
      process.env[`${envPrefix}_BASE_TOKEN_ADDRESS`] || defaults.baseTokenAddress,
    uniswapV2Router: process.env[`${envPrefix}_UNISWAP_V2_ROUTER`] || defaults.uniswapV2Router,
    uniswapV2Factory:
      process.env[`${envPrefix}_UNISWAP_V2_FACTORY`] || defaults.uniswapV2Factory,
    balancerVault: process.env[`${envPrefix}_BALANCER_VAULT`] || defaults.balancerVault,
    blockExplorer: process.env[`${envPrefix}_BLOCK_EXPLORER`] || defaults.blockExplorer,
    flashLoanPremiumBps: parseInt(
      process.env[`${envPrefix}_FLASH_LOAN_PREMIUM_BPS`] || `${defaults.flashLoanPremiumBps}`,
      10
    ),
  };
}

export function loadConfig(): BotConfig {
  const arbitrum = loadChain("ARBITRUM", ARBITRUM_DEFAULTS);

  const thresholds: ThresholdsConfig = {
    minProfitWei: process.env.MIN_PROFIT_WEI || "0",
    minProfitUsd: parseFloat(process.env.MIN_PROFIT_USD || "10"),
    maxGasPriceGwei: parseFloat(process.env.MAX_GAS_PRICE_GWEI || "100"),
    maxSlippageBps: parseFloat(process.env.MAX_SLIPPAGE_BPS || "50"),
    minLoopProfitMargin: parseFloat(process.env.MIN_LOOP_PROFIT_MARGIN || "0.05"),
  };

  return {
    chains: [arbitrum],
    thresholds,
    flashLoanPremiumBps: parseInt(
      process.env.FLASH_LOAN_PREMIUM_BPS || `${BALANCER_FLASH_LOAN_PREMIUM_BPS}`,
      10
    ),
    gasLimit: parseInt(process.env.GAS_LIMIT || "3000000", 10),
    priorityFeeWei: process.env.PRIORITY_FEE_WEI || "2000000000",
    baseFeeMultiplier: parseFloat(process.env.BASE_FEE_MULTIPLIER || "1.1"),
    redisUrl: process.env.REDIS_URL || "redis://localhost:6379",
    postgresUrl: process.env.POSTGRES_URL || "postgresql://localhost:5432/flashloan",
    simulationBlockDelay: parseInt(process.env.SIMULATION_BLOCK_DELAY || "1", 10),
    maxRetries: parseInt(process.env.MAX_RETRIES || "3", 10),
    retryDelayMs: parseInt(process.env.RETRY_DELAY_MS || "1000", 10),
  };
}

export const config = loadConfig();

if (config.chains.some((c) => !c.rpcUrl)) {
  logger.error("Missing ARBITRUM_RPC_URL (https endpoint) in environment");
  process.exit(1);
}

if (config.chains.some((c) => !c.wsRpcUrl)) {
  logger.warn(
    "Missing ARBITRUM_WS_RPC_URL; WebSocket monitoring will fail until it is set (wss endpoint, distinct from ARBITRUM_RPC_URL)"
  );
}

export function getChainById(chainId: number): ChainConfig | undefined {
  return config.chains.find((c) => c.chainId === chainId);
}
