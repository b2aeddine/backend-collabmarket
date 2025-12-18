// ==============================================================================
// CREATE-ORDER - V15.0 (SCHEMA V40 ALIGNED)
// Creates an order and redirects to Stripe Checkout
// ALIGNED: Uses buyer_id/seller_id, services/service_packages, amounts_coherence
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import Stripe from "https://esm.sh/stripe@14.21.0";
import { z } from "https://deno.land/x/zod@v3.22.4/mod.ts";
import { corsHeaders, handleCorsOptions, corsResponse, corsErrorResponse } from "../shared/utils/cors.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
  httpClient: Stripe.createFetchHttpClient(),
});

// Validation schema - aligned with v40
const orderSchema = z.object({
  serviceId: z.string().uuid(),
  packageId: z.string().uuid(),
  affiliateLinkCode: z.string().max(50).optional(),
});

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

    // Validation
    const validation = orderSchema.safeParse(body);
    if (!validation.success) {
      const errorMsg = validation.error.errors.map(e => `${e.path.join(".")}: ${e.message}`).join(", ");
      return corsErrorResponse(`Validation error: ${errorMsg}`, 400);
    }

    const { serviceId, packageId, affiliateLinkCode } = validation.data;

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

    // Authenticate user
    const { data: { user }, error: authError } = await supabaseUser.auth.getUser();
    if (authError || !user) {
      return corsErrorResponse("Unauthorized", 401);
    }

    const buyerId = user.id;

    // 1. Fetch Service & Package (v40 schema: services, service_packages)
    const { data: pkg, error: pkgError } = await supabaseUser
      .from("service_packages")
      .select(`
        id,
        name,
        description,
        price,
        services!inner (
          id,
          title,
          seller_id,
          status
        )
      `)
      .eq("id", packageId)
      .eq("service_id", serviceId)
      .single();

    if (pkgError || !pkg) {
      return corsErrorResponse("Package not found or does not belong to this service", 404);
    }

    const service = pkg.services as unknown as {
      id: string;
      title: string;
      seller_id: string;
      status: string;
    };

    // Verify service is active
    if (service.status !== 'active') {
      return corsErrorResponse("Service is not active", 400);
    }

    const sellerId = service.seller_id;

    // SECURITY: Prevent self-purchase
    if (buyerId === sellerId) {
      return corsErrorResponse("Cannot purchase from yourself", 400);
    }

    // 2. Verify seller has Stripe Connect ready
    const { data: sellerProfile, error: sellerError } = await supabaseAdmin
      .from("profiles")
      .select("id, display_name, stripe_account_id, stripe_onboarding_completed")
      .eq("id", sellerId)
      .single();

    if (sellerError || !sellerProfile) {
      return corsErrorResponse("Seller not found", 404);
    }

    if (!sellerProfile.stripe_account_id || !sellerProfile.stripe_onboarding_completed) {
      return corsErrorResponse("Seller has not completed payment setup", 400);
    }

    // 3. Handle Affiliate Logic
    let discountAmount = 0;
    let platformFeeRate = 5.0; // Default 5%
    let affiliateLinkId: string | null = null;

    if (affiliateLinkCode) {
      const { data: link } = await supabaseAdmin
        .from("affiliate_links")
        .select(`
          id,
          agent_id,
          is_active,
          listing_id,
          collabmarket_listings (
            client_discount_rate,
            platform_fee_rate
          )
        `)
        .eq("code", affiliateLinkCode)
        .single();

      if (link && link.is_active) {
        // Anti-fraud: agent cannot be the buyer
        if (link.agent_id !== buyerId) {
          affiliateLinkId = link.id;
          const listing = link.collabmarket_listings as unknown as {
            client_discount_rate: number;
            platform_fee_rate: number;
          } | null;

          if (listing) {
            // Calculate discount from base price
            discountAmount = Math.round((listing.client_discount_rate / 100) * pkg.price * 100) / 100;
            platformFeeRate = listing.platform_fee_rate;
          }
        }
      }
    }

    // 4. Calculate Amounts (aligned with amounts_coherence constraint)
    // amounts_coherence: total_amount = subtotal - discount_amount
    const subtotal = pkg.price;
    const totalAmount = subtotal - discountAmount;

    if (totalAmount < 1) {
      return corsErrorResponse("Total amount must be at least 1€", 400);
    }

    // Platform fee is calculated but NOT added to customer's total
    // It's deducted from seller's payout by distribute_commissions()
    const platformFee = Math.round((platformFeeRate / 100) * totalAmount * 100) / 100;

    // 5. Create Order in DB (v40 schema)
    const { data: order, error: orderError } = await supabaseAdmin
      .from("orders")
      .insert({
        buyer_id: buyerId,
        seller_id: sellerId,
        service_id: serviceId,
        package_id: packageId,
        affiliate_link_id: affiliateLinkId,
        order_type: "standard",
        subtotal: subtotal,
        discount_amount: discountAmount,
        total_amount: totalAmount,
        platform_fee: 0, // Will be calculated by distribute_commissions()
        status: "pending",
        stripe_payment_status: "unpaid",
      })
      .select("id, order_number")
      .single();

    if (orderError) {
      console.error("[Create Order] DB Error:", orderError);
      return corsErrorResponse(`Failed to create order: ${orderError.message}`, 500);
    }

    console.log(`[Create Order] Created order ${order.order_number} - Buyer: ${buyerId}, Seller: ${sellerId}`);

    // 6. Create Stripe Checkout Session
    const origin = req.headers.get("origin") || Deno.env.get("FRONTEND_URL") || "https://collabmarket.fr";

    const session = await stripe.checkout.sessions.create({
      payment_method_types: ["card"],
      line_items: [
        {
          price_data: {
            currency: "eur",
            product_data: {
              name: `${service.title} - ${pkg.name}`,
              description: pkg.description || undefined,
            },
            unit_amount: Math.round(totalAmount * 100), // Stripe uses cents
          },
          quantity: 1,
        },
      ],
      mode: "payment",
      payment_intent_data: {
        capture_method: "manual", // ESCROW - capture when seller accepts
        metadata: {
          order_id: order.id,
          order_number: order.order_number,
          buyer_id: buyerId,
          seller_id: sellerId,
        },
        transfer_group: order.id, // For reconciliation with transfers
      },
      success_url: `${origin}/orders/${order.id}?success=true`,
      cancel_url: `${origin}/services/${serviceId}?canceled=true`,
      metadata: {
        order_id: order.id,
        order_number: order.order_number,
        type: "standard_order",
      },
    });

    // 7. Update Order with Session ID
    const { error: updateError } = await supabaseAdmin
      .from("orders")
      .update({
        stripe_checkout_session_id: session.id,
      })
      .eq("id", order.id);

    if (updateError) {
      console.warn("[Create Order] Could not update session ID:", updateError.message);
      // Don't fail - order and session exist
    }

    // 8. System Log
    try {
      await supabaseAdmin.from("system_logs").insert({
        event_type: "info",
        message: "Order created via checkout",
        details: {
          order_id: order.id,
          order_number: order.order_number,
          buyer_id: buyerId,
          seller_id: sellerId,
          total_amount: totalAmount,
          checkout_session: session.id,
        },
      });
    } catch (logError) {
      console.warn("[Create Order] Failed to write system log:", logError);
    }

    return corsResponse({
      success: true,
      url: session.url,
      orderId: order.id,
      orderNumber: order.order_number,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("[Create Order Error]:", err);
    return corsErrorResponse(err.message, 500);
  }
});
