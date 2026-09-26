import { ethers, Wallet, JsonRpcProvider } from "ethers";
import { config } from "./config";
import { logger } from "./logger";
import { ProfitResult } from "./profitCalculator";

export interface ExecutionResult {
  success: boolean;
  txHash?: string;
  blockNumber?: number;
  gasUsed?: bigint;
  profit?: ProfitResult;
  error?: string;
  timestamp: number;
}

export interface FlashbotsBundle {
  txHashes: string[];
  targetBlock: number;
  timestamp: number;
}

export class ExecutionEngine {
  private provider: JsonRpcProvider | null = null;
  private wallet: Wallet | null = null;
  private isFlashbots: boolean = true;

  constructor() {
    this.initialize();
  }

  private async initialize(): Promise<void> {
    try {
      const chainConfig = config.chains[0];
      this.provider = new JsonRpcProvider(chainConfig.rpcUrl, undefined, {
        staticNetwork: true,
      });

      const privateKey = process.env.BOT_PRIVATE_KEY || "";
      if (privateKey) {
        this.wallet = new Wallet(privateKey, this.provider);
        this.provider.getTransactionCount(this.wallet.address);
      }

      this.isFlashbots = process.env.USE_FLASHBOTS !== "false";
      logger.info("ExecutionEngine initialized", {
        chainId: chainConfig.chainId,
        flashbots: this.isFlashbots,
        walletAddress: this.wallet?.address,
      });
    } catch (err: unknown) {
      logger.error("Failed to initialize ExecutionEngine", { error: String(err) });
      throw err;
    }
  }

  async buildTransaction(
    targetContract: string,
    calldata: string,
    value: bigint = BigInt(0),
    gasLimit: number = config.gasLimit
  ): Promise<ethers.TransactionRequest> {
    if (!this.provider || !this.wallet) {
      throw new Error("ExecutionEngine not fully initialized");
    }

    const feeData = await this.provider.getFeeData();
    const currentNonce = await this.provider.getTransactionCount(this.wallet.address, "pending");

    const tx: ethers.TransactionRequest = {
      to: targetContract,
      data: calldata,
      value,
      gasLimit: BigInt(gasLimit),
      type: 2,
      chainId: config.chains[0].chainId,
      nonce: currentNonce,
      maxFeePerGas: feeData.maxFeePerGas ?? BigInt(30) * BigInt(10) ** BigInt(9),
      maxPriorityFeePerGas: feeData.maxPriorityFeePerGas ?? BigInt(2) * BigInt(10) ** BigInt(9),
    };

    logger.debug("Transaction built", {
      to: targetContract,
      nonce: currentNonce,
      gasLimit,
      maxFeePerGas: tx.maxFeePerGas?.toString(),
    });

    return tx;
  }

  async simulateTransaction(tx: ethers.TransactionRequest): Promise<boolean> {
    try {
      const result = await this.provider!.call(tx);
      const success = result !== "0x" && result !== "0x0";
      logger.debug("Transaction simulation result", { success });
      return success;
    } catch (err: any) {
      logger.error("Transaction simulation reverted", { error: err.reason || err.message });
      return false;
    }
  }

  async submitToFlashbots(
    tx: ethers.TransactionRequest,
    targetBlock: number
  ): Promise<string> {
    if (!this.wallet || !this.provider) {
      throw new Error("Wallet not initialized");
    }

    const signedTx = await this.wallet.signTransaction(tx);
    const txHash = ethers.keccak256(signedTx);

    try {
      const flashbotsProvider = this.getFlashbotsProvider();
      await flashbotsProvider.sendRawTransaction(signedTx);

      logger.info("Transaction submitted to Flashbots", {
        txHash,
        targetBlock,
        nonce: tx.nonce,
      });

      return txHash;
    } catch (err: any) {
      logger.error("Flashbots submission failed, falling back to mempool", {
        error: err.message,
      });
      return await this.submitToMempool(tx);
    }
  }

