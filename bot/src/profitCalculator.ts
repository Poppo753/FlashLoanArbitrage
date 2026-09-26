import { config } from "./config";
import { ReserveData, OrientedReserve, pairKey, orientReserve } from "./poolMonitor";
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

const FALLBACK_BASE_FEE_WEI = BigInt(10_000_000_000);

let sharedBaseFeeWei: bigint = FALLBACK_BASE_FEE_WEI;

export function setBaseFeeWei(baseFeeWei: bigint): void {
  if (baseFeeWei > BigInt(0)) {
    sharedBaseFeeWei = baseFeeWei;
  }
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

      const reserveInBefore = reserve.reserveIn;
      const reserveOutBefore = reserve.reserveOut;
      const beforePrice = Number(reserveOutBefore) / Number(reserveInBefore);
      const amountInStep = currentAmount;
      const amountOut = this.swapAmount(amountInStep, reserveInBefore, reserveOutBefore);
      const reserveInAfter = reserveInBefore + amountInStep;
      const reserveOutAfter = reserveOutBefore - amountOut;
      const afterPrice = Number(reserveOutAfter) / Number(reserveInAfter);
      currentAmount = amountOut;
      if (beforePrice > 0) {
        priceImpactTotal += Math.abs(beforePrice - afterPrice) / beforePrice;
      }
    }

    const gasPriceWei = this.effectiveGasPriceWei();
    const gasCost = this.estimateGasCost(path.length, gasPriceWei);
    const gasPriceExceeded = !this.isGasPriceWithinLimit(gasPriceWei);
    if (gasPriceExceeded) {
      logger.warn("Effective gas price above thresholds.maxGasPriceGwei; marking not profitable", {
        gasPriceGwei: Number(gasPriceWei) / 1e9,
        maxGasPriceGwei: config.thresholds.maxGasPriceGwei,
      });
    }
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
      isProfitable: netProfit > BigInt(0) && !gasPriceExceeded,
      estimatedPriceImpact: priceImpactTotal,
      effectiveAmountOut: currentAmount,
    };

    logger.debug("Profit calculated", {
      loanSize: amountIn.toString(),
      grossProfit: grossProfit.toString(),
      netProfit: netProfit.toString(),
      gasCost: gasCost.toString(),
      gasPriceGwei: Number(gasPriceWei) / 1e9,
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
  ): OrientedReserve | undefined {
    const stored = reserves.get(pairKey(tokenIn, tokenOut));
    if (!stored) return undefined;
    return orientReserve(stored, tokenIn, tokenOut) ?? undefined;
  }

  private effectiveGasPriceWei(): bigint {
    const baseFeeWei =
      sharedBaseFeeWei > BigInt(0) ? sharedBaseFeeWei : FALLBACK_BASE_FEE_WEI;
    const multiplierBps = BigInt(Math.round(config.baseFeeMultiplier * 10000));
    const priorityFeeWei = BigInt(config.priorityFeeWei);
    return (baseFeeWei * multiplierBps) / BigInt(10000) + priorityFeeWei;
  }

  private isGasPriceWithinLimit(gasPriceWei: bigint): boolean {
    const gasPriceGwei = Number(gasPriceWei) / 1e9;
    return gasPriceGwei <= config.thresholds.maxGasPriceGwei;
  }

  private estimateGasCost(pathLength: number, gasPriceWei: bigint): bigint {
    const baseGas = BigInt(21000) * BigInt(pathLength);
    const flashLoanOverhead = BigInt(150000);
    const totalGas = baseGas + flashLoanOverhead;
    return totalGas * gasPriceWei;
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