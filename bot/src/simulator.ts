import { ethers, JsonRpcProvider, Contract, formatEther } from "ethers";
import { config } from "./config";
import { logger } from "./logger";
import { ProfitResult } from "./profitCalculator";

export interface SimulationResult {
  success: boolean;
  returnValue: string;
  gasEstimate: bigint;
  baseFee: bigint;
  maxFee: bigint;
  netProfitEstimate: ProfitResult | null;
  error?: string;
}

export class Simulator {
  private provider: JsonRpcProvider | null = null;
  private readonly flashLoanABI: any[] = [
    "function executeOperation(address[] calldata assets, uint256[] calldata amounts, uint256[] calldata premiums, address initiator, bytes calldata params) external returns (bool)",
  ];

  constructor() {
    this.initializeProvider();
  }

  private initializeProvider(): void {
    try {
      const chainConfig = config.chains[0];
      this.provider = new JsonRpcProvider(chainConfig.rpcUrl, undefined, {
        batchMaxCount: 100,
      });
      logger.info("Simulator provider initialized", { chainId: chainConfig.chainId });
    } catch (err: unknown) {
      logger.error("Failed to initialize Simulator provider", { error: String(err) });
      throw err;
    }
  }

  async simulateFlashLoan(
    flashLoanContract: string,
    assets: string[],
    amounts: bigint[],
    _flashLoanABI: string[] = this.flashLoanABI
  ): Promise<SimulationResult> {
    try {
      const feeData = await this.getFeeData();
      const gasEstimate = await this.estimateGas(
        flashLoanContract,
        assets,
        amounts,
        feeData
      );

      const block = await this.provider!.getBlock("latest");
      const baseFee = block?.baseFeePerGas ?? BigInt(0);
      const maxFee = baseFee * BigInt(Math.ceil(config.baseFeeMultiplier));

      const callResult = await this.provider!.call({
        to: flashLoanContract,
        data: this.encodeFlashLoanCall(assets, amounts),
        from: config.chains[0].uniswapV2Router,
        gasLimit: gasEstimate * 2n,
        type: 2,
        maxFeePerGas: maxFee,
        maxPriorityFeePerGas: BigInt(config.priorityFeeWei),
      });

      const success = callResult !== "0x";
      const result: SimulationResult = {
        success,
        returnValue: callResult,
        gasEstimate,
        baseFee,
        maxFee,
        netProfitEstimate: null,
      };

      logger.info("Flash loan simulation complete", {
        success,
        gasEstimate: gasEstimate.toString(),
        baseFee: formatEther(baseFee),
      });

      return result;
    } catch (err: any) {
      logger.error("Simulation failed", { error: err.message });
      return {
        success: false,
        returnValue: "0x",
        gasEstimate: BigInt(0),
        baseFee: BigInt(0),
        maxFee: BigInt(0),
        netProfitEstimate: null,
        error: err.message,
      };
    }
  }

  async estimateGas(
    contractAddress: string,
    assets: string[],
    amounts: bigint[],
    _feeData: any
  ): Promise<bigint> {
    try {
      const contract = new Contract(contractAddress, this.flashLoanABI, this.provider!);
      const gas = await (contract.estimateGas as any).executeOperation(assets, amounts, amounts.map((a) => (a * BigInt(config.flashLoanPremiumBps)) / BigInt(10000)), "0x00000000000000000000000000000000000000", "0x")
        .catch(() => BigInt(2_000_000));

      logger.debug("Gas estimated", { contract: contractAddress, gas: gas.toString() });
      return gas;
    } catch (err: unknown) {
      logger.error("Gas estimation failed", { error: String(err) });
      return BigInt(3_000_000);
    }
  }

  async getFeeData(): Promise<{
    gasPrice: bigint;
    maxFeePerGas: bigint;
    maxPriorityFeePerGas: bigint;
  }> {
    try {
      if (!this.provider) {
        throw new Error("Provider not initialized");
      }
      const feeData = await this.provider.getFeeData();
      return {
        gasPrice: feeData.gasPrice ?? BigInt(20) * BigInt(10) ** BigInt(9),
        maxFeePerGas: feeData.maxFeePerGas ?? BigInt(30) * BigInt(10) ** BigInt(9),
        maxPriorityFeePerGas: feeData.maxPriorityFeePerGas ?? BigInt(2) * BigInt(10) ** BigInt(9),
      };
    } catch (err: unknown) {
      logger.error("Fee data fetch failed", { error: String(err) });
      return {
        gasPrice: BigInt(20) * BigInt(10) ** BigInt(9),
        maxFeePerGas: BigInt(30) * BigInt(10) ** BigInt(9),
        maxPriorityFeePerGas: BigInt(2) * BigInt(10) ** BigInt(9),
      };
    }
  }

  async simulateWithProfit(
    flashLoanContract: string,
    assets: string[],
    amounts: bigint[],
    path: string[],
    reserves: Map<string, any>,
    loanSize: bigint
  ): Promise<SimulationResult> {
    const simResult = await this.simulateFlashLoan(flashLoanContract, assets, amounts);

    if (!simResult.success) {
      return simResult;
    }

    const { ProfitCalculator } = await import("./profitCalculator");
    const profitCalc = new ProfitCalculator();
    const netProfit = profitCalc.calculate(path, reserves, loanSize);

    return {
      ...simResult,
      netProfitEstimate: netProfit,
    };
  }

  private encodeFlashLoanCall(assets: string[], amounts: bigint[]): string {
    const iface = new ethers.Interface(this.flashLoanABI);
    return iface.encodeFunctionData("executeOperation", [
      assets,
      amounts,
      amounts.map((a) => (a * BigInt(config.flashLoanPremiumBps)) / BigInt(10000)),
      "0x00000000000000000000000000000000000000",
      "0x",
    ]);
  }

  async estimateSimulationBlockDelay(): Promise<number> {
    return config.simulationBlockDelay;
  }
}

export const simulator = new Simulator();