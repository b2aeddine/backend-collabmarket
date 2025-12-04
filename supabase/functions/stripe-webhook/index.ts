// ==============================================================================
// STRIPE-WEBHOOK - V15.0 (SECURITY HARDENED)
// Gère les webhooks Stripe pour les paiements
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
    const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
    const body = await req.text();

    // SECURITY: Rejeter si pas de secret configuré ou pas de signature
    if (!webhookSecret) {
      console.error("CRITICAL: STRIPE_WEBHOOK_SECRET not configured");
      await supabase.from("system_logs").insert({
        event_type: "security",
        message: "Webhook rejected: STRIPE_WEBHOOK_SECRET not configured",
        details: { ip: req.headers.get("x-forwarded-for") },
      });
      return new Response(JSON.stringify({ error: "Webhook not configured" }), {
        status: 500,
        headers: corsHeaders,
      });
    }

    if (!signature) {
      console.error("SECURITY: Webhook request without stripe-signature header");
      await supabase.from("system_logs").insert({
        event_type: "security",
        message: "Webhook rejected: Missing stripe-signature header",
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
      console.error("Webhook signature verification failed:", error.message);
      await supabase.from("system_logs").insert({
        event_type: "security",
        message: "Webhook signature verification failed",
        details: { error: error.message, ip: req.headers.get("x-forwarded-for") },
      });
      return new Response(JSON.stringify({ error: "Invalid signature" }), {
        status: 401,
        headers: corsHeaders,
      });
    }

    console.log(`[Stripe Webhook] Event: ${event.type}, ID: ${event.id}`);

    // IDEMPOTENCE: Vérifier si l'événement a déjà été traité
    const { data: existingLog } = await supabase
      .from("payment_logs")
      .select("id, processed")
      .eq("stripe_payment_intent_id", event.id)
      .eq("processed", true)
      .maybeSingle();

    if (existingLog) {
      console.log(`[Webhook] Event ${event.id} already processed, skipping.`);
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

    // Traitement par type d'événement
    switch (event.type) {
      case "payment_intent.amount_capturable_updated": {
        const paymentIntent = event.data.object as Stripe.PaymentIntent;
        const orderId = paymentIntent.metadata?.order_id;

        if (orderId) {
          console.log(`[Webhook] Payment authorized for order: ${orderId}`);

          const { error } = await supabase
            .from("orders")
            .update({
              stripe_payment_status: "requires_capture",
              payment_authorized_at: new Date().toISOString(),
            })
            .eq("id", orderId)
            .eq("stripe_payment_intent_id", paymentIntent.id);

          if (error) {
            console.error("Failed to update order:", error);
          }
        }
        break;
      }

      case "payment_intent.succeeded": {
        const paymentIntent = event.data.object as Stripe.PaymentIntent;
        const orderId = paymentIntent.metadata?.order_id;

        if (orderId) {
          console.log(`[Webhook] Payment captured for order: ${orderId}`);

          // IDEMPOTENCE: Vérifier le statut actuel avant update
          const { data: order } = await supabase
            .from("orders")
            .select("stripe_payment_status")
            .eq("id", orderId)
            .single();

          if (order && !["captured", "succeeded"].includes(order.stripe_payment_status)) {
            await supabase
              .from("orders")
              .update({
                stripe_payment_status: "captured",
                captured_at: new Date().toISOString(),
              })
              .eq("id", orderId);
          }
        }
        break;
      }

      case "payment_intent.canceled": {
        const paymentIntent = event.data.object as Stripe.PaymentIntent;
        const orderId = paymentIntent.metadata?.order_id;

        if (orderId) {
          console.log(`[Webhook] Payment canceled for order: ${orderId}`);

          // IDEMPOTENCE: Vérifier avant update
          const { data: order } = await supabase
            .from("orders")
            .select("status")
            .eq("id", orderId)
            .single();

          if (order && order.status !== "cancelled") {
            await supabase
              .from("orders")
              .update({
                stripe_payment_status: "canceled",
                status: "cancelled",
              })
              .eq("id", orderId);
          }
        }
        break;
      }

      case "charge.refunded": {
        const charge = event.data.object as Stripe.Charge;
        const paymentIntentId = charge.payment_intent as string;

        if (paymentIntentId) {
          console.log(`[Webhook] Refund processed for PI: ${paymentIntentId}`);

          await supabase
            .from("orders")
            .update({
              stripe_payment_status: "refunded",
            })
            .eq("stripe_payment_intent_id", paymentIntentId);
        }
        break;
      }

      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;

        if (session.id) {
          console.log(`[Webhook] Checkout session completed: ${session.id}`);

          const { data: order } = await supabase
            .from("orders")
            .select("id, stripe_payment_intent_id")
            .eq("stripe_checkout_session_id", session.id)
            .single();

          // IDEMPOTENCE: Ne pas réécrire si déjà présent
          if (order && !order.stripe_payment_intent_id && session.payment_intent) {
            await supabase
              .from("orders")
              .update({
                stripe_payment_intent_id: session.payment_intent as string,
              })
              .eq("id", order.id);
          }
        }
        break;
      }

      case "account.updated": {
        const account = event.data.object as Stripe.Account;

        console.log(`[Webhook] Account updated: ${account.id}`);

        let kycStatus = "pending";
        if (account.details_submitted && account.charges_enabled && account.payouts_enabled) {
          kycStatus = "verified";
        } else if (account.requirements?.currently_due && account.requirements.currently_due.length > 0) {
          kycStatus = "incomplete";
        } else if (account.requirements?.disabled_reason) {
          kycStatus = "rejected";
        }

        await supabase
          .from("profiles")
          .update({
            connect_kyc_status: kycStatus,
            connect_kyc_last_sync: new Date().toISOString(),
            connect_kyc_source: "webhook",
          })
          .eq("stripe_account_id", account.id);
        break;
      }

      case "identity.verification_session.verified": {
        const session = event.data.object as Stripe.Identity.VerificationSession;

        console.log(`[Webhook] Identity verified: ${session.id}`);

        await supabase
          .from("profiles")
          .update({
            is_verified: true,
            stripe_identity_last_status: "verified",
            identity_verified_at: new Date().toISOString(),
          })
          .eq("stripe_identity_session_id", session.id);
        break;
      }

      case "identity.verification_session.requires_input": {
        const session = event.data.object as Stripe.Identity.VerificationSession;

        await supabase
          .from("profiles")
          .update({
            stripe_identity_last_status: "requires_input",
            stripe_identity_last_update: new Date().toISOString(),
          })
          .eq("stripe_identity_session_id", session.id);
        break;
      }

      default:
        console.log(`[Webhook] Unhandled event type: ${event.type}`);
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
    console.error("[Webhook Error]:", err);

    await supabase.from("system_logs").insert({
      event_type: "error",
      message: "Webhook processing failed",
      details: { error: err.message },
    });

    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: corsHeaders,
    });
  }
});
