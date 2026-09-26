import { ethers, JsonRpcProvider } from "ethers";
import { config } from "../config";
import { logger } from "../logger";
import { FlashbotsBundlePayload } from "./bundleBuilder";

export interface BundleSubmissionResult {
  success: boolean;
  bundleHash?: string;
  error?: string;
  relayResponse?: any;
}

export interface BundleStatus {
  bundleHash: string;
  included: boolean;
  blockNumber?: number;
  txHash?: string;
  status: "pending" | "included" | "failed" | "unknown";
}

const FLASHBOTS_RELAY_URL =
  process.env.FLASHBOTS_RELAY_URL || "https://relay.flashbots.net";
const FLASHBOTS_PROTECT_URL =
  process.env.FLASHBOTS_PROTECT_URL || "https://flashbots.net/flashbots-protected";

export class FlashbotsService {
  private provider: JsonRpcProvider | null = null;
  private relayUrl: string;

  constructor() {
    this.relayUrl = FLASHBOTS_RELAY_URL;
    this.initializeProvider();
  }

  private async initializeProvider(): Promise<void> {
    try {
      const chainConfig = config.chains[0];
      this.provider = new JsonRpcProvider(chainConfig.rpcUrl);
      logger.info("FlashbotsService provider initialized", {
        chainId: chainConfig.chainId,
        relayUrl: this.relayUrl,
      });
    } catch (err: any) {
      logger.error("Failed to initialize FlashbotsService provider", {
        error: err.message,
      });
      throw err;
    }
  }

  async submitBundle(
    bundle: FlashbotsBundlePayload,
    signature: string
  ): Promise<BundleSubmissionResult> {
    try {
      if (bundle.rejected) {
        logger.warn("Refusing to submit rejected bundle", {
          reason: bundle.rejected,
        });
        return {
          success: false,
          error: bundle.rejected,
        };
      }

      const payload = {
        jsonrpc: "2.0",
        id: Date.now(),
        method: "eth_sendBundle",
        params: [
          {
            txs: bundle.txs,
            coinbaseTransfer: bundle.coinbaseTransfer || "0x",
            blockNumber: `0x${bundle.validity.startBlock.toString(16)}`,
            maxBlockNumber: `0x${bundle.validity.endBlock.toString(16)}`,
            timestamp: bundle.timestamp,
            simulationSignatures: {
              "0x000000000000000000000000000000000000000000000000000000000000":
                signature,
            },
          },
        ],
      };

      const response = await fetch(this.relayUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });

      if (!response.ok) {
        throw new Error(`Relay responded with status ${response.status}`);
      }

      const data: any = await response.json();

      if (data.error) {
        logger.error("Relay returned error", { error: data.error });
        return {
          success: false,
          error: data.error.message || "Relay error",
          relayResponse: data,
        };
      }

      const bundleHash = data.result || ethers.keccak256(JSON.stringify(bundle));

      logger.info("Bundle submitted to Flashbots relay successfully", {
        bundleHash,
        txCount: bundle.txs.length,
      });

      return {
        success: true,
        bundleHash,
        relayResponse: data,
      };
    } catch (err: any) {
      logger.error("Failed to submit bundle to Flashbots relay", {
        error: err.message,
      });
      return {
        success: false,
        error: err.message,
      };
    }
  }

  async submitBundleFlashbotsProtect(
    provider: JsonRpcProvider,
    tx: ethers.TransactionRequest
  ): Promise<string> {
    try {
      const signer = await provider.getSigner();
      if (!signer) {
        throw new Error("No signer available for Flashbots Protect");
      }

      const signedTx = await signer.signTransaction(tx);
      const txHash = ethers.keccak256(signedTx);

      const response = await fetch(FLASHBOTS_PROTECT_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: Date.now(),
          method: "eth_sendRawTransaction",
          params: [signedTx],
        }),
      });

      if (!response.ok) {
        throw new Error(`Flashbots Protect responded with status ${response.status}`);
      }

      const data: any = await response.json();

      if (data.error) {
        logger.error("Flashbots Protect returned error", { error: data.error });
        throw new Error(data.error.message || "Flashbots Protect error");
      }

      logger.info("Transaction submitted via Flashbots Protect", {
        txHash,
      });

      return data.result || txHash;
    } catch (err: any) {
      logger.error("Failed to submit via Flashbots Protect", {
        error: err.message,
      });
      throw err;
    }
  }

  async getBundleStatus(bundleHash: string): Promise<BundleStatus> {
    try {
      if (!this.provider) {
        throw new Error("Provider not initialized");
      }

      const payload = {
        jsonrpc: "2.0",
        id: Date.now(),
        method: "eth_getBundleStatus",
        params: [{ bundleHash }],
      };

      const response = await fetch(this.relayUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });

      if (!response.ok) {
        throw new Error(`Status query failed with status ${response.status}`);
      }

      const data: any = await response.json();

      if (data.error) {
        logger.warn("Bundle status query returned error", {
          bundleHash,
          error: data.error,
        });
        return {
          bundleHash,
          included: false,
          status: "unknown",
        };
      }

      const status = data.result || {};
      const result: BundleStatus = {
        bundleHash,
        included: status.included || false,
        blockNumber: status.blockNumber,
        txHash: status.txHash,
        status: status.included
          ? "included"
          : status.pending
          ? "pending"
          : "failed",
      };

      logger.debug("Bundle status retrieved", {
        bundleHash,
        status: result.status,
      });

      return result;
    } catch (err: any) {
      logger.error("Failed to get bundle status", {
        bundleHash,
        error: err.message,
      });
      return {
        bundleHash,
        included: false,
        status: "unknown",
      };
    }
  }

  async handleFallbackToMempool(
    provider: JsonRpcProvider,
    signedTx: string
  ): Promise<string> {
    try {
      logger.warn("Falling back to public mempool for transaction", {
        signedTx: signedTx.slice(0, 10) + "...",
      });

      const response = await provider.broadcastTransaction(signedTx);

      logger.info("Transaction submitted to public mempool successfully", {
        txHash: response.hash,
      });

      return response.hash;
    } catch (err: any) {
      logger.error("Failed to fallback to mempool", {
        error: err.message,
      });
      throw err;
    }
  }

  async isBundleIncluded(bundleHash: string): Promise<boolean> {
    try {
      const status = await this.getBundleStatus(bundleHash);
      const isIncluded = status.included;

      logger.debug("Bundle inclusion check", {
        bundleHash,
        included: isIncluded,
      });

      return isIncluded;
    } catch (err: any) {
      logger.error("Failed to check bundle inclusion", {
        bundleHash,
        error: err.message,
      });
      return false;
    }
  }
}

export const flashbotsService = new FlashbotsService();
