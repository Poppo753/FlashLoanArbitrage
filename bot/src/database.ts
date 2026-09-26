import { Pool } from "pg";
import { config } from "./config";
import { logger } from "./logger";

export interface OpportunityRecord {
  id?: string;
  type: string;
  tokens: string[];
  profitWei: string;
  netProfitWei: string;
  gasCostWei: string;
  detectedAt: Date;
  status: "pending" | "executed" | "expired";
}

export interface ExecutionRecord {
  id?: string;
  opportunityId: string;
  txHash: string;
  blockNumber?: number;
  gasUsed?: string;
  profitWei: string;
  status: "success" | "failed";
  error?: string;
  executedAt: Date;
}

export class Database {
  private pool: Pool | null = null;
  private readonly logger: typeof logger;

  constructor() {
    this.logger = logger;
  }

  async initialize(): Promise<void> {
    try {
      this.pool = new Pool({
        connectionString: config.postgresUrl,
        max: 20,
        idleTimeoutMillis: 30000,
        connectionTimeoutMillis: 2000,
      });

      this.pool.on("error", (err: Error) => {
        this.logger.error("Unexpected error on idle client", { error: err.message });
      });

      await this.pool.query("SELECT NOW()");
      await this.createTables();

      this.logger.info("Database connected and tables verified");
    } catch (err: unknown) {
      this.logger.error("Failed to initialize database", { error: String(err) });
      throw err;
    }
  }

  private async createTables(): Promise<void> {
    const queries = [
      `CREATE TABLE IF NOT EXISTS opportunities (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        type VARCHAR(50) NOT NULL,
        tokens TEXT[] NOT NULL,
        profit_wei VARCHAR(78) NOT NULL,
        net_profit_wei VARCHAR(78) NOT NULL,
        gas_cost_wei VARCHAR(78) NOT NULL,
        detected_at TIMESTAMP NOT NULL DEFAULT NOW(),
        status VARCHAR(20) NOT NULL DEFAULT 'pending'
      )`,
      `CREATE TABLE IF NOT EXISTS executions (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        opportunity_id UUID REFERENCES opportunities(id),
        tx_hash VARCHAR(66) NOT NULL,
        block_number BIGINT,
        gas_used VARCHAR(78),
        profit_wei VARCHAR(78) NOT NULL,
        status VARCHAR(20) NOT NULL,
        error TEXT,
        executed_at TIMESTAMP NOT NULL DEFAULT NOW()
      )`,
      `CREATE INDEX IF NOT EXISTS idx_opportunities_detected ON opportunities(detected_at)`,
      `CREATE INDEX IF NOT EXISTS idx_opportunities_status ON opportunities(status)`,
      `CREATE INDEX IF NOT EXISTS idx_executions_tx_hash ON executions(tx_hash)`,
      `CREATE INDEX IF NOT EXISTS idx_executions_status ON executions(status)`,
    ];

    const client = await this.pool!.connect();
    try {
      await client.query("BEGIN");
      for (const q of queries) {
        await client.query(q);
      }
      await client.query("COMMIT");
    } catch (err: unknown) {
      await client.query("ROLLBACK");
      throw err;
    } finally {
      client.release();
    }
  }

