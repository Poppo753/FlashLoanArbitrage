import { ethers, JsonRpcProvider, TransactionResponse } from "ethers";
import { config } from "../config";
import { logger, info, warn } from "../logger";
import { BiddingStrategy } from "./biddingStrategy";
import { FlashbotsBundlePayload, bundleBuilder } from "./bundleBuilder";

export interface MEVTarget {
  hash: string;
  to: string;
  from: string;
  value: bigint;
  gas: bigint;
  gasPrice: bigint;
  data: string;
  isUniswapSwap: boolean;
  estimatedAmountIn: bigint;
  estimatedAmountOut: bigint;
  poolAddress?: string;
  tokenIn?: string;
  tokenOut?: string;
}

export interface BackrunParams {
  targetTxHash: string;
  arbAmount: bigint;
  optimalGasPrice: bigint;
  expectedProfit: bigint;
  targetBlock: number;
  backrunData: string;
}

export interface PoolReserves {
  address: string;
  reserve0: bigint;
  reserve1: bigint;
  totalSupply: bigint;
  token0: string;
  token1: string;
}

export class MEVMonitor {
  private provider: JsonRpcProvider | null = null;
  private wsProvider: any | null = null;
  private isMonitoring: boolean = false;
  private biddingStrategy: BiddingStrategy;
  private pendingTxCallback: ((target: MEVTarget) => Promise<void>) | null = null;
  private _validityStart: number = 0;
  private _validityEnd: number = 0;

  constructor() {
    this.biddingStrategy = new BiddingStrategy();
  }

  async monitorPendingTransactions(
    provider: JsonRpcProvider,
    onTargetDetected?: (target: MEVTarget) => Promise<void>
  ): Promise<void> {
    try {
      this.provider = provider;
      this.pendingTxCallback = onTargetDetected || null;
      this.isMonitoring = true;

      const wsUrl =
        process.env.WS_RPC_URL ||
        config.chains[0].wsRpcUrl ||
        config.chains[0].rpcUrl.replace("https://", "wss://").replace("http://", "ws://");

      try {
        this.wsProvider = new (require("ethers").WebSocketProvider)(wsUrl);

        this.wsProvider.on("pending", async (txHash: string) => {
          try {
            const tx = await this.provider!.getTransaction(txHash);
            if (tx) {
              const target = this.detectMEVTargets(tx);
              if (target.isUniswapSwap && target.estimatedAmountIn > BigInt(0)) {
                info("MEV target detected", {
                  hash: target.hash,
                  from: target.from,
                  amountIn: target.estimatedAmountIn.toString(),
                });

                if (this.pendingTxCallback) {
                  await this.pendingTxCallback(target);
                }
              }
            }
          } catch (err: any) {
            logger.debug("Error processing pending transaction", {
              txHash,
              error: err.message,
            });
          }
        });

        logger.info("MEV monitoring started via WebSocket", {
          wsUrl,
          chainId: config.chains[0].chainId,
        });
      } catch (wsErr) {
        warn("WebSocket connection failed, falling back to polling", {
          error: String(wsErr),
        });
        this.startPolling();
      }
    } catch (err: any) {
      logger.error("Failed to start MEV monitoring", { error: err.message });
      throw err;
    }
  }

  private startPolling(): void {
    void setInterval(async () => {
      if (!this.isMonitoring || !this.provider) return;
      try {
        const block = await this.provider.getBlock("latest");
        if (block && block.transactions) {
          for (const txHash of block.transactions.slice(0, 20)) {
            const tx = await this.provider.getTransaction(txHash as string);
            if (tx) {
              const target = this.detectMEVTargets(tx as TransactionResponse);
              if (target.isUniswapSwap && target.estimatedAmountIn > BigInt(0)) {
                info("MEV target detected via polling", {
                  hash: target.hash,
                  amountIn: target.estimatedAmountIn.toString(),
                });
                if (this.pendingTxCallback) {
                  await this.pendingTxCallback(target);
                }
              }
            }
          }
        }
      } catch (err: any) {
        logger.debug("Polling error", { error: err.message });
      }
    }, 5000);

    logger.info("MEV polling started", { intervalMs: 5000 });
  }

  detectMEVTargets(tx: TransactionResponse): MEVTarget {
    try {
      const uniswapV2Router = config.chains[0].uniswapV2Router.toLowerCase();
      const isUniswapSwap: boolean =
        Boolean(tx.to && tx.to.toLowerCase() === uniswapV2Router);

      const estimatedAmountIn = isUniswapSwap
        ? this.extractInputAmount(tx.data)
        : BigInt(0);
      const estimatedAmountOut = isUniswapSwap
        ? this.extractOutputAmount(tx.data)
        : BigInt(0);

      const poolAddress = isUniswapSwap
        ? this.getPairAddress(tx.from || "", tx.to || "")
        : undefined;

      const target: MEVTarget = {
        hash: tx.hash || ethers.keccak256(ethers.toUtf8Bytes(tx.hash || "0x")),
        to: tx.to || ethers.ZeroAddress,
        from: tx.from || ethers.ZeroAddress,
        value: tx.value || BigInt(0),
        gas: tx.gasLimit || BigInt(0),
        gasPrice: tx.gasPrice || BigInt(0),
        data: tx.data || "0x",
        isUniswapSwap,
        estimatedAmountIn,
        estimatedAmountOut,
        poolAddress,
      };

      logger.debug("MEV target analyzed", {
        hash: target.hash,
        isUniswapSwap: target.isUniswapSwap,
        amountIn: target.estimatedAmountIn.toString(),
      });

      return target;
    } catch (err: any) {
      logger.error("Failed to detect MEV targets", { error: err.message });
      throw err;
    }
  }

