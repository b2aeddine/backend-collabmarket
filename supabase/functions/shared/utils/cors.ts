// ==============================================================================
// SHARED CORS UTILITIES - V1.0
// Centralized CORS configuration for all Edge Functions
// ==============================================================================

// SECURITY: Configurable origin via env, defaults to production domain
const ALLOWED_ORIGIN = Deno.env.get("ALLOWED_ORIGIN") || "https://collabmarket.fr";

/**
 * Standard CORS headers for browser requests
 * - Access-Control-Allow-Origin: Restricted to configured domain
 * - Access-Control-Allow-Headers: Standard Supabase headers + content-type
 * - Access-Control-Allow-Methods: Common HTTP methods
 */
export const corsHeaders = {
  "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
};

/**
 * Handle OPTIONS preflight requests
 * Usage: if (req.method === "OPTIONS") return handleCorsOptions();
 */
export function handleCorsOptions(): Response {
  return new Response(null, {
    status: 204,
    headers: corsHeaders
  });
}

/**
 * Create a JSON response with CORS headers
 */
export function corsResponse(
  data: unknown,
  status: number = 200
): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json"
    },
  });
}

/**
 * Create an error response with CORS headers
 */
export function corsErrorResponse(
  message: string,
  status: number = 400
): Response {
  return new Response(JSON.stringify({
    success: false,
    error: message
  }), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json"
    },
  });
}
