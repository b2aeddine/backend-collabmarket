import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders } from "../shared/utils/cors.ts";
import { nanoid } from "https://esm.sh/nanoid@4.0.0";

serve(async (req) => {
    if (req.method === "OPTIONS") {
        return new Response("ok", { headers: corsHeaders });
    }

    try {
        const supabase = createClient(
            Deno.env.get("SUPABASE_URL") ?? "",
            Deno.env.get("SUPABASE_ANON_KEY") ?? "",
            { global: { headers: { Authorization: req.headers.get("Authorization")! } } }
        );

        const { gig_id, listing_id } = await req.json();

        if (!gig_id && !listing_id) {
            throw new Error("Missing gig_id or listing_id");
        }

        // Get User
        const { data: { user }, error: authError } = await supabase.auth.getUser();
        if (authError || !user) throw new Error("Unauthorized");

        // Resolve Listing
        let targetListingId = listing_id;
        let targetGigId = gig_id;

        if (!targetListingId && targetGigId) {
            const { data: listing } = await supabase
                .from("collabmarket_listings")
                .select("id")
                .eq("gig_id", targetGigId)
                .eq("is_active", true)
                .single();

            if (!listing) throw new Error("Gig not affiliable");
            targetListingId = listing.id;
        } else if (targetListingId && !targetGigId) {
            const { data: listing } = await supabase
                .from("collabmarket_listings")
                .select("gig_id")
                .eq("id", targetListingId)
                .single();
            if (listing) targetGigId = listing.gig_id;
        }

        // Generate Code
        const code = nanoid(8).toUpperCase();
        const urlSlug = `${user.id.slice(0, 5)}-${code}`; // Simple slug strategy

        // Insert Link
        const { data, error } = await supabase
            .from("affiliate_links")
            .insert({
                agent_id: user.id,
                listing_id: targetListingId,
                gig_id: targetGigId,
                code: code,
                url_slug: urlSlug
            })
            .select()
            .single();

        if (error) throw error;

        return new Response(JSON.stringify(data), {
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
