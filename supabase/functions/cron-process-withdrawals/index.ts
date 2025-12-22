// ==============================================================================
// CRON-PROCESS-WITHDRAWALS - V15.2 (PARALLELIZED + STRUCTURED LOGGING)
// Processes pending withdrawals via Stripe Transfer + Payout
// SECURITY: Uses CRON_SECRET, atomic RPCs for status transitions
// RELIABILITY: Stripe idempotency keys, row-level locking, parallel processing
// PERFORMANCE: Processes up to 5 withdrawals concurrently (configurable)
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, handleCorsOptions } from "../shared/utils/cors.ts";
import { verifyCronSecret } from "../shared/utils/auth.ts";
import { createLogger, getRequestId, Logger } from "../_shared/logger.ts";

// Concurrency limit for parallel processing
const CONCURRENCY_LIMIT = 5;
const BATCH_SIZE = 50;

interface WithdrawalRecord {
  id: string;
  user_id: string;
  amount: number;
  status: string;
  stripe_transfer_id: string | null;
  profiles: {
    stripe_account_id: string | null;
    display_name: string | null;
  } | null;
}

interface ProcessResult {
  id: string;
  success: boolean;
  transferId?: string;
  payoutId?: string;
  error?: string;
  duration_ms?: number;
}

/**
 * Process a single withdrawal with Stripe Transfer + Payout
 */
async function processWithdrawal(
  withdrawal: WithdrawalRecord,
  stripe: Stripe,
  supabase: ReturnType<typeof createClient>,
  log: Logger
): Promise<ProcessResult> {
  const elapsed = log.startTimer();
  const withdrawalLog = log.child({ withdrawal_id: withdrawal.id, amount: withdrawal.amount });

  const stripeAccountId = withdrawal.profiles?.stripe_account_id;

  // Idempotency: Skip if already has transfer
  if (withdrawal.stripe_transfer_id) {
    withdrawalLog.info("Withdrawal already has transfer, skipping");
    return { id: withdrawal.id, success: true, transferId: withdrawal.stripe_transfer_id };
  }

  if (!stripeAccountId) {
    withdrawalLog.warn("No Stripe account configured");
    await supabase.rpc("confirm_withdrawal_failure", {
      p_withdrawal_id: withdrawal.id,
      p_reason: "No Stripe account configured for this user",
    });
    return { id: withdrawal.id, success: false, error: "No Stripe account", duration_ms: elapsed() };
  }

  // ATOMIC LOCK: Mark as processing with optimistic locking
  const { data: updateResult } = await supabase
    .from("withdrawals")
    .update({ status: "processing", updated_at: new Date().toISOString() })
    .eq("id", withdrawal.id)
    .eq("status", "pending")
    .select("id");

  if (!updateResult || updateResult.length === 0) {
    withdrawalLog.info("Withdrawal already claimed by another worker");
    return { id: withdrawal.id, success: false, error: "Already claimed", duration_ms: elapsed() };
  }

  try {
    // Step 1: Create Transfer from platform to connected account
    withdrawalLog.info("Creating Stripe transfer", { stripe_account: stripeAccountId });

    const transfer = await stripe.transfers.create({
      amount: Math.round(withdrawal.amount * 100),
      currency: "eur",
      destination: stripeAccountId,
      metadata: {
        withdrawal_id: withdrawal.id,
        user_id: withdrawal.user_id,
        type: "withdrawal_transfer",
      },
    }, {
      idempotencyKey: `transfer-${withdrawal.id}`,
    });

    await supabase
      .from("withdrawals")
      .update({ stripe_transfer_id: transfer.id })
      .eq("id", withdrawal.id);

    withdrawalLog.info("Transfer created", { transfer_id: transfer.id });

    // Step 2: Create Payout from connected account to bank
    withdrawalLog.info("Creating Stripe payout");

    const payout = await stripe.payouts.create(
      {
        amount: Math.round(withdrawal.amount * 100),
        currency: "eur",
        metadata: {
          withdrawal_id: withdrawal.id,
          user_id: withdrawal.user_id,
          transfer_id: transfer.id,
        },
      },
      {
        stripeAccount: stripeAccountId,
        idempotencyKey: `payout-${withdrawal.id}`,
      }
    );

    await supabase
      .from("withdrawals")
      .update({ stripe_payout_id: payout.id })
      .eq("id", withdrawal.id);

    withdrawalLog.info("Payout created, awaiting webhook confirmation", {
      transfer_id: transfer.id,
      payout_id: payout.id,
      duration_ms: elapsed(),
    });

    return {
      id: withdrawal.id,
      success: true,
      transferId: transfer.id,
      payoutId: payout.id,
      duration_ms: elapsed(),
    };

  } catch (stripeError: unknown) {
    const err = stripeError as Error & { code?: string; type?: string };
    withdrawalLog.error("Stripe error", err, { stripe_code: err.code, stripe_type: err.type });

    await supabase.rpc("confirm_withdrawal_failure", {
      p_withdrawal_id: withdrawal.id,
      p_reason: `Stripe error: ${err.message}`,
    });

    return {
      id: withdrawal.id,
      success: false,
      error: err.message,
      duration_ms: elapsed(),
    };
  }
}

