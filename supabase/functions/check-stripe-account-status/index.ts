// ==============================================================================
// CHECK-STRIPE-ACCOUNT-STATUS - V14.0 (CORRECTED)
// Vérifie le statut d'un compte Stripe Connect
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
      .select("stripe_account_id, connect_kyc_status")
      .eq("id", user.id)
      .single();

    if (profileError || !profile) {
      throw new Error("Profile not found");
    }

    // Pas de compte Connect
    if (!profile.stripe_account_id) {
      return new Response(JSON.stringify({
        success: true,
        status: "not_created",
        chargesEnabled: false,
        payoutsEnabled: false,
        detailsSubmitted: false,
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      });
    }

    console.log(`[Check Stripe Account] User: ${user.id}, Account: ${profile.stripe_account_id}`);

    // Init Stripe
    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    // Récupérer le compte
    const account = await stripe.accounts.retrieve(profile.stripe_account_id);

    // Déterminer le statut KYC
    let kycStatus = "pending";
    if (account.details_submitted && account.charges_enabled && account.payouts_enabled) {
      kycStatus = "verified";
    } else if (account.requirements?.currently_due && account.requirements.currently_due.length > 0) {
      kycStatus = "incomplete";
    } else if (account.requirements?.disabled_reason) {
      kycStatus = "rejected";
    }

    // Mettre à jour le profil si le statut a changé
    if (kycStatus !== profile.connect_kyc_status) {
      await supabaseAdmin
        .from("profiles")
        .update({
          connect_kyc_status: kycStatus,
          connect_kyc_last_sync: new Date().toISOString(),
          connect_kyc_source: "api_check",
        })
        .eq("id", user.id);
    }

    return new Response(JSON.stringify({
      success: true,
      accountId: account.id,
      status: kycStatus,
      chargesEnabled: account.charges_enabled,
      payoutsEnabled: account.payouts_enabled,
      detailsSubmitted: account.details_submitted,
      requirements: {
        currentlyDue: account.requirements?.currently_due || [],
        eventuallyDue: account.requirements?.eventually_due || [],
        pastDue: account.requirements?.past_due || [],
        disabledReason: account.requirements?.disabled_reason || null,
      },
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("Error in check-stripe-account-status:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
