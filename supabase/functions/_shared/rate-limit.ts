// ==============================================================================
// RATE LIMIT UTILITIES - Rate limiting with standard headers
// ==============================================================================
// Implements RFC 6585 rate limit headers:
// - X-RateLimit-Limit: max requests per window
// - X-RateLimit-Remaining: requests left in current window
// - X-RateLimit-Reset: Unix timestamp when window resets
// - Retry-After: seconds until rate limit resets (on 429)
// ==============================================================================

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

export interface RateLimitConfig {
  maxRequests: number;       // Maximum requests per window
  windowSeconds: number;     // Window duration in seconds
  keyPrefix?: string;        // Optional prefix for rate limit key
}

export interface RateLimitResult {
  allowed: boolean;
  limit: number;
  remaining: number;
  reset: number;             // Unix timestamp
  retryAfter?: number;       // Seconds until reset (only if blocked)
}

export interface RateLimitHeaders {
  "X-RateLimit-Limit": string;
  "X-RateLimit-Remaining": string;
  "X-RateLimit-Reset": string;
  "Retry-After"?: string;
}

/**
 * Default rate limit configurations
 */
export const RateLimits = {
  // Standard API endpoints
  standard: { maxRequests: 100, windowSeconds: 60 } as RateLimitConfig,

  // Authentication endpoints (stricter)
  auth: { maxRequests: 10, windowSeconds: 60 } as RateLimitConfig,

  // Payment endpoints (even stricter)
  payment: { maxRequests: 20, windowSeconds: 60 } as RateLimitConfig,

  // Webhook endpoints (more lenient)
  webhook: { maxRequests: 500, windowSeconds: 60 } as RateLimitConfig,

  // Search/listing endpoints
  search: { maxRequests: 60, windowSeconds: 60 } as RateLimitConfig,
};

/**
 * Check rate limit using database
 * Uses the existing rate_limits table in the schema
 */
export async function checkRateLimit(
  supabase: SupabaseClient,
  key: string,
  config: RateLimitConfig
): Promise<RateLimitResult> {
  const now = new Date();
  const windowStart = new Date(now.getTime() - config.windowSeconds * 1000);
  const resetTime = Math.floor(now.getTime() / 1000) + config.windowSeconds;

  // Use the RPC function if available, otherwise direct query
  const { data, error } = await supabase.rpc("check_rate_limit", {
    p_key: config.keyPrefix ? `${config.keyPrefix}:${key}` : key,
    p_limit: config.maxRequests,
    p_window_seconds: config.windowSeconds,
  });

  if (error) {
    // Fallback: allow request if rate limit check fails (fail open)
    console.error("[RateLimit] Check failed:", error.message);
    return {
      allowed: true,
      limit: config.maxRequests,
      remaining: config.maxRequests - 1,
      reset: resetTime,
    };
  }

  // RPC returns: { allowed: boolean, current_count: number }
  const allowed = data?.allowed ?? true;
  const currentCount = data?.current_count ?? 0;
  const remaining = Math.max(0, config.maxRequests - currentCount);

  return {
    allowed,
    limit: config.maxRequests,
    remaining: allowed ? remaining : 0,
    reset: resetTime,
    retryAfter: allowed ? undefined : config.windowSeconds,
  };
}

/**
 * Build rate limit headers from result
 */
export function buildRateLimitHeaders(result: RateLimitResult): RateLimitHeaders {
  const headers: RateLimitHeaders = {
    "X-RateLimit-Limit": result.limit.toString(),
    "X-RateLimit-Remaining": result.remaining.toString(),
    "X-RateLimit-Reset": result.reset.toString(),
  };

  if (result.retryAfter !== undefined) {
    headers["Retry-After"] = result.retryAfter.toString();
  }

  return headers;
}

/**
 * Create a rate-limited response (429 Too Many Requests)
 */
export function rateLimitedResponse(
  result: RateLimitResult,
  message = "Too many requests"
): Response {
  return new Response(
    JSON.stringify({
      success: false,
      error: {
        code: "RATE_LIMITED",
        message,
        retry_after: result.retryAfter,
      },
    }),
    {
      status: 429,
      headers: {
        "Content-Type": "application/json",
        ...buildRateLimitHeaders(result),
      },
    }
  );
}

/**
 * Add rate limit headers to an existing response
 */
export function addRateLimitHeaders(
  response: Response,
  result: RateLimitResult
): Response {
  const headers = new Headers(response.headers);
  const rateLimitHeaders = buildRateLimitHeaders(result);

  Object.entries(rateLimitHeaders).forEach(([key, value]) => {
    headers.set(key, value);
  });

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

/**
 * Rate limit middleware wrapper
 * Wraps a handler with rate limiting
 */
export function withRateLimit(
  handler: (req: Request) => Promise<Response>,
  config: RateLimitConfig,
  getKey: (req: Request) => string = getDefaultKey
): (req: Request) => Promise<Response> {
  return async (req: Request) => {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const key = getKey(req);
    const result = await checkRateLimit(supabase, key, config);

    if (!result.allowed) {
      return rateLimitedResponse(result);
    }

    const response = await handler(req);
    return addRateLimitHeaders(response, result);
  };
}

/**
 * Default key extraction: IP address or user ID from JWT
 */
function getDefaultKey(req: Request): string {
  // Try to get user ID from Authorization header
  const authHeader = req.headers.get("Authorization");
  if (authHeader?.startsWith("Bearer ")) {
    try {
      const token = authHeader.substring(7);
      const payload = JSON.parse(atob(token.split(".")[1]));
      if (payload.sub) {
        return `user:${payload.sub}`;
      }
    } catch {
      // Ignore JWT parsing errors
    }
  }

  // Fall back to IP address
  const ip =
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ||
    req.headers.get("x-real-ip") ||
    req.headers.get("cf-connecting-ip") ||
    "unknown";

  return `ip:${ip}`;
}

/**
 * Get rate limit key for a specific user
 */
export function userRateLimitKey(userId: string): string {
  return `user:${userId}`;
}

/**
 * Get rate limit key for an IP address
 */
export function ipRateLimitKey(ip: string): string {
  return `ip:${ip}`;
}

/**
 * Get rate limit key for a specific action
 */
export function actionRateLimitKey(userId: string, action: string): string {
  return `action:${userId}:${action}`;
}
