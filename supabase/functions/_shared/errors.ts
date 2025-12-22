// ==============================================================================
// ERROR CLASSES - Standardized error handling for Edge Functions
// ==============================================================================
// Usage:
//   throw new AppError("INVALID_INPUT", "Email is required", 400);
//   throw new SystemError("DATABASE_ERROR", "Connection failed", originalError);
//
// In handler:
//   catch (error) {
//     return handleError(error, log);
//   }
// ==============================================================================

import { Logger } from "./logger.ts";

export type ErrorCode =
  // Client errors (4xx)
  | "INVALID_INPUT"
  | "MISSING_FIELD"
  | "UNAUTHORIZED"
  | "FORBIDDEN"
  | "NOT_FOUND"
  | "CONFLICT"
  | "RATE_LIMITED"
  | "PAYMENT_REQUIRED"
  | "VALIDATION_FAILED"
  // Business logic errors
  | "INSUFFICIENT_FUNDS"
  | "ORDER_NOT_COMPLETABLE"
  | "ALREADY_PROCESSED"
  | "INVALID_STATE_TRANSITION"
  | "KYC_REQUIRED"
  | "STRIPE_NOT_CONNECTED"
  // System errors (5xx)
  | "DATABASE_ERROR"
  | "STRIPE_ERROR"
  | "EXTERNAL_SERVICE_ERROR"
  | "INTERNAL_ERROR"
  | "TIMEOUT"
  | "CONFIGURATION_ERROR";

export interface ErrorDetails {
  [key: string]: unknown;
}

/**
 * Application Error - Client-facing errors with structured response
 * Use for validation errors, business logic errors, and expected failures
 */
export class AppError extends Error {
  public readonly code: ErrorCode;
  public readonly statusCode: number;
  public readonly details?: ErrorDetails;
  public readonly isOperational = true; // Safe to expose to client

  constructor(
    code: ErrorCode,
    message: string,
    statusCode = 400,
    details?: ErrorDetails
  ) {
    super(message);
    this.name = "AppError";
    this.code = code;
    this.statusCode = statusCode;
    this.details = details;

    // Capture stack trace
    Error.captureStackTrace?.(this, AppError);
  }

  /**
   * Convert to JSON response body
   */
  toJSON(): { success: false; error: { code: ErrorCode; message: string; details?: ErrorDetails } } {
    return {
      success: false,
      error: {
        code: this.code,
        message: this.message,
        ...(this.details && { details: this.details }),
      },
    };
  }

  /**
   * Convert to Response object
   */
  toResponse(): Response {
    return new Response(JSON.stringify(this.toJSON()), {
      status: this.statusCode,
      headers: { "Content-Type": "application/json" },
    });
  }
}

/**
 * System Error - Internal errors that should be logged but not exposed to client
 * Use for database errors, external service failures, and unexpected errors
 */
export class SystemError extends Error {
  public readonly code: ErrorCode;
  public readonly originalError?: Error;
  public readonly context?: ErrorDetails;
  public readonly isOperational = false; // Not safe to expose details

  constructor(
    code: ErrorCode,
    message: string,
    originalError?: Error,
    context?: ErrorDetails
  ) {
    super(message);
    this.name = "SystemError";
    this.code = code;
    this.originalError = originalError;
    this.context = context;

    Error.captureStackTrace?.(this, SystemError);
  }

  /**
   * Convert to safe client response (hides internal details)
   */
  toResponse(): Response {
    return new Response(
      JSON.stringify({
        success: false,
        error: {
          code: this.code,
          message: "An internal error occurred. Please try again later.",
        },
      }),
      {
        status: 500,
        headers: { "Content-Type": "application/json" },
      }
    );
  }
}

/**
 * Common error factory functions
 */
