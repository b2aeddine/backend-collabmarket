// ==============================================================================
// CREATE-STRIPE-IDENTITY - V14.0 (CORRECTED)
// FIX CRITIQUE: Cette fonction crée maintenant réellement une session Identity
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) throw new Error("Missing Authorization Header");

    // Parse body optionnel (pour refresh_url et return_url custom)
    let body: { refresh_url?: string; return_url?: string } = {};
    try {
      body = await req.json();
    } catch {
      // Body vide acceptable
    }

    // Init Clients
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

    console.log(`[Create Stripe Identity] User: ${user.id}`);

    // Récupérer le profil
    const { data: profile, error: profileError } = await supabaseAdmin
      .from("profiles")
      .select("id, stripe_identity_session_id, stripe_identity_last_status, role")
      .eq("id", user.id)
      .single();

    if (profileError || !profile) {
      throw new Error("Profile not found");
    }

    // Seuls les influenceurs peuvent vérifier leur identité
    if (profile.role !== "influenceur") {
      throw new Error("Identity verification is only available for influencers");
    }

    // Init Stripe
    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    // Si une session existe déjà, vérifier son statut
    if (profile.stripe_identity_session_id) {
      try {
        const existingSession = await stripe.identity.verificationSessions.retrieve(
          profile.stripe_identity_session_id
        );

        // Si la session est terminée avec succès, pas besoin d'en créer une nouvelle
        if (existingSession.status === "verified") {
          return new Response(JSON.stringify({
            success: true,
            message: "Identity already verified",
            status: "verified",
            alreadyVerified: true,
          }), {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
            status: 200,
          });
        }

        // Si la session est en cours ou en attente, retourner l'URL existante
        if (existingSession.status === "requires_input" && existingSession.url) {
          return new Response(JSON.stringify({
            success: true,
            sessionId: existingSession.id,
            url: existingSession.url,
            status: existingSession.status,
          }), {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
            status: 200,
          });
        }

        // Session expirée ou échouée -> en créer une nouvelle
        console.log(`Existing session ${existingSession.id} has status ${existingSession.status}, creating new one.`);
      } catch (retrieveError) {
        console.warn("Could not retrieve existing session, creating new one:", retrieveError);
      }
    }

    // FIX: CRÉATION D'UNE NOUVELLE SESSION IDENTITY
    const baseUrl = Deno.env.get("PUBLIC_SITE_URL") || "https://collabmarket.fr";
    
    const verificationSession = await stripe.identity.verificationSessions.create({
      type: "document",
      options: {
        document: {
          require_matching_selfie: true,
          allowed_types: ["driving_license", "passport", "id_card"],
        },
      },
      metadata: {
        user_id: user.id,
        platform: "collabmarket",
      },
      return_url: body.return_url || `${baseUrl}/dashboard/identity-verified`,
    });

    console.log(`Created Stripe Identity Session: ${verificationSession.id}`);

    // Sauvegarder l'ID de session dans le profil
    const { error: updateError } = await supabaseAdmin
      .from("profiles")
      .update({
        stripe_identity_session_id: verificationSession.id,
        stripe_identity_last_status: verificationSession.status,
        stripe_identity_last_update: new Date().toISOString(),
      })
      .eq("id", user.id);

    if (updateError) {
      console.error("Failed to save session ID to profile:", updateError);
      // Ne pas throw, la session est créée côté Stripe
    }

    // Log système
    await supabaseAdmin.from("system_logs").insert({
      event_type: "identity_init",
      message: "Identity verification session created",
      details: {
        user_id: user.id,
        session_id: verificationSession.id,
      },
    });

    return new Response(JSON.stringify({
      success: true,
      sessionId: verificationSession.id,
      url: verificationSession.url,
      status: verificationSession.status,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("Error in create-stripe-identity:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
