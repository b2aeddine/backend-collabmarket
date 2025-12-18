// ==============================================================================
// GENERATE-MISSING-REVENUES - V14.1 (SECURED)
// Génère les revenus manquants pour les commandes complétées
// SECURITY: Uses CRON_SECRET instead of exposing service role key
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

    // Trouver les commandes complétées sans revenue associé
    const { data: ordersWithoutRevenue, error: fetchError } = await supabase
      .from("orders")
      .select(`
        id,
        influencer_id,
        total_amount,
        net_amount,
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

    // Vérifier lesquelles n'ont pas de revenue
    const orderIds = ordersWithoutRevenue.map(o => o.id);
    
    const { data: existingRevenues } = await supabase
      .from("revenues")
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

    // Générer les revenues manquants
    const revenuesToInsert = missingOrders.map(order => ({
      influencer_id: order.influencer_id,
      order_id: order.id,
      amount: order.total_amount,
      net_amount: order.net_amount,
      commission: order.total_amount - order.net_amount,
      status: "available",
    }));

    const { data: insertedRevenues, error: insertError } = await supabase
      .from("revenues")
      .insert(revenuesToInsert)
      .select();

    if (insertError) {
      console.error("Insert Error:", insertError);
      throw new Error(`Failed to insert revenues: ${insertError.message}`);
    }

    const generatedCount = insertedRevenues?.length || 0;
    console.log(`[Generate] Created ${generatedCount} revenues`);

    // Log système
    await supabase.from("system_logs").insert({
      event_type: "info",
      message: "Generated missing revenues",
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
