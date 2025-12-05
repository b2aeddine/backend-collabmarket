import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import Stripe from "https://esm.sh/stripe@11.1.0?target=deno";
import { corsHeaders } from "../shared/utils/cors.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") as string, {
    apiVersion: "2022-11-15",
    httpClient: Stripe.createFetchHttpClient(),
});

serve(async (req) => {
    if (req.method === "OPTIONS") {
        return new Response("ok", { headers: corsHeaders });
    }

    try {
        const supabase = createClient(
            Deno.env.get("SUPABASE_URL") ?? "",
            Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "" // Service role for admin-like fetching if needed
        );

        const {
            gig_id,
            package_id,
            affiliate_link_code,
            user_id // The buyer
        } = await req.json();

        if (!gig_id || !package_id || !user_id) {
            throw new Error("Missing required fields");
        }

        // 1. Fetch Gig & Package
        const { data: pkg, error: pkgError } = await supabase
            .from("gig_packages")
            .select("*, gigs(title, freelancer_id)")
            .eq("id", package_id)
            .single();

        if (pkgError || !pkg) throw new Error("Package not found");

        let basePrice = pkg.price;
        let clientDiscountRate = 0;
        let platformFeeRate = 5.0;
        let affiliateLinkId = null;

        // 2. Handle Affiliate Logic
        if (affiliate_link_code) {
            const { data: link } = await supabase
                .from("affiliate_links")
                .select("id, listing_id, collabmarket_listings(client_discount_rate, platform_fee_rate)")
                .eq("code", affiliate_link_code)
                .single();

            if (link) {
                affiliateLinkId = link.id;
                clientDiscountRate = link.collabmarket_listings.client_discount_rate;
                platformFeeRate = link.collabmarket_listings.platform_fee_rate;
            }
        }

        // 3. Calculate Amounts
        const clientDiscount = Math.round((clientDiscountRate / 100) * basePrice * 100) / 100;
        const priceAfterDiscount = basePrice - clientDiscount;
        const platformFee = Math.round((platformFeeRate / 100) * priceAfterDiscount * 100) / 100;
        const totalAmount = priceAfterDiscount + platformFee;

        // 4. Create Order in DB
        const { data: order, error: orderError } = await supabase
            .from("orders")
            .insert({
                merchant_id: user_id, // Client
                influencer_id: pkg.gigs.freelancer_id, // Freelancer
                gig_id: gig_id,
                gig_package_id: package_id,
                affiliate_link_id: affiliateLinkId,
                order_type: "freelance",
                total_amount: totalAmount,
                net_amount: basePrice, // We store base price here for reference, or priceAfterDiscount? 
                // SQL logic uses net_amount as base. Let's store basePrice.
                // Actually, V21 schema says net_amount is what influencer gets? No, calculate_order_amounts trigger overrides it.
                // We might need to disable that trigger for freelance orders or adapt it.
                // For now, let's trust the trigger or override it.
                // Let's store basePrice in net_amount and let the distribution logic handle the rest.
                status: "pending",
                stripe_payment_status: "unpaid"
            })
            .select("id")
            .single();

        if (orderError) throw orderError;

        // 5. Create Stripe Session
        const session = await stripe.checkout.sessions.create({
            payment_method_types: ["card"],
            line_items: [
                {
                    price_data: {
                        currency: "eur",
                        product_data: {
                            name: `${pkg.gigs.title} (${pkg.name})`,
                            description: pkg.description,
                        },
                        unit_amount: Math.round(totalAmount * 100), // Cents
                    },
                    quantity: 1,
                },
            ],
            mode: "payment",
            success_url: `${req.headers.get("origin")}/orders/${order.id}?success=true`,
            cancel_url: `${req.headers.get("origin")}/gigs/${gig_id}?canceled=true`,
            metadata: {
                order_id: order.id,
                type: "freelance_order"
            },
        });

        // 6. Update Order with Session ID
        await supabase
            .from("orders")
            .update({ stripe_checkout_session_id: session.id })
            .eq("id", order.id);

        return new Response(JSON.stringify({ url: session.url }), {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
            status: 200,
        });
    } catch (error) {
        return new Response(JSON.stringify({ error: error.message }), {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
            status: 400,
        });
    }
});
