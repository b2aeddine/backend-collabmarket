// ==============================================================================
// SHARED AUTH UTILITIES - V1.0
// Authentication helpers for Edge Functions
// ==============================================================================

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

/**
 * Verify CRON_SECRET for scheduled/ops endpoints
 * Much safer than exposing service role key on the network
 *
 * Usage:
 *   const authError = verifyCronSecret(req);
 *   if (authError) return authError;
 */
export function verifyCronSecret(req: Request): Response | null {
  const cronSecret = Deno.env.get("CRON_SECRET");

  if (!cronSecret) {
    console.error("[Auth] CRON_SECRET not configured");
    return new Response(JSON.stringify({
      success: false,
      error: "Server misconfiguration: CRON_SECRET not set"
    }), {
      status: 500,
      headers: { "Content-Type": "application/json" }
    });
  }

  // Check x-cron-secret header first, fallback to Authorization bearer
  const headerSecret = req.headers.get("x-cron-secret");
  const authHeader = req.headers.get("Authorization")?.replace("Bearer ", "");

  const providedSecret = headerSecret || authHeader;

  if (!providedSecret || providedSecret !== cronSecret) {
    console.warn("[Auth] Invalid or missing cron secret");
    return new Response(JSON.stringify({
      success: false,
      error: "Unauthorized: Invalid cron secret"
    }), {
      status: 401,
      headers: { "Content-Type": "application/json" }
    });
  }

  return null; // Auth passed
}

/**
 * Verify internal service call (from DB trigger or another Edge Function)
 * Uses a dedicated INTERNAL_SECRET that's different from service role
 */
export function verifyInternalCall(req: Request): Response | null {
  const internalSecret = Deno.env.get("INTERNAL_SECRET");

  if (!internalSecret) {
    // Fallback to CRON_SECRET if INTERNAL_SECRET not set
    return verifyCronSecret(req);
  }

  const headerSecret = req.headers.get("x-internal-secret");

  if (!headerSecret || headerSecret !== internalSecret) {
    console.warn("[Auth] Invalid or missing internal secret");
    return new Response(JSON.stringify({
      success: false,
      error: "Unauthorized: Invalid internal secret"
    }), {
      status: 401,
      headers: { "Content-Type": "application/json" }
    });
  }

  return null;
}

/**
 * Get authenticated user from JWT
 * Returns null if not authenticated
 */
export async function getAuthenticatedUser(
  req: Request,
  supabaseUrl: string,
  supabaseAnonKey: string
): Promise<{ user: { id: string; email?: string } | null; error: string | null }> {
  const authHeader = req.headers.get("Authorization");

  if (!authHeader) {
    return { user: null, error: "Missing Authorization header" };
  }

  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } }
  });

  const { data: { user }, error } = await supabase.auth.getUser();

  if (error || !user) {
    return { user: null, error: error?.message || "Invalid token" };
  }

  return { user: { id: user.id, email: user.email }, error: null };
}

/**
 * Check if user is admin via RPC
 */
export async function isUserAdmin(
  supabase: SupabaseClient,
  userId: string
): Promise<boolean> {
  try {
    const { data, error } = await supabase.rpc("is_admin");
    if (error) {
      console.error("[Auth] is_admin check failed:", error);
      return false;
    }
    return data === true;
  } catch {
    return false;
  }
}

/**
 * Create a service role client (admin access)
 * ONLY use for operations that require elevated privileges
 */
export function createServiceClient(): SupabaseClient {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );
}
