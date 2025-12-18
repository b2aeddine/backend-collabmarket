// ==============================================================================
// CAPTURE-PAYMENT - V15.0 (SCHEMA V40 ALIGNED)
// Captures an authorized payment - Seller accepts the order
// ALIGNED: Uses seller_id, valid status 'accepted', safe_update_order_status RPC
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { corsHeaders, handleCorsOptions, corsResponse, corsErrorResponse } from "../shared/utils/cors.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
  httpClient: Stripe.createFetchHttpClient(),
});

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return handleCorsOptions();
  }

  try {
    const { order_id } = await req.json();
    const authHeader = req.headers.get("Authorization");

    if (!authHeader) {
      return corsErrorResponse("Missing Authorization Header", 401);
    }

    if (!order_id) {
      return corsErrorResponse("Missing order_id", 400);
    }

    // Init Supabase clients
    const supabaseUser = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Authenticate user
    const { data: { user }, error: authError } = await supabaseUser.auth.getUser();
    if (authError || !user) {
      return corsErrorResponse("Unauthorized", 401);
    }

    // Fetch order (v40 schema: seller_id, not influencer_id)
    const { data: order, error: orderError } = await supabaseUser
      .from("orders")
      .select(`
        id,
        order_number,
        status,
        buyer_id,
        seller_id,
        stripe_payment_intent_id,
        stripe_payment_status,
        total_amount
      `)
      .eq("id", order_id)
      .single();

    if (orderError || !order) {
      return corsErrorResponse("Order not found", 404);
    }

    // SECURITY: Only the seller can accept/capture
    if (order.seller_id !== user.id) {
      return corsErrorResponse("Unauthorized: Only the seller can accept this order", 403);
    }

    // IDEMPOTENCE: If already accepted/in_progress, return success
    if (["accepted", "in_progress", "delivered", "completed"].includes(order.status)) {
      console.log(`[Capture] Order ${order_id} already accepted (status: ${order.status}). Skipping.`);
      return corsResponse({
        success: true,
        message: "Order already accepted",
        status: order.status,
        alreadyProcessed: true,
      });
    }

    // Status validation: Must be payment_authorized to capture
    if (order.status !== "payment_authorized") {
      return corsErrorResponse(
        `Invalid status: Cannot capture order in state '${order.status}'. Must be 'payment_authorized'.`,
        400
      );
    }

    if (!order.stripe_payment_intent_id) {
      return corsErrorResponse("Missing Stripe Payment Intent ID", 400);
    }

    // Stripe Capture
    console.log(`[Capture] Capturing payment for order ${order.order_number} (PI: ${order.stripe_payment_intent_id})`);

    const paymentIntent = await stripe.paymentIntents.capture(order.stripe_payment_intent_id);

    if (paymentIntent.status !== "succeeded") {
      return corsErrorResponse(`Stripe Capture Failed: Status is ${paymentIntent.status}`, 500);
    }

    console.log(`[Capture] Payment captured successfully for order ${order.order_number}`);

    // Update order status via atomic RPC
    // v40 valid statuses: pending/payment_authorized/accepted/in_progress/delivered/revision_requested/completed/disputed/cancelled/refunded
    // After capture, order goes to 'accepted' (seller has accepted the work)
    const { error: rpcError } = await supabaseAdmin.rpc("safe_update_order_status", {
      p_order_id: order_id,
      p_new_status: "accepted",
    });

    if (rpcError) {
      console.error("[Capture] RPC Error:", rpcError);
      // Don't fail completely - payment was captured
      // The webhook or sync will eventually fix the status
    }

    // Update stripe_payment_status directly (this should trigger sync_stripe_status_to_order if configured)
    await supabaseAdmin
      .from("orders")
      .update({
        stripe_payment_status: "captured",
        accepted_at: new Date().toISOString(),
      })
      .eq("id", order_id);

    // System log
    await supabaseAdmin.from("system_logs").insert({
      event_type: "info",
      message: "Order accepted and payment captured",
      details: {
        order_id: order.id,
        order_number: order.order_number,
        seller_id: order.seller_id,
        buyer_id: order.buyer_id,
        amount: order.total_amount,
        payment_intent: order.stripe_payment_intent_id,
      },
    });

    return corsResponse({
      success: true,
      message: "Payment captured and order accepted",
      orderId: order.id,
      orderNumber: order.order_number,
      status: "accepted",
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("[Capture Error]:", err);
    return corsErrorResponse(err.message, 500);
  }
});
