import { logger } from "../logger";

export interface ABTestResult {
  variant: string;
  winRate: number;
  avgTip: number;
  totalBids: number;
  avgProfit: number;
}

export interface AuctionSimulationResult {
  winningBid: bigint;
  expectedProfit: bigint;
}

interface ABTestVariant {
  name: string;
  tips: number[];
  wins: number;
  totalBids: number;
  profits: number[];
}

export class BiddingStrategy {
  private confidenceFactor: number = 0.95;
  private abTestRunner: ABTestRunner;

  constructor() {
    this.abTestRunner = new ABTestRunner();
  }

  calculateOptimalTip(
    grossProfitWei: bigint,
    competitorCount: number
  ): bigint {
    try {
      if (competitorCount < 0) {
        throw new Error("Competitor count cannot be negative");
      }
      if (grossProfitWei < BigInt(0)) {
        throw new Error("Gross profit cannot be negative");
      }

      const confidenceFactorScaled = Math.floor(this.confidenceFactor * 10000);
      const numerator = competitorCount * confidenceFactorScaled;
      const denominator = (competitorCount + 1) * 10000;

      const optimalTip = (grossProfitWei * BigInt(numerator)) / BigInt(denominator);

      logger.debug("Optimal tip calculated", {
        grossProfitWei: grossProfitWei.toString(),
        competitorCount,
        optimalTip: optimalTip.toString(),
        confidenceFactor: this.confidenceFactor,
      });

      return optimalTip;
    } catch (err: any) {
      logger.error("Failed to calculate optimal tip", {
        error: err.message,
      });
      throw err;
    }
  }

  adjustTip(winRate: number, currentTipPercent: number): number {
    try {
      if (winRate < 0 || winRate > 100) {
        throw new Error("Win rate must be between 0 and 100");
      }
      if (currentTipPercent < 0 || currentTipPercent > 100) {
        throw new Error("Current tip percent must be between 0 and 100");
      }

      let adjustedTip: number;

      if (winRate > 80) {
        adjustedTip = currentTipPercent * 0.9;
        logger.info("High win rate detected, decreasing tip by 10%", {
          winRate,
          oldTip: currentTipPercent,
          newTip: adjustedTip,
        });
      } else if (winRate < 20) {
        adjustedTip = currentTipPercent * 1.2;
        logger.warn("Low win rate detected, increasing tip by 20%", {
          winRate,
          oldTip: currentTipPercent,
          newTip: adjustedTip,
        });
      } else {
        adjustedTip = currentTipPercent;
        logger.debug("Win rate in optimal range, maintaining current tip", {
          winRate,
          tip: currentTipPercent,
        });
      }

      return Math.round(adjustedTip * 100) / 100;
    } catch (err: any) {
      logger.error("Failed to adjust tip", { error: err.message });
      throw err;
    }
  }

  simulateAuction(
    grossProfit: bigint,
    numBidders: number
  ): AuctionSimulationResult {
    try {
      if (numBidders <= 0) {
        throw new Error("Number of bidders must be positive");
      }
      if (grossProfit < BigInt(0)) {
        throw new Error("Gross profit cannot be negative");
      }

      const equilibriumBid =
        (grossProfit * BigInt(numBidders)) / BigInt(numBidders + 1);
      const expectedProfit = grossProfit - equilibriumBid;

      logger.debug("Auction simulation complete", {
        grossProfit: grossProfit.toString(),
        numBidders,
        winningBid: equilibriumBid.toString(),
        expectedProfit: expectedProfit.toString(),
      });

      return {
        winningBid: equilibriumBid,
        expectedProfit,
      };
    } catch (err: any) {
      logger.error("Failed to simulate auction", { error: err.message });
      throw err;
    }
  }

  getABTestRunner(): ABTestRunner {
    return this.abTestRunner;
  }

  setConfidenceFactor(factor: number): void {
    this.confidenceFactor = factor;
  }
}

export class ABTestRunner {
  private variants: Map<string, ABTestVariant> = new Map();

  constructor() {}

  registerVariant(name: string, initialTip: number): void {
    try {
      if (this.variants.has(name)) {
        logger.warn("Variant already exists, resetting", { name });
      }
      this.variants.set(name, {
        name,
        tips: [],
        wins: 0,
        totalBids: 0,
        profits: [],
      });
      logger.info("AB test variant registered", { name, initialTip });
    } catch (err: any) {
      logger.error("Failed to register AB test variant", {
        name,
        error: err.message,
      });
      throw err;
    }
  }

  recordBid(
    variantName: string,
    tip: number,
    won: boolean,
    profit: number
  ): void {
    try {
      const variant = this.variants.get(variantName);
      if (!variant) {
        throw new Error(`Variant ${variantName} not found`);
      }

      variant.tips.push(tip);
      variant.totalBids += 1;
      variant.profits.push(profit);
      if (won) {
        variant.wins += 1;
      }

      logger.debug("Bid recorded", {
        variant: variantName,
        tip,
        won,
        totalBids: variant.totalBids,
      });
    } catch (err: any) {
      logger.error("Failed to record bid", {
        variantName,
        error: err.message,
      });
      throw err;
    }
  }

  getWinRate(variantName: string): number {
    try {
      const variant = this.variants.get(variantName);
      if (!variant) {
        return 0;
      }
      if (variant.totalBids === 0) {
        return 0;
      }
      return (variant.wins / variant.totalBids) * 100;
    } catch (err: any) {
      logger.error("Failed to get win rate", {
        variantName,
        error: err.message,
      });
      return 0;
    }
  }

  getAverageTip(variantName: string): number {
    try {
      const variant = this.variants.get(variantName);
      if (!variant || variant.tips.length === 0) {
        return 0;
      }
      const sum = variant.tips.reduce((acc, val) => acc + val, 0);
      return sum / variant.tips.length;
    } catch (err: any) {
      logger.error("Failed to get average tip", {
        variantName,
        error: err.message,
      });
      return 0;
    }
  }

  getResults(): ABTestResult[] {
    const results: ABTestResult[] = [];
    for (const [name, variant] of this.variants) {
      results.push({
        variant: name,
        winRate: this.getWinRate(name),
        avgTip: this.getAverageTip(name),
        totalBids: variant.totalBids,
        avgProfit:
          variant.profits.length > 0
            ? variant.profits.reduce((a, b) => a + b, 0) / variant.profits.length
            : 0,
      });
    }
    return results;
  }

  getBestVariant(): string | null {
    let bestName: string | null = null;
    let bestWinRate = -1;

    for (const [name] of this.variants) {
      const wr = this.getWinRate(name);
      if (wr > bestWinRate) {
        bestWinRate = wr;
        bestName = name;
      }
    }

    logger.debug("Best variant selected", { variant: bestName, winRate: bestWinRate });
    return bestName;
  }
}

export const biddingStrategy = new BiddingStrategy();
