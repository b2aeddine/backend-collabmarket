// ==============================================================================
// UPDATE-STRIPE-ACCOUNT-DETAILS - V14.0 (CORRECTED)
// Met à jour les détails d'un compte Stripe Connect
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { z } from "https://deno.land/x/zod@v3.22.4/mod.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("ALLOWED_ORIGIN") || "https://collabmarket.fr",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Validation schema
const updateSchema = z.object({
  business_profile: z.object({
    url: z.string().url().optional(),
    mcc: z.string().optional(),
  }).optional(),
  settings: z.object({
    payouts: z.object({
      schedule: z.object({
        interval: z.enum(["daily", "weekly", "monthly"]).optional(),
        weekly_anchor: z.enum(["monday", "tuesday", "wednesday", "thursday", "friday"]).optional(),
        monthly_anchor: z.number().min(1).max(31).optional(),
      }).optional(),
    }).optional(),
  }).optional(),
});

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const authHeader = req.headers.get("Authorization");

    if (!authHeader) throw new Error("Missing Authorization Header");

    // Validation
    const validation = updateSchema.safeParse(body);
    if (!validation.success) {
      throw new Error("Invalid update parameters");
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
      .select("stripe_account_id")
      .eq("id", user.id)
      .single();

    if (profileError || !profile || !profile.stripe_account_id) {
      throw new Error("No Stripe account found");
    }

    console.log(`[Update Stripe Account] User: ${user.id}, Account: ${profile.stripe_account_id}`);

    // Init Stripe
    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    // Préparer les données de mise à jour
    const updateData: Stripe.AccountUpdateParams = {};

    if (validation.data.business_profile) {
      updateData.business_profile = validation.data.business_profile;
    }

    if (validation.data.settings) {
      updateData.settings = validation.data.settings as Stripe.AccountUpdateParams.Settings;
    }

    // Mettre à jour le compte
    const updatedAccount = await stripe.accounts.update(
      profile.stripe_account_id,
      updateData
    );

    return new Response(JSON.stringify({
      success: true,
      account: {
        id: updatedAccount.id,
        chargesEnabled: updatedAccount.charges_enabled,
        payoutsEnabled: updatedAccount.payouts_enabled,
        detailsSubmitted: updatedAccount.details_submitted,
      },
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("[Update Stripe Account Error]:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
