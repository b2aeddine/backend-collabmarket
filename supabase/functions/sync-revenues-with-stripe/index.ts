// ==============================================================================
// SYNC-REVENUES-WITH-STRIPE - V14.0 (CORRECTED)
// Synchronise les revenus avec les données Stripe
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
    // Vérification Service Role
    const authHeader = req.headers.get("Authorization")?.replace("Bearer ", "");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!authHeader || authHeader !== serviceKey) {
      throw new Error("Unauthorized: Service role required");
    }

    console.log("[Sync Revenues] Starting...");

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    // Récupérer les revenus 'pending' avec les commandes associées
    const { data: pendingRevenues, error: fetchError } = await supabase
      .from("revenues")
      .select(`
        id,
        order_id,
        amount,
        status,
        orders:order_id (
          stripe_payment_intent_id,
          stripe_payment_status
        )
      `)
      .eq("status", "pending")
      .limit(100);

    if (fetchError) {
      throw new Error(`Failed to fetch revenues: ${fetchError.message}`);
    }

    if (!pendingRevenues || pendingRevenues.length === 0) {
      return new Response(JSON.stringify({
        success: true,
        synced: 0,
        message: "No pending revenues to sync",
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      });
    }

    console.log(`[Sync] Found ${pendingRevenues.length} pending revenues`);

    let syncedCount = 0;

    for (const revenue of pendingRevenues) {
      const order = revenue.orders as unknown as {
        stripe_payment_intent_id: string | null;
        stripe_payment_status: string;
      };

      if (!order || !order.stripe_payment_intent_id) continue;

      try {
        const pi = await stripe.paymentIntents.retrieve(order.stripe_payment_intent_id);

        // Si le paiement est capturé, le revenue devient disponible
        if (pi.status === "succeeded" && revenue.status === "pending") {
          await supabase
            .from("revenues")
            .update({
              status: "available",
              updated_at: new Date().toISOString(),
            })
            .eq("id", revenue.id);

          syncedCount++;
          console.log(`[Sync] Revenue ${revenue.id} marked as available`);
        }

      } catch (stripeErr: unknown) {
        const err = stripeErr as Error;
        console.warn(`[Sync] Could not fetch PI for revenue ${revenue.id}:`, err.message);
      }
    }

    // Log système
    await supabase.from("system_logs").insert({
      event_type: "info",
      message: "Revenue sync completed",
      details: {
        checked: pendingRevenues.length,
        synced: syncedCount,
      },
    });

    return new Response(JSON.stringify({
      success: true,
      checked: pendingRevenues.length,
      synced: syncedCount,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("[Sync Revenues Error]:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 500,
    });
  }
});
