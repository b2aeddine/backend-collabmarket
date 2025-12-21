// ==============================================================================
// JOB-WORKER - V1.1 (SCHEMA V40 ALIGNED)
// Background job processor for async tasks
// SECURITY: Uses CRON_SECRET, atomic RPCs for job lifecycle
// RELIABILITY: Timeout protection (50s default), full webhook processing
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
 * Handles Stripe webhook events that require order/payment state updates
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

  console.log(`[Job] Processing webhook: ${eventType} (${eventId})`);

  // Extract the object from the event data
  const stripeObject = eventData?.object as Record<string, unknown> | undefined;
  if (!stripeObject) {
    console.warn(`[Job] No object in webhook data for ${eventType}`);
    return;
  }

  switch (eventType) {
    // =========================================================================
    // PAYMENT INTENT EVENTS
    // =========================================================================
    case "payment_intent.amount_capturable_updated": {
      // Payment authorized - update order status
      const orderId = stripeObject.metadata?.order_id as string;
      if (orderId) {
        const { error } = await supabase
          .from("orders")
          .update({
            status: "payment_authorized",
            stripe_payment_status: "authorized",
          })
          .eq("id", orderId)
          .eq("status", "pending");

        if (error) {
          console.warn(`[Job] Failed to update order ${orderId} to authorized:`, error.message);
        } else {
          console.log(`[Job] Order ${orderId} marked as payment_authorized`);
        }
      }
      break;
    }

    case "payment_intent.succeeded": {
      // Payment captured successfully
      const orderId = stripeObject.metadata?.order_id as string;
      if (orderId) {
        const { error } = await supabase
          .from("orders")
          .update({
            stripe_payment_status: "captured",
          })
          .eq("id", orderId);

        if (!error) {
          console.log(`[Job] Order ${orderId} payment captured`);
        }
      }
      break;
    }

    case "payment_intent.payment_failed": {
      const orderId = stripeObject.metadata?.order_id as string;
      if (orderId) {
        const { error } = await supabase
          .from("orders")
          .update({
            stripe_payment_status: "failed",
          })
          .eq("id", orderId);

        if (!error) {
          console.log(`[Job] Order ${orderId} payment failed`);
        }
      }
      break;
    }

    case "payment_intent.canceled": {
      const orderId = stripeObject.metadata?.order_id as string;
      if (orderId) {
        // Payment cancelled - void the authorization
        const { error } = await supabase
          .from("orders")
          .update({
            status: "cancelled",
            stripe_payment_status: "failed",
            cancelled_at: new Date().toISOString(),
          })
          .eq("id", orderId)
          .in("status", ["pending", "payment_authorized"]);

        if (!error) {
          console.log(`[Job] Order ${orderId} cancelled due to payment cancellation`);
        }
      }
      break;
    }

    // =========================================================================
    // REFUND EVENTS
    // =========================================================================
    case "charge.refunded": {
      const paymentIntentId = stripeObject.payment_intent as string;
      if (paymentIntentId) {
        // Find order by payment intent and update status
        const { data: order } = await supabase
          .from("orders")
          .select("id, status")
          .eq("stripe_payment_intent_id", paymentIntentId)
          .single();

        if (order) {
          // Reverse commissions if order was completed
          if (order.status === "completed") {
            await supabase.rpc("enqueue_job", {
              p_job_type: "reverse_commissions",
              p_payload: { order_id: order.id, reason: "Refund processed" },
              p_priority: 10,
            });
          }

          // Update order status
          await supabase
            .from("orders")
            .update({
              status: "refunded",
              stripe_payment_status: "refunded",
            })
            .eq("id", order.id);

          console.log(`[Job] Order ${order.id} marked as refunded, commissions reversal queued`);
        }
      }
      break;
    }

    // =========================================================================
    // DISPUTE EVENTS
    // =========================================================================
    case "charge.dispute.created": {
      const paymentIntentId = stripeObject.payment_intent as string;
      if (paymentIntentId) {
        const { data: order } = await supabase
          .from("orders")
          .select("id")
          .eq("stripe_payment_intent_id", paymentIntentId)
          .single();

        if (order) {
          await supabase
            .from("orders")
            .update({ status: "disputed" })
            .eq("id", order.id);

          console.log(`[Job] Order ${order.id} marked as disputed`);

          // Create alert for dispute
          await supabase.rpc("create_alert", {
            p_alert_type: "stripe_error",
            p_severity: "critical",
            p_title: "Payment dispute created",
            p_message: `Dispute opened for order ${order.id}`,
            p_context: { order_id: order.id, dispute_id: stripeObject.id },
          });
        }
      }
      break;
    }

    // =========================================================================
    // PAYOUT EVENTS (Withdrawal completion)
    // =========================================================================
    case "payout.paid": {
      const withdrawalId = stripeObject.metadata?.withdrawal_id as string;
      if (withdrawalId) {
        const { error } = await supabase.rpc("confirm_withdrawal_success", {
          p_withdrawal_id: withdrawalId,
          p_payout_id: stripeObject.id as string,
        });

        if (error) {
          console.error(`[Job] Failed to confirm withdrawal ${withdrawalId}:`, error.message);
          throw new Error(`confirm_withdrawal_success failed: ${error.message}`);
        }

        console.log(`[Job] Withdrawal ${withdrawalId} confirmed as paid`);
      }
      break;
    }

    case "payout.failed": {
      const withdrawalId = stripeObject.metadata?.withdrawal_id as string;
      if (withdrawalId) {
        const failureMessage = (stripeObject.failure_message as string) || "Payout failed";

        const { error } = await supabase.rpc("confirm_withdrawal_failure", {
          p_withdrawal_id: withdrawalId,
          p_reason: failureMessage,
        });

        if (!error) {
          console.log(`[Job] Withdrawal ${withdrawalId} marked as failed: ${failureMessage}`);
        }
      }
      break;
    }

    // =========================================================================
    // CONNECT ACCOUNT EVENTS
    // =========================================================================
    case "account.updated": {
      const accountId = stripeObject.id as string;
      const chargesEnabled = stripeObject.charges_enabled as boolean;
      const payoutsEnabled = stripeObject.payouts_enabled as boolean;

      // Update user profile with onboarding status
      const { error } = await supabase
        .from("profiles")
        .update({
          stripe_onboarding_completed: chargesEnabled && payoutsEnabled,
          updated_at: new Date().toISOString(),
        })
        .eq("stripe_account_id", accountId);

      if (!error) {
        console.log(`[Job] Profile updated for Stripe account ${accountId}: charges=${chargesEnabled}, payouts=${payoutsEnabled}`);
      }
      break;
    }

    // =========================================================================
    // INVOICE EVENTS
    // =========================================================================
    case "invoice.payment_succeeded":
    case "invoice.payment_failed":
      console.log(`[Job] Invoice event processed: ${eventType}`);
      break;

    default:
      console.log(`[Job] Unhandled webhook type: ${eventType}`);
  }

  // Log processing completion
  await supabase.from("system_logs").insert({
    event_type: "webhook_processed",
    message: `Webhook processed: ${eventType}`,
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

// Edge Function timeout safety margin (stop processing before we hit the 60s limit)
const MAX_EXECUTION_TIME_MS = 50000; // 50 seconds

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return handleCorsOptions();
  }

  const workerStartTime = Date.now();

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
    let timeoutMs = MAX_EXECUTION_TIME_MS;

    try {
      const body = await req.json();
      if (body.max_jobs && typeof body.max_jobs === "number") {
        maxJobs = Math.min(body.max_jobs, 50); // Cap at 50
      }
      if (body.job_types && Array.isArray(body.job_types)) {
        jobTypes = body.job_types;
      }
      if (body.timeout_ms && typeof body.timeout_ms === "number") {
        timeoutMs = Math.min(body.timeout_ms, MAX_EXECUTION_TIME_MS);
      }
    } catch {
      // No body or invalid JSON, use defaults
    }

    const results: JobResult[] = [];
    let processedCount = 0;
    let stoppedDueToTimeout = false;

    // Process jobs in a loop with timeout protection
    while (processedCount < maxJobs) {
      // TIMEOUT CHECK: Stop processing if we're approaching the Edge Function timeout
      const elapsedMs = Date.now() - workerStartTime;
      if (elapsedMs > timeoutMs) {
        console.log(`[Job Worker] Stopping due to timeout (${elapsedMs}ms elapsed, limit: ${timeoutMs}ms)`);
        stoppedDueToTimeout = true;
        break;
      }
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
    // Calculate elapsed time
    const totalElapsedMs = Date.now() - workerStartTime;

    if (results.length > 0) {
      await supabase.from("system_logs").insert({
        event_type: "job_worker",
        message: stoppedDueToTimeout ? "Job processing stopped due to timeout" : "Job processing cycle completed",
        details: {
          processed: results.length,
          success: successCount,
          failed: failCount,
          total_duration_ms: totalDuration,
          avg_duration_ms: Math.round(totalDuration / results.length),
          elapsed_ms: totalElapsedMs,
          stopped_due_to_timeout: stoppedDueToTimeout,
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
        elapsed_ms: totalElapsedMs,
        stopped_due_to_timeout: stoppedDueToTimeout,
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
