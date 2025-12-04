// ==============================================================================
// CANCEL-ORDER-AND-REFUND - V14.0 (CORRECTED)
// Annule une commande et rembourse/libère les fonds Stripe
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

// SECURITY: CORS restrictif - configurable via env
const ALLOWED_ORIGIN = Deno.env.get("ALLOWED_ORIGIN") || "https://collabmarket.fr";

const corsHeaders = {
  "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { orderId } = await req.json();
    const authHeader = req.headers.get("Authorization");

    if (!authHeader || !orderId) {
      throw new Error("Missing parameters or authorization");
    }

    // Validation UUID
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
    if (!uuidRegex.test(orderId)) {
      throw new Error("Invalid orderId format");
    }

    // Client Supabase (Contexte Utilisateur)
    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: authHeader } } }
    );

    // Vérification utilisateur
    const { data: { user }, error: authError } = await supabaseClient.auth.getUser();
    if (authError || !user) throw new Error("Unauthorized: Invalid token");

    console.log(`[Cancel Order] User: ${user.id} -> Order: ${orderId}`);

    // Récupérer la commande
    const { data: order, error: orderError } = await supabaseClient
      .from("orders")
      .select("id, merchant_id, influencer_id, status, stripe_payment_intent_id, stripe_payment_status")
      .eq("id", orderId)
      .single();

    if (orderError || !order) {
      throw new Error("Order not found");
    }

    // Vérification Permissions
    const { data: adminCheck } = await supabaseClient.rpc("is_admin");
    const isAdmin = adminCheck === true;

    if (order.merchant_id !== user.id && order.influencer_id !== user.id && !isAdmin) {
      throw new Error("Unauthorized: You are not a participant of this order");
    }

    // Vérification du statut - on ne peut annuler que certaines commandes
    const cancellableStatuses = ["pending", "payment_authorized", "accepted"];
    if (!cancellableStatuses.includes(order.status)) {
      throw new Error(`Cannot cancel order with status: ${order.status}`);
    }

    // Logique Stripe (Remboursement ou Annulation)
    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") || "", {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    if (order.stripe_payment_intent_id) {
      try {
        const paymentIntent = await stripe.paymentIntents.retrieve(order.stripe_payment_intent_id);

        if (paymentIntent.status === "succeeded") {
          // Argent capturé -> REMBOURSEMENT
          console.log(`Creating refund for captured intent: ${order.stripe_payment_intent_id}`);
          await stripe.refunds.create({
            payment_intent: order.stripe_payment_intent_id,
            reason: "requested_by_customer",
          });
        } else if (paymentIntent.status === "requires_capture" || paymentIntent.status === "requires_payment_method") {
          // Argent bloqué -> ANNULATION DE L'EMPREINTE
          console.log(`Canceling authorization: ${order.stripe_payment_intent_id}`);
          await stripe.paymentIntents.cancel(order.stripe_payment_intent_id);
        } else if (paymentIntent.status === "canceled") {
          console.log("Payment intent already canceled in Stripe");
        }
      } catch (stripeError: unknown) {
        const err = stripeError as { type?: string; message?: string };
        console.error("Stripe Error:", err);
        // On continue sauf erreur critique
        if (err.type === "StripeAuthenticationError") throw stripeError;
      }
    }

    // Mise à jour DB via RPC
    const { error: rpcError } = await supabaseClient.rpc("safe_update_order_status", {
      p_order_id: orderId,
      p_new_status: "cancelled",
    });

    if (rpcError) {
      console.error("DB Update Error:", rpcError);
      throw new Error(`Failed to update order status: ${rpcError.message}`);
    }

    return new Response(JSON.stringify({
      success: true,
      message: "Order cancelled and refunded successfully",
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("Error in cancel-order-and-refund:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