export const Errors = {
  // 400 Bad Request
  invalidInput: (message: string, details?: ErrorDetails) =>
    new AppError("INVALID_INPUT", message, 400, details),

  missingField: (field: string) =>
    new AppError("MISSING_FIELD", `Missing required field: ${field}`, 400, { field }),

  validationFailed: (message: string, details?: ErrorDetails) =>
    new AppError("VALIDATION_FAILED", message, 400, details),

  // 401 Unauthorized
  unauthorized: (message = "Authentication required") =>
    new AppError("UNAUTHORIZED", message, 401),

  // 403 Forbidden
  forbidden: (message = "Access denied") =>
    new AppError("FORBIDDEN", message, 403),

  kycRequired: () =>
    new AppError("KYC_REQUIRED", "KYC verification required for this action", 403),

  stripeNotConnected: () =>
    new AppError("STRIPE_NOT_CONNECTED", "Stripe account not connected or onboarding incomplete", 403),

  // 404 Not Found
  notFound: (resource: string, id?: string) =>
    new AppError("NOT_FOUND", `${resource} not found${id ? `: ${id}` : ""}`, 404, id ? { id } : undefined),

  // 409 Conflict
  conflict: (message: string, details?: ErrorDetails) =>
    new AppError("CONFLICT", message, 409, details),

  alreadyProcessed: (resource: string) =>
    new AppError("ALREADY_PROCESSED", `${resource} has already been processed`, 409),

  invalidStateTransition: (from: string, to: string) =>
    new AppError("INVALID_STATE_TRANSITION", `Cannot transition from ${from} to ${to}`, 409, { from, to }),

  // 402 Payment Required
  insufficientFunds: (required: number, available: number) =>
    new AppError("INSUFFICIENT_FUNDS", "Insufficient funds for this operation", 402, { required, available }),

  // 429 Rate Limited
  rateLimited: (retryAfter?: number) =>
    new AppError("RATE_LIMITED", "Too many requests", 429, retryAfter ? { retry_after: retryAfter } : undefined),

  // 500 Internal Server Error
  database: (message: string, originalError?: Error) =>
    new SystemError("DATABASE_ERROR", message, originalError),

  stripe: (message: string, originalError?: Error, context?: ErrorDetails) =>
    new SystemError("STRIPE_ERROR", message, originalError, context),

  internal: (message: string, originalError?: Error) =>
    new SystemError("INTERNAL_ERROR", message, originalError),

  timeout: (operation: string) =>
    new SystemError("TIMEOUT", `Operation timed out: ${operation}`),

  configuration: (message: string) =>
    new SystemError("CONFIGURATION_ERROR", message),
};

/**
 * Global error handler for Edge Functions
 * Logs error and returns appropriate response
 */
export function handleError(error: unknown, log?: Logger): Response {
  // AppError - Client-safe, log as warning
  if (error instanceof AppError) {
    log?.warn("Application error", {
      code: error.code,
      message: error.message,
      details: error.details,
    });
    return error.toResponse();
  }

  // SystemError - Log full details, return safe response
  if (error instanceof SystemError) {
    log?.error("System error", error.originalError || error, {
      code: error.code,
      context: error.context,
    });
    return error.toResponse();
  }

  // Unknown error - Log and return generic response
  const unknownError = error instanceof Error ? error : new Error(String(error));
  log?.fatal("Unhandled error", unknownError);

  return new Response(
    JSON.stringify({
      success: false,
      error: {
        code: "INTERNAL_ERROR",
        message: "An unexpected error occurred",
      },
    }),
    {
      status: 500,
      headers: { "Content-Type": "application/json" },
    }
  );
}

/**
 * Wrap an async handler with error handling
 */
export function withErrorHandler(
  handler: (req: Request, log: Logger) => Promise<Response>,
  funcName: string
): (req: Request) => Promise<Response> {
  return async (req: Request) => {
    const { createLoggerFromRequest } = await import("./logger.ts");
    const log = createLoggerFromRequest(funcName, req);

    try {
      return await handler(req, log);
    } catch (error) {
      return handleError(error, log);
    }
  };
}