  async submitToMempool(tx: ethers.TransactionRequest): Promise<string> {
    if (!this.wallet || !this.provider) {
      throw new Error("Wallet not initialized");
    }

    const signedTx = await this.wallet.signTransaction(tx);

    try {
      const response = await this.provider.broadcastTransaction(signedTx);
      logger.info("Transaction submitted to mempool", {
        txHash: response.hash,
        nonce: tx.nonce,
      });
      return response.hash;
    } catch (err: any) {
      logger.error("Mempool submission failed", { error: err.message });
      throw err;
    }
  }

  async execute(
    targetContract: string,
    calldata: string,
    loanSize: bigint,
    path: string[],
    reserves: Map<string, any>
  ): Promise<ExecutionResult> {
    const timestamp = Date.now();
    void loanSize;
    void path;
    void reserves;

    try {
      const tx = await this.buildTransaction(targetContract, calldata);
      const simulationResult = await this.simulateTransaction(tx);

      if (!simulationResult) {
        return {
          success: false,
          error: "Transaction simulation reverted",
          timestamp,
        };
      }

      const targetBlock = (await this.provider!.getBlock("latest"))!.number + 1;
      const txHash = await this.submitToFlashbots(tx, targetBlock);

      const receipt = await this.provider!.waitForTransaction(txHash, 1, 30000);

      if (receipt && receipt.status === 1) {
        const gasCost = receipt.gasUsed * BigInt(tx.maxFeePerGas as bigint || 0);
        const profitResult: ProfitResult = {
          grossProfitWei: BigInt(0),
          flashLoanFeeWei: BigInt(0),
          gasCostWei: gasCost,
          netProfitWei: BigInt(0),
          netProfitUsd: 0,
          profitMargin: 0,
          isProfitable: true,
          estimatedPriceImpact: 0,
          effectiveAmountOut: BigInt(0),
        };

        logger.info("Transaction executed successfully", {
          txHash,
          blockNumber: receipt.blockNumber,
          gasUsed: receipt.gasUsed.toString(),
        });

        return {
          success: true,
          txHash,
          blockNumber: receipt.blockNumber,
          gasUsed: receipt.gasUsed,
          profit: profitResult,
          timestamp,
        };
      }

      return {
        success: false,
        txHash,
        error: "Transaction reverted on-chain",
        timestamp,
      };
    } catch (err: any) {
      logger.error("Execution failed", { error: err.message });
      return {
        success: false,
        error: err.message,
        timestamp,
      };
    }
  }

  async cancelTransaction(txHash: string): Promise<boolean> {
    try {
      if (!this.provider || !this.wallet) return false;

      const nonce = await this.provider.getTransactionCount(this.wallet.address, "pending");
      const feeData = await this.provider.getFeeData();

      const cancelTx = {
        to: this.wallet.address,
        value: BigInt(0),
        gasLimit: BigInt(21000),
        nonce,
        type: 2,
        maxFeePerGas: feeData.maxFeePerGas,
        maxPriorityFeePerGas: feeData.maxPriorityFeePerGas,
        chainId: config.chains[0].chainId,
      };

      const signed = await this.wallet.signTransaction(cancelTx);
      await this.provider.broadcastTransaction(signed);

      logger.info("Transaction cancelled", { originalTxHash: txHash });
      return true;
    } catch (err: unknown) {
      logger.error("Failed to cancel transaction", { error: String(err) });
      return false;
    }
  }

  private getFlashbotsProvider(): any {
    const flashbotsUrl = process.env.FLASHBOTS_URL || "https://relay.flashbots.net";
    return {
      sendRawTransaction: async (signedTx: string) => {
        const response = await fetch(flashbotsUrl, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            jsonrpc: "2.0",
            id: 1,
            method: "eth_sendRawTransaction",
            params: [signedTx],
          }),
        });
        return response.json();
      },
    };
  }
}

export const executionEngine = new ExecutionEngine();