// ==============================================================================
// CREATE-STRIPE-CONNECT-ACCOUNT - V14.0 (CORRECTED)
// Crée un compte Stripe Connect pour un influenceur
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

    console.log(`[Create Stripe Connect] User: ${user.id}`);

    // Récupérer le profil avec email déchiffré
    const { data: profile, error: profileError } = await supabaseAdmin
      .from("profiles")
      .select("id, role, stripe_account_id, first_name, last_name")
      .eq("id", user.id)
      .single();

    if (profileError || !profile) {
      throw new Error("Profile not found");
    }

    // Seuls les influenceurs peuvent avoir un compte Connect
    if (profile.role !== "influenceur") {
      throw new Error("Only influencers can create a Stripe Connect account");
    }

    // Idempotence: Si déjà un compte, retourner l'existant
    if (profile.stripe_account_id) {
      console.log(`User ${user.id} already has Stripe account: ${profile.stripe_account_id}`);
      return new Response(JSON.stringify({
        success: true,
        accountId: profile.stripe_account_id,
        alreadyExists: true,
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      });
    }

    // Init Stripe
    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    // Vérifier qu'aucun compte n'existe déjà avec cet email (anti-doublon)
    if (user.email) {
      const existingAccounts = await stripe.accounts.list({
        limit: 1,
      });

      // Vérifier chaque compte pour l'email
      for (const acc of existingAccounts.data) {
        if (acc.email === user.email) {
          // Mettre à jour le profil avec ce compte existant
          await supabaseAdmin
            .from("profiles")
            .update({ stripe_account_id: acc.id })
            .eq("id", user.id);

          return new Response(JSON.stringify({
            success: true,
            accountId: acc.id,
            alreadyExists: true,
            message: "Existing Stripe account linked to your profile",
          }), {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
            status: 200,
          });
        }
      }
    }

    // Créer le compte Connect
    const account = await stripe.accounts.create({
      type: "express",
      country: "FR",
      email: user.email,
      capabilities: {
        card_payments: { requested: true },
        transfers: { requested: true },
      },
      business_type: "individual",
      metadata: {
        user_id: user.id,
        platform: "collabmarket",
      },
    });

    console.log(`Created Stripe Connect account: ${account.id}`);

    // Sauvegarder l'ID du compte
    const { error: updateError } = await supabaseAdmin
      .from("profiles")
      .update({
        stripe_account_id: account.id,
        connect_kyc_status: "pending",
        connect_kyc_last_sync: new Date().toISOString(),
      })
      .eq("id", user.id);

    if (updateError) {
      console.error("Failed to update profile with Stripe account:", updateError);
      // Ne pas throw, le compte est créé
    }

    // Log système
    await supabaseAdmin.from("system_logs").insert({
      event_type: "info",
      message: "Stripe Connect account created",
      details: {
        user_id: user.id,
        account_id: account.id,
      },
    });

    return new Response(JSON.stringify({
      success: true,
      accountId: account.id,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("Error in create-stripe-connect-account:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
