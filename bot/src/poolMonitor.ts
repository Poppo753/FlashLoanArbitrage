import { ethers, Contract, WebSocketProvider, JsonRpcApiProvider } from "ethers";
import { Logger } from "winston";
import { config, ChainConfig } from "./config";
import { logger } from "./logger";

export interface ReserveData {
  pairAddress: string;
  token0: string;
  token1: string;
  reserve0: bigint;
  reserve1: bigint;
  blockNumber: number;
  timestamp: number;
}

export interface OrientedReserve {
  pairAddress: string;
  tokenIn: string;
  tokenOut: string;
  reserveIn: bigint;
  reserveOut: bigint;
}

export interface PoolSnapshot {
  pairAddress: string;
  reserves: { token0: string; token1: string; reserve0: bigint; reserve1: bigint };
  totalSupply: bigint;
  blockNumber: number;
}

export function pairKey(tokenA: string, tokenB: string): string {
  const a = tokenA.toLowerCase();
  const b = tokenB.toLowerCase();
  return a < b ? `${a}_${b}` : `${b}_${a}`;
}

export function orientReserve(
  reserve: ReserveData,
  tokenIn: string,
  tokenOut: string
): OrientedReserve | null {
  const inAddr = tokenIn.toLowerCase();
  const outAddr = tokenOut.toLowerCase();
  const t0 = reserve.token0.toLowerCase();
  const t1 = reserve.token1.toLowerCase();

  if (inAddr === t0 && outAddr === t1) {
    return {
      pairAddress: reserve.pairAddress,
      tokenIn: reserve.token0,
      tokenOut: reserve.token1,
      reserveIn: reserve.reserve0,
      reserveOut: reserve.reserve1,
    };
  }
  if (inAddr === t1 && outAddr === t0) {
    return {
      pairAddress: reserve.pairAddress,
      tokenIn: reserve.token1,
      tokenOut: reserve.token0,
      reserveIn: reserve.reserve1,
      reserveOut: reserve.reserve0,
    };
  }
  return null;
}

const UNISWAP_V2_PAIR_ABI = [
  "event Sync(uint112 reserve0, uint112 reserve1)",
  "function getReserves() view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)",
  "function token0() view returns (address)",
  "function token1() view returns (address)",
];

const UNISWAP_V2_FACTORY_ABI = [
  "function getPair(address tokenA, address tokenB) view returns (address pair)",
];

/**
 * Fallback detection universe, used only when MONITOR_TOKENS is unset/empty.
 * Keyed by chainId; only the active chain (Arbitrum One) has an entry. WETH is
 * always prepended by `tokensToMonitor`, so listing it here is de-duplicated.
 * Arbitrum One: native USDC (6 decimals) is the base token of the cycle.
 */
const KNOWN_TOKENS_BY_CHAIN: Record<number, string[]> = {
  42161: [
    "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1", // WETH (18 decimals, quote token)
    "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", // USDC (6 decimals, base token)
  ],
};

export class PoolMonitor {
  private provider: WebSocketProvider | JsonRpcApiProvider | null = null;
  private reserves: Map<string, ReserveData> = new Map();
  private pairTokens: Map<string, { token0: string; token1: string }> = new Map();
  private syncSubscriptions: Map<string, Contract> = new Map();
  private readonly logger: Logger;
  private _isRunning: boolean = false;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;

  constructor() {
    this.logger = logger;
  }

  async initialize(chainWsUrl: string, chainId: number): Promise<void> {
    try {
      if (!/^wss?:\/\//.test(chainWsUrl)) {
        throw new Error(
          `PoolMonitor requires a ws:// or wss:// endpoint, got "${chainWsUrl}". Set *_WS_RPC_URL in bot/.env.`
        );
      }
      this.provider = new WebSocketProvider(chainWsUrl, chainId, {
        batchMaxCount: 100,
        staticNetwork: true,
      } as any);

      (this.provider as any).on("error", (err: Error) => {
        this.logger.error("WebSocket provider error", { error: err.message });
        this.handleDisconnect();
      });

      ((this.provider as WebSocketProvider).websocket as any).on("close", () => {
        this.logger.warn("WebSocket connection closed, reconnecting...");
        this.handleDisconnect();
      });

      this.logger.info("PoolMonitor initialized", { chainId, provider: chainWsUrl });
    } catch (err: unknown) {
      this.logger.error("Failed to initialize PoolMonitor", { error: String(err) });
      throw err;
    }
  }

