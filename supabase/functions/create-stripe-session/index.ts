// ==============================================================================
// CREATE-STRIPE-SESSION - V14.0 (CORRECTED)
// Crée une session Stripe Checkout pour un paiement
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { z } from "https://deno.land/x/zod@v3.22.4/mod.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Validation schema
const sessionSchema = z.object({
  orderId: z.string().uuid(),
  successUrl: z.string().url().optional(),
  cancelUrl: z.string().url().optional(),
});

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const authHeader = req.headers.get("Authorization");

    if (!authHeader) throw new Error("Missing Authorization Header");

    // Validation
    const validation = sessionSchema.safeParse(body);
    if (!validation.success) {
      throw new Error(validation.error.errors[0].message);
    }

    const { orderId, successUrl, cancelUrl } = validation.data;

    // Clients
    const supabaseUser = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const { data: { user }, error: authError } = await supabaseUser.auth.getUser();
    if (authError || !user) throw new Error("Unauthorized");

    // Récupérer la commande
    const { data: order, error: orderError } = await supabaseUser
      .from("orders")
      .select(`
        id,
        merchant_id,
        influencer_id,
        total_amount,
        status,
        stripe_payment_intent_id,
        offers:offer_id (
          title
        )
      `)
      .eq("id", orderId)
      .single();

    if (orderError || !order) {
      throw new Error("Order not found");
    }

    // Seul le merchant peut payer
    if (order.merchant_id !== user.id) {
      throw new Error("Unauthorized: Only the merchant can pay for this order");
    }

    // Vérifier le statut
    if (order.status !== "pending") {
      throw new Error(`Cannot create payment session for order with status: ${order.status}`);
    }

    console.log(`[Create Stripe Session] Order: ${orderId}, Amount: ${order.total_amount}€`);

    // Init Stripe
    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    const baseUrl = Deno.env.get("PUBLIC_SITE_URL") || "https://collabmarket.fr";
    const offerTitle = (order.offers as { title?: string } | null)?.title || "Commande CollabMarket";

    // Créer la session Checkout
    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      payment_method_types: ["card"],
      line_items: [
        {
          price_data: {
            currency: "eur",
            product_data: {
              name: offerTitle,
              description: `Commande #${orderId.slice(0, 8)}`,
            },
            unit_amount: Math.round(order.total_amount * 100),
          },
          quantity: 1,
        },
      ],
      payment_intent_data: {
        capture_method: "manual", // ESCROW
        metadata: {
          order_id: orderId,
          merchant_id: user.id,
          influencer_id: order.influencer_id,
        },
      },
      success_url: successUrl || `${baseUrl}/orders/${orderId}?payment=success`,
      cancel_url: cancelUrl || `${baseUrl}/orders/${orderId}?payment=cancelled`,
      metadata: {
        order_id: orderId,
      },
    });

    // Sauvegarder l'ID de la session
    await supabaseAdmin
      .from("orders")
      .update({
        stripe_checkout_session_id: session.id,
      })
      .eq("id", orderId);

    return new Response(JSON.stringify({
      success: true,
      sessionId: session.id,
      url: session.url,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("[Create Stripe Session Error]:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
