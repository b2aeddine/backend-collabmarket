// ==============================================================================
// PROCESS-WITHDRAWAL - V15.0 (SCHEMA V40.11 ALIGNED)
// Traite une demande de retrait : Transfer + Payout
// FEATURES:
// - Retry with exponential backoff on Stripe calls
// - Alerting on failures
// - Proper role check via user_roles table
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { z } from "https://deno.land/x/zod@v3.22.4/mod.ts";
import { withStripeRetry } from "../_shared/retry.ts";
import { alertTransferFailure, alertWithdrawalFailure } from "../_shared/alerting.ts";

// SECURITY: CORS restrictif
const ALLOWED_ORIGIN = Deno.env.get("ALLOWED_ORIGIN") || "https://collabmarket.fr";

const corsHeaders = {
  "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Validation
const withdrawalSchema = z.object({
  amount: z.number().min(5, "Minimum withdrawal is 5€"),
});

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  // Initialize admin client early for alerting
  const supabaseAdmin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  let userId: string | undefined;
  let withdrawalId: string | undefined;

  try {
    const body = await req.json();
    const authHeader = req.headers.get("Authorization");

    if (!authHeader) throw new Error("Missing Authorization Header");

    // Validation
    const validation = withdrawalSchema.safeParse(body);
    if (!validation.success) {
      throw new Error(validation.error.errors[0].message);
    }

    const { amount } = validation.data;

    // User client
    const supabaseUser = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user }, error: authError } = await supabaseUser.auth.getUser();
    if (authError || !user) throw new Error("Unauthorized");

    userId = user.id;
    console.log(`[Process Withdrawal] User: ${user.id}, Amount: ${amount}€`);

    // 1. GET PROFILE WITH STRIPE ACCOUNT
    // -------------------------------------------------------------------------
    const { data: profile, error: profileError } = await supabaseAdmin
      .from("profiles")
      .select("id, stripe_account_id, stripe_payouts_enabled")
      .eq("id", user.id)
      .single();

    if (profileError || !profile) {
      throw new Error("Profile not found");
    }

    // 2. CHECK USER HAS SELLER OR AGENT ROLE (v40 schema)
    // -------------------------------------------------------------------------
    const { data: roles, error: rolesError } = await supabaseAdmin
      .from("user_roles")
      .select("role")
      .eq("user_id", user.id)
      .eq("status", "active")
      .in("role", ["freelance", "influencer", "agent"]);

    if (rolesError || !roles || roles.length === 0) {
      throw new Error("You must be a seller or agent to request withdrawals");
    }

    // 3. CHECK STRIPE ACCOUNT CONFIGURED
    // -------------------------------------------------------------------------
    if (!profile.stripe_account_id) {
      throw new Error("No Stripe account configured. Please complete your Stripe setup first.");
    }

    // 4. CREATE WITHDRAWAL REQUEST VIA RPC (checks balance)
    // -------------------------------------------------------------------------
    const { data: rpcResult, error: rpcError } = await supabaseUser.rpc("request_withdrawal", {
      p_amount: amount,
    });

    if (rpcError) {
      throw new Error(rpcError.message);
    }

    // Handle different RPC return formats
    if (typeof rpcResult === "object" && rpcResult !== null) {
      if (rpcResult.success === false) {
        throw new Error(rpcResult.error || "Withdrawal request failed");
      }
      withdrawalId = rpcResult.withdrawal_id;
    } else {
      withdrawalId = rpcResult;
    }

    console.log(`[Process Withdrawal] Request created: ${withdrawalId}`);

    // 5. INIT STRIPE
    // -------------------------------------------------------------------------
    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    // 6. VERIFY STRIPE ACCOUNT CAN RECEIVE PAYOUTS (with retry)
    // -------------------------------------------------------------------------
    const account = await withStripeRetry(() =>
      stripe.accounts.retrieve(profile.stripe_account_id!)
    );

    if (!account.payouts_enabled) {
      // Cancel withdrawal and release funds
      await supabaseAdmin.rpc("confirm_withdrawal_failure", {
        p_withdrawal_id: withdrawalId,
        p_reason: "Payouts not enabled on Stripe account",
      });

      throw new Error("Your Stripe account cannot receive payouts yet. Please complete your account setup.");
    }

    // 7. UPDATE STATUS TO PROCESSING
    // -------------------------------------------------------------------------
    await supabaseAdmin
      .from("withdrawals")
      .update({ status: "processing" })
      .eq("id", withdrawalId);

    // 8. CREATE TRANSFER TO CONNECT ACCOUNT (with retry)
    // -------------------------------------------------------------------------
    let transfer: Stripe.Transfer;
    try {
      transfer = await withStripeRetry(() =>
        stripe.transfers.create({
          amount: Math.round(amount * 100), // Convert to cents
          currency: "eur",
          destination: profile.stripe_account_id!,
          transfer_group: withdrawalId,
          metadata: {
            withdrawal_id: withdrawalId!,
            user_id: user.id,
          },
        })
      );

      console.log(`[Process Withdrawal] Transfer created: ${transfer.id}`);

      // Save transfer ID
      await supabaseAdmin
        .from("withdrawals")
        .update({ stripe_transfer_id: transfer.id })
        .eq("id", withdrawalId);

    } catch (transferError: unknown) {
      const err = transferError as Error;
      console.error("[Process Withdrawal] Transfer failed:", err);

      // Alert and fail withdrawal
      await alertTransferFailure(supabaseAdmin, withdrawalId!, user.id, amount, err.message);

      await supabaseAdmin.rpc("confirm_withdrawal_failure", {
        p_withdrawal_id: withdrawalId,
        p_reason: `Transfer failed: ${err.message}`,
      });

      throw new Error(`Transfer failed: ${err.message}`);
    }

    // 9. CREATE PAYOUT TO BANK ACCOUNT (with retry)
    // -------------------------------------------------------------------------
    let payout: Stripe.Payout;
    try {
      payout = await withStripeRetry(() =>
        stripe.payouts.create(
          {
            amount: Math.round(amount * 100),
            currency: "eur",
            metadata: {
              withdrawal_id: withdrawalId!,
              user_id: user.id,
              transfer_id: transfer.id,
            },
          },
          {
            stripeAccount: profile.stripe_account_id!,
          }
        )
      );

      console.log(`[Process Withdrawal] Payout created: ${payout.id}`);

      // Save payout ID
      await supabaseAdmin
        .from("withdrawals")
        .update({ stripe_payout_id: payout.id })
        .eq("id", withdrawalId);

    } catch (payoutError: unknown) {
      const err = payoutError as Error;
      console.error("[Process Withdrawal] Payout failed:", err);

      // Alert - funds are in transit, need manual intervention
      await alertWithdrawalFailure(supabaseAdmin, withdrawalId!, `Payout failed after successful transfer: ${err.message}`, {
        transfer_id: transfer.id,
        user_id: user.id,
        amount,
      });

      await supabaseAdmin
        .from("withdrawals")
        .update({
          status: "failed",
          failure_reason: `Payout failed: ${err.message}. Transfer ${transfer.id} succeeded - manual intervention required.`,
        })
        .eq("id", withdrawalId);

      throw new Error(`Payout failed: ${err.message}. Our team has been notified.`);
    }

    // 10. SUCCESS - Status will change to 'completed' via webhook (payout.paid)
    // -------------------------------------------------------------------------
    return new Response(
      JSON.stringify({
        success: true,
        withdrawal_id: withdrawalId,
        transfer_id: transfer.id,
        payout_id: payout.id,
        status: "processing",
        message: "Withdrawal initiated. You will be notified when funds reach your bank account.",
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      }
    );

  } catch (error: unknown) {
    const err = error as Error;
    console.error("[Process Withdrawal] Error:", err);

    // Alert on unexpected errors (not validation errors)
    if (
      withdrawalId &&
      !err.message.includes("Minimum") &&
      !err.message.includes("must be") &&
      !err.message.includes("Unauthorized")
    ) {
      await alertWithdrawalFailure(supabaseAdmin, withdrawalId, err.message, {
        user_id: userId,
      });
    }

    return new Response(
      JSON.stringify({
        success: false,
        error: err.message,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 400,
      }
    );
  }
});
