// ==============================================================================
// JOB-WORKER - V1.0 (SCHEMA V40 ALIGNED)
// Background job processor for async tasks
// SECURITY: Uses CRON_SECRET, atomic RPCs for job lifecycle
// JOB TYPES: distribute_commissions, reverse_commissions, send_notification,
//            sync_analytics, process_webhook, cleanup_data, release_revenues
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, handleCorsOptions } from "../shared/utils/cors.ts";
import { verifyCronSecret } from "../shared/utils/auth.ts";
import { alert } from "../_shared/alerting.ts";
import { withDbRetry } from "../_shared/retry.ts";

// Job record from job_queue table
interface JobRecord {
  id: string;
  job_type: string;
  payload: Record<string, unknown>;
  priority: number;
  status: string;
  attempts: number;
  max_attempts: number;
  last_error: string | null;
  scheduled_at: string;
  started_at: string | null;
  completed_at: string | null;
  created_at: string;
}

interface JobResult {
  jobId: string;
  jobType: string;
  success: boolean;
  error?: string;
  duration?: number;
}

// Job handlers map
type JobHandler = (
  supabase: SupabaseClient,
  payload: Record<string, unknown>
) => Promise<void>;

const JOB_HANDLERS: Record<string, JobHandler> = {
  distribute_commissions: handleDistributeCommissions,
  reverse_commissions: handleReverseCommissions,
  send_notification: handleSendNotification,
  sync_analytics: handleSyncAnalytics,
  process_webhook: handleProcessWebhook,
  cleanup_data: handleCleanupData,
  release_revenues: handleReleaseRevenues,
};

// ==============================================================================
// JOB HANDLERS
// ==============================================================================

/**
 * Distribute commissions for a completed order
 */
async function handleDistributeCommissions(
  supabase: SupabaseClient,
  payload: Record<string, unknown>
): Promise<void> {
  const orderId = payload.order_id as string;
  if (!orderId) {
    throw new Error("Missing order_id in payload");
  }

  const { error } = await supabase.rpc("distribute_commissions", {
    p_order_id: orderId,
  });

  if (error) {
    throw new Error(`distribute_commissions failed: ${error.message}`);
  }

  console.log(`[Job] Distributed commissions for order ${orderId}`);
}

/**
 * Reverse commissions for a cancelled/refunded order
 */
async function handleReverseCommissions(
  supabase: SupabaseClient,
  payload: Record<string, unknown>
): Promise<void> {
  const orderId = payload.order_id as string;
  const reason = (payload.reason as string) || "Order cancelled";

  if (!orderId) {
    throw new Error("Missing order_id in payload");
  }

  const { error } = await supabase.rpc("reverse_commissions", {
    p_order_id: orderId,
    p_reason: reason,
  });

  if (error) {
    throw new Error(`reverse_commissions failed: ${error.message}`);
  }

  console.log(`[Job] Reversed commissions for order ${orderId}`);
}

/**
 * Send notification to a user
 */
async function handleSendNotification(
  supabase: SupabaseClient,
  payload: Record<string, unknown>
): Promise<void> {
  const userId = payload.user_id as string;
  const notificationType = payload.type as string;
  const title = payload.title as string;
  const message = payload.message as string;
  const data = payload.data as Record<string, unknown> | undefined;

  if (!userId || !notificationType || !title) {
    throw new Error("Missing required fields: user_id, type, title");
  }

  const { error } = await supabase.from("notifications").insert({
    user_id: userId,
    type: notificationType,
    title,
    message: message || null,
    data: data || {},
    is_read: false,
  });

  if (error) {
    throw new Error(`Failed to create notification: ${error.message}`);
  }

  console.log(`[Job] Created notification for user ${userId}: ${title}`);

  // TODO: Add push notification via FCM/APNs if configured
  // TODO: Add email notification if user preferences allow
}

/**
 * Sync analytics data (e.g., aggregate daily stats)
 */
async function handleSyncAnalytics(
  supabase: SupabaseClient,
  payload: Record<string, unknown>
): Promise<void> {
  const targetDate = payload.date as string | undefined;

  // If no date specified, use yesterday
  const date = targetDate || new Date(Date.now() - 86400000).toISOString().split("T")[0];

  const { error } = await supabase.rpc("aggregate_daily_stats", {
    p_date: date,
  });

  if (error) {
    throw new Error(`aggregate_daily_stats failed: ${error.message}`);
  }

  console.log(`[Job] Synced analytics for date ${date}`);
}

/**
 * Process a webhook event (deferred processing)
 */
async function handleProcessWebhook(
  supabase: SupabaseClient,
  payload: Record<string, unknown>
): Promise<void> {
  const eventId = payload.event_id as string;
  const eventType = payload.event_type as string;
  const eventData = payload.data as Record<string, unknown>;

  if (!eventId || !eventType) {
    throw new Error("Missing event_id or event_type in payload");
  }

  // Log the deferred processing
  console.log(`[Job] Processing deferred webhook: ${eventType} (${eventId})`);

  // The actual processing logic depends on the event type
  // This is a placeholder for custom webhook handling
  switch (eventType) {
    case "invoice.payment_succeeded":
    case "invoice.payment_failed":
      // Handle invoice events
      console.log(`[Job] Invoice event processed: ${eventType}`);
      break;

    case "account.updated":
      // Handle Connect account updates
      console.log(`[Job] Account update processed`);
      break;

    default:
      console.log(`[Job] Unhandled webhook type: ${eventType}`);
  }

  // Mark as processed in system log
  await supabase.from("system_logs").insert({
    event_type: "webhook_processed",
    message: `Deferred webhook processed: ${eventType}`,
    details: { event_id: eventId, event_type: eventType },
  });
}

