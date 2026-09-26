import winston from "winston";
import { format, transports } from "winston";
import path from "path";

const { combine, timestamp, printf, colorize, json } = format;

const logFormat = printf(({ level, message, timestamp: ts }) => {
  return `${ts} [${level}]: ${message}`;
});

export const logger = winston.createLogger({
  level: "debug",
  format: combine(colorize(), timestamp({ format: "YYYY-MM-DD HH:mm:ss" }), logFormat),
  transports: [
    new transports.Console({
      level: "info",
      format: combine(colorize(), timestamp({ format: "YYYY-MM-DD HH:mm:ss" }), logFormat),
    }),
    new transports.File({
      filename: path.join(__dirname, "..", "logs", "error.log"),
      level: "error",
      format: combine(timestamp({ format: "YYYY-MM-DD HH:mm:ss" }), json()),
    }),
    new transports.File({
      filename: path.join(__dirname, "..", "logs", "combined.log"),
      level: "info",
      format: combine(timestamp({ format: "YYYY-MM-DD HH:mm:ss" }), json()),
    }),
  ],
  exceptionHandlers: [
    new transports.File({ filename: path.join(__dirname, "..", "logs", "exceptions.log") }),
  ],
  rejectionHandlers: [
    new transports.File({ filename: path.join(__dirname, "..", "logs", "rejections.log") }),
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
