// ==============================================================================
// STRIPE-WITHDRAWAL-WEBHOOK - V15.0 (SCHEMA V40 ALIGNED)
// Handles Stripe Connect payout webhooks
// SECURITY: Signature required + check_webhook_replay for idempotency
// ALIGNED: Uses user_id (not influencer_id), correct RPC params
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, handleCorsOptions } from "../shared/utils/cors.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return handleCorsOptions();
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  try {
    // SECURITY: Signature required in production
    const signature = req.headers.get("stripe-signature");
    const webhookSecret = Deno.env.get("STRIPE_CONNECT_WEBHOOK_SECRET");
    const body = await req.text();

    // SECURITY: Reject if no secret configured
    if (!webhookSecret) {
      console.error("CRITICAL: STRIPE_CONNECT_WEBHOOK_SECRET not configured");
      await supabase.from("system_logs").insert({
        event_type: "security",
        message: "Payout webhook rejected: STRIPE_CONNECT_WEBHOOK_SECRET not configured",
        details: { ip: req.headers.get("x-forwarded-for") },
      });
      return new Response(JSON.stringify({ error: "Webhook not configured" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // SECURITY: Reject if no signature
    if (!signature) {
      console.error("SECURITY: Payout webhook request without stripe-signature header");
      await supabase.from("system_logs").insert({
        event_type: "security",
        message: "Payout webhook rejected: Missing stripe-signature header",
        details: { ip: req.headers.get("x-forwarded-for") },
      });
      return new Response(JSON.stringify({ error: "Missing signature" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    // Verify signature
    let event: Stripe.Event;
    try {
      event = stripe.webhooks.constructEvent(body, signature, webhookSecret);
    } catch (err: unknown) {
      const error = err as Error;
      console.error("Payout webhook signature verification failed:", error.message);
      await supabase.from("system_logs").insert({
        event_type: "security",
        message: "Payout webhook signature verification failed",
        details: { error: error.message, ip: req.headers.get("x-forwarded-for") },
      });
      return new Response(JSON.stringify({ error: "Invalid signature" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    console.log(`[Payout Webhook] Event: ${event.type}, ID: ${event.id}`);

    // IDEMPOTENCY: Use check_webhook_replay RPC for atomic idempotency
    const { data: isNewEvent, error: replayError } = await supabase.rpc("check_webhook_replay", {
      p_event_id: event.id,
      p_event_type: event.type,
      p_payload_hash: null, // Payout webhooks don't need payload hash
    });

    if (replayError) {
      console.error("[Payout Webhook] check_webhook_replay error:", replayError);
      // Continue anyway - let the status checks provide secondary idempotency
    } else if (isNewEvent === false) {
      console.log(`[Payout Webhook] Event ${event.id} already processed, skipping.`);
      return new Response(JSON.stringify({ received: true, duplicate: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    switch (event.type) {
      case "payout.paid": {
        const payout = event.data.object as Stripe.Payout;
        const withdrawalId = payout.metadata?.withdrawal_id;

        // Find withdrawal by ID or payout ID (v40 schema: user_id, not influencer_id)
        let withdrawal;
        if (withdrawalId) {
          const { data } = await supabase
            .from("withdrawals")
            .select("id, user_id, amount, status, stripe_payout_id")
            .eq("id", withdrawalId)
            .single();
          withdrawal = data;
        } else {
          const { data } = await supabase
            .from("withdrawals")
            .select("id, user_id, amount, status, stripe_payout_id")
            .eq("stripe_payout_id", payout.id)
            .single();
          withdrawal = data;
        }

        if (withdrawal) {
          // IDEMPOTENCE: Check if already completed
          if (withdrawal.status === "completed") {
            console.log(`[Payout Webhook] Withdrawal ${withdrawal.id} already completed, skipping.`);
            break;
          }

          console.log(`[Payout Webhook] Payout completed for withdrawal: ${withdrawal.id}`);

          // ATOMIC RPC CALL - Note: confirm_withdrawal_success requires p_payout_id
          const { error: rpcError } = await supabase.rpc("confirm_withdrawal_success", {
            p_withdrawal_id: withdrawal.id,
            p_payout_id: payout.id,
          });

          if (rpcError) {
            console.error("CRITICAL: Failed to confirm withdrawal success:", rpcError);
            throw new Error(`RPC confirm_withdrawal_success failed: ${rpcError.message}`);
          }

          console.log(`[Payout Webhook] Withdrawal ${withdrawal.id} confirmed via Atomic RPC.`);

          // System log
          await supabase.from("system_logs").insert({
            event_type: "info",
            message: "Withdrawal completed via webhook",
            details: {
              withdrawal_id: withdrawal.id,
              user_id: withdrawal.user_id,
              amount: withdrawal.amount,
              payout_id: payout.id,
            },
          });
        } else {
          console.warn(`[Payout Webhook] No withdrawal found for payout ${payout.id}`);
        }
        break;
      }

      case "payout.failed": {
        const payout = event.data.object as Stripe.Payout;
        const withdrawalId = payout.metadata?.withdrawal_id;
        const failureMessage = payout.failure_message || "Payout failed";

        let withdrawal;
        if (withdrawalId) {
          const { data } = await supabase
            .from("withdrawals")
            .select("id, user_id, amount, status")
            .eq("id", withdrawalId)
            .single();
          withdrawal = data;
        } else {
          const { data } = await supabase
            .from("withdrawals")
            .select("id, user_id, amount, status")
            .eq("stripe_payout_id", payout.id)
            .single();
          withdrawal = data;
        }

        if (withdrawal) {
          if (withdrawal.status === "failed") {
            console.log(`[Payout Webhook] Withdrawal ${withdrawal.id} already failed, skipping.`);
            break;
          }

          console.log(`[Payout Webhook] Payout failed for withdrawal: ${withdrawal.id}`);

          // ATOMIC RPC CALL
          const { error: rpcError } = await supabase.rpc("confirm_withdrawal_failure", {
            p_withdrawal_id: withdrawal.id,
            p_reason: failureMessage,
          });

          if (rpcError) {
            console.error("Failed to mark withdrawal as failed:", rpcError);
          }

          console.log(`[Payout Webhook] Withdrawal ${withdrawal.id} marked as failed via Atomic RPC.`);

          // System log
          await supabase.from("system_logs").insert({
            event_type: "warning",
            message: "Withdrawal failed via webhook",
            details: {
              withdrawal_id: withdrawal.id,
              user_id: withdrawal.user_id,
              amount: withdrawal.amount,
              payout_id: payout.id,
              reason: failureMessage,
            },
          });
        }
        break;
      }

      case "payout.canceled": {
        const payout = event.data.object as Stripe.Payout;

        const { data: withdrawal } = await supabase
          .from("withdrawals")
          .select("id, user_id, amount, status")
          .eq("stripe_payout_id", payout.id)
          .single();

        if (withdrawal) {
          if (withdrawal.status === "failed" || withdrawal.status === "cancelled") {
            console.log(`[Payout Webhook] Withdrawal ${withdrawal.id} already cancelled/failed, skipping.`);
            break;
          }

          const { error: rpcError } = await supabase.rpc("confirm_withdrawal_failure", {
            p_withdrawal_id: withdrawal.id,
            p_reason: "Payout was canceled",
          });

          if (rpcError) {
            console.error("Failed to mark withdrawal as cancelled:", rpcError);
          }

          console.log(`[Payout Webhook] Withdrawal ${withdrawal.id} marked as cancelled.`);
        }
        break;
      }

      default:
        console.log(`[Payout Webhook] Unhandled event: ${event.type}`);
    }

    return new Response(JSON.stringify({ received: true }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("[Payout Webhook Error]:", err);

    await supabase.from("system_logs").insert({
      event_type: "error",
      message: "Payout webhook processing failed",
      details: { error: err.message },
    });

    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
