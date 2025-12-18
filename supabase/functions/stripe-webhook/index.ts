// ==============================================================================
// STRIPE-WEBHOOK - V15.1 (SCHEMA V40 ALIGNED)
// Receives Stripe webhook events and queues them for processing
// ALIGNED: Uses processed_webhooks via check_webhook_replay RPC
// ALIGNED: Uses process_webhook job type
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import Stripe from "https://esm.sh/stripe@14.21.0";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
  httpClient: Stripe.createFetchHttpClient(),
});

const cryptoProvider = Stripe.createSubtleCryptoProvider();

// Compute SHA-256 hash of payload for extra idempotency
async function hashPayload(payload: string): Promise<string> {
  const data = new TextEncoder().encode(payload);
  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map(b => b.toString(16).padStart(2, "0")).join("");
}

serve(async (req) => {
  const signature = req.headers.get("Stripe-Signature");
  const body = await req.text();

  if (!signature) {
    console.error("[Webhook] Missing Stripe-Signature header");
    return new Response("Missing signature", { status: 400 });
  }

  try {
    // Verify webhook signature (Stripe validation)
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

    // Hash payload for extra idempotency tracking
    const payloadHash = await hashPayload(body);

    // 1. IDEMPOTENCY CHECK via atomic RPC
    // ------------------------------------------------------------------------
    // check_webhook_replay returns TRUE if new event, FALSE if duplicate
    // It atomically inserts into processed_webhooks if new
    const { data: isNewEvent, error: replayError } = await supabase.rpc("check_webhook_replay", {
      p_event_id: event.id,
      p_event_type: event.type,
      p_payload_hash: payloadHash,
    });

    if (replayError) {
      console.error("[Webhook] check_webhook_replay error:", replayError);
      // If RPC fails, fall back to direct insert (defensive)
      const { error: insertError } = await supabase
        .from("processed_webhooks")
        .insert({
          event_id: event.id,
          event_type: event.type,
          payload_hash: payloadHash,
        });

      if (insertError?.code === "23505") {
        console.log(`[Webhook] Duplicate event ignored: ${event.id}`);
        return new Response(JSON.stringify({ received: true, duplicate: true }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
    } else if (isNewEvent === false) {
      // Duplicate event detected by RPC
      console.log(`[Webhook] Duplicate event ignored: ${event.id}`);
      return new Response(JSON.stringify({ received: true, duplicate: true }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    console.log(`[Webhook] Processing event: ${event.type} (${event.id})`);

    // 2. QUEUE EVENT (Serialization)
    // ------------------------------------------------------------------------
    // Instead of processing immediately, we push to job_queue.
    // A separate worker (triggered by DB or Cron) will process it.
    // This ensures we can handle out-of-order events or retry logic.

    const relevantEvents = [
      // Payment lifecycle
      "payment_intent.amount_capturable_updated", // Auth success (funds reserved)
      "payment_intent.succeeded",                  // Capture success (payment complete)
      "payment_intent.payment_failed",             // Payment failed
      "payment_intent.canceled",                   // Payment canceled
      "charge.refunded",                           // Refund processed

      // Checkout
      "checkout.session.completed",                // Checkout session completed
      "checkout.session.expired",                  // Checkout session expired

      // Connect accounts
      "account.updated",                           // Connect account updated (onboarding)

      // Payouts
      "payout.paid",                               // Payout completed (withdrawal success)
      "payout.failed",                             // Payout failed (withdrawal failure)

      // Disputes
      "charge.dispute.created",                    // Dispute opened
      "charge.dispute.closed",                     // Dispute resolved
    ];

    if (relevantEvents.includes(event.type)) {
      // Enqueue for async processing
      const { error: queueError } = await supabase
        .from("job_queue")
        .insert({
          job_type: "process_webhook",  // v40 schema: job_type_enum includes 'process_webhook'
          payload: {
            event_id: event.id,
            event_type: event.type,
            data: event.data.object,
            created: event.created,
          },
          status: "pending",
        });

      if (queueError) {
        console.error("[Webhook] Queue Error:", queueError);
        // Don't throw - webhook was recorded, just couldn't queue
        // System will need to replay from processed_webhooks
      } else {
        console.log(`[Webhook] Event queued: ${event.type} (${event.id})`);
      }
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
