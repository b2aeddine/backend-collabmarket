// ==============================================================================
// STRIPE-WITHDRAWAL-WEBHOOK - V15.0 (SECURITY HARDENED)
// Gère les webhooks Stripe Connect pour les payouts
// SECURITY: Signature obligatoire + Idempotence + CORS restrictif
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

// SECURITY: CORS restrictif - configurable via env
const ALLOWED_ORIGIN = Deno.env.get("ALLOWED_ORIGIN") || "https://collabmarket.fr";

const corsHeaders = {
  "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, stripe-signature",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  try {
    // SECURITY: Signature obligatoire en production
    const signature = req.headers.get("stripe-signature");
    const webhookSecret = Deno.env.get("STRIPE_CONNECT_WEBHOOK_SECRET");
    const body = await req.text();

    // SECURITY: Rejeter si pas de secret configuré
    if (!webhookSecret) {
      console.error("CRITICAL: STRIPE_CONNECT_WEBHOOK_SECRET not configured");
      await supabase.from("system_logs").insert({
        event_type: "security",
        message: "Payout webhook rejected: STRIPE_CONNECT_WEBHOOK_SECRET not configured",
        details: { ip: req.headers.get("x-forwarded-for") },
      });
      return new Response(JSON.stringify({ error: "Webhook not configured" }), {
        status: 500,
        headers: corsHeaders,
      });
    }

    // SECURITY: Rejeter si pas de signature
    if (!signature) {
      console.error("SECURITY: Payout webhook request without stripe-signature header");
      await supabase.from("system_logs").insert({
        event_type: "security",
        message: "Payout webhook rejected: Missing stripe-signature header",
        details: { ip: req.headers.get("x-forwarded-for") },
      });
      return new Response(JSON.stringify({ error: "Missing signature" }), {
        status: 401,
        headers: corsHeaders,
      });
    }

    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    // Vérification de signature
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
        headers: corsHeaders,
      });
    }

    console.log(`[Payout Webhook] Event: ${event.type}, ID: ${event.id}`);

    // IDEMPOTENCE: Vérifier si l'événement a déjà été traité
    const { data: existingLog } = await supabase
      .from("payment_logs")
      .select("id, processed")
      .eq("stripe_payment_intent_id", event.id)
      .eq("processed", true)
      .maybeSingle();

    if (existingLog) {
      console.log(`[Payout Webhook] Event ${event.id} already processed, skipping.`);
      return new Response(JSON.stringify({ received: true, skipped: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Log l'événement (avant traitement)
    const { data: logEntry } = await supabase
      .from("payment_logs")
      .insert({
        event_type: event.type,
        event_data: event.data.object as Record<string, unknown>,
        stripe_payment_intent_id: event.id,
        processed: false,
      })
      .select("id")
      .single();

    switch (event.type) {
      case "payout.paid": {
        const payout = event.data.object as Stripe.Payout;
        const withdrawalId = payout.metadata?.withdrawal_id;

        // Trouver le withdrawal
        let withdrawal;
        if (withdrawalId) {
          const { data } = await supabase
            .from("withdrawals")
            .select("id, influencer_id, amount, status")
            .eq("id", withdrawalId)
            .single();
          withdrawal = data;
        } else {
          const { data } = await supabase
            .from("withdrawals")
            .select("id, influencer_id, amount, status")
            .eq("stripe_payout_id", payout.id)
            .single();
          withdrawal = data;
        }

        if (withdrawal) {
          // IDEMPOTENCE: Vérifier si déjà traité
          if (withdrawal.status === "completed") {
            console.log(`[Payout Webhook] Withdrawal ${withdrawal.id} already completed, skipping.`);
            break;
          }

          console.log(`[Webhook] Payout completed for withdrawal: ${withdrawal.id}`);

          await supabase
            .from("withdrawals")
            .update({
              status: "completed",
              processed_at: new Date().toISOString(),
            })
            .eq("id", withdrawal.id);

          await supabase.rpc("finalize_revenue_withdrawal", {
            p_influencer_id: withdrawal.influencer_id,
            p_amount: withdrawal.amount,
          });

          console.log(`[Webhook] Withdrawal ${withdrawal.id} completed, revenues marked as withdrawn.`);
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
            .select("id, influencer_id, amount, status")
            .eq("id", withdrawalId)
            .single();
          withdrawal = data;
        } else {
          const { data } = await supabase
            .from("withdrawals")
            .select("id, influencer_id, amount, status")
            .eq("stripe_payout_id", payout.id)
            .single();
          withdrawal = data;
        }

        if (withdrawal) {
          // IDEMPOTENCE: Vérifier si déjà traité
          if (withdrawal.status === "failed") {
            console.log(`[Payout Webhook] Withdrawal ${withdrawal.id} already failed, skipping.`);
            break;
          }

          console.log(`[Webhook] Payout failed for withdrawal: ${withdrawal.id}`);

          await supabase
            .from("withdrawals")
            .update({
              status: "failed",
              failure_reason: failureMessage,
            })
            .eq("id", withdrawal.id);

          await supabase.rpc("revert_revenue_withdrawal", {
            p_influencer_id: withdrawal.influencer_id,
            p_amount: withdrawal.amount,
          });

          console.log(`[Webhook] Withdrawal ${withdrawal.id} failed, revenues reverted.`);
        }
        break;
      }

      case "payout.canceled": {
        const payout = event.data.object as Stripe.Payout;

        const { data: withdrawal } = await supabase
          .from("withdrawals")
          .select("id, influencer_id, amount, status")
          .eq("stripe_payout_id", payout.id)
          .single();

        if (withdrawal) {
          // IDEMPOTENCE: Vérifier si déjà traité
          if (withdrawal.status === "failed" || withdrawal.status === "cancelled") {
            console.log(`[Payout Webhook] Withdrawal ${withdrawal.id} already cancelled/failed, skipping.`);
            break;
          }

          await supabase
            .from("withdrawals")
            .update({
              status: "failed",
              failure_reason: "Payout was canceled",
            })
            .eq("id", withdrawal.id);

          await supabase.rpc("revert_revenue_withdrawal", {
            p_influencer_id: withdrawal.influencer_id,
            p_amount: withdrawal.amount,
          });
        }
        break;
      }

      default:
        console.log(`[Payout Webhook] Unhandled event: ${event.type}`);
    }

    // IDEMPOTENCE: Marquer l'événement comme traité
    if (logEntry?.id) {
      await supabase
        .from("payment_logs")
        .update({ processed: true })
        .eq("id", logEntry.id);
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
      headers: corsHeaders,
    });
  }
});
