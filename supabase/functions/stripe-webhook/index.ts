// ==============================================================================
// STRIPE-WEBHOOK - V14.0 (CORRECTED)
// Gère les webhooks Stripe pour les paiements
// FIX: Utilise stripe_checkout_session_id au lieu de stripe_session_id
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, stripe-signature",
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
    const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
    const body = await req.text();

    let event: Stripe.Event;

    // Vérification de signature
    if (webhookSecret && signature) {
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
    } else {
      // Fallback sans vérification (dev only)
      event = JSON.parse(body);
      console.warn("⚠️ Webhook received without signature verification");
    }

    console.log(`[Stripe Webhook] Event: ${event.type}, ID: ${event.id}`);

    // Log l'événement
    await supabase.from("payment_logs").insert({
      event_type: event.type,
      event_data: event.data.object as Record<string, unknown>,
      stripe_payment_intent_id: (event.data.object as { id?: string }).id,
    });

    // Traitement par type d'événement
    switch (event.type) {
      case "payment_intent.amount_capturable_updated": {
        // Autorisation réussie (escrow)
        const paymentIntent = event.data.object as Stripe.PaymentIntent;
        const orderId = paymentIntent.metadata?.order_id;

        if (orderId) {
          console.log(`[Webhook] Payment authorized for order: ${orderId}`);

          const { error } = await supabase
            .from("orders")
            .update({
              stripe_payment_status: "authorized",
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
        // Capture réussie
        const paymentIntent = event.data.object as Stripe.PaymentIntent;
        const orderId = paymentIntent.metadata?.order_id;

        if (orderId) {
          console.log(`[Webhook] Payment captured for order: ${orderId}`);

          await supabase
            .from("orders")
            .update({
              stripe_payment_status: "captured",
              captured_at: new Date().toISOString(),
            })
            .eq("id", orderId);
        }
        break;
      }

      case "payment_intent.canceled": {
        // Annulation
        const paymentIntent = event.data.object as Stripe.PaymentIntent;
        const orderId = paymentIntent.metadata?.order_id;

        if (orderId) {
          console.log(`[Webhook] Payment canceled for order: ${orderId}`);

          await supabase
            .from("orders")
            .update({
              stripe_payment_status: "canceled",
              status: "cancelled",
            })
            .eq("id", orderId);
        }
        break;
      }

      case "charge.refunded": {
        // Remboursement
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
        // Session Checkout complétée
        const session = event.data.object as Stripe.Checkout.Session;

        // FIX: Utilise stripe_checkout_session_id
        if (session.id) {
          console.log(`[Webhook] Checkout session completed: ${session.id}`);

          const { data: order } = await supabase
            .from("orders")
            .select("id")
            .eq("stripe_checkout_session_id", session.id)
            .single();

          if (order && session.payment_intent) {
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
        // Mise à jour compte Connect
        const account = event.data.object as Stripe.Account;

        console.log(`[Webhook] Account updated: ${account.id}`);

        // Déterminer le statut KYC
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
        // Vérification Identity réussie
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
        // Identity nécessite plus d'infos
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

    return new Response(JSON.stringify({ received: true }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("[Webhook Error]:", err);

    // Log l'erreur
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
