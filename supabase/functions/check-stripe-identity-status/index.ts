// ==============================================================================
// CHECK-STRIPE-IDENTITY-STATUS - V14.0 (CORRECTED)
// Vérifie le statut d'une session de vérification Identity
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

// SECURITY: CORS restrictif - configurable via env
const ALLOWED_ORIGIN = Deno.env.get("ALLOWED_ORIGIN") || "https://collabmarket.fr";

const corsHeaders = {
  "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) throw new Error("Missing Authorization Header");

    // Clients
    const supabaseUser = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const { data: { user }, error: authError } = await supabaseUser.auth.getUser();
    if (authError || !user) throw new Error("Unauthorized");

    // Récupérer le profil
    const { data: profile, error: profileError } = await supabaseAdmin
      .from("profiles")
      .select("stripe_identity_session_id, stripe_identity_last_status, is_verified")
      .eq("id", user.id)
      .single();

    if (profileError || !profile) {
      throw new Error("Profile not found");
    }

    // Pas de session Identity
    if (!profile.stripe_identity_session_id) {
      return new Response(JSON.stringify({
        success: true,
        status: "not_started",
        message: "No identity verification session found. Please initiate verification first.",
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      });
    }

    // Vérifier le statut actuel sur Stripe
    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    const session = await stripe.identity.verificationSessions.retrieve(
      profile.stripe_identity_session_id,
      { expand: ["verified_outputs"] }
    );

    console.log(`[Check Identity] User: ${user.id}, Session: ${session.id}, Status: ${session.status}`);

    // Mettre à jour le profil si le statut a changé
    if (session.status !== profile.stripe_identity_last_status) {
      const updateData: Record<string, unknown> = {
        stripe_identity_last_status: session.status,
        stripe_identity_last_update: new Date().toISOString(),
      };

      // Si vérifié, mettre à jour les champs associés
      if (session.status === "verified") {
        updateData.is_verified = true;
        updateData.identity_verified_at = new Date().toISOString();
        
        // Extraire les infos vérifiées si disponibles
        const verifiedOutputs = session.verified_outputs as {
          id_number_type?: string;
          address?: { country?: string };
        } | null;
        
        if (verifiedOutputs?.address?.country) {
          updateData.identity_document_country = verifiedOutputs.address.country;
        }
      }

      await supabaseAdmin
        .from("profiles")
        .update(updateData)
        .eq("id", user.id);
    }

    // Construire la réponse
    const response: Record<string, unknown> = {
      success: true,
      status: session.status,
      lastError: session.last_error?.code || null,
    };

    // URL de reprise si nécessaire
    if (session.status === "requires_input" && session.url) {
      response.url = session.url;
    }

    // Détails si vérifié
    if (session.status === "verified") {
      response.verified = true;
      response.verifiedAt = session.created;
    }

    return new Response(JSON.stringify(response), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("Error in check-stripe-identity-status:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
