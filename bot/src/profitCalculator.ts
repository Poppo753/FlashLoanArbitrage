import { config } from "./config";
import { ReserveData } from "./poolMonitor";
import { logger } from "./logger";

export interface ProfitResult {
  grossProfitWei: bigint;
  flashLoanFeeWei: bigint;
  gasCostWei: bigint;
  netProfitWei: bigint;
  netProfitUsd: number;
  profitMargin: number;
  isProfitable: boolean;
  estimatedPriceImpact: number;
  effectiveAmountOut: bigint;
}

export class ProfitCalculator {
  private readonly aavePremiumBps: number;

  constructor(aavePremiumBps?: number) {
    this.aavePremiumBps = aavePremiumBps ?? config.flashLoanPremiumBps;
  }

  calculate(
    path: string[],
    reserves: Map<string, ReserveData>,
    loanSizeWei: bigint,
    tokenPrices?: Record<string, number>
  ): ProfitResult {
    const amountIn = loanSizeWei;
    const aaveFee = this.calculateAaveFee(amountIn);

    let currentAmount = amountIn;
    let priceImpactTotal = 0;

    for (let i = 0; i < path.length - 1; i++) {
      const tokenIn = path[i];
      const tokenOut = path[i + 1];
      const reserve = this.findReserve(reserves, tokenIn, tokenOut);

      if (!reserve || reserve.reserveIn === BigInt(0) || reserve.reserveOut === BigInt(0)) {
        return this.emptyResult();
      }

      const beforePrice = Number(reserve.reserveOut) / Number(reserve.reserveIn);
      const amountOut = this.swapAmount(currentAmount, reserve.reserveIn, reserve.reserveOut);
      currentAmount = amountOut;
      const afterPrice = Number(reserve.reserveOut) / Number(reserve.reserveIn);
      priceImpactTotal += Math.abs(beforePrice - afterPrice) / beforePrice;
    }

    const gasCost = this.estimateGasCost(path.length);
    const grossProfit = currentAmount - amountIn;
    const netProfit = grossProfit - aaveFee - gasCost;

    const tokenPricesMap = tokenPrices ?? {};
    const netProfitUsd = this.weiToUsd(netProfit, tokenPricesMap);
    const profitMargin = grossProfit > BigInt(0) ? Number(netProfit) / Number(grossProfit) : 0;

    const result: ProfitResult = {
      grossProfitWei: grossProfit,
      flashLoanFeeWei: aaveFee,
      gasCostWei: gasCost,
      netProfitWei: netProfit,
      netProfitUsd,
      profitMargin,
      isProfitable: netProfit > BigInt(0),
      estimatedPriceImpact: priceImpactTotal,
      effectiveAmountOut: currentAmount,
    };

    logger.debug("Profit calculated", {
      loanSize: amountIn.toString(),
      grossProfit: grossProfit.toString(),
      netProfit: netProfit.toString(),
      isProfitable: result.isProfitable,
    });

    return result;
  }

  private calculateAaveFee(amountIn: bigint): bigint {
    const premiumBps = BigInt(this.aavePremiumBps);
    return (amountIn * premiumBps) / BigInt(10000);
  }

  private swapAmount(amountIn: bigint, reserveIn: bigint, reserveOut: bigint): bigint {
    const amountInWithFee = amountIn * BigInt(997);
    const numerator = amountInWithFee * reserveOut;
    const denominator = reserveIn * BigInt(1000) + amountInWithFee;
    return numerator / denominator;
  }

  private findReserve(
    reserves: Map<string, ReserveData>,
    tokenIn: string,
    tokenOut: string
  ): ReserveData | undefined {
    for (const [, reserve] of reserves) {
      if (
        (reserve.tokenIn === tokenIn && reserve.tokenOut === tokenOut) ||
        (reserve.tokenIn === tokenOut && reserve.tokenOut === tokenIn)
      ) {
        return reserve;
      }
    }
    return undefined;
  }

  private estimateGasCost(pathLength: number): bigint {
    const baseGas = BigInt(21000) * BigInt(pathLength);
    const flashLoanOverhead = BigInt(150000);
    const totalGas = baseGas + flashLoanOverhead;
    return totalGas * BigInt(config.priorityFeeWei);
  }

  private weiToUsd(
    weiAmount: bigint,
    tokenPrices: Record<string, number>
  ): number {
    const ethPrice = tokenPrices["ETH"] ?? tokenPrices["WETH"] ?? 1800;
    const weiPerEth = Math.pow(10, 18);
    const ethAmount = Number(weiAmount) / weiPerEth;
    return ethAmount * ethPrice;
  }

  static calculateOptimalAmount(
    reserves: Map<string, ReserveData>,
    path: string[],
    maxLoanWei: bigint
  ): bigint {
    let low = BigInt(0);
    let high = maxLoanWei;
    let bestAmount = BigInt(0);
    let bestProfit = BigInt(0);

    for (let i = 0; i < 64; i++) {
      const mid1 = low + (high - low) / BigInt(3);
      const mid2 = high - (high - low) / BigInt(3);

      const profit1 = new ProfitCalculator().calculate(path, reserves, mid1).netProfitWei;
      const profit2 = new ProfitCalculator().calculate(path, reserves, mid2).netProfitWei;

      if (profit1 > profit2) {
        high = mid2;
        if (profit1 > bestProfit) {
          bestProfit = profit1;
          bestAmount = mid1;
        }
      } else {
        low = mid1;
        if (profit2 > bestProfit) {
          bestProfit = profit2;
          bestAmount = mid2;
        }
      }
    }

    return bestAmount;
  }

  private emptyResult(): ProfitResult {
    return {
      grossProfitWei: BigInt(0),
      flashLoanFeeWei: BigInt(0),
      gasCostWei: BigInt(0),
      netProfitWei: BigInt(0),
      netProfitUsd: 0,
      profitMargin: 0,
      isProfitable: false,
      estimatedPriceImpact: 0,
      effectiveAmountOut: BigInt(0),
    };
  }
}

export const profitCalculator = new ProfitCalculator();