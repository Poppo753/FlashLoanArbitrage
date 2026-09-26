import { config } from "./config";
import { info, error, warn, debug } from "./logger";
import { poolMonitor } from "./poolMonitor";
import { opportunityDetector } from "./opportunityDetector";
import { profitCalculator } from "./profitCalculator";
import { simulator } from "./simulator";
import { executionEngine } from "./executionEngine";
import { database } from "./database";

let isShuttingDown: boolean = false;

async function initializeBot(): Promise<void> {
  info("Starting Flash Loan Arbitrage Bot...");

  try {
    await database.initialize();
    info("Database initialized");
  } catch (err) {
    error("Failed to initialize database", { error: String(err) });
    throw err;
  }

  try {
    const primaryChain = config.chains[0];
    await poolMonitor.initialize(primaryChain.wsRpcUrl || primaryChain.rpcUrl, primaryChain.chainId);
    await poolMonitor.start();
    info("PoolMonitor initialized", { chainId: primaryChain.chainId });
  } catch (err) {
    error("Failed to initialize PoolMonitor", { error: String(err) });
    throw err;
  }

  info("All modules initialized successfully");
}

async function startMonitoring(): Promise<void> {
  try {
    const tokens = config.chains.flatMap((c) => [c.wethAddress]);
    const opportunities = await opportunityDetector.detectAllOpportunities(tokens);

    if (opportunities.length > 0) {
      info("Opportunities detected", { count: opportunities.length });

      for (const opp of opportunities) {
        const reserves = poolMonitor.getReserves();
        const loanSize = opportunityDetector.calculateOptimalLoanSize(
          opp,
          reserves,
          BigInt(10) ** BigInt(27)
        );

        const profitResult = profitCalculator.calculate(
          opp.tokens,
          reserves,
          loanSize
        );

        if (profitResult.isProfitable) {
          info("Profitable opportunity found", {
            type: opp.type,
            profitWei: profitResult.netProfitWei.toString(),
            netProfitUsd: profitResult.netProfitUsd,
          });

          const simResult = await simulator.simulateFlashLoan(
            config.chains[0].aaveLendingPool,
            opp.tokens.slice(0, -1),
            [loanSize],
            undefined,
            opp.tokens,
            reserves
          );

          if (simResult.success && simResult.netProfitEstimate?.isProfitable) {
            const result = await executionEngine.execute(
              config.chains[0].aaveLendingPool,
              "0x",
              loanSize,
              opp.tokens,
              reserves
            );

            if (result.success) {
              info("Execution successful", { txHash: result.txHash });
            } else {
              warn("Execution failed", { error: result.error });
            }
          }
        }
      }
    } else {
      debug("No opportunities detected in this cycle");
    }
  } catch (err) {
    error("Monitoring cycle error", { error: String(err) });
  }
}

async function shutdown(): Promise<void> {
  if (isShuttingDown) return;
  isShuttingDown = true;

  warn("Shutting down Flash Loan Arbitrage Bot...");

  try {
    await poolMonitor.stop();
    info("PoolMonitor stopped");
  } catch (err) {
    error("Error stopping PoolMonitor", { error: String(err) });
  }

  try {
    await database.close();
    info("Database closed");
  } catch (err) {
    error("Error closing database", { error: String(err) });
  }

  info("Bot shutdown complete");
  process.exit(0);
}

async function main(): Promise<void> {
  process.on("SIGINT", () => shutdown());
  process.on("SIGTERM", () => shutdown());
  process.on("uncaughtException", (err) => {
    error("Uncaught exception", { error: String(err) });
    shutdown().catch(() => process.exit(1));
  });
  process.on("unhandledRejection", (reason) => {
    error("Unhandled rejection", { reason: String(reason) });
    shutdown().catch(() => process.exit(1));
  });

  try {
    await initializeBot();
    info("Bot initialization complete, starting monitoring loop");

    const monitoringInterval = 15000;

    setInterval(async () => {
      if (!isShuttingDown) {
        await startMonitoring();
      }
    }, monitoringInterval);

    await startMonitoring();
  } catch (err) {
    error("Fatal error during bot startup", { error: String(err) });
    process.exit(1);
  }
}

main();