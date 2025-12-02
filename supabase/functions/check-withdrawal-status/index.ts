// ==============================================================================
// CHECK-WITHDRAWAL-STATUS - V14.0 (CORRECTED)
// Vérifie le statut d'un retrait
// FIX: Typage correct des jointures
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Types pour les résultats de requêtes
interface WithdrawalWithProfile {
  id: string;
  influencer_id: string;
  amount: number;
  status: string;
  stripe_transfer_id: string | null;
  stripe_payout_id: string | null;
  failure_reason: string | null;
  created_at: string;
  profiles: {
    stripe_account_id: string | null;
  } | null;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { withdrawalId } = await req.json();
    const authHeader = req.headers.get("Authorization");

    if (!authHeader) throw new Error("Missing Authorization Header");
    if (!withdrawalId) throw new Error("Missing withdrawalId");

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

    // Récupérer le retrait avec le profil (pour stripe_account_id)
    const { data: withdrawal, error: withdrawalError } = await supabaseAdmin
      .from("withdrawals")
      .select(`
        id,
        influencer_id,
        amount,
        status,
        stripe_transfer_id,
        stripe_payout_id,
        failure_reason,
        created_at,
        profiles:influencer_id (
          stripe_account_id
        )
      `)
      .eq("id", withdrawalId)
      .single();

    if (withdrawalError || !withdrawal) {
      throw new Error("Withdrawal not found");
    }

    // Cast avec le bon type
    const typedWithdrawal = withdrawal as unknown as WithdrawalWithProfile;

    // Vérification des droits
    if (typedWithdrawal.influencer_id !== user.id) {
      throw new Error("Unauthorized: This withdrawal does not belong to you");
    }

    console.log(`[Check Withdrawal] ID: ${withdrawalId}, Status: ${typedWithdrawal.status}`);

    // Si le retrait est en cours et a un payout_id, vérifier sur Stripe
    if (typedWithdrawal.status === "processing" && typedWithdrawal.stripe_payout_id) {
      const stripeAccountId = typedWithdrawal.profiles?.stripe_account_id;

      if (stripeAccountId) {
        const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
          apiVersion: "2023-10-16",
          httpClient: Stripe.createFetchHttpClient(),
        });

        try {
          const payout = await stripe.payouts.retrieve(
            typedWithdrawal.stripe_payout_id,
            { stripeAccount: stripeAccountId }
          );

          // Mettre à jour le statut si changé
          if (payout.status === "paid" && typedWithdrawal.status !== "completed") {
            await supabaseAdmin
              .from("withdrawals")
              .update({
                status: "completed",
                processed_at: new Date().toISOString(),
              })
              .eq("id", withdrawalId);

            // Finaliser les revenues
            await supabaseAdmin.rpc("finalize_revenue_withdrawal", {
              p_influencer_id: typedWithdrawal.influencer_id,
              p_amount: typedWithdrawal.amount,
            });

            return new Response(JSON.stringify({
              success: true,
              withdrawal: {
                ...typedWithdrawal,
                status: "completed",
              },
              stripeStatus: payout.status,
              arrivalDate: payout.arrival_date,
            }), {
              headers: { ...corsHeaders, "Content-Type": "application/json" },
              status: 200,
            });
          }

          if (payout.status === "failed" && typedWithdrawal.status !== "failed") {
            await supabaseAdmin
              .from("withdrawals")
              .update({
                status: "failed",
                failure_reason: payout.failure_message || "Payout failed",
              })
              .eq("id", withdrawalId);

            // Reverser les revenues
            await supabaseAdmin.rpc("revert_revenue_withdrawal", {
              p_influencer_id: typedWithdrawal.influencer_id,
              p_amount: typedWithdrawal.amount,
            });
          }

          return new Response(JSON.stringify({
            success: true,
            withdrawal: typedWithdrawal,
            stripeStatus: payout.status,
            arrivalDate: payout.arrival_date,
          }), {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
            status: 200,
          });

        } catch (stripeError) {
          console.warn("Could not fetch Stripe payout:", stripeError);
        }
      }
    }

    return new Response(JSON.stringify({
      success: true,
      withdrawal: {
        id: typedWithdrawal.id,
        amount: typedWithdrawal.amount,
        status: typedWithdrawal.status,
        failureReason: typedWithdrawal.failure_reason,
        createdAt: typedWithdrawal.created_at,
      },
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("Error in check-withdrawal-status:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
