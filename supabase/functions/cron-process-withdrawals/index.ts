// ==============================================================================
// CRON-PROCESS-WITHDRAWALS - V15.0 (SCHEMA V40 ALIGNED)
// Processes pending withdrawals via Stripe Transfer + Payout
// SECURITY: Uses CRON_SECRET, atomic RPCs for status transitions
// ALIGNED: Uses user_id, confirm_withdrawal_success/failure RPCs
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, handleCorsOptions } from "../shared/utils/cors.ts";
import { verifyCronSecret } from "../shared/utils/auth.ts";

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
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return handleCorsOptions();
  }

  try {
    // SECURITY: Verify cron secret
    const authError = verifyCronSecret(req);
    if (authError) {
      console.warn("[Cron Process Withdrawals] Unauthorized access attempt");
      return authError;
    }

    console.log("[Cron Process Withdrawals] Starting batch processing...");

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Fetch pending withdrawals with user profile (v40 schema: user_id)
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
      .limit(50); // Batch limit

    if (fetchError) {
      throw new Error(`Failed to fetch withdrawals: ${fetchError.message}`);
    }

    if (!withdrawals || withdrawals.length === 0) {
      console.log("[Cron] No pending withdrawals to process.");
      return new Response(JSON.stringify({
        success: true,
        processed: 0,
        message: "No pending withdrawals",
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      });
    }

    console.log(`[Cron] Found ${withdrawals.length} pending withdrawals`);

    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    const results: ProcessResult[] = [];

    for (const rawWithdrawal of withdrawals) {
      const withdrawal = rawWithdrawal as unknown as WithdrawalRecord;
      const stripeAccountId = withdrawal.profiles?.stripe_account_id;

      // Idempotency: Skip if already has transfer (processing resumed)
      if (withdrawal.stripe_transfer_id) {
        console.log(`[Cron] Withdrawal ${withdrawal.id} already has transfer, checking payout status...`);
        // Could add logic to check payout status and complete if needed
        continue;
      }

      if (!stripeAccountId) {
        // No Stripe account - use atomic RPC to fail
        const { error: failError } = await supabase.rpc("confirm_withdrawal_failure", {
          p_withdrawal_id: withdrawal.id,
          p_reason: "No Stripe account configured for this user",
        });

        if (failError) {
          console.error(`[Cron] Failed to mark withdrawal ${withdrawal.id} as failed:`, failError.message);
        }

        results.push({
          id: withdrawal.id,
          success: false,
          error: "No Stripe account",
        });
        continue;
      }

      try {
        // Mark as processing (prevents double-processing)
        const { error: processError } = await supabase
          .from("withdrawals")
          .update({ status: "processing", updated_at: new Date().toISOString() })
          .eq("id", withdrawal.id)
          .eq("status", "pending"); // Only if still pending (optimistic lock)

        if (processError) {
          console.warn(`[Cron] Could not mark ${withdrawal.id} as processing:`, processError.message);
          continue; // Skip, might be processed by another worker
        }

        // Step 1: Create Transfer from platform to connected account
        const transfer = await stripe.transfers.create({
          amount: Math.round(withdrawal.amount * 100), // cents
          currency: "eur",
          destination: stripeAccountId,
          metadata: {
            withdrawal_id: withdrawal.id,
            user_id: withdrawal.user_id,
            type: "withdrawal_transfer",
          },
        });

        // Update with transfer ID
        await supabase
          .from("withdrawals")
          .update({ stripe_transfer_id: transfer.id })
          .eq("id", withdrawal.id);

        console.log(`[Cron] Transfer created: ${transfer.id} for withdrawal ${withdrawal.id}`);

        // Step 2: Create Payout from connected account to bank
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
          }
        );

        console.log(`[Cron] Payout created: ${payout.id} for withdrawal ${withdrawal.id}`);

        // Step 3: Use atomic RPC to finalize
        // Note: Payout status is async - Stripe will send webhook when completed
        // For now, we mark as completed and trust the payout
        // In production, you'd listen to payout.paid webhook instead
        const { error: successError } = await supabase.rpc("confirm_withdrawal_success", {
          p_withdrawal_id: withdrawal.id,
          p_payout_id: payout.id,
        });

        if (successError) {
          console.error(`[Cron] RPC confirm_withdrawal_success failed:`, successError.message);
          // Don't throw - transfer/payout already created
        }

        results.push({
          id: withdrawal.id,
          success: true,
          transferId: transfer.id,
          payoutId: payout.id,
        });

        console.log(`[Cron] Successfully processed withdrawal ${withdrawal.id}`);

      } catch (stripeError: unknown) {
        const err = stripeError as Error & { code?: string; type?: string };
        console.error(`[Cron] Stripe error for withdrawal ${withdrawal.id}:`, err.message);

        // Use atomic RPC to handle failure (reverts allocated revenues)
        const { error: failError } = await supabase.rpc("confirm_withdrawal_failure", {
          p_withdrawal_id: withdrawal.id,
          p_reason: `Stripe error: ${err.message}`,
        });

        if (failError) {
          console.error(`[Cron] Failed to revert withdrawal ${withdrawal.id}:`, failError.message);
        }

        results.push({
          id: withdrawal.id,
          success: false,
          error: err.message,
        });
      }
    }

    // Stats
    const successCount = results.filter(r => r.success).length;
    const failCount = results.filter(r => !r.success).length;

    // System log
    await supabase.from("system_logs").insert({
      event_type: "cron",
      message: "Batch withdrawal processing completed",
      details: {
        total: results.length,
        success: successCount,
        failed: failCount,
        results: results.map(r => ({
          id: r.id,
          success: r.success,
          error: r.error,
        })),
      },
    });

    return new Response(JSON.stringify({
      success: true,
      processed: results.length,
      successful: successCount,
      failed: failCount,
      results,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("[Cron Error]:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 500,
    });
  }
});
