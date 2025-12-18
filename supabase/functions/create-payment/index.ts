// ==============================================================================
// CREATE-PAYMENT - V15.1 (SCHEMA V40 ALIGNED)
// Crée une commande et initialise le PaymentIntent Stripe (mode escrow)
// ALIGNED: Uses buyer_id/seller_id, services/service_packages, amounts_coherence
// SECURITY: Verifies seller role, KYC status, and Stripe onboarding
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { z } from "https://deno.land/x/zod@v3.22.4/mod.ts";
import { corsHeaders, handleCorsOptions, corsResponse, corsErrorResponse } from "../shared/utils/cors.ts";

// Validation schema - aligned with v40
const paymentSchema = z.object({
  // For standard orders (service/package)
  serviceId: z.string().uuid().optional(),
  packageId: z.string().uuid().optional(),
  // For offer orders (global_offer)
  globalOfferId: z.string().uuid().optional(),
  // The seller who will fulfill the order
  sellerId: z.string().uuid(),
  // Order details
  orderType: z.enum(['standard', 'custom', 'quote_request', 'offer']).default('standard'),
  // Amounts (subtotal is the base price, discount is optional)
  subtotal: z.number().min(1, "Minimum 1€"),
  discountAmount: z.number().min(0).default(0),
  // Optional affiliate link
  affiliateLinkId: z.string().uuid().optional(),
  // Brief/requirements
  brief: z.string().max(5000).optional(),
  requirementsResponses: z.array(z.any()).optional(),
  selectedExtras: z.array(z.any()).optional(),
});