/**
 * Cleanup old data (logs, expired sessions, etc.)
 */
async function handleCleanupData(
  supabase: SupabaseClient,
  payload: Record<string, unknown>
): Promise<void> {
  const cleanupType = payload.type as string || "all";

  const { data, error } = await supabase.rpc("cleanup_old_data");

  if (error) {
    throw new Error(`cleanup_old_data failed: ${error.message}`);
  }

  console.log(`[Job] Cleanup completed:`, data);
}

/**
 * Release revenues for a specific order (make them available for withdrawal)
 */
async function handleReleaseRevenues(
  supabase: SupabaseClient,
  payload: Record<string, unknown>
): Promise<void> {
  const orderId = payload.order_id as string;

  if (!orderId) {
    throw new Error("Missing order_id in payload");
  }

  // Update seller_revenues and agent_revenues to 'available' status
  const { error: sellerError } = await supabase
    .from("seller_revenues")
    .update({
      status: "available",
      available_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq("order_id", orderId)
    .eq("status", "pending");

  if (sellerError) {
    console.warn(`[Job] Failed to release seller revenues: ${sellerError.message}`);
  }

  const { error: agentError } = await supabase
    .from("agent_revenues")
    .update({
      status: "available",
      available_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq("order_id", orderId)
    .eq("status", "pending");

  if (agentError) {
    console.warn(`[Job] Failed to release agent revenues: ${agentError.message}`);
  }

  console.log(`[Job] Released revenues for order ${orderId}`);
}

// ==============================================================================
// MAIN HANDLER
// ==============================================================================

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return handleCorsOptions();
  }

  try {
    // SECURITY: Verify cron secret
    const authError = verifyCronSecret(req);
    if (authError) {
      console.warn("[Job Worker] Unauthorized access attempt");
      return authError;
    }

    console.log("[Job Worker] Starting job processing cycle...");

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Parse optional parameters
    let maxJobs = 10; // Default batch size
    let jobTypes: string[] | null = null;

    try {
      const body = await req.json();
      if (body.max_jobs && typeof body.max_jobs === "number") {
        maxJobs = Math.min(body.max_jobs, 50); // Cap at 50
      }
      if (body.job_types && Array.isArray(body.job_types)) {
        jobTypes = body.job_types;
      }
    } catch {
      // No body or invalid JSON, use defaults
    }

    const results: JobResult[] = [];
    let processedCount = 0;

    // Process jobs in a loop
    while (processedCount < maxJobs) {
      // Claim next job using atomic RPC
      const { data: job, error: claimError } = await withDbRetry(() =>
        supabase.rpc("claim_next_job", {
          p_job_types: jobTypes,
        })
      );

      if (claimError) {
        console.error("[Job Worker] Failed to claim job:", claimError.message);
        break;
      }

      // No more jobs available
      if (!job) {
        console.log("[Job Worker] No more pending jobs");
        break;
      }

      const jobRecord = job as JobRecord;
      const startTime = Date.now();

      console.log(`[Job Worker] Processing job ${jobRecord.id} (${jobRecord.job_type})`);

      try {
        // Get handler for this job type
        const handler = JOB_HANDLERS[jobRecord.job_type];

        if (!handler) {
          throw new Error(`Unknown job type: ${jobRecord.job_type}`);
        }

        // Execute the job
        await handler(supabase, jobRecord.payload);

        // Mark as completed
        await supabase.rpc("complete_job", {
          p_job_id: jobRecord.id,
          p_success: true,
          p_error: null,
        });

        const duration = Date.now() - startTime;
        results.push({
          jobId: jobRecord.id,
          jobType: jobRecord.job_type,
          success: true,
          duration,
        });

        console.log(`[Job Worker] Job ${jobRecord.id} completed in ${duration}ms`);

      } catch (jobError: unknown) {
        const err = jobError as Error;
        const duration = Date.now() - startTime;

        console.error(`[Job Worker] Job ${jobRecord.id} failed:`, err.message);

        // Mark as failed (will retry if attempts < max_attempts)
        await supabase.rpc("complete_job", {
          p_job_id: jobRecord.id,
          p_success: false,
          p_error: err.message,
        });

        results.push({
          jobId: jobRecord.id,
          jobType: jobRecord.job_type,
          success: false,
          error: err.message,
          duration,
        });

        // Alert on repeated failures
        if (jobRecord.attempts >= jobRecord.max_attempts - 1) {
          await alert(
            supabase,
            "job_failed",
            "error",
            `Job failed after ${jobRecord.attempts + 1} attempts: ${jobRecord.job_type}`,
            err.message,
            {
              job_id: jobRecord.id,
              job_type: jobRecord.job_type,
              payload: jobRecord.payload,
            }
          );
        }
      }

      processedCount++;
    }

    // Stats
    const successCount = results.filter((r) => r.success).length;
    const failCount = results.filter((r) => !r.success).length;
    const totalDuration = results.reduce((sum, r) => sum + (r.duration || 0), 0);

    // Log processing cycle
    if (results.length > 0) {
      await supabase.from("system_logs").insert({
        event_type: "job_worker",
        message: "Job processing cycle completed",
        details: {
          processed: results.length,
          success: successCount,
          failed: failCount,
          total_duration_ms: totalDuration,
          avg_duration_ms: Math.round(totalDuration / results.length),
        },
      });
    }

    return new Response(
      JSON.stringify({
        success: true,
        processed: results.length,
        successful: successCount,
        failed: failCount,
        total_duration_ms: totalDuration,
        results,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      }
    );

  } catch (error: unknown) {
    const err = error as Error;
    console.error("[Job Worker Error]:", err);

    return new Response(
      JSON.stringify({
        success: false,
        error: err.message,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 500,
      }
    );
  }
});
