// ==============================================================================
// COMPLETE-ORDER - V14.0 (CORRECTED)
// Finalise une commande - Le merchant confirme la livraison
// NOTE: Remplace complete-order-and-pay ET complete-order-payment (doublons supprimés)
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
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
    const { orderId } = await req.json();
    const authHeader = req.headers.get("Authorization");

    if (!authHeader) throw new Error("Missing Authorization Header");
    if (!orderId) throw new Error("Missing orderId");

    // Init Client Supabase (Contexte Utilisateur)
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) throw new Error("Unauthorized");

    // Récupération optimisée
    const { data: order, error: orderError } = await supabase
      .from("orders")
      .select("id, status, merchant_id, influencer_id, stripe_payment_status, total_amount, net_amount")
      .eq("id", orderId)
      .single();

    if (orderError || !order) throw new Error("Order not found");

    // IDEMPOTENCE: Si déjà complété, retourner succès
    if (["completed", "finished"].includes(order.status)) {
      console.log(`Order ${orderId} already completed. Skipping.`);
      return new Response(JSON.stringify({
        success: true,
        message: "Order already completed",
        status: order.status,
        alreadyProcessed: true,
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      });
    }

    // Seul le merchant peut compléter
    if (order.merchant_id !== user.id) {
      throw new Error("Unauthorized: Only the merchant can complete this order");
    }

    // Vérification logique métier
    const completableStatuses = ["submitted", "review_pending", "in_progress"];
    if (!completableStatuses.includes(order.status)) {
      throw new Error(`Cannot complete order. Influencer must submit work first (Current status: ${order.status})`);
    }

    // Vérification financière
    if (order.stripe_payment_status !== "captured") {
      throw new Error("Payment integrity check failed: Funds not captured.");
    }

    // Appel RPC (State Machine & Ledger)
    const { error: rpcError } = await supabase.rpc("safe_update_order_status", {
      p_order_id: orderId,
      p_new_status: "completed",
    });

    if (rpcError) {
      console.error("RPC Error:", rpcError);
      throw new Error(`Failed to complete order: ${rpcError.message}`);
    }

    console.log(`Order ${orderId} completed successfully. Revenue generated.`);

    return new Response(JSON.stringify({
      success: true,
      message: "Order successfully completed",
      status: "completed",
      data: {
        orderId: order.id,
        amounts: {
          total: order.total_amount,
          influencerNet: order.net_amount,
        },
      },
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("Error in complete-order:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