// Seller roles that can receive payments
const SELLER_ROLES = ['influencer', 'freelance', 'merchant'];

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return handleCorsOptions();
  }

  try {
    const body = await req.json();
    const authHeader = req.headers.get("Authorization");

    if (!authHeader) {
      return corsErrorResponse("Missing Authorization Header", 401);
    }

    // Validation des entrées
    const validation = paymentSchema.safeParse(body);
    if (!validation.success) {
      const errorMsg = validation.error.errors.map(e => `${e.path.join(".")}: ${e.message}`).join(", ");
      return corsErrorResponse(`Validation error: ${errorMsg}`, 400);
    }

    const {
      serviceId,
      packageId,
      globalOfferId,
      sellerId,
      orderType,
      subtotal,
      discountAmount,
      affiliateLinkId,
      brief,
      requirementsResponses,
      selectedExtras,
    } = validation.data;

    // Calculate total_amount per amounts_coherence constraint
    const totalAmount = subtotal - discountAmount;
    if (totalAmount < 1) {
      return corsErrorResponse("Total amount must be at least 1€", 400);
    }

    // Init Clients Supabase
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
    if (authError || !user) {
      return corsErrorResponse("Unauthorized", 401);
    }

    const buyerId = user.id;

    // SECURITY: Prevent self-purchase
    if (buyerId === sellerId) {
      return corsErrorResponse("Cannot purchase from yourself", 400);
    }

    console.log(`[Create Payment] Buyer ${buyerId} -> Seller ${sellerId}`);

    // Verify buyer has completed KYC (for large orders) or at least exists
    const { data: buyerProfile, error: buyerError } = await supabaseUser
      .from("profiles")
      .select("id, display_name")
      .eq("id", buyerId)
      .single();

    if (buyerError || !buyerProfile) {
      return corsErrorResponse("Buyer profile not found", 404);
    }

    // Verify seller exists and has Stripe Connect ready
    const { data: sellerProfile, error: sellerError } = await supabaseAdmin
      .from("profiles")
      .select("id, display_name, stripe_account_id, stripe_onboarding_completed, kyc_status")
      .eq("id", sellerId)
      .single();

    if (sellerError || !sellerProfile) {
      return corsErrorResponse("Seller not found", 404);
    }

    // SECURITY: Verify seller has an active seller role
    const { data: sellerRoles, error: rolesError } = await supabaseAdmin
      .from("user_roles")
      .select("role, status")
      .eq("user_id", sellerId)
      .eq("status", "active")
      .in("role", SELLER_ROLES);

    if (rolesError || !sellerRoles || sellerRoles.length === 0) {
      return corsErrorResponse("Seller does not have an active seller role", 403);
    }

    // SECURITY: Verify seller has completed KYC (for amounts > threshold)
    const KYC_THRESHOLD = 1000; // Require KYC for orders > 1000€
    if (totalAmount > KYC_THRESHOLD) {
      if (sellerProfile.kyc_status !== 'verified') {
        return corsErrorResponse(`Orders over ${KYC_THRESHOLD}€ require seller KYC verification`, 400);
      }
    }

    // SECURITY: Verify seller has completed Stripe onboarding
    if (!sellerProfile.stripe_account_id || !sellerProfile.stripe_onboarding_completed) {
      return corsErrorResponse("Seller has not completed Stripe onboarding", 400);
    }

    // Verify service/package if provided (for standard orders)
    if (orderType === 'standard' && serviceId) {
      const { data: service, error: serviceError } = await supabaseUser
        .from("services")
        .select("id, seller_id, status, starting_price")
        .eq("id", serviceId)
        .single();

      if (serviceError || !service) {
        return corsErrorResponse("Service not found", 404);
      }

      if (service.seller_id !== sellerId) {
        return corsErrorResponse("Service does not belong to the specified seller", 400);
      }

      if (service.status !== 'active') {
        return corsErrorResponse("Service is not active", 400);
      }
    }

    // Verify global offer if provided (for offer orders)
    if (orderType === 'offer' && globalOfferId) {
      const { data: offer, error: offerError } = await supabaseUser
        .from("global_offers")
        .select("id, author_id, status")
        .eq("id", globalOfferId)
        .single();

      if (offerError || !offer) {
        return corsErrorResponse("Global offer not found", 404);
      }

      // The buyer should be the author of the offer
      if (offer.author_id !== buyerId) {
        return corsErrorResponse("You are not the author of this offer", 403);
      }
    }

    // Verify affiliate link if provided
    let validAffiliateLinkId: string | null = null;
    if (affiliateLinkId) {
      const { data: affiliateLink } = await supabaseAdmin
        .from("affiliate_links")
        .select("id, agent_id, is_active")
        .eq("id", affiliateLinkId)
        .single();

      if (affiliateLink && affiliateLink.is_active) {
        // Anti-fraud: agent cannot be the buyer
        if (affiliateLink.agent_id !== buyerId) {
          validAffiliateLinkId = affiliateLinkId;
        }
      }
    }

    // Create the order in DB (amounts_coherence constraint will validate)
    const { data: order, error: insertError } = await supabaseAdmin
      .from("orders")
      .insert({
        buyer_id: buyerId,
        seller_id: sellerId,
        service_id: serviceId || null,
        global_offer_id: globalOfferId || null,
        package_id: packageId || null,
        affiliate_link_id: validAffiliateLinkId,
        order_type: orderType,
        subtotal: subtotal,
        discount_amount: discountAmount,
        total_amount: totalAmount,
        platform_fee: 0,  // Will be calculated by distribute_commissions()
        brief: brief || null,
        requirements_responses: requirementsResponses || [],
        selected_extras: selectedExtras || [],
        status: 'pending',
        stripe_payment_status: 'unpaid',
      })
      .select()
      .single();

    if (insertError) {
      console.error("DB Insert Error:", insertError);
      return corsErrorResponse(`Failed to create order: ${insertError.message}`, 500);
    }

    // Init Stripe & PaymentIntent (Escrow with manual capture)
    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    const paymentIntent = await stripe.paymentIntents.create({
      amount: Math.round(totalAmount * 100), // Stripe uses cents
      currency: "eur",
      automatic_payment_methods: { enabled: true },
      capture_method: "manual", // ESCROW - capture when seller accepts
      metadata: {
        order_id: order.id,
        order_number: order.order_number,
        buyer_id: buyerId,
        seller_id: sellerId,
      },
      transfer_group: order.id, // For reconciliation with transfers
    });

    // Update order with Stripe PaymentIntent ID
    const { error: updateError } = await supabaseAdmin
      .from("orders")
      .update({
        stripe_payment_intent_id: paymentIntent.id,
        stripe_payment_status: 'pending',
      })
      .eq("id", order.id);

    if (updateError) {
      console.error("DB Update Error (Stripe ID):", updateError);
      // Don't fail - order exists, Stripe PI exists, we can reconcile
    }

    // System Log
    try {
      await supabaseAdmin.from("system_logs").insert({
        event_type: "info",
        message: "Payment initiated",
        details: {
          order_id: order.id,
          order_number: order.order_number,
          buyer_id: buyerId,
          seller_id: sellerId,
          total_amount: totalAmount,
          stripe_intent: paymentIntent.id,
        },
      });
    } catch (logError) {
      console.warn("Failed to write system log:", logError);
    }

    return corsResponse({
      success: true,
      orderId: order.id,
      orderNumber: order.order_number,
      clientSecret: paymentIntent.client_secret,
      amount: totalAmount,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("Error in create-payment:", err);
    return corsErrorResponse(err.message, 500);
  }
});
