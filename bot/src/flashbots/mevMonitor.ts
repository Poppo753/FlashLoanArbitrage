import { ethers, JsonRpcProvider, TransactionResponse } from "ethers";
import { config } from "../config";
import { logger, info, warn } from "../logger";
import { BiddingStrategy } from "./biddingStrategy";
import { FlashbotsBundlePayload, bundleBuilder } from "./bundleBuilder";

const UNISWAP_V2_ROUTER_IFACE = new ethers.Interface([
  "function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline)",
  "function swapTokensForExactTokens(uint256 amountOut, uint256 amountInMax, address[] path, address to, uint256 deadline)",
  "function swapExactETHForTokens(uint256 amountOutMin, address[] path, address to, uint256 deadline) payable",
  "function swapETHForExactTokens(uint256 amountOut, address[] path, address to, uint256 deadline) payable",
  "function swapExactTokensForETH(uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline)",
  "function swapTokensForExactETH(uint256 amountOut, uint256 amountInMax, address[] path, address to, uint256 deadline)",
  "function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline)",
  "function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256 amountOutMin, address[] path, address to, uint256 deadline) payable",
  "function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline)",
]);

const UNISWAP_V2_INIT_CODE_HASH =
  "0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f";

interface DecodedRouterCall {
  name: string;
  args: ethers.Result;
}

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

      const decoded = isUniswapSwap ? this.decodeRouterCall(tx.data || "0x") : null;

      const estimatedAmountIn = decoded
        ? this.extractInputAmount(decoded, tx.value || BigInt(0))
        : BigInt(0);
      const estimatedAmountOut = decoded
        ? this.extractOutputAmount(decoded)
        : BigInt(0);

      const path = decoded ? this.extractPath(decoded) : undefined;
      const tokenIn = path && path.length > 0 ? path[0] : undefined;
      const tokenOut = path && path.length > 0 ? path[path.length - 1] : undefined;
      const poolAddress =
        tokenIn && tokenOut ? this.getPairAddress(tokenIn, tokenOut) : undefined;

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
        tokenIn,
        tokenOut,
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

      if (this.provider) {
        bundleBuilder.setProvider(this.provider);
      }

      const validity = { startBlock: targetBlock, endBlock: targetBlock + 2 };
      const backrunData = this.buildBackrunCalldata(targetTx, arbAmount, []);
      const backrunTarget = process.env.BACKRUN_CONTRACT_ADDRESS || "";

      const missing: string[] = [];
      if (!backrunData || backrunData === "0x" || backrunData.length < 10) {
        missing.push("backrun calldata (buildBackrunCalldata is not implemented)");
      }
      if (!ethers.isAddress(backrunTarget)) {
        missing.push("backrun target contract address (BACKRUN_CONTRACT_ADDRESS not set)");
      }

      if (missing.length > 0) {
        const rejected = `Backrun bundle rejected before submission: ${missing.join("; ")}`;
        logger.warn("Backrun bundle rejected", {
          targetTxHash: targetTx.hash,
          rejected,
        });
        return {
          txs: [],
          validity,
          timestamp: Date.now(),
          blockNumber: targetBlock,
          rejected,
        };
      }

      const backrunTx: import("./bundleBuilder").Transaction = {
        to: ethers.getAddress(backrunTarget),
        data: backrunData,
        value: BigInt(0),
        gasLimit: BigInt(config.gasLimit),
        maxFeePerGas: BigInt(30) * BigInt(10) ** BigInt(9),
        maxPriorityFeePerGas: BigInt(2) * BigInt(10) ** BigInt(9),
        chainId: config.chains[0].chainId,
        type: 2,
      };

      const bundle = await bundleBuilder.buildBundle([backrunTx], BigInt(0), validity);

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

  private decodeRouterCall(data: string): DecodedRouterCall | null {
    if (!data || data.length < 10) return null;
    try {
      const parsed = UNISWAP_V2_ROUTER_IFACE.parseTransaction({ data });
      if (!parsed) return null;
      return { name: parsed.name, args: parsed.args };
    } catch {
      return null;
    }
  }

  private extractPath(call: DecodedRouterCall): string[] | undefined {
    try {
      const path = call.args.path;
      if (Array.isArray(path) && path.length > 0) {
        return path.map((token: unknown) => String(token));
      }
      return undefined;
    } catch {
      return undefined;
    }
  }

  private getPairAddress(tokenA: string, tokenB: string): string | undefined {
    try {
      const factory = config.chains[0].uniswapV2Factory;
      if (!factory || factory === ethers.ZeroAddress) {
        logger.warn(
          "Uniswap V2 factory address not configured; cannot derive pair address"
        );
        return undefined;
      }
      const tokenAHex = tokenA.toLowerCase();
      const tokenBHex = tokenB.toLowerCase();
      if (tokenAHex === tokenBHex) {
        return undefined;
      }
      const [token0, token1] =
        BigInt(tokenAHex) <= BigInt(tokenBHex)
          ? [tokenAHex, tokenBHex]
          : [tokenBHex, tokenAHex];
      const salt = ethers.keccak256(
        ethers.solidityPacked(["address", "address"], [token0, token1])
      );
      const pairAddress = ethers.keccak256(
        ethers.concat([
          "0xff",
          ethers.getAddress(factory),
          salt,
          UNISWAP_V2_INIT_CODE_HASH,
        ])
      );
      return ethers.getAddress(ethers.dataSlice(pairAddress, 12, 32));
    } catch {
      return undefined;
    }
  }

  private extractInputAmount(call: DecodedRouterCall, value: bigint): bigint {
    try {
      switch (call.name) {
        case "swapExactTokensForTokens":
        case "swapExactTokensForETH":
        case "swapExactTokensForTokensSupportingFeeOnTransferTokens":
        case "swapExactTokensForETHSupportingFeeOnTransferTokens":
          return BigInt(call.args.amountIn ?? 0);
        case "swapTokensForExactTokens":
        case "swapTokensForExactETH":
          return BigInt(call.args.amountInMax ?? 0);
        case "swapExactETHForTokens":
        case "swapETHForExactTokens":
        case "swapExactETHForTokensSupportingFeeOnTransferTokens":
          return BigInt(value);
        default:
          return BigInt(0);
      }
    } catch {
      return BigInt(0);
    }
  }

  private extractOutputAmount(call: DecodedRouterCall): bigint {
    try {
      switch (call.name) {
        case "swapExactTokensForTokens":
        case "swapExactTokensForETH":
        case "swapExactETHForTokens":
        case "swapExactTokensForTokensSupportingFeeOnTransferTokens":
        case "swapExactTokensForETHSupportingFeeOnTransferTokens":
        case "swapExactETHForTokensSupportingFeeOnTransferTokens":
          return BigInt(call.args.amountOutMin ?? 0);
        case "swapTokensForExactTokens":
        case "swapTokensForExactETH":
        case "swapETHForExactTokens":
          return BigInt(call.args.amountOut ?? 0);
        default:
          return BigInt(0);
      }
    } catch {
      return BigInt(0);
    }
  }
}

export const mevMonitor = new MEVMonitor();
