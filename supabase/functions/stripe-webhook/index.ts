// ==============================================================================
// STRIPE-WEBHOOK - V15.0 (SCHEMA V40 ALIGNED)
// Receives Stripe webhook events and queues them for processing
// ALIGNED: Uses processed_webhooks table, process_webhook job type
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import Stripe from "https://esm.sh/stripe@14.21.0";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
  httpClient: Stripe.createFetchHttpClient(),
});

const cryptoProvider = Stripe.createSubtleCryptoProvider();

serve(async (req) => {
  const signature = req.headers.get("Stripe-Signature");
  const body = await req.text();

  if (!signature) {
    console.error("[Webhook] Missing Stripe-Signature header");
    return new Response("Missing signature", { status: 400 });
  }

  try {
    // Verify webhook signature
    const event = await stripe.webhooks.constructEventAsync(
      body,
      signature,
      Deno.env.get("STRIPE_WEBHOOK_SECRET")!,
      undefined,
      cryptoProvider
    );

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Extract order_id from metadata (if available)
    const metadata = (event.data.object as { metadata?: { order_id?: string } }).metadata;
    const orderId = metadata?.order_id || null;

    // 1. IDEMPOTENCY CHECK (Fast Fail)
    // ------------------------------------------------------------------------
    // We insert into processed_webhooks immediately.
    // If it exists, we return 200 OK (idempotent).
    const { error: insertError } = await supabase
      .from("processed_webhooks")  // v40 schema: processed_webhooks (not processed_events)
      .insert({
        event_id: event.id,
        event_type: event.type,
        order_id: orderId,
      });

    if (insertError) {
      // If unique constraint violation, it's a duplicate.
      if (insertError.code === "23505") {
        console.log(`[Webhook] Duplicate event ignored: ${event.id}`);
        return new Response(JSON.stringify({ received: true, duplicate: true }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
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
      "payment_intent.amount_capturable_updated", // Auth success (funds reserved)
      "payment_intent.succeeded",                  // Capture success (payment complete)
      "payment_intent.payment_failed",             // Payment failed
      "payment_intent.canceled",                   // Payment canceled
      "charge.refunded",                           // Refund processed
      "checkout.session.completed",                // Checkout session completed
      "checkout.session.expired",                  // Checkout session expired
      "account.updated",                           // Connect account updated
      "payout.paid",                               // Payout completed
      "payout.failed",                             // Payout failed
    ];

    if (relevantEvents.includes(event.type)) {
      const { error: queueError } = await supabase
        .from("job_queue")
        .insert({
          job_type: "process_webhook",  // v40 schema: job_type_enum includes 'process_webhook'
          payload: event,
          status: "pending",
        });

      if (queueError) {
        console.error("[Webhook] Queue Error:", queueError);
        throw queueError;
      }
      console.log(`[Webhook] Event queued: ${event.type} (${event.id})`);
    } else {
      console.log(`[Webhook] Event ignored (not relevant): ${event.type}`);
    }

    return new Response(JSON.stringify({ received: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });

  } catch (err: unknown) {
    const error = err as Error;
    console.error(`[Webhook Error]: ${error.message}`);
    return new Response(`Webhook Error: ${error.message}`, { status: 400 });
  }
});
