import winston from "winston";
import { format, transports } from "winston";
import path from "path";
import fs from "fs";
import dotenv from "dotenv";

// config.ts imports this module before its own dotenv.config() runs,
// so load .env here as well to make LOG_LEVEL/LOG_DIR available.
dotenv.config();

const { combine, timestamp, printf, colorize, json } = format;

const WINSTON_LEVELS = ["error", "warn", "info", "http", "verbose", "debug", "silly"];

const configuredLevel = (process.env.LOG_LEVEL ?? "").trim().toLowerCase();
const logLevel: string = WINSTON_LEVELS.includes(configuredLevel) ? configuredLevel : "info";

function resolveLogDir(): string {
  const fallback = path.join(__dirname, "..", "logs");
  const configured = (process.env.LOG_DIR ?? "").trim();
  const candidates = configured ? [path.resolve(configured), fallback] : [fallback];
  for (const dir of candidates) {
    try {
      fs.mkdirSync(dir, { recursive: true });
      return dir;
    } catch {
      // try next candidate
    }
  }
  return fallback;
}

const logDir = resolveLogDir();

const logFormat = printf(({ level, message, timestamp: ts }) => {
  return `${ts} [${level}]: ${message}`;
});

export const logger = winston.createLogger({
  level: logLevel,
  format: combine(colorize(), timestamp({ format: "YYYY-MM-DD HH:mm:ss" }), logFormat),
  transports: [
    new transports.Console({
      level: logLevel,
      format: combine(colorize(), timestamp({ format: "YYYY-MM-DD HH:mm:ss" }), logFormat),
    }),
    new transports.File({
      filename: path.join(logDir, "error.log"),
      level: "error",
      format: combine(timestamp({ format: "YYYY-MM-DD HH:mm:ss" }), json()),
    }),
    new transports.File({
      filename: path.join(logDir, "combined.log"),
      level: logLevel,
      format: combine(timestamp({ format: "YYYY-MM-DD HH:mm:ss" }), json()),
    }),
  ],
  exceptionHandlers: [
    new transports.File({ filename: path.join(logDir, "exceptions.log") }),
  ],
  rejectionHandlers: [
    new transports.File({ filename: path.join(logDir, "rejections.log") }),
  ],
});

export const info = (message: string, meta?: Record<string, unknown>): void => {
  logger.info(message, { ...meta });
};

export const error = (message: string, meta?: Record<string, unknown>): void => {
  logger.error(message, { ...meta });
};

export const warn = (message: string, meta?: Record<string, unknown>): void => {
  logger.warn(message, { ...meta });
};

export const debug = (message: string, meta?: Record<string, unknown>): void => {
  logger.debug(message, { ...meta });
};
