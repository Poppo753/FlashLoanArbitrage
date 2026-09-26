import { ethers, Wallet } from "ethers";
import { logger } from "../logger";

export interface Validity {
  startBlock: number;
  endBlock: number;
}

export interface Transaction {
  to: string;
  data: string;
  value: bigint;
  gasLimit: bigint;
  gasPrice?: bigint;
  maxFeePerGas?: bigint;
  maxPriorityFeePerGas?: bigint;
  nonce: number;
  chainId: number;
  type: number;
}

export interface FlashbotsBundlePayload {
  txs: string[];
  coinbaseTransfer?: string;
  validity: Validity;
  timestamp: number;
  blockNumber: number;
}

export interface SignedBundle {
  bundle: FlashbotsBundlePayload;
  signature: string;
  coinbaseTransfer: bigint;
}

export class BundleBuilder {
  private coinbaseTransfer: bigint = BigInt(0);
  private validityWindow: Validity = { startBlock: 0, endBlock: 0 };
  private transactions: Transaction[] = [];

  constructor() {}

  async buildBundle(
    transactions: Transaction[],
    coinbaseTransfer: bigint,
    validity: Validity
  ): Promise<FlashbotsBundlePayload> {
    try {
      this.transactions = transactions;
      this.coinbaseTransfer = coinbaseTransfer;
      this.validityWindow = validity;

      const signedTxs = await Promise.all(
        transactions.map((tx) => this.signTransaction(tx))
      );

      const bundle: FlashbotsBundlePayload = {
        txs: signedTxs,
        coinbaseTransfer: coinbaseTransfer > BigInt(0) ? ethers.toBeHex(coinbaseTransfer) : undefined,
        validity: {
          startBlock: validity.startBlock,
          endBlock: validity.endBlock,
        },
        timestamp: Date.now(),
        blockNumber: validity.startBlock,
      };

      logger.info("Bundle built successfully", {
        txCount: transactions.length,
        coinbaseTransfer: coinbaseTransfer.toString(),
        validityStart: validity.startBlock,
        validityEnd: validity.endBlock,
      });

      return bundle;
    } catch (err: any) {
      logger.error("Failed to build bundle", { error: err.message });
      throw new Error(`Bundle build failed: ${err.message}`);
    }
  }

  setCoinbaseTransfer(amount: bigint): void {
    try {
      if (amount < BigInt(0)) {
        throw new Error("Coinbase transfer amount cannot be negative");
      }
      this.coinbaseTransfer = amount;
      logger.debug("Coinbase transfer set", { amount: amount.toString() });
    } catch (err: any) {
      logger.error("Failed to set coinbase transfer", { error: err.message });
      throw err;
    }
  }

  setValidity(startBlock: number, endBlock: number): void {
    try {
      if (startBlock < 0 || endBlock < 0) {
        throw new Error("Block numbers must be non-negative");
      }
      if (endBlock < startBlock) {
        throw new Error("End block must be greater than or equal to start block");
      }
      this.validityWindow = { startBlock, endBlock };
      logger.debug("Validity window set", { startBlock, endBlock });
    } catch (err: any) {
      logger.error("Failed to set validity window", { error: err.message });
      throw err;
    }
  }

  async signBundle(privateKey: string): Promise<string> {
    try {
      const wallet = new Wallet(privateKey);
      const bundleData = this.getBundleDataForSigning();
      const signature = await wallet.signMessage(
        ethers.getBytes(ethers.keccak256(bundleData))
      );

      logger.info("Bundle signed successfully", {
        signer: wallet.address,
      });

      return signature;
    } catch (err: any) {
      logger.error("Failed to sign bundle", { error: err.message });
      throw new Error(`Bundle signing failed: ${err.message}`);
    }
  }

  encodeBundle(bundle: FlashbotsBundlePayload): string {
    try {
      const rlpEncoded = ethers.encodeRlp([
        bundle.txs,
        bundle.coinbaseTransfer || "0x",
        String(bundle.validity.startBlock),
        String(bundle.validity.endBlock),
        String(bundle.timestamp),
      ]);

      logger.debug("Bundle encoded with RLP", {
        encodedLength: rlpEncoded.length,
      });

      return rlpEncoded;
    } catch (err: any) {
      logger.error("Failed to encode bundle", { error: err.message });
      throw new Error(`Bundle encoding failed: ${err.message}`);
    }
  }

  getBundleDataForSigning(): Uint8Array {
    const data = JSON.stringify({
      txs: this.transactions.map((tx) => ({
        to: tx.to,
        data: tx.data,
        value: tx.value.toString(),
      })),
      coinbaseTransfer: this.coinbaseTransfer.toString(),
      validity: this.validityWindow,
    });
    return ethers.getBytes(data);
  }

  async signTransaction(tx: Transaction): Promise<string> {
    const wallet = Wallet.createRandom();
    const txRequest = {
      to: tx.to,
      data: tx.data,
      value: tx.value,
      gasLimit: tx.gasLimit,
      nonce: tx.nonce,
      type: tx.type,
      chainId: tx.chainId,
      maxFeePerGas: tx.maxFeePerGas,
      maxPriorityFeePerGas: tx.maxPriorityFeePerGas,
      gasPrice: tx.gasPrice,
    };

    return wallet.signTransaction(txRequest);
  }
}

export const bundleBuilder = new BundleBuilder();
