import { ethers, Wallet, JsonRpcProvider } from "ethers";
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
  nonce?: number;
  chainId: number;
  type: number;
}

export interface FlashbotsBundlePayload {
  txs: string[];
  coinbaseTransfer?: string;
  validity: Validity;
  timestamp: number;
  blockNumber: number;
  rejected?: string;
}

export interface SignedBundle {
  bundle: FlashbotsBundlePayload;
  signature: string;
  coinbaseTransfer: bigint;
}

export function toMinimalHex(value: bigint): string {
  if (value < BigInt(0)) {
    throw new Error("Cannot RLP-encode a negative integer");
  }
  if (value === BigInt(0)) {
    return "0x";
  }
  let hex = value.toString(16);
  if (hex.length % 2 !== 0) {
    hex = "0" + hex;
  }
  return "0x" + hex;
}

export class BundleBuilder {
  private coinbaseTransfer: bigint = BigInt(0);
  private validityWindow: Validity = { startBlock: 0, endBlock: 0 };
  private transactions: Transaction[] = [];
  private provider: JsonRpcProvider | null = null;

  constructor() {}

  setProvider(provider: JsonRpcProvider): void {
    this.provider = provider;
  }

  private getSignerWallet(): Wallet {
    const privateKey = process.env.BOT_PRIVATE_KEY;
    if (!privateKey || !/^0x[0-9a-fA-F]{64}$/.test(privateKey)) {
      throw new Error(
        "BOT_PRIVATE_KEY is missing or malformed; refusing to sign bundle transactions with an unconfigured key"
      );
    }
    return new Wallet(privateKey);
  }

  private async resolveNonce(
    address: string,
    providedNonce: number | undefined,
    offset: number
  ): Promise<number> {
    if (this.provider) {
      return (await this.provider.getTransactionCount(address, "pending")) + offset;
    }
    if (
      typeof providedNonce === "number" &&
      Number.isInteger(providedNonce) &&
      providedNonce >= 0
    ) {
      logger.warn("BundleBuilder has no provider; using caller-supplied nonce", {
        nonce: providedNonce,
      });
      return providedNonce;
    }
    throw new Error(
      "Cannot resolve transaction nonce: no provider configured and tx.nonce is not a valid non-negative integer"
    );
  }

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
        transactions.map((tx, index) => this.signTransaction(tx, index))
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
      const coinbaseTransfer =
        !bundle.coinbaseTransfer || bundle.coinbaseTransfer === "0x"
          ? BigInt(0)
          : BigInt(bundle.coinbaseTransfer);
      const rlpEncoded = ethers.encodeRlp([
        bundle.txs,
        toMinimalHex(coinbaseTransfer),
        toMinimalHex(BigInt(bundle.validity.startBlock)),
        toMinimalHex(BigInt(bundle.validity.endBlock)),
        toMinimalHex(BigInt(bundle.timestamp)),
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

  async signTransaction(tx: Transaction, nonceOffset: number = 0): Promise<string> {
    const wallet = this.getSignerWallet();
    const nonce = await this.resolveNonce(wallet.address, tx.nonce, nonceOffset);
    const txRequest = {
      to: tx.to,
      data: tx.data,
      value: tx.value,
      gasLimit: tx.gasLimit,
      nonce,
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
