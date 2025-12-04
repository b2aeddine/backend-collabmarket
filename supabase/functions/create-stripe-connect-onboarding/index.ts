// ==============================================================================
// CREATE-STRIPE-CONNECT-ONBOARDING - V14.0 (CORRECTED)
// Génère un lien d'onboarding Stripe Connect
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("ALLOWED_ORIGIN") || "https://collabmarket.fr",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) throw new Error("Missing Authorization Header");

    // Parse body optionnel
    let body: { refresh_url?: string; return_url?: string } = {};
    try {
      body = await req.json();
    } catch {
      // Body vide acceptable
    }

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
      .select("stripe_account_id, role")
      .eq("id", user.id)
      .single();

    if (profileError || !profile) {
      throw new Error("Profile not found");
    }

    if (profile.role !== "influenceur") {
      throw new Error("Only influencers can access Stripe onboarding");
    }

    if (!profile.stripe_account_id) {
      throw new Error("No Stripe account found. Please create one first.");
    }

    console.log(`[Stripe Onboarding] User: ${user.id}, Account: ${profile.stripe_account_id}`);

    // Init Stripe
    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    // Vérifier le statut du compte
    const account = await stripe.accounts.retrieve(profile.stripe_account_id);

    // Si déjà complètement configuré
    if (account.details_submitted && account.charges_enabled && account.payouts_enabled) {
      return new Response(JSON.stringify({
        success: true,
        message: "Account already fully configured",
        alreadyComplete: true,
        chargesEnabled: true,
        payoutsEnabled: true,
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      });
    }

    // Générer le lien d'onboarding
    const baseUrl = Deno.env.get("PUBLIC_SITE_URL") || "https://collabmarket.fr";

    const accountLink = await stripe.accountLinks.create({
      account: profile.stripe_account_id,
      refresh_url: body.refresh_url || `${baseUrl}/dashboard/stripe-refresh`,
      return_url: body.return_url || `${baseUrl}/dashboard/stripe-complete`,
      type: "account_onboarding",
    });

    return new Response(JSON.stringify({
      success: true,
      url: accountLink.url,
      expiresAt: accountLink.expires_at,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("Error in create-stripe-connect-onboarding:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
