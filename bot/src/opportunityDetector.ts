import { poolMonitor, PoolMonitor, ReserveData } from "./poolMonitor";
import { config } from "./config";
import { logger } from "./logger";

export interface ArbitragePath {
  tokens: string[];
  pools: string[];
  directions: ("exactIn" | "exactOut")[];
  profitWei: bigint;
  type: "two_way" | "triangular";
}

export interface BellmanFordResult {
  hasNegativeCycle: boolean;
  cycle: string[] | null;
  distances: Map<string, bigint>;
  predecessors: Map<string, string | null>;
}

export class OpportunityDetector {
  private poolMonitor: PoolMonitor;
  private readonly logger: typeof logger;
  private readonly WEI_MULTIPLIER = BigInt(10) ** BigInt(18);

  constructor(poolMonitor: PoolMonitor) {
    this.poolMonitor = poolMonitor;
    this.logger = logger;
  }

  async checkTwoWayArbitrage(tokenA: string, tokenB: string): Promise<ArbitragePath | null> {
    const reserveAB = this.poolMonitor.getReserve(tokenA);
    const reserveBA = this.poolMonitor.getReserve(tokenB);

    if (!reserveAB || !reserveBA) {
      this.logger.debug("Missing reserves for two-way arbitrage", {
        tokenA,
        tokenB,
      });
      return null;
    }

    const amountIn = this.WEI_MULTIPLIER / BigInt(10);

    const amountOutAB = this.getAmountOut(amountIn, reserveAB.reserveIn, reserveAB.reserveOut);
    const amountOutBA = this.getAmountOut(amountOutAB, reserveBA.reserveIn, reserveBA.reserveOut);

    const profitWei = amountOutBA - amountIn;

    if (profitWei <= BigInt(0)) {
      return null;
    }

    this.logger.info("Two-way arbitrage opportunity found", {
      tokenA,
      tokenB,
      profitWei: profitWei.toString(),
    });

    return {
      tokens: [tokenA, tokenB, tokenA],
      pools: [tokenA, tokenB],
      directions: ["exactIn", "exactIn"],
      profitWei,
      type: "two_way",
    };
  }

  async checkTriangularArbitrage(
    tokenA: string,
    tokenB: string,
    tokenC: string
  ): Promise<ArbitragePath | null> {
    const reserveAB = this.poolMonitor.getReserve(tokenA + "_" + tokenB);
    const reserveBC = this.poolMonitor.getReserve(tokenB + "_" + tokenC);
    const reserveCA = this.poolMonitor.getReserve(tokenC + "_" + tokenA);

    const reserves: Record<string, ReserveData | undefined> = {
      [tokenA]: reserveAB,
      [tokenB]: reserveBC,
      [tokenC]: reserveCA,
    };

    for (const [, r] of Object.entries(reserves)) {
      if (!r) {
        this.logger.debug("Missing reserves for triangular arbitrage", { tokens: Object.keys(reserves) });
        return null;
      }
    }

    const amountIn = this.WEI_MULTIPLIER / BigInt(100);

    const amountOutAB = this.getAmountOut(amountIn, reserveAB!.reserveIn, reserveAB!.reserveOut);
    const amountOutBC = this.getAmountOut(amountOutAB, reserveBC!.reserveIn, reserveBC!.reserveOut);
    const amountOutCA = this.getAmountOut(amountOutBC, reserveCA!.reserveIn, reserveCA!.reserveOut);

    const profitWei = amountOutCA - amountIn;

    if (profitWei <= BigInt(0)) {
      return null;
    }

    this.logger.info("Triangular arbitrage opportunity found", {
      tokens: [tokenA, tokenB, tokenC],
      profitWei: profitWei.toString(),
    });

    return {
      tokens: [tokenA, tokenB, tokenC, tokenA],
      pools: [tokenA, tokenB, tokenC],
      directions: ["exactIn", "exactIn", "exactIn"],
      profitWei,
      type: "triangular",
    };
  }

  findNegativeCycles(
    tokens: string[],
    pools: Map<string, ReserveData>
  ): BellmanFordResult {
    const n = tokens.length;
    const distances = new Map<string, bigint>();
    const predecessors = new Map<string, string | null>();

    for (const token of tokens) {
      distances.set(token, this.WEI_MULTIPLIER * BigInt(10));
      predecessors.set(token, null);
    }
    distances.set(tokens[0], BigInt(0));

    for (let i = 0; i < n - 1; i++) {
      for (const [pair, reserve] of pools) {
        const [tokenIn, tokenOut] = pair.split("_");
        const idxIn = tokens.indexOf(tokenIn);
        const idxOut = tokens.indexOf(tokenOut);

        if (idxIn === -1 || idxOut === -1) continue;

        const amountOut = this.getAmountOut(
          distances.get(tokenIn) || BigInt(0),
          reserve.reserveIn,
          reserve.reserveOut
        );

        const newDist = distances.get(tokenIn) || BigInt(0);
        if (amountOut > newDist) {
          distances.set(tokenOut, amountOut);
          predecessors.set(tokenOut, tokenIn);
        }
      }
    }

    let negativeCycleToken: string | null = null;
    for (const [pair, reserve] of pools) {
      const [tokenIn, tokenOut] = pair.split("_");
      const amountOut = this.getAmountOut(
        distances.get(tokenIn) || BigInt(0),
        reserve.reserveIn,
        reserve.reserveOut
      );
      if (amountOut > (distances.get(tokenIn) || BigInt(0))) {
        negativeCycleToken = tokenOut;
        break;
      }
    }

    if (!negativeCycleToken) {
      return { hasNegativeCycle: false, cycle: null, distances, predecessors };
    }

    const cycle = this.reconstructCycle(negativeCycleToken, predecessors);
    return {
      hasNegativeCycle: true,
      cycle,
      distances,
      predecessors,
    };
  }

