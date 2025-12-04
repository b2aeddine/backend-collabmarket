// ==============================================================================
// CAPTURE-PAYMENT - V14.0 (CORRECTED)
// Capture le paiement quand l'influenceur accepte la commande
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("ALLOWED_ORIGIN") || "https://collabmarket.fr",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { orderId } = await req.json();
    const authHeader = req.headers.get("Authorization");

    if (!authHeader) throw new Error("Missing Authorization Header");
    if (!orderId) throw new Error("Missing orderId");

    console.log(`[Capture Payment] Processing order: ${orderId}`);

    // Init Client Supabase (Contexte Utilisateur)
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    // Vérification Token
    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) throw new Error("Unauthorized");

    // Récupération de la commande
    const { data: order, error: orderError } = await supabase
      .from("orders")
      .select("id, status, influencer_id, stripe_payment_intent_id")
      .eq("id", orderId)
      .single();

    if (orderError || !order) throw new Error("Order not found");

    // Seul l'influenceur assigné peut accepter
    if (order.influencer_id !== user.id) {
      throw new Error("Unauthorized: Only the assigned influencer can accept this order");
    }

    // L'ordre doit être strictement 'payment_authorized'
    if (order.status !== "payment_authorized") {
      throw new Error(`Invalid status: cannot capture from status '${order.status}'`);
    }

    if (!order.stripe_payment_intent_id) {
      throw new Error("Missing payment intent on order");
    }

    // Capture Stripe
    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    let intent;
    try {
      intent = await stripe.paymentIntents.capture(order.stripe_payment_intent_id);
      console.log("Stripe capture successful:", intent.id);
    } catch (err: unknown) {
      const stripeErr = err as { code?: string };
      // Gestion de l'idempotence
      if (stripeErr.code === "payment_intent_unexpected_state") {
        const pi = await stripe.paymentIntents.retrieve(order.stripe_payment_intent_id);
        if (pi.status === "succeeded") {
          console.log("Payment was already captured, proceeding.");
          intent = pi;
        } else {
          throw err;
        }
      } else {
        throw err;
      }
    }

    // FIX V20: Utiliser le service role pour mettre stripe_payment_status
    // Le trigger sync_stripe_status_to_order fera automatiquement la transition vers 'accepted'
    // Plus besoin d'appeler safe_update_order_status (c'était redondant et échouait)
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const { error: updateError } = await supabaseAdmin
      .from("orders")
      .update({
        stripe_payment_status: "captured",
        captured_at: new Date().toISOString(),
      })
      .eq("id", orderId);

    if (updateError) {
      console.error("CRITICAL: Payment captured BUT DB update failed", updateError);
      throw new Error("Payment captured but order status update failed");
    }

    // Le trigger sync_stripe_status_to_order a automatiquement:
    // 1. Mis status = 'accepted'
    // 2. Mis accepted_at = NOW()
    console.log(`Order ${orderId} automatically transitioned to 'accepted' via trigger`);

    return new Response(JSON.stringify({
      success: true,
      status: "accepted",
      paymentIntentId: intent.id,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("Error in capture-payment:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
