// ==============================================================================
// STRUCTURED JSON LOGGER - Production-grade logging for Edge Functions
// ==============================================================================
// Usage:
//   import { createLogger } from "../_shared/logger.ts";
//   const log = createLogger("job-worker", requestId);
//   log.info("Processing order", { orderId: "123", amount: 50 });
//
// Output:
//   {"level":"info","msg":"Processing order","orderId":"123","amount":50,
//    "func":"job-worker","request_id":"req_xyz","ts":"2024-01-15T10:30:00Z"}
// ==============================================================================

export type LogLevel = "debug" | "info" | "warn" | "error" | "fatal";

export interface LogContext {
  [key: string]: unknown;
}

export interface LogEntry {
  level: LogLevel;
  msg: string;
  func: string;
  request_id?: string;
  ts: string;
  duration_ms?: number;
  error?: string;
  stack?: string;
  [key: string]: unknown;
}

export interface Logger {
  debug(msg: string, context?: LogContext): void;
  info(msg: string, context?: LogContext): void;
  warn(msg: string, context?: LogContext): void;
  error(msg: string, error?: Error | string, context?: LogContext): void;
  fatal(msg: string, error?: Error | string, context?: LogContext): void;
  child(context: LogContext): Logger;
  startTimer(): () => number;
}

// Minimum log level (set via LOG_LEVEL env or default to "info")
const LOG_LEVELS: Record<LogLevel, number> = {
  debug: 0,
  info: 1,
  warn: 2,
  error: 3,
  fatal: 4,
};

function getMinLevel(): LogLevel {
  const env = Deno.env.get("LOG_LEVEL")?.toLowerCase();
  if (env && env in LOG_LEVELS) {
    return env as LogLevel;
  }
  return "info";
}

function shouldLog(level: LogLevel): boolean {
  return LOG_LEVELS[level] >= LOG_LEVELS[getMinLevel()];
}

function formatError(error: Error | string): { error: string; stack?: string } {
  if (typeof error === "string") {
    return { error };
  }
  return {
    error: error.message,
    stack: error.stack,
  };
}

function writeLog(entry: LogEntry): void {
  // Use console methods that map to stdout/stderr appropriately
  const output = JSON.stringify(entry);

  if (entry.level === "error" || entry.level === "fatal") {
    console.error(output);
  } else {
    console.log(output);
  }
}

/**
 * Create a structured logger for an Edge Function
 * @param funcName - The function name (e.g., "job-worker", "create-payment")
 * @param requestId - Optional correlation ID from x-request-id header
 * @param baseContext - Optional base context to include in all logs
 */
export function createLogger(
  funcName: string,
  requestId?: string,
  baseContext: LogContext = {}
): Logger {
  const createEntry = (
    level: LogLevel,
    msg: string,
    context: LogContext = {}
  ): LogEntry => ({
    level,
    msg,
    func: funcName,
    ...(requestId && { request_id: requestId }),
    ...baseContext,
    ...context,
    ts: new Date().toISOString(),
  });

  const logger: Logger = {
    debug(msg: string, context?: LogContext): void {
      if (shouldLog("debug")) {
        writeLog(createEntry("debug", msg, context));
      }
    },

    info(msg: string, context?: LogContext): void {
      if (shouldLog("info")) {
        writeLog(createEntry("info", msg, context));
      }
    },

    warn(msg: string, context?: LogContext): void {
      if (shouldLog("warn")) {
        writeLog(createEntry("warn", msg, context));
      }
    },

    error(msg: string, error?: Error | string, context?: LogContext): void {
      if (shouldLog("error")) {
        const entry = createEntry("error", msg, context);
        if (error) {
          const { error: errMsg, stack } = formatError(error);
          entry.error = errMsg;
          if (stack) entry.stack = stack;
        }
        writeLog(entry);
      }
    },

    fatal(msg: string, error?: Error | string, context?: LogContext): void {
      if (shouldLog("fatal")) {
        const entry = createEntry("fatal", msg, context);
        if (error) {
          const { error: errMsg, stack } = formatError(error);
          entry.error = errMsg;
          if (stack) entry.stack = stack;
        }
        writeLog(entry);
      }
    },

    /**
     * Create a child logger with additional context
     */
    child(context: LogContext): Logger {
      return createLogger(funcName, requestId, { ...baseContext, ...context });
    },

    /**
     * Start a timer, returns a function that returns elapsed ms
     */
    startTimer(): () => number {
      const start = performance.now();
      return () => Math.round(performance.now() - start);
    },
  };

  return logger;
}

/**
 * Extract correlation ID from request headers
 * Checks x-request-id, x-correlation-id, and cf-ray (Cloudflare)
 */
export function getRequestId(req: Request): string {
  return (
    req.headers.get("x-request-id") ||
    req.headers.get("x-correlation-id") ||
    req.headers.get("cf-ray") ||
    crypto.randomUUID()
  );
}

/**
 * Create a logger from a Request object (convenience function)
 */
export function createLoggerFromRequest(
  funcName: string,
  req: Request
): Logger {
  const requestId = getRequestId(req);
  return createLogger(funcName, requestId, {
    method: req.method,
    url: new URL(req.url).pathname,
  });
}

/**
 * Log decorator for timing async functions
 */
export function withLogging<T>(
  log: Logger,
  operation: string,
  fn: () => Promise<T>,
  context?: LogContext
): Promise<T> {
  const elapsed = log.startTimer();

  return fn()
    .then((result) => {
      log.info(`${operation} completed`, {
        ...context,
        duration_ms: elapsed(),
      });
      return result;
    })
    .catch((error) => {
      log.error(`${operation} failed`, error, {
        ...context,
        duration_ms: elapsed(),
      });
      throw error;
    });
}