  async saveOpportunity(opportunity: OPPORTUNITY): Promise<string> {
    if (!this.pool) throw new Error("Database not initialized");

    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const result = await client.query(
        `INSERT INTO opportunities (type, tokens, profit_wei, net_profit_wei, gas_cost_wei, detected_at, status)
         VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id`,
        [
          opportunity.type,
          opportunity.tokens,
          opportunity.profitWei,
          opportunity.netProfitWei,
          opportunity.gasCostWei,
          opportunity.detectedAt,
          opportunity.status,
        ]
      );
      await client.query("COMMIT");
      logger.info("Opportunity saved", { id: result.rows[0].id, type: opportunity.type });
      return result.rows[0].id;
    } catch (err: unknown) {
      await client.query("ROLLBACK");
      this.logger.error("Failed to save opportunity", { error: String(err) });
      throw err;
    } finally {
      client.release();
    }
  }

  async saveExecution(execution: EXECUTION): Promise<string> {
    if (!this.pool) throw new Error("Database not initialized");

    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const result = await client.query(
        `INSERT INTO executions (opportunity_id, tx_hash, block_number, gas_used, profit_wei, status, error, executed_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id`,
        [
          execution.opportunityId,
          execution.txHash,
          execution.blockNumber,
          execution.gasUsed,
          execution.profitWei,
          execution.status,
          execution.error,
          execution.executedAt,
        ]
      );
      await client.query("COMMIT");
      logger.info("Execution saved", { id: result.rows[0].id, txHash: execution.txHash });
      return result.rows[0].id;
    } catch (err: unknown) {
      await client.query("ROLLBACK");
      this.logger.error("Failed to save execution", { error: String(err) });
      throw err;
    } finally {
      client.release();
    }
  }

  async updateOpportunityStatus(id: string, status: string): Promise<void> {
    if (!this.pool) throw new Error("Database not initialized");

    await this.pool.query(
      `UPDATE opportunities SET status = $1 WHERE id = $2`,
      [status, id]
    );
    logger.debug("Opportunity status updated", { id, status });
  }

  async getPendingOpportunities(): Promise<OpportunityRecord[]> {
    if (!this.pool) throw new Error("Database not initialized");

    const result = await this.pool.query(
      `SELECT * FROM opportunities WHERE status = 'pending' ORDER BY detected_at DESC`
    );
    return result.rows.map((row: any) => ({
      id: row.id,
      type: row.type,
      tokens: row.tokens,
      profitWei: row.profit_wei,
      netProfitWei: row.net_profit_wei,
      gasCostWei: row.gas_cost_wei,
      detectedAt: row.detected_at,
      status: row.status,
    }));
  }

  async getExecutionsByStatus(status: string): Promise<ExecutionRecord[]> {
    if (!this.pool) throw new Error("Database not initialized");

    const result = await this.pool.query(
      `SELECT * FROM executions WHERE status = $1 ORDER BY executed_at DESC`,
      [status]
    );
    return result.rows.map((row: any) => ({
      id: row.id,
      opportunityId: row.opportunity_id,
      txHash: row.tx_hash,
      blockNumber: row.block_number,
      gasUsed: row.gas_used,
      profitWei: row.profit_wei,
      status: row.status,
      error: row.error,
      executedAt: row.executed_at,
    }));
  }

  async getLatestOpportunities(limit: number = 100): Promise<OpportunityRecord[]> {
    if (!this.pool) throw new Error("Database not initialized");

    const result = await this.pool.query(
      `SELECT * FROM opportunities ORDER BY detected_at DESC LIMIT $1`,
      [limit]
    );
    return result.rows.map((row: any) => ({
      id: row.id,
      type: row.type,
      tokens: row.tokens,
      profitWei: row.profit_wei,
      netProfitWei: row.net_profit_wei,
      gasCostWei: row.gas_cost_wei,
      detectedAt: row.detected_at,
      status: row.status,
    }));
  }

  async getProfitStats(): Promise<{
    totalOpportunities: number;
    totalExecuted: number;
    totalProfitWei: string;
    avgProfitUsd: number | null;
  }> {
    if (!this.pool) throw new Error("Database not initialized");

    const result = await this.pool.query(`
      SELECT
        (SELECT COUNT(*) FROM opportunities) as total_opportunities,
        (SELECT COUNT(*) FROM executions WHERE status = 'success') as total_executed,
        COALESCE((
          SELECT SUM(o.net_profit_wei::numeric)
          FROM opportunities o
          WHERE EXISTS (
            SELECT 1 FROM executions e
            WHERE e.opportunity_id = o.id AND e.status = 'success'
          )
        ), 0) as total_profit_wei
    `);

    const row = result.rows[0];
    return {
      totalOpportunities: parseInt(row.total_opportunities, 10),
      totalExecuted: parseInt(row.total_executed, 10),
      totalProfitWei: String(row.total_profit_wei ?? "0"),
      // Schema stores profit only in wei (no USD columns/prices), so no USD average can be computed.
      avgProfitUsd: null,
    };
  }

  async close(): Promise<void> {
    if (this.pool) {
      await this.pool.end();
      this.logger.info("Database connection pool closed");
    }
  }
}

interface OPPORTUNITY {
  type: string;
  tokens: string[];
  profitWei: string;
  netProfitWei: string;
  gasCostWei: string;
  detectedAt: Date;
  status: string;
}

interface EXECUTION {
  opportunityId: string;
  txHash: string;
  blockNumber?: number;
  gasUsed?: string;
  profitWei: string;
  status: string;
  error?: string;
  executedAt: Date;
}

export const database = new Database();