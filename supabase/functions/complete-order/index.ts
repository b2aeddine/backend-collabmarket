// ==============================================================================
// COMPLETE-ORDER - V15.0 (SCHEMA V40 ALIGNED)
// Completes an order - The buyer confirms delivery acceptance
// ALIGNED: Uses buyer_id/seller_id, safe_update_order_status RPC
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, handleCorsOptions, corsResponse, corsErrorResponse } from "../shared/utils/cors.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return handleCorsOptions();
  }

  try {
    const { orderId } = await req.json();
    const authHeader = req.headers.get("Authorization");

    if (!authHeader) {
      return corsErrorResponse("Missing Authorization Header", 401);
    }

    if (!orderId) {
      return corsErrorResponse("Missing orderId", 400);
    }

    // Init Client Supabase (User Context)
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) {
      return corsErrorResponse("Unauthorized", 401);
    }

    // Fetch order with v40 schema columns
    const { data: order, error: orderError } = await supabase
      .from("orders")
      .select(`
        id,
        order_number,
        status,
        buyer_id,
        seller_id,
        stripe_payment_status,
        total_amount,
        subtotal,
        discount_amount,
        platform_fee
      `)
      .eq("id", orderId)
      .single();

    if (orderError || !order) {
      return corsErrorResponse("Order not found", 404);
    }

    // IDEMPOTENCE: If already completed, return success
    if (["completed", "finished"].includes(order.status)) {
      console.log(`Order ${orderId} already completed. Skipping.`);
      return corsResponse({
        success: true,
        message: "Order already completed",
        status: order.status,
        alreadyProcessed: true,
      });
    }

    // SECURITY: Only the buyer can complete/accept the delivery
    if (order.buyer_id !== user.id) {
      return corsErrorResponse("Unauthorized: Only the buyer can complete this order", 403);
    }

    // Business logic validation
    const completableStatuses = ["submitted", "review_pending", "in_progress", "delivered"];
    if (!completableStatuses.includes(order.status)) {
      return corsErrorResponse(
        `Cannot complete order. Seller must submit work first (Current status: ${order.status})`,
        400
      );
    }

    // Payment integrity check - funds must be captured
    if (!["captured", "succeeded"].includes(order.stripe_payment_status)) {
      return corsErrorResponse("Payment integrity check failed: Funds not captured.", 400);
    }

    // Call RPC (State Machine & Ledger) - this handles distribution automatically
    const { error: rpcError } = await supabase.rpc("safe_update_order_status", {
      p_order_id: orderId,
      p_new_status: "completed",
    });

    if (rpcError) {
      console.error("RPC Error:", rpcError);
      return corsErrorResponse(`Failed to complete order: ${rpcError.message}`, 500);
    }

    console.log(`Order ${order.order_number || orderId} completed successfully.`);

    // Calculate seller net (what they'll receive)
    const sellerNet = order.total_amount - (order.platform_fee || 0);

    return corsResponse({
      success: true,
      message: "Order successfully completed",
      status: "completed",
      data: {
        orderId: order.id,
        orderNumber: order.order_number,
        amounts: {
          total: order.total_amount,
          subtotal: order.subtotal,
          discount: order.discount_amount,
          platformFee: order.platform_fee,
          sellerNet: sellerNet,
        },
      },
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("Error in complete-order:", err);
    return corsErrorResponse(err.message, 500);
  }
});
