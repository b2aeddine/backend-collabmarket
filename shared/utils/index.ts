// ==============================================================================
// SHARED UTILITIES - V20.0
// Emplacement partagé pour les Edge Functions (import: ../shared/utils/index.ts)
// ==============================================================================

import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

// ==============================================================================
// CORS HEADERS
// ==============================================================================
export const corsHeaders = {
  "Access-Control-Allow-Origin": "*", // En production, remplacer par votre domaine
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// ==============================================================================
// JSON RESPONSE HELPER
// ==============================================================================
export function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// ==============================================================================
// ERROR RESPONSE HELPER
// ==============================================================================
export function errorResponse(message: string, status = 400, code?: string): Response {
  return json({ success: false, error: message, code }, status);
}

// ==============================================================================
// CORS PREFLIGHT HANDLER
// ==============================================================================
export function handleCors(req: Request): Response | null {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }
  return null;
}

// ==============================================================================
// ENVIRONMENT VARIABLES
// ==============================================================================
export function getEnvOrThrow(key: string): string {
  const value = Deno.env.get(key);
  if (!value) {
    throw new Error(`Missing required environment variable: ${key}`);
  }
  return value;
}

export const ENV = {
  get SUPABASE_URL() { return getEnvOrThrow("SUPABASE_URL"); },
  get SUPABASE_ANON_KEY() { return getEnvOrThrow("SUPABASE_ANON_KEY"); },
  get SUPABASE_SERVICE_ROLE_KEY() { return getEnvOrThrow("SUPABASE_SERVICE_ROLE_KEY"); },
  get STRIPE_SECRET_KEY() { return getEnvOrThrow("STRIPE_SECRET_KEY"); },
  get STRIPE_WEBHOOK_SECRET() { return Deno.env.get("STRIPE_WEBHOOK_SECRET") || ""; },
  get STRIPE_CONNECT_WEBHOOK_SECRET() { return Deno.env.get("STRIPE_CONNECT_WEBHOOK_SECRET") || ""; },
};

// ==============================================================================
// SUPABASE CLIENT FACTORIES
// ==============================================================================

/**
 * Client avec contexte utilisateur (RLS activé)
 */
export function createUserClient(authHeader: string): SupabaseClient {
  return createClient(ENV.SUPABASE_URL, ENV.SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
}

/**
 * Client admin (bypass RLS)
 */
export function createAdminClient(): SupabaseClient {
  return createClient(ENV.SUPABASE_URL, ENV.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
}

// ==============================================================================
// STRIPE CLIENT FACTORY
// ==============================================================================
export function createStripeClient(): Stripe {
  return new Stripe(ENV.STRIPE_SECRET_KEY, {
    apiVersion: "2023-10-16",
    httpClient: Stripe.createFetchHttpClient(),
  });
}

// ==============================================================================
// AUTH HELPERS
// ==============================================================================

export interface AuthUser {
  id: string;
  email?: string;
}

/**
 * Vérifie l'authentification et retourne l'utilisateur
 */
export async function requireAuth(req: Request): Promise<{ user: AuthUser; supabase: SupabaseClient }> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    throw new Error("Missing Authorization Header");
  }

  const supabase = createUserClient(authHeader);
  const { data: { user }, error } = await supabase.auth.getUser();

  if (error || !user) {
    throw new Error("Unauthorized");
  }

  return { user: { id: user.id, email: user.email }, supabase };
}

/**
 * Vérifie que l'appelant est un admin
 */
export async function requireAdmin(req: Request): Promise<{ user: AuthUser; supabase: SupabaseClient }> {
  const { user, supabase } = await requireAuth(req);
  const adminClient = createAdminClient();

  const { data: adminCheck } = await adminClient
    .from("admins")
    .select("user_id")
    .eq("user_id", user.id)
    .single();

  if (!adminCheck) {
    throw new Error("Unauthorized: Admin access required");
  }

  return { user, supabase };
}

