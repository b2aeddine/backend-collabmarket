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

    // 1. AUTHENTICATION (User must be logged in)
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) throw new Error("Missing Authorization Header");

    const { data: { user }, error: authError } = await supabase.auth.getUser(authHeader.replace("Bearer ", ""));
    if (authError || !user) throw new Error("Unauthorized");

    const { order_id } = await req.json();
    if (!order_id) throw new Error("Missing order_id");

    // 2. FETCH ORDER & VALIDATE
    const { data: order, error: orderError } = await supabase
      .from("orders")
      .select("*")
      .eq("id", order_id)
      .single();

    if (orderError || !order) throw new Error("Order not found");

    // 3. SECURITY CHECKS
    // Only the Seller (Influencer) can accept/capture
    if (order.influencer_id !== user.id) {
      throw new Error("Unauthorized: Only the assigned influencer can accept this order.");
    }

    // Strict Status Check
    if (order.status !== "payment_authorized") {
      throw new Error(`Invalid status: Cannot capture order in state '${order.status}'. Must be 'payment_authorized'.`);
    }

    if (!order.stripe_payment_intent_id) {
      throw new Error("Missing Stripe Payment Intent ID");
    }

    // 4. STRIPE CAPTURE
    console.log(`[Capture] Capturing payment for order ${order_id} (PI: ${order.stripe_payment_intent_id})`);

    const paymentIntent = await stripe.paymentIntents.capture(order.stripe_payment_intent_id);

    if (paymentIntent.status !== "succeeded") {
      throw new Error(`Stripe Capture Failed: Status is ${paymentIntent.status}`);
    }

    // 5. UPDATE ORDER STATUS
    // We update to 'accepted' or 'awaiting_delivery'. 
    // The user workflow says: "L’influenceur a 48h pour accepter → si oui, Stripe capture le paiement"
    // So status should be 'accepted' (or 'in_progress' / 'awaiting_delivery').
    // Let's use 'awaiting_delivery' as per plan.

    const { error: updateError } = await supabase
      .from("orders")
      .update({
        status: "awaiting_delivery",
        stripe_payment_status: "captured", // Sync immediately, webhook will confirm
        accepted_at: new Date().toISOString(),
        updated_at: new Date().toISOString()
      })
      .eq("id", order_id);

    if (updateError) throw updateError;

    // 6. LOG AUDIT
    await supabase.from("audit_logs").insert({
      user_id: user.id,
      event_name: "order_accepted_captured",
      table_name: "orders",
      record_id: order_id,
      new_values: { status: "awaiting_delivery", stripe_status: "captured" }
    });

    return new Response(JSON.stringify({ success: true, order_id }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error) {
    console.error(`Capture Error: ${error.message}`);
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
