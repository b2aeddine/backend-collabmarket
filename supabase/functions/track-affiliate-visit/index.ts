// ==============================================================================
// TRACK-AFFILIATE-VISIT - V15.0 (SCHEMA V40 ALIGNED)
// Tracks affiliate link clicks (anonymous, no auth required)
// SECURITY: Hashes IP for GDPR compliance, uses anon key for RLS
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, handleCorsOptions, corsResponse, corsErrorResponse } from "../shared/utils/cors.ts";

// Hash IP for privacy/GDPR compliance - one-way hash
async function hashIP(ip: string): Promise<string> {
  if (!ip) return "";

  // Add a salt from environment for extra security
  const salt = Deno.env.get("IP_HASH_SALT") || "collabmarket-affiliate-salt";
  const data = new TextEncoder().encode(ip + salt);
  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  const hashHex = hashArray.map(b => b.toString(16).padStart(2, "0")).join("");

  // Return first 32 chars (128 bits) - enough for uniqueness, less storage
  return hashHex.substring(0, 32);
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return handleCorsOptions();
  }

  try {
    const { code, ip, user_agent, referer } = await req.json();

    if (!code) {
      // Don't expose error details for tracking endpoint
      return corsResponse({ success: false });
    }

    // Use ANON key - this is a public endpoint but with RLS protection
    // The affiliate_links and affiliate_clicks tables should have appropriate RLS policies
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!
    );

    // 1. Find Link by code
    const { data: link, error: linkError } = await supabase
      .from("affiliate_links")
      .select("id, is_active")
      .eq("code", code)
      .single();

    if (linkError || !link) {
      // Don't fail hard for tracking, just log
      console.warn(`[Track Visit] Affiliate link not found for code: ${code}`);
      return corsResponse({ success: false });
    }

    // Only track if link is active
    if (!link.is_active) {
      console.warn(`[Track Visit] Inactive affiliate link: ${code}`);
      return corsResponse({ success: false });
    }

    // 2. Hash IP for privacy (GDPR compliance)
    const ipHash = await hashIP(ip || "");

    // 3. Record Click via RPC for proper security
    // This uses a SECURITY DEFINER function that bypasses RLS safely
    const { error: clickError } = await supabase.rpc("record_affiliate_click", {
      p_link_id: link.id,
      p_ip_hash: ipHash,
      p_user_agent: user_agent?.substring(0, 500) || null, // Limit length
      p_referer: referer?.substring(0, 2000) || null, // Limit length
    });

    if (clickError) {
      // If RPC doesn't exist, fall back to direct insert (for backwards compat)
      // But log the error for monitoring
      console.warn("[Track Visit] RPC failed, attempting direct insert:", clickError.message);

      // Fallback: direct insert (requires INSERT policy on affiliate_clicks for anon)
      const { error: insertError } = await supabase
        .from("affiliate_clicks")
        .insert({
          affiliate_link_id: link.id,
          ip_hash: ipHash,
          user_agent: user_agent?.substring(0, 500) || null,
          referer: referer?.substring(0, 2000) || null,
        });

      if (insertError) {
        console.error("[Track Visit] Insert failed:", insertError.message);
        // Still return success to client - don't expose tracking failures
        return corsResponse({ success: false });
      }
    }

    console.log(`[Track Visit] Recorded click for link ${link.id}`);
    return corsResponse({ success: true });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("[Track Visit Error]:", err.message);
    // Don't expose error details for tracking endpoint
    return corsResponse({ success: false });
  }
});
