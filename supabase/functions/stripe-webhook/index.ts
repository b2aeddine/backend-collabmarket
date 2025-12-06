import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import Stripe from "https://esm.sh/stripe@14.21.0?target=deno";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") as string, {
  apiVersion: "2023-10-16",
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

    // 1. IDEMPOTENCY CHECK (Fast Fail)
    // ------------------------------------------------------------------------
    // We insert into processed_events immediately. 
    // If it exists, we return 200 OK (idempotent).
    const { error: insertError } = await supabase
      .from("processed_events")
      .insert({
        event_id: event.id,
        event_type: event.type,
        order_id: event.data.object.metadata?.order_id || null,
      });

    if (insertError) {
      // If unique constraint violation, it's a duplicate.
      if (insertError.code === "23505") {
        console.log(`[Webhook] Duplicate event ignored: ${event.id}`);
        return new Response(JSON.stringify({ received: true, duplicate: true }), { status: 200 });
      }
      console.error("[Webhook] DB Error:", insertError);
      throw insertError;
    }

    // 2. QUEUE EVENT (Serialization)
    // ------------------------------------------------------------------------
    // Instead of processing immediately, we push to job_queue.
    // A separate worker (triggered by DB or Cron) will process it.
    // This ensures we can handle out-of-order events or retry logic.

    const relevantEvents = [
      "payment_intent.amount_capturable_updated", // Auth success
      "payment_intent.succeeded", // Capture success
      "payment_intent.payment_failed",
      "payment_intent.canceled",
      "charge.refunded"
    ];

    if (relevantEvents.includes(event.type)) {
      const { error: queueError } = await supabase
        .from("job_queue")
        .insert({
          job_type: "stripe_webhook",
          payload: event,
          status: "pending"
        });

      if (queueError) {
        console.error("[Webhook] Queue Error:", queueError);
        throw queueError;
      }
      console.log(`[Webhook] Event queued: ${event.type} (${event.id})`);
    } else {
      console.log(`[Webhook] Event ignored (not relevant): ${event.type}`);
    }

    return new Response(JSON.stringify({ received: true }), { status: 200 });

  } catch (err) {
    console.error(`Webhook Error: ${err.message}`);
    return new Response(`Webhook Error: ${err.message}`, { status: 400 });
  }
});
