// ==============================================================================
// CREATE-PAYMENT - V14.0 (CORRECTED)
// Crée une commande et initialise le PaymentIntent Stripe (mode escrow)
// NOTE: Remplace create-payment-authorization ET create-payment-with-connect
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
const paymentSchema = z.object({
  influencerId: z.string().uuid(),
  offerId: z.string().uuid(),
  amount: z.number().min(0.5, "Minimum 0.50€"),
  brandName: z.string().max(200).optional(),
  productName: z.string().max(200).optional(),
  brief: z.string().max(5000).optional(),
  deadline: z.string().max(100).optional(),
  specialInstructions: z.string().max(2000).optional(),
});

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const authHeader = req.headers.get("Authorization");
    
    if (!authHeader) throw new Error("Missing Authorization Header");

    // Validation des entrées
    const validation = paymentSchema.safeParse(body);
    if (!validation.success) {
      const errorMsg = validation.error.errors.map(e => `${e.path.join(".")}: ${e.message}`).join(", ");
      throw new Error(`Validation error: ${errorMsg}`);
    }

    const { influencerId, offerId, amount, brandName, productName, brief, deadline, specialInstructions } = validation.data;

    // Init Clients Supabase
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

    console.log(`[Create Payment] Init for Merchant ${user.id} -> Influencer ${influencerId}`);

    // Vérification Rôle Commerçant
    const { data: userProfile } = await supabaseUser
      .from("profiles")
      .select("role")
      .eq("id", user.id)
      .single();

    if (userProfile?.role !== "commercant") {
      throw new Error("Access denied: Only merchants can create orders.");
    }

    // Vérification Offre & Prix
    const { data: offer, error: offerError } = await supabaseUser
      .from("offers")
      .select("influencer_id, is_active, price")
      .eq("id", offerId)
      .single();

    if (offerError || !offer) throw new Error("Offer not found");
    if (!offer.is_active) throw new Error("This offer is not active");
    if (offer.influencer_id !== influencerId) throw new Error("Integrity Error: Offer owner mismatch.");
    if (amount < offer.price) throw new Error(`Invalid Amount: Minimum price for this offer is ${offer.price}€`);

    // Vérification Stripe Connect de l'influenceur
    const { data: influencer, error: infError } = await supabaseAdmin
      .from("profiles")
      .select("stripe_account_id")
      .eq("id", influencerId)
      .single();

    if (infError || !influencer || !influencer.stripe_account_id) {
      throw new Error("Influencer Stripe account not ready. The influencer must complete their Stripe setup.");
    }

    // Construction du champ 'requirements'
    const compiledRequirements = `
MARQUE: ${brandName || "N/A"}
PRODUIT: ${productName || "N/A"}
DEADLINE SOUHAITÉE: ${deadline || "Non spécifiée"}

BRIEF:
${brief || "Aucun brief fourni."}

INSTRUCTIONS SPÉCIALES:
${specialInstructions || "Aucune."}
    `.trim();

    // Création de la commande en DB
    const { data: order, error: insertError } = await supabaseUser
      .from("orders")
      .insert({
        merchant_id: user.id,
        influencer_id: influencerId,
        offer_id: offerId,
        total_amount: amount,
        requirements: compiledRequirements,
      })
      .select()
      .single();

    if (insertError) {
      console.error("DB Insert Error:", insertError);
      throw new Error(`Failed to create order: ${insertError.message}`);
    }

    // Init Stripe & PaymentIntent (Escrow)
    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    const paymentIntent = await stripe.paymentIntents.create({
      amount: Math.round(amount * 100),
      currency: "eur",
      automatic_payment_methods: { enabled: true },
      capture_method: "manual", // ESCROW
      metadata: {
        order_id: order.id,
        merchant_id: user.id,
        influencer_id: influencerId,
      },
    });

    // Mise à jour de la commande avec l'ID Stripe
    const { error: updateError } = await supabaseUser
      .from("orders")
      .update({ stripe_payment_intent_id: paymentIntent.id })
      .eq("id", order.id);

    if (updateError) {
      console.error("DB Update Error (Stripe ID):", updateError);
    }

    // System Log
    try {
      await supabaseAdmin.from("system_logs").insert({
        event_type: "info",
        message: "Payment Authorization Initiated",
        details: {
          merchant: user.id,
          influencer: influencerId,
          orderId: order.id,
          amount: amount,
          stripe_intent: paymentIntent.id,
        },
      });
    } catch (logError) {
      console.warn("Failed to write system log:", logError);
    }

    return new Response(JSON.stringify({
      success: true,
      orderId: order.id,
      clientSecret: paymentIntent.client_secret,
      amount: order.total_amount,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("Error in create-payment:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