/**
 * Process withdrawals with controlled concurrency (p-map style)
 */
async function processWithConcurrency<T, R>(
  items: T[],
  processor: (item: T) => Promise<R>,
  concurrency: number
): Promise<R[]> {
  const results: R[] = [];
  const executing: Promise<void>[] = [];

  for (const item of items) {
    const promise = processor(item).then((result) => {
      results.push(result);
    });

    executing.push(promise);

    if (executing.length >= concurrency) {
      await Promise.race(executing);
      // Remove completed promises
      for (let i = executing.length - 1; i >= 0; i--) {
        // Check if promise is settled by racing with immediate resolve
        const settled = await Promise.race([
          executing[i].then(() => true),
          Promise.resolve(false),
        ]);
        if (settled) {
          executing.splice(i, 1);
        }
      }
    }
  }

  // Wait for remaining
  await Promise.all(executing);
  return results;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return handleCorsOptions();
  }

  const requestId = getRequestId(req);
  const log = createLogger("cron-process-withdrawals", requestId);
  const totalElapsed = log.startTimer();

  try {
    // SECURITY: Verify cron secret
    const authError = verifyCronSecret(req);
    if (authError) {
      log.warn("Unauthorized access attempt");
      return authError;
    }

    log.info("Starting batch processing");

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Fetch pending withdrawals with user profile
    const { data: withdrawals, error: fetchError } = await supabase
      .from("withdrawals")
      .select(`
        id,
        user_id,
        amount,
        status,
        stripe_transfer_id,
        profiles:user_id (
          stripe_account_id,
          display_name
        )
      `)
      .eq("status", "pending")
      .order("created_at", { ascending: true })
      .limit(BATCH_SIZE);

    if (fetchError) {
      throw new Error(`Failed to fetch withdrawals: ${fetchError.message}`);
    }

    if (!withdrawals || withdrawals.length === 0) {
      log.info("No pending withdrawals to process");
      return new Response(JSON.stringify({
        success: true,
        processed: 0,
        message: "No pending withdrawals",
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      });
    }

    log.info("Found pending withdrawals", { count: withdrawals.length });

    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    // Process withdrawals with controlled concurrency
    const results = await processWithConcurrency(
      withdrawals as unknown as WithdrawalRecord[],
      (w) => processWithdrawal(w, stripe, supabase, log),
      CONCURRENCY_LIMIT
    );

    // Stats
    const successCount = results.filter(r => r.success).length;
    const failCount = results.filter(r => !r.success).length;
    const totalDuration = totalElapsed();

    log.info("Batch processing completed", {
      total: results.length,
      successful: successCount,
      failed: failCount,
      concurrency: CONCURRENCY_LIMIT,
      duration_ms: totalDuration,
    });

    // System log
    await supabase.from("system_logs").insert({
      level: "info",
      event_type: "cron_withdrawals",
      message: `Processed ${results.length} withdrawals: ${successCount} success, ${failCount} failed`,
      details: {
        request_id: requestId,
        total: results.length,
        success: successCount,
        failed: failCount,
        concurrency: CONCURRENCY_LIMIT,
        duration_ms: totalDuration,
        results: results.map(r => ({
          id: r.id,
          success: r.success,
          duration_ms: r.duration_ms,
          error: r.error,
        })),
      },
    });

    return new Response(JSON.stringify({
      success: true,
      processed: results.length,
      successful: successCount,
      failed: failCount,
      duration_ms: totalDuration,
      results,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    log.error("Cron job failed", err);

    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 500,
    });
  }
});