  private handleDisconnect(): void {
    if (!this._isRunning) return;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = setTimeout(async () => {
      try {
        await this.initialize(
          config.chains[0].wsRpcUrl || config.chains[0].rpcUrl,
          config.chains[0].chainId
        );
        await this.reSubscribeAll();
      } catch (err: unknown) {
        this.logger.error("Reconnection failed", { error: String(err) });
      }
    }, 5000);
  }

  async subscribeToPairs(pairAddresses: string[]): Promise<void> {
    if (!this.provider) {
      throw new Error("PoolMonitor not initialized");
    }

    const blockNumber = await this.provider.getBlockNumber().catch(() => 0);

    for (const pairAddress of pairAddresses) {
      try {
        const contract = new Contract(pairAddress, UNISWAP_V2_PAIR_ABI, this.provider);
        const [token0, token1] = (await Promise.all([
          contract.token0(),
          contract.token1(),
        ])) as [string, string];

        this.pairTokens.set(pairAddress.toLowerCase(), { token0, token1 });
        this.syncSubscriptions.set(pairAddress.toLowerCase(), contract);

        contract.on("Sync", (reserve0: bigint, reserve1: bigint, log: ethers.Log) => {
          this.handleSyncEvent(pairAddress, reserve0, reserve1, log);
        });

        const reserves = await contract.getReserves();
        this.writeReserves(
          pairAddress,
          token0,
          token1,
          reserves.reserve0,
          reserves.reserve1,
          blockNumber,
          Math.floor(Date.now() / 1000)
        );
      } catch (err: unknown) {
        this.logger.warn("Failed to subscribe to pair", {
          pair: pairAddress,
          error: String(err),
        });
      }
    }

    this.logger.info(`Subscribed to ${this.syncSubscriptions.size} Uniswap V2 pairs`);
  }

  private writeReserves(
    pairAddress: string,
    token0: string,
    token1: string,
    reserve0: bigint,
    reserve1: bigint,
    blockNumber: number,
    timestamp: number
  ): void {
    this.reserves.set(pairKey(token0, token1), {
      pairAddress: pairAddress.toLowerCase(),
      token0,
      token1,
      reserve0,
      reserve1,
      blockNumber,
      timestamp,
    });
  }

  private handleSyncEvent(
    pairAddress: string,
    reserve0: bigint,
    reserve1: bigint,
    log: ethers.Log
  ): void {
    const tokens = this.pairTokens.get(pairAddress.toLowerCase());
    if (!tokens) {
      this.logger.warn("Sync event for unknown pair", { pair: pairAddress });
      return;
    }

    this.writeReserves(
      pairAddress,
      tokens.token0,
      tokens.token1,
      reserve0,
      reserve1,
      log.blockNumber,
      Math.floor(Date.now() / 1000)
    );

    this.logger.debug("Sync event processed", {
      pair: pairAddress,
      reserve0: reserve0.toString(),
      reserve1: reserve1.toString(),
      block: log.blockNumber,
    });
  }

  async reSubscribeAll(): Promise<void> {
    const addresses = Array.from(this.syncSubscriptions.keys());
    await this.subscribeToPairs(addresses);
  }

  getReserves(): Map<string, ReserveData> {
    return new Map(this.reserves);
  }

  getReserve(reserveKey: string): ReserveData | undefined {
    return this.reserves.get(reserveKey.toLowerCase());
  }

  getReserveForPair(tokenA: string, tokenB: string): OrientedReserve | undefined {
    const reserve = this.reserves.get(pairKey(tokenA, tokenB));
    if (!reserve) return undefined;
    return orientReserve(reserve, tokenA, tokenB) ?? undefined;
  }

  getReserveAtBlock(tokenA: string, tokenB: string, blockNumber: number): ReserveData | undefined {
    const reserve = this.reserves.get(pairKey(tokenA, tokenB));
    if (reserve && reserve.blockNumber === blockNumber) {
      return reserve;
    }
    return undefined;
  }

