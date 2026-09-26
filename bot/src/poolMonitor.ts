import { ethers, Contract, WebSocketProvider, JsonRpcApiProvider } from "ethers";
import { Logger } from "winston";
import { config } from "./config";
import { logger } from "./logger";

export interface ReserveData {
  tokenIn: string;
  tokenOut: string;
  reserveIn: bigint;
  reserveOut: bigint;
  blockNumber: number;
  timestamp: number;
}

export interface PoolSnapshot {
  pairAddress: string;
  reserves: { token0: string; token1: string; reserve0: bigint; reserve1: bigint };
  totalSupply: bigint;
  blockNumber: number;
}

const UNISWAP_V2_SYNC_ABI = [
  "event Sync(uint112 reserve0, uint112 reserve1)",
  "function getReserves() view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)",
];

export class PoolMonitor {
  private provider: WebSocketProvider | JsonRpcApiProvider | null = null;
  private reserves: Map<string, ReserveData> = new Map();
  private syncSubscriptions: Map<string, Contract> = new Map();
  private readonly logger: Logger;
  private _isRunning: boolean = false;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;

  constructor() {
    this.logger = logger;
  }

  async initialize(chainRpcUrl: string, chainId: number): Promise<void> {
    try {
      this.provider = new WebSocketProvider(chainRpcUrl, chainId, {
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

      this.logger.info("PoolMonitor initialized", { chainId, provider: chainRpcUrl });
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
          config.chains[0].rpcUrl,
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

    for (const pairAddress of pairAddresses) {
      const contract = new Contract(pairAddress, UNISWAP_V2_SYNC_ABI, this.provider);
      this.syncSubscriptions.set(pairAddress.toLowerCase(), contract);

      contract.on("Sync", (reserve0: bigint, reserve1: bigint, log: ethers.Log) => {
        this.handleSyncEvent(pairAddress, reserve0, reserve1, log);
      });

      const reserves = await contract.getReserves();
      this.reserves.set(pairAddress.toLowerCase(), {
        tokenIn: pairAddress,
        tokenOut: pairAddress,
        reserveIn: reserves.reserve0,
        reserveOut: reserves.reserve1,
        blockNumber: Number(reserves.blockTimestampLast),
        timestamp: Math.floor(Date.now() / 1000),
      });
    }

    this.logger.info(`Subscribed to ${pairAddresses.length} Uniswap V2 pairs`);
  }

  private handleSyncEvent(
    pairAddress: string,
    reserve0: bigint,
    reserve1: bigint,
    log: ethers.Log
  ): void {
    const key = pairAddress.toLowerCase();
    const now = Math.floor(Date.now() / 1000);

    this.reserves.set(key, {
      tokenIn: pairAddress,
      tokenOut: pairAddress,
      reserveIn: reserve0,
      reserveOut: reserve1,
      blockNumber: log.blockNumber,
      timestamp: now,
    });

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

  getReserve(pairAddress: string): ReserveData | undefined {
    return this.reserves.get(pairAddress.toLowerCase());
  }

  getReserveAtBlock(pairAddress: string, blockNumber: number): ReserveData | undefined {
    const reserve = this.reserves.get(pairAddress.toLowerCase());
    if (reserve && reserve.blockNumber === blockNumber) {
      return reserve;
    }
    return undefined;
  }

  get isRunning(): boolean {
    return this._isRunning;
  }

  async start(): Promise<void> {
    this._isRunning = true;
    this.logger.info("PoolMonitor started");
  }

  async stop(): Promise<void> {
    this._isRunning = false;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);

    for (const [, contract] of this.syncSubscriptions) {
      contract.removeAllListeners("Sync");
    }
    this.syncSubscriptions.clear();
    this.reserves.clear();

    if (this.provider && (this.provider as WebSocketProvider).websocket) {
      await (this.provider as WebSocketProvider).websocket.close();
    }

    this.logger.info("PoolMonitor stopped");
  }
}

export const poolMonitor = new PoolMonitor();