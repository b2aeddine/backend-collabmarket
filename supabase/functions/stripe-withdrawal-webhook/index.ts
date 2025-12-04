// ==============================================================================
// STRIPE-WITHDRAWAL-WEBHOOK - V14.0 (CORRECTED)
// Gère les webhooks Stripe Connect pour les payouts
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const allowedOrigin =
  Deno.env.get("ALLOWED_ORIGIN") || "https://collabmarket.fr";

const corsHeaders = {
  "Access-Control-Allow-Origin": allowedOrigin,
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, stripe-signature",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
    apiVersion: "2023-10-16",
    httpClient: Stripe.createFetchHttpClient(),
  });

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  try {
    const signature = req.headers.get("stripe-signature");
    const webhookSecret = Deno.env.get("STRIPE_CONNECT_WEBHOOK_SECRET");
    const body = await req.text();

    let event: Stripe.Event;

    // Vérification de signature obligatoire
    if (!webhookSecret) {
      console.error("Withdrawal webhook secret not configured");
      return new Response(JSON.stringify({ error: "Webhook not configured" }), {
        status: 500,
        headers: corsHeaders,
      });
    }

    if (!signature) {
      console.warn("Missing Stripe signature header");
      return new Response(JSON.stringify({ error: "Missing signature" }), {
        status: 401,
        headers: corsHeaders,
      });
    }

    try {
      event = stripe.webhooks.constructEvent(body, signature, webhookSecret);
    } catch (err: unknown) {
      const error = err as Error;
      console.error("Webhook signature verification failed:", error.message);
      return new Response(JSON.stringify({ error: "Invalid signature" }), {
        status: 400,
        headers: corsHeaders,
      });
    }

    console.log(`[Payout Webhook] Event: ${event.type}, ID: ${event.id}`);

    const { data: existingLog } = await supabase
      .from("payment_logs")
      .select("id, processed")
      .eq("stripe_event_id", event.id)
      .maybeSingle();

    if (existingLog?.processed) {
      console.log("Payout event already processed, skipping", event.id);
      return new Response(JSON.stringify({ received: true, skipped: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    await supabase
      .from("payment_logs")
      .upsert(
        {
          stripe_event_id: event.id,
          event_type: event.type,
          event_data: event.data.object as Record<string, unknown>,
          stripe_payment_intent_id: (event.data.object as { id?: string }).id,
          processed: false,
        },
        { onConflict: "stripe_event_id" }
      );

    switch (event.type) {
      case "payout.paid": {
        // Payout effectué avec succès
        const payout = event.data.object as Stripe.Payout;
        const withdrawalId = payout.metadata?.withdrawal_id;

        if (withdrawalId) {
          console.log(`[Webhook] Payout completed for withdrawal: ${withdrawalId}`);

          // Récupérer le retrait pour avoir l'influencer_id
          const { data: withdrawal } = await supabase
            .from("withdrawals")
            .select("influencer_id, amount, status")
            .eq("id", withdrawalId)
            .single();

          if (withdrawal) {
            if (withdrawal.status === "completed") {
              console.log("Withdrawal already completed, skipping", withdrawalId);
              break;
            }

            // Mettre à jour le retrait
            await supabase
              .from("withdrawals")
              .update({
                status: "completed",
                processed_at: new Date().toISOString(),
              })
              .eq("id", withdrawalId);

            // Finaliser les revenues (FIFO)
            await supabase.rpc("finalize_revenue_withdrawal", {
              p_influencer_id: withdrawal.influencer_id,
              p_amount: withdrawal.amount,
            });

            console.log(`[Webhook] Withdrawal ${withdrawalId} completed, revenues marked as withdrawn.`);
          }
        } else {
          // Fallback: chercher par stripe_payout_id
          const { data: withdrawal } = await supabase
            .from("withdrawals")
            .select("id, influencer_id, amount, status")
            .eq("stripe_payout_id", payout.id)
            .single();

          if (withdrawal) {
            if (withdrawal.status === "completed") {
              console.log("Withdrawal already completed, skipping", withdrawal.id);
              break;
            }

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
          }
        }
        break;
      }

      case "payout.failed": {
        // Payout échoué
        const payout = event.data.object as Stripe.Payout;
        const withdrawalId = payout.metadata?.withdrawal_id;

        const failureMessage = payout.failure_message || "Payout failed";

        if (withdrawalId) {
          console.log(`[Webhook] Payout failed for withdrawal: ${withdrawalId}`);

          // Récupérer le retrait
          const { data: withdrawal } = await supabase
            .from("withdrawals")
            .select("influencer_id, amount, status")
            .eq("id", withdrawalId)
            .single();

          if (withdrawal) {
            if (withdrawal.status === "failed") {
              console.log("Withdrawal already failed, skipping", withdrawalId);
              break;
            }

            // Marquer comme échoué
            await supabase
              .from("withdrawals")
              .update({
                status: "failed",
                failure_reason: failureMessage,
              })
              .eq("id", withdrawalId);

            // Reverser les revenues
            await supabase.rpc("revert_revenue_withdrawal", {
              p_influencer_id: withdrawal.influencer_id,
              p_amount: withdrawal.amount,
            });

            console.log(`[Webhook] Withdrawal ${withdrawalId} failed, revenues reverted.`);
          }
        } else {
          // Fallback
          const { data: withdrawal } = await supabase
            .from("withdrawals")
            .select("id, influencer_id, amount, status")
            .eq("stripe_payout_id", payout.id)
            .single();

          if (withdrawal) {
            if (withdrawal.status === "failed") {
              console.log("Withdrawal already failed, skipping", withdrawal.id);
              break;
            }

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
          }
        }
        break;
      }

      case "payout.canceled": {
        // Payout annulé
        const payout = event.data.object as Stripe.Payout;

        const { data: withdrawal } = await supabase
          .from("withdrawals")
          .select("id, influencer_id, amount, status")
          .eq("stripe_payout_id", payout.id)
          .single();

        if (withdrawal) {
          if (withdrawal.status === "failed" || withdrawal.status === "completed") {
            console.log("Withdrawal already finalized, skipping", withdrawal.id);
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

    await supabase
      .from("payment_logs")
      .update({ processed: true })
      .eq("stripe_event_id", event.id);

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