  async getBaseFeeWei(): Promise<bigint | null> {
    if (!this.provider) return null;
    try {
      const block = await this.provider.getBlock("latest");
      return block?.baseFeePerGas ?? null;
    } catch (err: unknown) {
      this.logger.debug("Base fee lookup failed", { error: String(err) });
      return null;
    }
  }

  get isRunning(): boolean {
    return this._isRunning;
  }

  tokensToMonitor(chain: ChainConfig): string[] {
    const weth = chain.wethAddress;
    const envTokens = (process.env.MONITOR_TOKENS || "")
      .split(",")
      .map((token) => token.trim())
      .filter((token) => token.length > 0 && ethers.isAddress(token));

    let extras: string[] = [];
    if (envTokens.length > 0) {
      extras = envTokens;
    } else {
      extras = KNOWN_TOKENS_BY_CHAIN[chain.chainId] ?? [];
      if (extras.length > 0) {
        this.logger.info("MONITOR_TOKENS not set; falling back to built-in token list", {
          chainId: chain.chainId,
          tokens: extras.length,
        });
      }
    }

    const wethKey = weth.toLowerCase();
    const deduped = Array.from(
      new Set(extras.map((token) => token.toLowerCase()).filter((token) => token !== wethKey))
    );
    return [weth, ...deduped];
  }

  async subscribeConfiguredPairs(): Promise<void> {
    if (!this.provider) {
      throw new Error("PoolMonitor not initialized");
    }
    if (this.syncSubscriptions.size > 0) {
      return;
    }

    const chain = config.chains[0];
    const factoryAddress = chain.uniswapV2Factory;
    if (
      !factoryAddress ||
      !ethers.isAddress(factoryAddress) ||
      factoryAddress.toLowerCase() === ethers.ZeroAddress
    ) {
      this.logger.warn("Primary chain has no Uniswap V2 factory configured; nothing to subscribe", {
        chain: chain.name,
      });
      return;
    }

    const tokens = this.tokensToMonitor(chain);
    if (tokens.length < 2) {
      this.logger.warn(
        "No token pairs to monitor; set MONITOR_TOKENS (comma-separated token addresses)",
        { chain: chain.name }
      );
      return;
    }

    const factory = new Contract(factoryAddress, UNISWAP_V2_FACTORY_ABI, this.provider);
    const combos: Array<[string, string]> = [];
    for (let i = 0; i < tokens.length; i++) {
      for (let j = i + 1; j < tokens.length; j++) {
        combos.push([tokens[i], tokens[j]]);
      }
    }

    const pairs: string[] = [];
    const lookups = await Promise.all(
      combos.map(async ([tokenA, tokenB]) => {
        try {
          const pair = await factory.getPair(tokenA, tokenB);
          return pair as string;
        } catch (err: unknown) {
          this.logger.warn("Factory getPair lookup failed", {
            tokenA,
            tokenB,
            error: String(err),
          });
          return null;
        }
      })
    );

    for (const pair of lookups) {
      if (pair && pair.toLowerCase() !== ethers.ZeroAddress) {
        pairs.push(pair);
      }
    }

    if (pairs.length === 0) {
      this.logger.warn("No Uniswap V2 pairs discovered for configured tokens", {
        chain: chain.name,
        candidates: combos.length,
      });
      return;
    }

    await this.subscribeToPairs(pairs);
  }

  async start(): Promise<void> {
    this._isRunning = true;
    this.logger.info("PoolMonitor started");
    try {
      await this.subscribeConfiguredPairs();
    } catch (err: unknown) {
      this.logger.error("Failed to subscribe configured pairs", { error: String(err) });
    }
  }

  async stop(): Promise<void> {
    this._isRunning = false;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);

    for (const [, contract] of this.syncSubscriptions) {
      contract.removeAllListeners("Sync");
    }
    this.syncSubscriptions.clear();
    this.pairTokens.clear();
    this.reserves.clear();

    if (this.provider && (this.provider as WebSocketProvider).websocket) {
      await (this.provider as WebSocketProvider).websocket.close();
    }

    this.logger.info("PoolMonitor stopped");
  }
}

export const poolMonitor = new PoolMonitor();
