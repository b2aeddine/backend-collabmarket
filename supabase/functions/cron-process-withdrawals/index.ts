// ==============================================================================
// CRON-PROCESS-WITHDRAWALS - V14.0 (CORRECTED)
// Traite les retraits en batch (appelé par cron)
// FIX: Typage correct des jointures
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("ALLOWED_ORIGIN") || "https://collabmarket.fr",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Types
interface WithdrawalWithProfile {
  id: string;
  influencer_id: string;
  amount: number;
  status: string;
  profiles: {
    stripe_account_id: string | null;
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
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // Vérification Service Role
    const authHeader = req.headers.get("Authorization")?.replace("Bearer ", "");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!authHeader || authHeader !== serviceKey) {
      throw new Error("Unauthorized: Service role required");
    }

    console.log("[Cron Process Withdrawals] Starting batch processing...");

    // Client Admin
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Récupérer les retraits en attente
    const { data: withdrawals, error: fetchError } = await supabase
      .from("withdrawals")
      .select(`
        id,
        influencer_id,
        amount,
        status,
        profiles:influencer_id (
          stripe_account_id
        )
      `)
      .eq("status", "pending")
      .order("created_at", { ascending: true })
      .limit(50); // Batch de 50 max

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

    // Init Stripe
    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    const results: ProcessResult[] = [];

    for (const rawWithdrawal of withdrawals) {
      const withdrawal = rawWithdrawal as unknown as WithdrawalWithProfile;
      const stripeAccountId = withdrawal.profiles?.stripe_account_id;

      if (!stripeAccountId) {
        // Marquer comme échoué
        await supabase
          .from("withdrawals")
          .update({
            status: "failed",
            failure_reason: "No Stripe account configured",
          })
          .eq("id", withdrawal.id);

        results.push({
          id: withdrawal.id,
          success: false,
          error: "No Stripe account",
        });
        continue;
      }

      try {
        // Passer en processing
        await supabase
          .from("withdrawals")
          .update({ status: "processing" })
          .eq("id", withdrawal.id);

        // Transfer
        const transfer = await stripe.transfers.create({
          amount: Math.round(withdrawal.amount * 100),
          currency: "eur",
          destination: stripeAccountId,
          metadata: {
            withdrawal_id: withdrawal.id,
            user_id: withdrawal.influencer_id,
          },
        });

        await supabase
          .from("withdrawals")
          .update({ stripe_transfer_id: transfer.id })
          .eq("id", withdrawal.id);

        // Payout
        const payout = await stripe.payouts.create(
          {
            amount: Math.round(withdrawal.amount * 100),
            currency: "eur",
            metadata: {
              withdrawal_id: withdrawal.id,
              user_id: withdrawal.influencer_id,
            },
          },
          {
            stripeAccount: stripeAccountId,
          }
        );

        await supabase
          .from("withdrawals")
          .update({ stripe_payout_id: payout.id })
          .eq("id", withdrawal.id);

        results.push({
          id: withdrawal.id,
          success: true,
          transferId: transfer.id,
          payoutId: payout.id,
        });

        console.log(`[Cron] Processed withdrawal ${withdrawal.id} -> Payout ${payout.id}`);

      } catch (stripeError: unknown) {
        const err = stripeError as Error;
        console.error(`[Cron] Failed to process withdrawal ${withdrawal.id}:`, err.message);

        await supabase
          .from("withdrawals")
          .update({
            status: "failed",
            failure_reason: err.message,
          })
          .eq("id", withdrawal.id);

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

    // Log système
    await supabase.from("system_logs").insert({
      event_type: "cron",
      message: "Batch withdrawal processing completed",
      details: {
        total: results.length,
        success: successCount,
        failed: failCount,
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
