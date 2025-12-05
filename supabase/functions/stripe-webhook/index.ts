import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import Stripe from "https://esm.sh/stripe@11.1.0?target=deno";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") as string, {
  apiVersion: "2022-11-15",
  httpClient: Stripe.createFetchHttpClient(),
});

const cryptoProvider = Stripe.createSubtleCryptoProvider();

serve(async (req) => {
  const signature = req.headers.get("Stripe-Signature");
  const body = await req.text();

  try {
    const event = await stripe.webhooks.constructEventAsync(
      body,
      signature!,
      Deno.env.get("STRIPE_WEBHOOK_SECRET")!,
      undefined,
      cryptoProvider
    );

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    if (event.type === "checkout.session.completed") {
      const session = event.data.object as Stripe.Checkout.Session;
      const orderId = session.metadata?.order_id;

      if (orderId) {
        console.log(`[Webhook] Checkout completed for order: ${orderId}`);

        // 1. Update Order Status
        const { error: updateError } = await supabase
          .from("orders")
          .update({
            stripe_payment_status: "succeeded",
            status: "payment_authorized", // Or 'accepted' if auto-accept
            payment_authorized_at: new Date().toISOString(),
          })
          .eq("id", orderId);

        if (updateError) console.error("Error updating order:", updateError);

        // 2. Distribute Commissions (Financial Logic)
        const { error: rpcError } = await supabase.rpc("distribute_commissions", {
          p_order_id: orderId,
        });

        if (rpcError) {
          console.error("Error distributing commissions:", rpcError);
          // Log critical error to system_logs
          await supabase.from("system_logs").insert({
            event_type: "error",
            message: "Failed to distribute commissions",
            details: { order_id: orderId, error: rpcError },
          });
        } else {
          console.log(`[Webhook] Commissions distributed for order: ${orderId}`);
        }
      }
    }

    return new Response(JSON.stringify({ received: true }), { status: 200 });
  } catch (err) {
    console.error(`Webhook Error: ${err.message}`);
    return new Response(`Webhook Error: ${err.message}`, { status: 400 });
  }
});
