// ==============================================================================
// STRIPE-WEBHOOK - V15.2 (SCHEMA V40.11 ALIGNED)
// Receives Stripe webhook events and queues them for processing
// FEATURES:
// - Signature verification
// - Atomic idempotency via check_webhook_replay RPC
// - Event logging for out-of-order handling
// - Alerting on failures
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import Stripe from "https://esm.sh/stripe@14.21.0";
import {
  verifyStripeWebhook,
  hashPayload,
  checkIdempotency,
  logStripeEvent,
  getEventPriority,
} from "../_shared/stripe-utils.ts";
import { alert } from "../_shared/alerting.ts";

// Relevant events to process
const RELEVANT_EVENTS = [
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

serve(async (req) => {
  const signature = req.headers.get("Stripe-Signature");
  const body = await req.text();

  // 1. VALIDATE SIGNATURE
  // -------------------------------------------------------------------------
  if (!signature) {
    console.error("[Webhook] Missing Stripe-Signature header");
    return new Response(JSON.stringify({ error: "Missing signature" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!webhookSecret) {
    console.error("[Webhook] STRIPE_WEBHOOK_SECRET not configured");
    return new Response(JSON.stringify({ error: "Webhook not configured" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  // 2. VERIFY WEBHOOK SIGNATURE
  // -------------------------------------------------------------------------
  const { event, error: verifyError } = await verifyStripeWebhook(
    body,
    signature,
    webhookSecret
  );

  if (verifyError || !event) {
    console.error("[Webhook] Signature verification failed:", verifyError);
    return new Response(
      JSON.stringify({ error: "Invalid signature", details: verifyError }),
      { status: 400, headers: { "Content-Type": "application/json" } }
    );
  }

  // 3. INITIALIZE SUPABASE CLIENT
  // -------------------------------------------------------------------------
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  try {
    // 4. IDEMPOTENCY CHECK
    // -----------------------------------------------------------------------
    const payloadHash = await hashPayload(body);
    const { isNew, error: idempotencyError } = await checkIdempotency(
      supabase,
      event.id,
      event.type,
      payloadHash
    );

    if (idempotencyError) {
      console.error("[Webhook] Idempotency check error:", idempotencyError);
      // Continue anyway - better to potentially double-process than drop
    }

    if (!isNew) {
      console.log(`[Webhook] Duplicate event ignored: ${event.id}`);
      return new Response(
        JSON.stringify({ received: true, duplicate: true }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    }

    console.log(`[Webhook] Processing event: ${event.type} (${event.id})`);

    // 5. LOG EVENT FOR OUT-OF-ORDER TRACKING
    // -----------------------------------------------------------------------
    const logResult = await logStripeEvent(supabase, event);
    if (!logResult.success) {
      console.warn("[Webhook] Failed to log event for tracking:", logResult.error);
    }

    // 6. QUEUE EVENT FOR ASYNC PROCESSING
    // -----------------------------------------------------------------------
    if (RELEVANT_EVENTS.includes(event.type)) {
      const priority = getEventPriority(event.type);

      const { error: queueError } = await supabase.from("job_queue").insert({
        job_type: "process_webhook",
        payload: {
          event_id: event.id,
          event_type: event.type,
          data: event.data.object,
          created: event.created,
        },
        status: "pending",
        priority: priority,
      });

      if (queueError) {
        console.error("[Webhook] Queue Error:", queueError);

        // Alert on queue failure
        await alert(
          supabase,
          "webhook_failure",
          "error",
          `Failed to queue webhook: ${event.type}`,
          queueError.message,
          { event_id: event.id, event_type: event.type }
        );

        // Return 500 so Stripe will retry
        return new Response(
          JSON.stringify({ error: "Failed to queue event", retry: true }),
          { status: 500, headers: { "Content-Type": "application/json" } }
        );
      }

      console.log(`[Webhook] Event queued with priority ${priority}: ${event.type} (${event.id})`);
    } else {
      console.log(`[Webhook] Event ignored (not relevant): ${event.type}`);
    }

    // 7. SUCCESS RESPONSE
    // -----------------------------------------------------------------------
    return new Response(
      JSON.stringify({ received: true, event_id: event.id }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );

  } catch (err: unknown) {
    const error = err as Error;
    console.error(`[Webhook Error]: ${error.message}`);

    // Alert on unexpected error
    await alert(
      supabase,
      "webhook_failure",
      "critical",
      `Webhook processing error: ${event.type}`,
      error.message,
      { event_id: event.id, event_type: event.type, stack: error.stack }
    );

    // Return 500 so Stripe will retry
    return new Response(
      JSON.stringify({ error: error.message, retry: true }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }
});
