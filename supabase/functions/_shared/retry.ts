// ==============================================================================
// RETRY UTILITIES - Exponential backoff with jitter
// ==============================================================================

export interface RetryOptions {
  maxAttempts?: number;
  baseDelayMs?: number;
  maxDelayMs?: number;
  jitter?: boolean;
  retryOn?: (error: Error) => boolean;
}

const DEFAULT_OPTIONS: Required<RetryOptions> = {
  maxAttempts: 3,
  baseDelayMs: 1000,
  maxDelayMs: 30000,
  jitter: true,
  retryOn: () => true,
};

/**
 * Sleep for a given number of milliseconds
 */
export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Calculate delay with exponential backoff and optional jitter
 */
export function calculateDelay(
  attempt: number,
  baseDelayMs: number,
  maxDelayMs: number,
  jitter: boolean
): number {
  const exponentialDelay = Math.min(
    baseDelayMs * Math.pow(2, attempt - 1),
    maxDelayMs
  );

  if (jitter) {
    // Add random jitter between 0% and 25% of the delay
    const jitterAmount = exponentialDelay * 0.25 * Math.random();
    return Math.floor(exponentialDelay + jitterAmount);
  }

  return exponentialDelay;
}

/**
 * Retry a function with exponential backoff
 */
export async function withRetry<T>(
  fn: () => Promise<T>,
  options: RetryOptions = {}
): Promise<T> {
  const opts = { ...DEFAULT_OPTIONS, ...options };
  let lastError: Error | null = null;

  for (let attempt = 1; attempt <= opts.maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastError = err as Error;

      // Check if we should retry this error
      if (!opts.retryOn(lastError)) {
        throw lastError;
      }

      // Don't wait after the last attempt
      if (attempt < opts.maxAttempts) {
        const delay = calculateDelay(
          attempt,
          opts.baseDelayMs,
          opts.maxDelayMs,
          opts.jitter
        );
        console.log(
          `[Retry] Attempt ${attempt}/${opts.maxAttempts} failed, retrying in ${delay}ms...`,
          lastError.message
        );
        await sleep(delay);
      }
    }
  }

  throw lastError;
}

/**
 * Check if an error is retryable (network errors, rate limits, etc.)
 */
export function isRetryableError(error: Error): boolean {
  const message = error.message.toLowerCase();

  // Network errors
  if (
    message.includes("network") ||
    message.includes("timeout") ||
    message.includes("connection") ||
    message.includes("econnrefused") ||
    message.includes("econnreset")
  ) {
    return true;
  }

  // Rate limits
  if (message.includes("rate limit") || message.includes("too many requests")) {
    return true;
  }

  // Stripe-specific retryable errors
  if (
    message.includes("stripe_api_error") ||
    message.includes("api_connection_error")
  ) {
    return true;
  }

  // HTTP 5xx errors
  if (/5\d{2}/.test(message)) {
    return true;
  }

  return false;
}

/**
 * Stripe-specific retry function
 */
export async function withStripeRetry<T>(fn: () => Promise<T>): Promise<T> {
  return withRetry(fn, {
    maxAttempts: 4,
    baseDelayMs: 2000,
    maxDelayMs: 16000,
    jitter: true,
    retryOn: isRetryableError,
  });
}

/**
 * Database-specific retry function
 */
export async function withDbRetry<T>(fn: () => Promise<T>): Promise<T> {
  return withRetry(fn, {
    maxAttempts: 3,
    baseDelayMs: 500,
    maxDelayMs: 5000,
    jitter: true,
    retryOn: (error) => {
      const message = error.message.toLowerCase();
      return (
        message.includes("deadlock") ||
        message.includes("lock timeout") ||
        message.includes("connection") ||
        isRetryableError(error)
      );
    },
  });
}
