// ==============================================================================
// PROCESS-WITHDRAWAL - V14.0 (CORRECTED)
// Traite une demande de retrait : Transfer + Payout
// NOTE: Version unifiée remplaçant create-stripe-payout
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { z } from "https://deno.land/x/zod@v3.22.4/mod.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("ALLOWED_ORIGIN") || "https://collabmarket.fr",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Validation
const withdrawalSchema = z.object({
  amount: z.number().min(1, "Minimum withdrawal is 1€"),
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
    const validation = withdrawalSchema.safeParse(body);
    if (!validation.success) {
      throw new Error(validation.error.errors[0].message);
    }

    const { amount } = validation.data;

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

    console.log(`[Process Withdrawal] User: ${user.id}, Amount: ${amount}€`);

    // Récupérer le profil avec le compte Stripe
    const { data: profile, error: profileError } = await supabaseAdmin
      .from("profiles")
      .select("id, stripe_account_id, role")
      .eq("id", user.id)
      .single();

    if (profileError || !profile) {
      throw new Error("Profile not found");
    }

    if (profile.role !== "influenceur") {
      throw new Error("Only influencers can request withdrawals");
    }

    if (!profile.stripe_account_id) {
      throw new Error("No Stripe account configured. Please complete your Stripe setup first.");
    }

    // Créer la demande de retrait via RPC (vérifie le solde)
    const { data: withdrawalId, error: rpcError } = await supabaseUser.rpc("request_withdrawal", {
      p_amount: amount,
    });

    if (rpcError) {
      throw new Error(rpcError.message);
    }

    console.log(`Withdrawal request created: ${withdrawalId}`);

    // Init Stripe
    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    // Vérifier que le compte peut recevoir des payouts
    const account = await stripe.accounts.retrieve(profile.stripe_account_id);
    if (!account.payouts_enabled) {
      // Annuler le retrait
      await supabaseAdmin
        .from("withdrawals")
        .update({ status: "failed", failure_reason: "Payouts not enabled on Stripe account" })
        .eq("id", withdrawalId);

      throw new Error("Your Stripe account cannot receive payouts yet. Please complete your account setup.");
    }

    // Mettre à jour le statut en 'processing'
    await supabaseAdmin
      .from("withdrawals")
      .update({ status: "processing" })
      .eq("id", withdrawalId);

    try {
      // Étape 1: Transfer vers le compte Connect
      const transfer = await stripe.transfers.create({
        amount: Math.round(amount * 100),
        currency: "eur",
        destination: profile.stripe_account_id,
        transfer_group: withdrawalId, // Link for reconciliation
        metadata: {
          withdrawal_id: withdrawalId,
          user_id: user.id,
        },
      });

      console.log(`Transfer created: ${transfer.id}`);

      // Sauvegarder l'ID du transfer
      await supabaseAdmin
        .from("withdrawals")
        .update({ stripe_transfer_id: transfer.id })
        .eq("id", withdrawalId);

      // Étape 2: Payout vers le compte bancaire de l'influenceur
      const payout = await stripe.payouts.create(
        {
          amount: Math.round(amount * 100),
          currency: "eur",
          metadata: {
            withdrawal_id: withdrawalId,
            user_id: user.id,
          },
        },
        {
          stripeAccount: profile.stripe_account_id,
        }
      );

      console.log(`Payout created: ${payout.id}`);

      // Sauvegarder l'ID du payout
      await supabaseAdmin
        .from("withdrawals")
        .update({ stripe_payout_id: payout.id })
        .eq("id", withdrawalId);

      // Le statut passera à 'completed' via webhook quand le payout sera effectif

      return new Response(JSON.stringify({
        success: true,
        withdrawalId,
        transferId: transfer.id,
        payoutId: payout.id,
        status: "processing",
        message: "Withdrawal initiated. You will be notified when funds reach your bank account.",
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      });

    } catch (stripeError: unknown) {
      const err = stripeError as Error;
      console.error("Stripe Error:", err);

      // Marquer le retrait comme échoué
      await supabaseAdmin
        .from("withdrawals")
        .update({
          status: "failed",
          failure_reason: err.message,
        })
        .eq("id", withdrawalId);

      throw new Error(`Stripe error: ${err.message}`);
    }

  } catch (error: unknown) {
    const err = error as Error;
    console.error("Error in process-withdrawal:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
