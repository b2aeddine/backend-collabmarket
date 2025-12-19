// ==============================================================================
// STRIPE UTILITIES - Webhook verification, idempotency, event ordering
// ==============================================================================

import Stripe from "https://esm.sh/stripe@14.21.0";
import { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

// Event dependencies for out-of-order handling
// Key: event type, Value: event types that must be processed first
const EVENT_DEPENDENCIES: Record<string, string[]> = {
  "payment_intent.succeeded": ["payment_intent.amount_capturable_updated"],
  "charge.refunded": ["payment_intent.succeeded"],
  "payout.paid": [], // No dependencies
  "payout.failed": [], // No dependencies
  "checkout.session.completed": [],
  "account.updated": [],
};

// Event priority (higher = more urgent)
const EVENT_PRIORITIES: Record<string, number> = {
  "charge.dispute.created": 10,
  "payout.failed": 9,
  "payment_intent.payment_failed": 8,
  "charge.refunded": 7,
  "payment_intent.succeeded": 6,
  "payment_intent.amount_capturable_updated": 5,
  "payout.paid": 4,
  "checkout.session.completed": 3,
  "account.updated": 2,
  default: 1,
};

/**
 * Get the priority of an event type
 */
export function getEventPriority(eventType: string): number {
  return EVENT_PRIORITIES[eventType] ?? EVENT_PRIORITIES["default"];
}

/**
 * Get resource info from Stripe event
 */
export function getResourceInfo(event: Stripe.Event): {
  resourceType: string;
  resourceId: string;
} {
  const data = event.data.object as Record<string, unknown>;

  // Determine resource type from event type
  const eventParts = event.type.split(".");
  const resourceType = eventParts[0]; // 'payment_intent', 'payout', 'charge', etc.

  // Get resource ID
  const resourceId = (data.id as string) || "";

  return { resourceType, resourceId };
}

/**
 * Log event to stripe_event_log for tracking order and dependencies
 */
export async function logStripeEvent(
  supabase: SupabaseClient,
  event: Stripe.Event
): Promise<{ success: boolean; error?: string }> {
  const { resourceType, resourceId } = getResourceInfo(event);

  // Determine dependency (if any)
  let dependsOnEvent: string | null = null;
  const dependencies = EVENT_DEPENDENCIES[event.type];

  if (dependencies && dependencies.length > 0) {
    // Check if we have any of the dependency events for this resource
    const { data: dependencyEvents } = await supabase
      .from("stripe_event_log")
      .select("event_id, processed")
      .eq("resource_id", resourceId)
      .in("event_type", dependencies)
      .order("event_created", { ascending: false })
      .limit(1);

    if (dependencyEvents && dependencyEvents.length > 0) {
      const dep = dependencyEvents[0];
      if (!dep.processed) {
        dependsOnEvent = dep.event_id;
      }
    }
  }

  const { error } = await supabase.from("stripe_event_log").upsert(
    {
      event_id: event.id,
      event_type: event.type,
      resource_type: resourceType,
      resource_id: resourceId,
      event_created: event.created,
      depends_on_event: dependsOnEvent,
    },
    { onConflict: "event_id" }
  );

  if (error) {
    console.error("[Stripe Utils] Failed to log event:", error);
    return { success: false, error: error.message };
  }

  return { success: true };
}

/**
 * Mark event as processed in stripe_event_log
 */
export async function markEventProcessed(
  supabase: SupabaseClient,
  eventId: string,
  error?: string
): Promise<void> {
  await supabase
    .from("stripe_event_log")
    .update({
      processed: error ? false : true,
      processed_at: new Date().toISOString(),
      error: error || null,
      retry_count: error
        ? supabase.rpc("increment_retry_count", { p_event_id: eventId })
        : undefined,
    })
    .eq("event_id", eventId);
}

/**
 * Check if event can be processed (dependencies resolved)
 */
export async function canProcessEvent(
  supabase: SupabaseClient,
  eventId: string
): Promise<boolean> {
  const { data } = await supabase.rpc("can_process_stripe_event", {
    p_event_id: eventId,
  });
  return data === true;
}

/**
 * Get pending events that can be processed (dependencies resolved)
 */
export async function getPendingEvents(
  supabase: SupabaseClient,
  limit: number = 10
): Promise<Array<{ event_id: string; event_type: string; resource_id: string }>> {
  // Get unprocessed events where either:
  // 1. No dependency
  // 2. Dependency is processed
  const { data, error } = await supabase
    .from("stripe_event_log")
    .select("event_id, event_type, resource_id, depends_on_event")
    .eq("processed", false)
    .order("event_created", { ascending: true })
    .limit(limit * 2); // Get more to filter

  if (error || !data) {
    return [];
  }

  // Filter to events that can be processed
  const processable: Array<{
    event_id: string;
    event_type: string;
    resource_id: string;
  }> = [];

  for (const event of data) {
    if (!event.depends_on_event) {
      processable.push(event);
    } else {
      // Check if dependency is processed
      const { data: depData } = await supabase
        .from("stripe_event_log")
        .select("processed")
        .eq("event_id", event.depends_on_event)
        .single();

      if (depData?.processed) {
        processable.push(event);
      }
    }

    if (processable.length >= limit) break;
  }

  // Sort by priority
  return processable.sort(
    (a, b) => getEventPriority(b.event_type) - getEventPriority(a.event_type)
  );
}

/**
 * Verify Stripe webhook signature and construct event
 */
export async function verifyStripeWebhook(
  body: string,
  signature: string,
  webhookSecret: string
): Promise<{ event: Stripe.Event | null; error: string | null }> {
  const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
    apiVersion: "2023-10-16",
    httpClient: Stripe.createFetchHttpClient(),
  });

  const cryptoProvider = Stripe.createSubtleCryptoProvider();

  try {
    const event = await stripe.webhooks.constructEventAsync(
      body,
      signature,
      webhookSecret,
      undefined,
      cryptoProvider
    );
    return { event, error: null };
  } catch (err) {
    const error = err as Error;
    console.error("[Stripe Verify] Signature verification failed:", error.message);
    return { event: null, error: error.message };
  }
}

/**
 * Compute SHA-256 hash of payload for idempotency
 */
export async function hashPayload(payload: string): Promise<string> {
  const data = new TextEncoder().encode(payload);
  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Check idempotency and record webhook
 */
export async function checkIdempotency(
  supabase: SupabaseClient,
  eventId: string,
  eventType: string,
  payloadHash: string
): Promise<{ isNew: boolean; error?: string }> {
  // Use atomic RPC for idempotency
  const { data: isNewEvent, error: rpcError } = await supabase.rpc(
    "check_webhook_replay",
    {
      p_event_id: eventId,
      p_event_type: eventType,
      p_payload_hash: payloadHash,
    }
  );

  if (rpcError) {
    console.error("[Idempotency] RPC error:", rpcError);

    // Fallback to direct insert
    const { error: insertError } = await supabase
      .from("processed_webhooks")
      .insert({
        event_id: eventId,
        event_type: eventType,
        payload_hash: payloadHash,
      });

    if (insertError?.code === "23505") {
      return { isNew: false };
    }

    if (insertError) {
      return { isNew: false, error: insertError.message };
    }

    return { isNew: true };
  }

  return { isNew: isNewEvent === true };
}