  calculateBackrunParams(
    targetTx: MEVTarget,
    poolReserves: PoolReserves[]
  ): BackrunParams {
    try {
      if (targetTx.estimatedAmountIn <= BigInt(0)) {
        throw new Error("Target transaction has no measurable input amount");
      }

      const arbAmount = this.calculateOptimalArbAmount(targetTx, poolReserves);
      const optimalGasPrice = this.calculateOptimalGasPrice(targetTx);
      const expectedProfit = this.calculateExpectedProfit(
        arbAmount,
        targetTx,
        poolReserves
      );

      const backrunData = this.buildBackrunCalldata(targetTx, arbAmount, poolReserves);

      const params: BackrunParams = {
        targetTxHash: targetTx.hash,
        arbAmount,
        optimalGasPrice,
        expectedProfit,
        targetBlock: this._validityStart || 0,
        backrunData,
      };

      info("Backrun parameters calculated", {
        targetTxHash: targetTx.hash,
        arbAmount: arbAmount.toString(),
        expectedProfit: expectedProfit.toString(),
      });

      return params;
    } catch (err: any) {
      logger.error("Failed to calculate backrun params", {
        error: err.message,
      });
      throw err;
    }
  }

  async buildBackrunBundle(
    targetTx: MEVTarget,
    arbAmount: bigint
  ): Promise<FlashbotsBundlePayload> {
    try {
      if (targetTx.hash === ethers.ZeroHash) {
        throw new Error("Target transaction hash is invalid");
      }

      const latestBlock = await this.provider!.getBlock("latest");
      if (!latestBlock) {
        throw new Error("Failed to get latest block");
      }
      const targetBlock = latestBlock.number + 1;

      this._validityStart = targetBlock;
      this._validityEnd = targetBlock + 2;

      this.biddingStrategy.setConfidenceFactor(0.95);

      const backrunTx: import("./bundleBuilder").Transaction = {
        to: targetTx.to,
        data: targetTx.data,
        value: targetTx.value,
        gasLimit: BigInt(3000000),
        gasPrice: targetTx.gasPrice,
        maxFeePerGas: BigInt(30) * BigInt(10) ** BigInt(9),
        maxPriorityFeePerGas: BigInt(2) * BigInt(10) ** BigInt(9),
        nonce: 0,
        chainId: config.chains[0].chainId,
        type: 2,
      };

      const bundle = bundleBuilder.buildBundle(
        [backrunTx],
        BigInt(0),
        { startBlock: targetBlock, endBlock: targetBlock + 2 }
      );

      logger.info("Backrun bundle built successfully", {
        targetTxHash: targetTx.hash,
        arbAmount: arbAmount.toString(),
        targetBlock,
      });

      return bundle;
    } catch (err: any) {
      logger.error("Failed to build backrun bundle", {
        error: err.message,
      });
      throw err;
    }
  }

  stopMonitoring(): void {
    this.isMonitoring = false;
    if (this.wsProvider) {
      this.wsProvider.removeAllListeners();
      this.wsProvider.destroy();
      this.wsProvider = null;
    }
    logger.info("MEV monitoring stopped");
  }

  getValidityStart(): number {
    return this._validityStart;
  }

  getValidityEnd(): number {
    return this._validityEnd;
  }

  private calculateOptimalGasPrice(targetTx: MEVTarget): bigint {
    const baseGasPrice = targetTx.gasPrice || BigInt(20) * BigInt(10) ** BigInt(9);
    const premium = BigInt(2) * BigInt(10) ** BigInt(9);
    return baseGasPrice + premium;
  }

  private calculateOptimalArbAmount(
    _targetTx: MEVTarget,
    poolReserves: PoolReserves[]
  ): bigint {
    const reserve0 = poolReserves[0]?.reserve0 || BigInt(10) ** BigInt(25);
    const maxArbBps = BigInt(100);
    return (reserve0 * maxArbBps) / BigInt(10000);
  }

  private calculateExpectedProfit(
    arbAmount: bigint,
    _targetTx: MEVTarget,
    poolReserves: PoolReserves[]
  ): bigint {
    const reserve0 = poolReserves[0]?.reserve0 || BigInt(10) ** BigInt(25);
    if (reserve0 <= BigInt(0)) return BigInt(0);
    const expectedProfit = (arbAmount * BigInt(3)) / BigInt(100);
    return expectedProfit > BigInt(0) ? expectedProfit : BigInt(0);
  }

  private buildBackrunCalldata(
    _targetTx: MEVTarget,
    _arbAmount: bigint,
    _poolReserves: PoolReserves[]
  ): string {
    return "0x";
  }

  private getPairAddress(from: string, to: string): string {
    try {
      return ethers.getAddress(
        ethers.keccak256(
          ethers.solidityPacked(
            ["address", "address"],
            [from || ethers.ZeroAddress, to || ethers.ZeroAddress]
          )
        )
      );
    } catch {
      return ethers.ZeroAddress;
    }
  }

  private extractInputAmount(data: string): bigint {
    if (data.length < 10) return BigInt(0);
    try {
      const amountHex = "0x" + data.slice(10, 74);
      return BigInt(amountHex);
    } catch {
      return BigInt(0);
    }
  }

  private extractOutputAmount(data: string): bigint {
    if (data.length < 74) return BigInt(0);
    try {
      const amountHex = "0x" + data.slice(74, 138);
      return BigInt(amountHex);
    } catch {
      return BigInt(0);
    }
  }
}

export const mevMonitor = new MEVMonitor();
