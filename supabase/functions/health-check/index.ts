// ==============================================================================
// HEALTH CHECK ENDPOINT V1.0
// ==============================================================================
// Checks:
// - Database connectivity
// - Stripe API connectivity
// - Job queue health
// - Configuration validation
//
// Usage:
//   GET /functions/v1/health-check
//   GET /functions/v1/health-check?deep=true (full diagnostics)
// ==============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import Stripe from "https://esm.sh/stripe@14.21.0?target=deno";
import { createLogger } from "../_shared/logger.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-request-id, content-type",
};

interface HealthStatus {
  status: "healthy" | "degraded" | "unhealthy";
  timestamp: string;
  version: string;
  checks: {
    database: CheckResult;
    stripe: CheckResult;
    job_queue?: CheckResult;
    configuration?: CheckResult;
  };
  latency_ms: number;
}

interface CheckResult {
  status: "pass" | "warn" | "fail";
  latency_ms?: number;
  message?: string;
  details?: Record<string, unknown>;
}

async function checkDatabase(supabase: ReturnType<typeof createClient>): Promise<CheckResult> {
  const start = performance.now();
  try {
    const { data, error } = await supabase
      .from("profiles")
      .select("id")
      .limit(1);

    if (error) {
      return {
        status: "fail",
        latency_ms: Math.round(performance.now() - start),
        message: error.message,
      };
    }

    return {
      status: "pass",
      latency_ms: Math.round(performance.now() - start),
    };
  } catch (err) {
    return {
      status: "fail",
      latency_ms: Math.round(performance.now() - start),
      message: err instanceof Error ? err.message : "Unknown error",
    };
  }
}

async function checkStripe(stripe: Stripe): Promise<CheckResult> {
  const start = performance.now();
  try {
    // Use balance.retrieve as a lightweight connectivity check
    await stripe.balance.retrieve();

    return {
      status: "pass",
      latency_ms: Math.round(performance.now() - start),
    };
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unknown error";
    // Rate limit is a "warn" not "fail" - API is reachable
    if (message.includes("rate limit")) {
      return {
        status: "warn",
        latency_ms: Math.round(performance.now() - start),
        message: "Rate limited",
      };
    }
    return {
      status: "fail",
      latency_ms: Math.round(performance.now() - start),
      message,
    };
  }
}

async function checkJobQueue(supabase: ReturnType<typeof createClient>): Promise<CheckResult> {
  const start = performance.now();
  try {
    // Check for stuck jobs (processing > 30 min)
    const { data: stuckJobs, error: stuckError } = await supabase
      .from("job_queue")
      .select("id, job_type, started_at")
      .eq("status", "processing")
      .lt("started_at", new Date(Date.now() - 30 * 60 * 1000).toISOString());

    if (stuckError) {
      return {
        status: "fail",
        latency_ms: Math.round(performance.now() - start),
        message: stuckError.message,
      };
    }

    // Check failed jobs in last hour
    const { data: failedJobs, error: failedError } = await supabase
      .from("job_queue")
      .select("id")
      .eq("status", "failed")
      .gt("completed_at", new Date(Date.now() - 60 * 60 * 1000).toISOString());

    if (failedError) {
      return {
        status: "fail",
        latency_ms: Math.round(performance.now() - start),
        message: failedError.message,
      };
    }

    const stuckCount = stuckJobs?.length || 0;
    const failedCount = failedJobs?.length || 0;

    if (stuckCount > 0 || failedCount >= 10) {
      return {
        status: "warn",
        latency_ms: Math.round(performance.now() - start),
        message: `${stuckCount} stuck, ${failedCount} failed in last hour`,
        details: { stuck_jobs: stuckCount, failed_jobs_1h: failedCount },
      };
    }

    return {
      status: "pass",
      latency_ms: Math.round(performance.now() - start),
      details: { failed_jobs_1h: failedCount },
    };
  } catch (err) {
    return {
      status: "fail",
      latency_ms: Math.round(performance.now() - start),
      message: err instanceof Error ? err.message : "Unknown error",
    };
  }
}

async function checkConfiguration(supabase: ReturnType<typeof createClient>): Promise<CheckResult> {
  const start = performance.now();
  try {
    const { data, error } = await supabase.rpc("validate_cron_configuration");

    if (error) {
      return {
        status: "fail",
        latency_ms: Math.round(performance.now() - start),
        message: error.message,
      };
    }

    const issues = data?.filter((r: { issue: string }) => r.issue !== "OK") || [];

    if (issues.length > 0) {
      return {
        status: "warn",
        latency_ms: Math.round(performance.now() - start),
        message: `${issues.length} configuration issue(s)`,
        details: { issues: issues.map((i: { setting_name: string; issue: string }) => i.setting_name) },
      };
    }

    return {
      status: "pass",
      latency_ms: Math.round(performance.now() - start),
    };
  } catch (err) {
    return {
      status: "fail",
      latency_ms: Math.round(performance.now() - start),
      message: err instanceof Error ? err.message : "Unknown error",
    };
  }
}

function determineOverallStatus(checks: HealthStatus["checks"]): "healthy" | "degraded" | "unhealthy" {
  const results = Object.values(checks).filter(Boolean);

  if (results.some((r) => r.status === "fail")) {
    return "unhealthy";
  }
  if (results.some((r) => r.status === "warn")) {
    return "degraded";
  }
  return "healthy";
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const log = createLogger("health-check");
  const startTime = performance.now();

  try {
    const url = new URL(req.url);
    const deepCheck = url.searchParams.get("deep") === "true";

    // Initialize clients
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY")!;

    const supabase = createClient(supabaseUrl, supabaseServiceKey);
    const stripe = new Stripe(stripeSecretKey, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    // Run checks in parallel
    const [dbResult, stripeResult] = await Promise.all([
      checkDatabase(supabase),
      checkStripe(stripe),
    ]);

    const checks: HealthStatus["checks"] = {
      database: dbResult,
      stripe: stripeResult,
    };

    // Deep check includes job queue and configuration
    if (deepCheck) {
      const [jobQueueResult, configResult] = await Promise.all([
        checkJobQueue(supabase),
        checkConfiguration(supabase),
      ]);
      checks.job_queue = jobQueueResult;
      checks.configuration = configResult;
    }

    const status = determineOverallStatus(checks);
    const latency = Math.round(performance.now() - startTime);

    const health: HealthStatus = {
      status,
      timestamp: new Date().toISOString(),
      version: "1.0.0",
      checks,
      latency_ms: latency,
    };

    log.info("Health check completed", {
      status,
      latency_ms: latency,
      deep: deepCheck,
    });

    // Return 200 for healthy/degraded, 503 for unhealthy
    const httpStatus = status === "unhealthy" ? 503 : 200;

    return new Response(JSON.stringify(health), {
      status: httpStatus,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json",
        "Cache-Control": "no-cache, no-store, must-revalidate",
      },
    });
  } catch (err) {
    log.error("Health check failed", err instanceof Error ? err : new Error(String(err)));

    return new Response(
      JSON.stringify({
        status: "unhealthy",
        timestamp: new Date().toISOString(),
        version: "1.0.0",
        checks: {},
        latency_ms: Math.round(performance.now() - startTime),
        error: err instanceof Error ? err.message : "Unknown error",
      }),
      {
        status: 503,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
        },
      }
    );
  }
});
