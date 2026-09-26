import dotenv from "dotenv";
import { logger } from "./logger";

dotenv.config();

export interface ChainConfig {
  name: string;
  rpcUrl: string;
  chainId: number;
  wethAddress: string;
  uniswapV2Router: string;
  uniswapV2Factory: string;
  aaveLendingPool: string;
  aavePoolAddressesProvider: string;
  blockExplorer: string;
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

function loadChain(envPrefix: string): ChainConfig {
  return {
    name: process.env[`${envPrefix}_NAME`] || "Unknown",
    rpcUrl: process.env[`${envPrefix}_RPC_URL`] || "",
    chainId: parseInt(process.env[`${envPrefix}_CHAIN_ID`] || "1", 10),
    wethAddress: process.env[`${envPrefix}_WETH_ADDRESS`] || "",
    uniswapV2Router: process.env[`${envPrefix}_UNISWAP_V2_ROUTER`] || "",
    uniswapV2Factory: process.env[`${envPrefix}_UNISWAP_V2_FACTORY`] || "",
    aaveLendingPool: process.env[`${envPrefix}_AAVE_LENDING_POOL`] || "",
    aavePoolAddressesProvider: process.env[`${envPrefix}_AAVE_POOL_ADDRESSES_PROVIDER`] || "",
    blockExplorer: process.env[`${envPrefix}_BLOCK_EXPLORER`] || "",
    flashLoanPremiumBps: parseInt(
      process.env[`${envPrefix}_FLASH_LOAN_PREMIUM_BPS`] || "5",
      10
    ),
  };
}

export function loadConfig(): BotConfig {
  const eth = loadChain("ETHEREUM");
  const base = loadChain("BASE");
  const arb = loadChain("ARBITRUM");

  const thresholds: ThresholdsConfig = {
    minProfitWei: process.env.MIN_PROFIT_WEI || "0",
    minProfitUsd: parseFloat(process.env.MIN_PROFIT_USD || "10"),
    maxGasPriceGwei: parseFloat(process.env.MAX_GAS_PRICE_GWEI || "100"),
    maxSlippageBps: parseFloat(process.env.MAX_SLIPPAGE_BPS || "50"),
    minLoopProfitMargin: parseFloat(process.env.MIN_LOOP_PROFIT_MARGIN || "0.05"),
  };

  return {
    chains: [eth, base, arb],
    thresholds,
    flashLoanPremiumBps: parseInt(process.env.FLASH_LOAN_PREMIUM_BPS || "5", 10),
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

if (config.chains.some((c) => !c.rpcUrl || !c.wethAddress)) {
  logger.error("Missing required chain configuration in environment");
  process.exit(1);
}

export function getChainById(chainId: number): ChainConfig | undefined {
  return config.chains.find((c) => c.chainId === chainId);
}