  calculateOptimalLoanSize(
    path: ArbitragePath,
    reserves: Map<string, ReserveData>,
    maxLoanSizeWei: bigint
  ): bigint {
    let low = BigInt(0);
    let high = maxLoanSizeWei;
    let optimalSize = BigInt(0);
    let maxProfit = BigInt(0);

    const iterations = 50;

    for (let i = 0; i < iterations; i++) {
      const mid1 = low + (high - low) / BigInt(3);
      const mid2 = high - (high - low) / BigInt(3);

      const profit1 = this.estimatePathProfit(mid1, path, reserves);
      const profit2 = this.estimatePathProfit(mid2, path, reserves);

      if (profit1 > profit2) {
        high = mid2;
        if (profit1 > maxProfit) {
          maxProfit = profit1;
          optimalSize = mid1;
        }
      } else {
        low = mid1;
        if (profit2 > maxProfit) {
          maxProfit = profit2;
          optimalSize = mid2;
        }
      }
    }

    this.logger.debug("Optimal loan size calculated", {
      pathType: path.type,
      optimalSize: optimalSize.toString(),
      maxProfit: maxProfit.toString(),
    });

    return optimalSize;
  }

  private estimatePathProfit(
    loanSize: bigint,
    path: ArbitragePath,
    reserves: Map<string, ReserveData>
  ): bigint {
    let amountIn = loanSize;
    const feeBps = BigInt(config.flashLoanPremiumBps);
    const aaveFee = (amountIn * feeBps) / BigInt(10000);

    for (let i = 0; i < path.tokens.length - 1; i++) {
      const tokenIn = path.tokens[i];
      const tokenOut = path.tokens[i + 1];
      const reserve = reserves.get(
        i === 0 ? tokenIn + "_" + tokenOut : tokenIn
      );

      if (!reserve) return BigInt(0);
      amountIn = this.getAmountOut(amountIn, reserve.reserveIn, reserve.reserveOut);
    }

    const profit = amountIn - loanSize - aaveFee;
    return profit > BigInt(0) ? profit : BigInt(0);
  }

  private getAmountOut(
    amountIn: bigint,
    reserveIn: bigint,
    reserveOut: bigint
  ): bigint {
    if (amountIn <= BigInt(0) || reserveIn <= BigInt(0) || reserveOut <= BigInt(0)) {
      return BigInt(0);
    }
    const amountInWithFee = amountIn * BigInt(997);
    const numerator = amountInWithFee * reserveOut;
    const denominator = reserveIn * BigInt(1000) + amountInWithFee;
    return numerator / denominator;
  }

  reconstructCycle(
    startToken: string,
    predecessors: Map<string, string | null>
  ): string[] {
    const visited = new Set<string>();
    const cycle: string[] = [];
    let current: string | null = startToken;

    while (current && !visited.has(current)) {
      visited.add(current);
      cycle.push(current);
      current = predecessors.get(current) ?? null;
    }

    if (current) {
      const cycleStart = cycle.indexOf(current);
      return cycle.slice(cycleStart).concat(current);
    }

    return cycle;
  }

  async detectAllOpportunities(tokens: string[]): Promise<ArbitragePath[]> {
    const opportunities: ArbitragePath[] = [];

    for (let i = 0; i < tokens.length; i++) {
      for (let j = i + 1; j < tokens.length; j++) {
        const twoWay = await this.checkTwoWayArbitrage(tokens[i], tokens[j]);
        if (twoWay) opportunities.push(twoWay);
      }
    }

    for (let i = 0; i < tokens.length; i++) {
      for (let j = i + 1; j < tokens.length; j++) {
        for (let k = j + 1; k < tokens.length; k++) {
          const triangular = await this.checkTriangularArbitrage(tokens[i], tokens[j], tokens[k]);
          if (triangular) opportunities.push(triangular);
        }
      }
    }

    this.logger.info("Opportunity detection complete", { count: opportunities.length });
    return opportunities;
  }
}

export const opportunityDetector = new OpportunityDetector(poolMonitor);