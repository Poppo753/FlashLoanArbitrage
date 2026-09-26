import { poolMonitor, PoolMonitor, ReserveData, pairKey, orientReserve } from "./poolMonitor";
import { config } from "./config";
import { logger } from "./logger";
import { setBaseFeeWei } from "./profitCalculator";

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
  private readonly CYCLE_MIN_PRODUCT_NUM = BigInt(1000001);
  private readonly CYCLE_MIN_PRODUCT_DEN = BigInt(1000000);

  constructor(poolMonitor: PoolMonitor) {
    this.poolMonitor = poolMonitor;
    this.logger = logger;
  }

  async checkTwoWayArbitrage(tokenA: string, tokenB: string): Promise<ArbitragePath | null> {
    const poolAB = this.poolMonitor.getReserveForPair(tokenA, tokenB);
    const poolBA = this.poolMonitor.getReserveForPair(tokenB, tokenA);

    if (!poolAB || !poolBA) {
      this.logger.debug("Missing reserves for two-way arbitrage", {
        tokenA,
        tokenB,
      });
      return null;
    }

    if (poolAB.pairAddress.toLowerCase() === poolBA.pairAddress.toLowerCase()) {
      this.logger.debug("Two-way arbitrage requires two distinct pools", {
        tokenA,
        tokenB,
        pair: poolAB.pairAddress,
      });
      return null;
    }

    const amountIn = this.WEI_MULTIPLIER / BigInt(10);

    const amountOutAB = this.getAmountOut(amountIn, poolAB.reserveIn, poolAB.reserveOut);
    const amountOutBA = this.getAmountOut(amountOutAB, poolBA.reserveIn, poolBA.reserveOut);

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
      pools: [poolAB.pairAddress, poolBA.pairAddress],
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
    const poolAB = this.poolMonitor.getReserveForPair(tokenA, tokenB);
    const poolBC = this.poolMonitor.getReserveForPair(tokenB, tokenC);
    const poolCA = this.poolMonitor.getReserveForPair(tokenC, tokenA);

    if (!poolAB || !poolBC || !poolCA) {
      this.logger.debug("Missing reserves for triangular arbitrage", {
        tokenA,
        tokenB,
        tokenC,
      });
      return null;
    }

    const amountIn = this.WEI_MULTIPLIER / BigInt(100);

    const amountOutAB = this.getAmountOut(amountIn, poolAB.reserveIn, poolAB.reserveOut);
    const amountOutBC = this.getAmountOut(amountOutAB, poolBC.reserveIn, poolBC.reserveOut);
    const amountOutCA = this.getAmountOut(amountOutBC, poolCA.reserveIn, poolCA.reserveOut);

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
      pools: [poolAB.pairAddress, poolBC.pairAddress, poolCA.pairAddress],
      directions: ["exactIn", "exactIn", "exactIn"],
      profitWei,
      type: "triangular",
    };
  }

  findNegativeCycles(
    tokens: string[],
    pools: Map<string, ReserveData>
  ): BellmanFordResult {
    const distances = new Map<string, bigint>();
    const predecessors = new Map<string, string | null>();
    const n = tokens.length;

    for (const token of tokens) {
      distances.set(token, this.WEI_MULTIPLIER);
      predecessors.set(token, null);
    }

    if (n < 2) {
      return { hasNegativeCycle: false, cycle: null, distances, predecessors };
    }

    interface RateEdge {
      from: string;
      to: string;
      num: bigint;
      den: bigint;
    }

    const canonicalTokens = new Map<string, string>();
    for (const token of tokens) {
      canonicalTokens.set(token.toLowerCase(), token);
    }

    const edges: RateEdge[] = [];
    const edgeIndex = new Map<string, RateEdge>();

    for (const [poolKey, reserve] of pools) {
      const sep = poolKey.indexOf("_");
      if (sep <= 0 || sep === poolKey.length - 1) continue;

      const tokenA = canonicalTokens.get(poolKey.slice(0, sep));
      const tokenB = canonicalTokens.get(poolKey.slice(sep + 1));
      if (!tokenA || !tokenB) continue;
      if (reserve.reserve0 <= BigInt(0) || reserve.reserve1 <= BigInt(0)) continue;

      const forward: RateEdge = {
        from: tokenA,
        to: tokenB,
        num: BigInt(997) * reserve.reserve1,
        den: BigInt(1000) * reserve.reserve0,
      };
      const backward: RateEdge = {
        from: tokenB,
        to: tokenA,
        num: BigInt(997) * reserve.reserve0,
        den: BigInt(1000) * reserve.reserve1,
      };
      edges.push(forward, backward);
      edgeIndex.set(this.edgeKey(forward.from, forward.to), forward);
      edgeIndex.set(this.edgeKey(backward.from, backward.to), backward);
    }

    const relax = (): string | null => {
      let updatedNode: string | null = null;
      for (const edge of edges) {
        const fromDist = distances.get(edge.from);
        if (fromDist === undefined || fromDist <= BigInt(0)) continue;
        const candidate = (fromDist * edge.num) / edge.den;
        const current = distances.get(edge.to) ?? BigInt(0);
        if (candidate > current) {
          distances.set(edge.to, candidate);
          predecessors.set(edge.to, edge.from);
          updatedNode = edge.to;
        }
      }
      return updatedNode;
    };

    for (let i = 0; i < n - 1; i++) {
      relax();
    }

    const updatedInFinalRound = relax();
    if (!updatedInFinalRound) {
      return { hasNegativeCycle: false, cycle: null, distances, predecessors };
    }

    let cycleNode = updatedInFinalRound;
    for (let i = 0; i < n; i++) {
      const predecessor = predecessors.get(cycleNode);
      if (!predecessor) {
        return { hasNegativeCycle: false, cycle: null, distances, predecessors };
      }
      cycleNode = predecessor;
    }

    const cycle = this.reconstructCycle(cycleNode, predecessors);
    if (cycle.length < 3) {
      return { hasNegativeCycle: false, cycle: null, distances, predecessors };
    }

    let productNum = BigInt(1);
    let productDen = BigInt(1);
    for (let i = 0; i + 1 < cycle.length; i++) {
      const edge = edgeIndex.get(this.edgeKey(cycle[i], cycle[i + 1]));
      if (!edge) {
        return { hasNegativeCycle: false, cycle: null, distances, predecessors };
      }
      productNum *= edge.num;
      productDen *= edge.den;
    }

    if (productNum * this.CYCLE_MIN_PRODUCT_DEN <= productDen * this.CYCLE_MIN_PRODUCT_NUM) {
      this.logger.debug("Cycle below profitability threshold", {
        cycle: cycle.join(" -> "),
        product: `${productNum}/${productDen}`,
      });
      return { hasNegativeCycle: false, cycle: null, distances, predecessors };
    }

    this.logger.info("Profitable cycle detected", { cycle: cycle.join(" -> ") });
    return {
      hasNegativeCycle: true,
      cycle,
      distances,
      predecessors,
    };
  }

  private edgeKey(from: string, to: string): string {
    return `${from.toLowerCase()}>${to.toLowerCase()}`;
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
      const stored = reserves.get(pairKey(tokenIn, tokenOut));
      const reserve = stored ? orientReserve(stored, tokenIn, tokenOut) : null;

      if (!reserve || reserve.reserveIn <= BigInt(0) || reserve.reserveOut <= BigInt(0)) {
        return BigInt(0);
      }
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
    const seenAt = new Map<string, number>();
    const chain: string[] = [];
    let current: string | null = startToken;

    while (current !== null && !seenAt.has(current)) {
      seenAt.set(current, chain.length);
      chain.push(current);
      current = predecessors.get(current) ?? null;
    }

    if (current === null) {
      return [];
    }

    const cycleStart = seenAt.get(current);
    if (cycleStart === undefined) {
      return [];
    }

    const forward = chain.slice(cycleStart).reverse();
    return [...forward, forward[0]];
  }

  async detectAllOpportunities(tokens: string[]): Promise<ArbitragePath[]> {
    try {
      const baseFeeWei = await this.poolMonitor.getBaseFeeWei();
      if (baseFeeWei !== null) {
        setBaseFeeWei(baseFeeWei);
      }
    } catch (err: unknown) {
      this.logger.debug("Base fee refresh failed", { error: String(err) });
    }

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