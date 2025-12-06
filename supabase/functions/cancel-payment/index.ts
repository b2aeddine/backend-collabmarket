import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import Stripe from "https://esm.sh/stripe@14.21.0?target=deno";
import { corsHeaders } from "../shared/utils/cors.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") as string, {
  apiVersion: "2023-10-16",
  httpClient: Stripe.createFetchHttpClient(),
});

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    // 1. AUTHENTICATION
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) throw new Error("Missing Authorization Header");

    const { data: { user }, error: authError } = await supabase.auth.getUser(authHeader.replace("Bearer ", ""));
    if (authError || !user) throw new Error("Unauthorized");

    const { order_id, reason } = await req.json();
    if (!order_id) throw new Error("Missing order_id");

    // 2. FETCH ORDER
    const { data: order, error: orderError } = await supabase
      .from("orders")
      .select("*")
      .eq("id", order_id)
      .single();

    if (orderError || !order) throw new Error("Order not found");

    // 3. SECURITY & STATE CHECKS
    // Who can cancel?
    // - Merchant (Buyer) if status is 'submitted' or 'payment_authorized' (before acceptance)
    // - Influencer (Seller) if status is 'payment_authorized' (Refusal)
    // - Admin (Anytime)

    const isBuyer = order.merchant_id === user.id;
    const isSeller = order.influencer_id === user.id;
    // const isAdmin = ... (check via RPC or claims)

    if (!isBuyer && !isSeller) {
      // Check if admin? For now assume strict role check.
      throw new Error("Unauthorized: Only buyer or seller can cancel.");
    }

    if (order.status !== "payment_authorized" && order.status !== "submitted") {
      throw new Error(`Cannot cancel order in state '${order.status}'. Only 'payment_authorized' or 'submitted' orders can be cancelled via this endpoint.`);
    }

    if (!order.stripe_payment_intent_id) {
      throw new Error("Missing Stripe Payment Intent ID");
    }

    // 4. STRIPE CANCEL (RELEASE AUTH)
    console.log(`[Cancel] Cancelling payment intent ${order.stripe_payment_intent_id} for order ${order_id}`);

    const paymentIntent = await stripe.paymentIntents.cancel(order.stripe_payment_intent_id, {
      cancellation_reason: reason || (isSeller ? "abandoned" : "requested_by_customer"),
    });

    if (paymentIntent.status !== "canceled") {
      throw new Error(`Stripe Cancel Failed: Status is ${paymentIntent.status}`);
    }

    // 5. UPDATE ORDER STATUS
    const { error: updateError } = await supabase
      .from("orders")
      .update({
        status: "cancelled",
        stripe_payment_status: "canceled",
        cancelled_at: new Date().toISOString(),
        updated_at: new Date().toISOString()
      })
      .eq("id", order_id);

    if (updateError) throw updateError;

    // 6. LOG AUDIT
    await supabase.from("audit_logs").insert({
      user_id: user.id,
      event_name: "order_cancelled",
      table_name: "orders",
      record_id: order_id,
      new_values: { status: "cancelled", stripe_status: "canceled", reason }
    });

    return new Response(JSON.stringify({ success: true, order_id }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error) {
    console.error(`Cancel Error: ${error.message}`);
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
