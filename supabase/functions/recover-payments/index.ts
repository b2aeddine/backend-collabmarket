// ==============================================================================
// RECOVER-PAYMENTS - V14.1 (SECURED)
// Récupère et synchronise les paiements en attente
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
      console.warn("[Recover Payments] Unauthorized access attempt");
      return authError;
    }

    console.log("[Recover Payments] Starting payment sync...");

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    // Récupérer les commandes avec un paiement en cours
    const { data: pendingOrders, error: fetchError } = await supabase
      .from("orders")
      .select("id, stripe_payment_intent_id, status, stripe_payment_status")
      .not("stripe_payment_intent_id", "is", null)
      .in("stripe_payment_status", ["unpaid", "requires_payment_method", "requires_capture", "processing"])
      .limit(100);

    if (fetchError) {
      throw new Error(`Failed to fetch orders: ${fetchError.message}`);
    }

    if (!pendingOrders || pendingOrders.length === 0) {
      return new Response(JSON.stringify({
        success: true,
        synced: 0,
        message: "No pending payments to sync",
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      });
    }

    console.log(`[Recover] Found ${pendingOrders.length} orders to check`);

    let syncedCount = 0;
    const updates: Array<{ orderId: string; oldStatus: string; newStatus: string }> = [];

    for (const order of pendingOrders) {
      if (!order.stripe_payment_intent_id) continue;

      try {
        const pi = await stripe.paymentIntents.retrieve(order.stripe_payment_intent_id);

        let newPaymentStatus = order.stripe_payment_status;
        let newOrderStatus = order.status;
        let updateNeeded = false;

        // Mapper le statut Stripe vers notre statut
        switch (pi.status) {
          case "requires_capture":
            if (order.stripe_payment_status !== "authorized") {
              newPaymentStatus = "authorized";
              if (order.status === "pending") {
                newOrderStatus = "payment_authorized";
              }
              updateNeeded = true;
            }
            break;

          case "succeeded":
            if (order.stripe_payment_status !== "captured") {
              newPaymentStatus = "captured";
              updateNeeded = true;
            }
            break;

          case "canceled":
            if (order.stripe_payment_status !== "canceled") {
              newPaymentStatus = "canceled";
              if (!["cancelled", "disputed"].includes(order.status)) {
                newOrderStatus = "cancelled";
              }
              updateNeeded = true;
            }
            break;

          case "requires_payment_method":
            // Paiement échoué ou annulé par le client
            if (order.stripe_payment_status !== "requires_payment_method") {
              newPaymentStatus = "requires_payment_method";
              updateNeeded = true;
            }
            break;
        }

        if (updateNeeded) {
          const updateData: Record<string, unknown> = {
            stripe_payment_status: newPaymentStatus,
          };

          if (newOrderStatus !== order.status) {
            updateData.status = newOrderStatus;
          }

          if (newPaymentStatus === "authorized" && !order.stripe_payment_status?.includes("authorized")) {
            updateData.payment_authorized_at = new Date().toISOString();
            updateData.acceptance_deadline = new Date(Date.now() + 48 * 60 * 60 * 1000).toISOString();
          }

          if (newPaymentStatus === "captured") {
            updateData.captured_at = new Date().toISOString();
          }

          await supabase
            .from("orders")
            .update(updateData)
            .eq("id", order.id);

          updates.push({
            orderId: order.id,
            oldStatus: order.stripe_payment_status,
            newStatus: newPaymentStatus,
          });

          syncedCount++;
          console.log(`[Recover] Synced order ${order.id}: ${order.stripe_payment_status} -> ${newPaymentStatus}`);
        }

      } catch (stripeErr: unknown) {
        const err = stripeErr as Error;
        console.warn(`[Recover] Could not fetch PI for order ${order.id}:`, err.message);
      }
    }

    // Log système
    if (syncedCount > 0) {
      await supabase.from("system_logs").insert({
        event_type: "info",
        message: "Payment recovery completed",
        details: {
          checked: pendingOrders.length,
          synced: syncedCount,
          updates,
        },
      });
    }

    return new Response(JSON.stringify({
      success: true,
      checked: pendingOrders.length,
      synced: syncedCount,
      updates,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("[Recover Payments Error]:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 500,
    });
  }
});
