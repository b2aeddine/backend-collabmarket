// ==============================================================================
// GENERATE-MISSING-REVENUES - V15.0 (SCHEMA V40 ALIGNED)
// Generates missing revenue records for completed orders
// SECURITY: Uses CRON_SECRET instead of exposing service role key
// ALIGNED: Uses seller_id, seller_revenues/agent_revenues tables
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, handleCorsOptions } from "../shared/utils/cors.ts";
import { verifyCronSecret } from "../shared/utils/auth.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return handleCorsOptions();
  }

  try {
    // SECURITY: Verify cron secret instead of exposing service role key
    const authError = verifyCronSecret(req);
    if (authError) {
      console.warn("[Generate Missing Revenues] Unauthorized access attempt");
      return authError;
    }

    console.log("[Generate Missing Revenues] Starting...");

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Find completed orders without seller_revenue record
    // v40 schema: orders have buyer_id, seller_id, subtotal, discount_amount, total_amount, platform_fee
    const { data: ordersWithoutRevenue, error: fetchError } = await supabase
      .from("orders")
      .select(`
        id,
        seller_id,
        total_amount,
        platform_fee,
        status,
        stripe_payment_status
      `)
      .in("status", ["completed", "finished"])
      .eq("stripe_payment_status", "captured");

    if (fetchError) {
      throw new Error(`Failed to fetch orders: ${fetchError.message}`);
    }

    if (!ordersWithoutRevenue || ordersWithoutRevenue.length === 0) {
      return new Response(JSON.stringify({
        success: true,
        generated: 0,
        message: "No completed orders found",
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      });
    }

    // Check which orders don't have a seller_revenue record
    const orderIds = ordersWithoutRevenue.map(o => o.id);

    const { data: existingRevenues } = await supabase
      .from("seller_revenues")
      .select("order_id")
      .in("order_id", orderIds);

    const existingOrderIds = new Set((existingRevenues || []).map(r => r.order_id));
    const missingOrders = ordersWithoutRevenue.filter(o => !existingOrderIds.has(o.id));

    if (missingOrders.length === 0) {
      console.log("[Generate] All completed orders have revenues.");
      return new Response(JSON.stringify({
        success: true,
        generated: 0,
        message: "All revenues already exist",
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      });
    }

    console.log(`[Generate] Found ${missingOrders.length} orders without revenues`);

    // Generate missing seller revenues
    // v40 schema: seller_revenues has seller_id, order_id, gross_amount, net_amount, platform_fee, status
    const revenuesToInsert = missingOrders.map(order => {
      const grossAmount = order.total_amount || 0;
      const platformFee = order.platform_fee || 0;
      const netAmount = grossAmount - platformFee;

      return {
        seller_id: order.seller_id,
        order_id: order.id,
        gross_amount: grossAmount,
        net_amount: netAmount,
        platform_fee: platformFee,
        status: "available", // Already captured, so available for withdrawal
      };
    });

    const { data: insertedRevenues, error: insertError } = await supabase
      .from("seller_revenues")
      .insert(revenuesToInsert)
      .select();

    if (insertError) {
      console.error("Insert Error:", insertError);
      throw new Error(`Failed to insert revenues: ${insertError.message}`);
    }

    const generatedCount = insertedRevenues?.length || 0;
    console.log(`[Generate] Created ${generatedCount} seller revenues`);

    // Log système
    await supabase.from("system_logs").insert({
      event_type: "info",
      message: "Generated missing seller revenues",
      details: {
        ordersChecked: ordersWithoutRevenue.length,
        revenuesGenerated: generatedCount,
        orderIds: missingOrders.map(o => o.id),
      },
    });

    return new Response(JSON.stringify({
      success: true,
      checked: ordersWithoutRevenue.length,
      generated: generatedCount,
      orderIds: missingOrders.map(o => o.id),
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("[Generate Missing Revenues Error]:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 500,
    });
  }
});
