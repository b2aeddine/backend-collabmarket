// ==============================================================================
// CANCEL-PAYMENT - V14.0 (CORRECTED)
// Annule un paiement autorisé (libère les fonds bloqués)
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { orderId, reason } = await req.json();
    const authHeader = req.headers.get("Authorization");

    if (!authHeader) {
      throw new Error("Missing Authorization Header");
    }

    if (!orderId) {
      throw new Error("Missing orderId");
    }

    console.log(`[Cancel Payment] Order: ${orderId}, Reason: ${reason || "not specified"}`);

    // Init Supabase avec Contexte Utilisateur
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: authHeader } } }
    );

    // Vérification de l'utilisateur connecté
    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) throw new Error("Unauthorized");

    // Récupération de la commande
    const { data: order, error: orderError } = await supabase
      .from("orders")
      .select("id, merchant_id, influencer_id, status, stripe_payment_intent_id")
      .eq("id", orderId)
      .single();

    if (orderError || !order) {
      throw new Error("Order not found");
    }

    // Vérification des Droits
    if (order.merchant_id !== user.id && order.influencer_id !== user.id) {
      throw new Error("Unauthorized: You are not a participant of this order");
    }

    // Vérification du Statut
    if (!["pending", "payment_authorized"].includes(order.status)) {
      throw new Error(`Cannot cancel payment for order with status: ${order.status}. Use refund instead.`);
    }

    // Annulation Stripe
    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") || "", {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    if (order.stripe_payment_intent_id) {
      try {
        const pi = await stripe.paymentIntents.retrieve(order.stripe_payment_intent_id);

        if (pi.status === "requires_capture" || pi.status === "requires_payment_method") {
          await stripe.paymentIntents.cancel(order.stripe_payment_intent_id, {
            cancellation_reason: reason === "refused_by_influencer" ? "abandoned" : "requested_by_customer",
          });
          console.log(`Stripe PI ${order.stripe_payment_intent_id} cancelled.`);
        } else if (pi.status !== "canceled") {
          console.log(`Stripe PI status is ${pi.status}, skipping cancellation.`);
        }
      } catch (stripeError) {
        console.error("Stripe Error:", stripeError);
        // Continue pour mettre à jour la DB
      }
    }

    // Mise à jour DB via RPC
    const { error: rpcError } = await supabase.rpc("safe_update_order_status", {
      p_order_id: orderId,
      p_new_status: "cancelled",
    });

    if (rpcError) {
      console.error("DB RPC Error:", rpcError);
      throw new Error(`Failed to update order status: ${rpcError.message}`);
    }

    return new Response(JSON.stringify({
      success: true,
      message: "Payment released and order cancelled",
      newStatus: "cancelled",
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("Error in cancel-payment:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