/**
 * Vérifie que l'appelant utilise la Service Role Key
 */
export function requireServiceRole(req: Request): void {
  const authHeader = req.headers.get("Authorization")?.replace("Bearer ", "");
  if (!authHeader || authHeader !== ENV.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error("Unauthorized: Service role required");
  }
}

// ==============================================================================
// SYSTEM LOGGING
// ==============================================================================

type LogEventType = "info" | "warning" | "error" | "cron" | "security" | "identity_init";

export async function logSystemEvent(
  supabase: SupabaseClient,
  eventType: LogEventType,
  message: string,
  details?: Record<string, unknown>
): Promise<void> {
  try {
    await supabase.from("system_logs").insert({
      event_type: eventType,
      message,
      details: details ?? null,
    });
  } catch (e) {
    console.error("[system_logs] Insert failed:", e);
  }
}

// ==============================================================================
// STRIPE RETRY HELPER
// ==============================================================================
export async function withStripeRetry<T>(
  fn: () => Promise<T>,
  maxRetries = 2
): Promise<T> {
  let lastErr: Error | null = null;

  for (let i = 0; i <= maxRetries; i++) {
    try {
      return await fn();
    } catch (err: unknown) {
      lastErr = err as Error;
      const stripeErr = err as { code?: string; raw?: { code?: string } };
      const code = stripeErr?.code || stripeErr?.raw?.code;

      // Ne pas retry sur les erreurs logiques Stripe
      if (["resource_missing", "invalid_request_error", "card_error"].includes(code || "")) {
        throw err;
      }

      if (i < maxRetries) {
        const delay = 200 * (i + 1);
        console.warn(`Retrying Stripe call in ${delay}ms (attempt ${i + 2})`, code);
        await new Promise((r) => setTimeout(r, delay));
      }
    }
  }

  throw lastErr;
}

// ==============================================================================
// VALIDATION HELPERS
// ==============================================================================

export function validateUUID(value: unknown, fieldName: string): string {
  if (typeof value !== "string") {
    throw new Error(`${fieldName} must be a string`);
  }
  const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  if (!uuidRegex.test(value)) {
    throw new Error(`${fieldName} must be a valid UUID`);
  }
  return value;
}

export function validateAmount(value: unknown, fieldName: string, min = 0.5): number {
  const num = Number(value);
  if (isNaN(num) || num < min) {
    throw new Error(`${fieldName} must be a number >= ${min}`);
  }
  return num;
}

// ==============================================================================
// PROFILE HELPERS
// ==============================================================================

export interface Profile {
  id: string;
  stripe_account_id: string | null;
  stripe_customer_id: string | null;
  role: string;
  first_name: string | null;
  last_name: string | null;
}

export async function getProfile(supabase: SupabaseClient, userId: string): Promise<Profile | null> {
  const { data, error } = await supabase
    .from("profiles")
    .select("id, stripe_account_id, stripe_customer_id, role, first_name, last_name")
    .eq("id", userId)
    .single();

  if (error) return null;
  return data as Profile;
}

// ==============================================================================
// ORDER HELPERS
// ==============================================================================

export interface Order {
  id: string;
  merchant_id: string;
  influencer_id: string;
  status: string;
  total_amount: number;
  net_amount: number;
  stripe_payment_intent_id: string | null;
  stripe_payment_status: string;
}

export async function getOrder(supabase: SupabaseClient, orderId: string): Promise<Order | null> {
  const { data, error } = await supabase
    .from("orders")
    .select("id, merchant_id, influencer_id, status, total_amount, net_amount, stripe_payment_intent_id, stripe_payment_status")
    .eq("id", orderId)
    .single();

  if (error) return null;
  return data as Order;
}

// ==============================================================================
// CLIENT IP HELPER
// ==============================================================================
export function getClientIp(req: Request): string {
  return (
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ||
    req.headers.get("x-real-ip") ||
    req.headers.get("cf-connecting-ip") ||
    "unknown"
  );
}
