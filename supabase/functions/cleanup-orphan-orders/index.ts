// ==============================================================================
// CLEANUP-ORPHAN-ORDERS - V14.1 (SECURED)
// Nettoie les commandes orphelines (sans paiement après X heures)
// SECURITY: Uses CRON_SECRET instead of exposing service role key
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
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
      console.warn("[Cleanup Orphan Orders] Unauthorized access attempt");
      return authError;
    }

    console.log("[Cleanup Orphan Orders] Starting...");

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    // Trouver les commandes "pending" créées il y a plus de 2 heures
    const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString();

    const { data: orphanOrders, error: fetchError } = await supabase
      .from("orders")
      .select("id, stripe_payment_intent_id, created_at")
      .eq("status", "pending")
      .lt("created_at", twoHoursAgo)
      .limit(100);

    if (fetchError) {
      throw new Error(`Failed to fetch orphan orders: ${fetchError.message}`);
    }

    if (!orphanOrders || orphanOrders.length === 0) {
      console.log("[Cleanup] No orphan orders found.");
      return new Response(JSON.stringify({
        success: true,
        cleaned: 0,
        message: "No orphan orders to clean",
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      });
    }

    console.log(`[Cleanup] Found ${orphanOrders.length} orphan orders`);

    let cleanedCount = 0;
    const errors: Array<{ orderId: string; error: string }> = [];

    for (const order of orphanOrders) {
      try {
        // Si un PaymentIntent existe, l'annuler
        if (order.stripe_payment_intent_id) {
          try {
            const pi = await stripe.paymentIntents.retrieve(order.stripe_payment_intent_id);
            
            if (pi.status !== "canceled" && pi.status !== "succeeded") {
              await stripe.paymentIntents.cancel(order.stripe_payment_intent_id);
              console.log(`[Cleanup] Canceled PI: ${order.stripe_payment_intent_id}`);
            }
          } catch (stripeErr) {
            console.warn(`[Cleanup] Could not cancel PI ${order.stripe_payment_intent_id}:`, stripeErr);
          }
        }

        // Mettre à jour le statut
        await supabase
          .from("orders")
          .update({
            status: "cancelled",
            stripe_payment_status: "canceled",
          })
          .eq("id", order.id);

        // Audit
        await supabase.from("audit_orders").insert({
          order_id: order.id,
          old_status: "pending",
          new_status: "cancelled",
          notes: "Auto-cleaned: orphan order without payment",
        });

        cleanedCount++;

      } catch (err: unknown) {
        const error = err as Error;
        errors.push({ orderId: order.id, error: error.message });
      }
    }

    // Log système
    await supabase.from("system_logs").insert({
      event_type: "cron",
      message: "Orphan orders cleanup completed",
      details: {
        found: orphanOrders.length,
        cleaned: cleanedCount,
        errors: errors.length,
      },
    });

    return new Response(JSON.stringify({
      success: true,
      found: orphanOrders.length,
      cleaned: cleanedCount,
      errors: errors.length > 0 ? errors : undefined,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("[Cleanup Error]:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 500,
    });
  }
});
