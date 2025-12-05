import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders } from "../shared/utils/cors.ts";

serve(async (req) => {
    if (req.method === "OPTIONS") {
        return new Response("ok", { headers: corsHeaders });
    }

    try {
        const supabase = createClient(
            Deno.env.get("SUPABASE_URL") ?? "",
            Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "" // Service Role required for public tracking
        );

        const { code, ip, user_agent, referer } = await req.json();

        if (!code) {
            throw new Error("Missing code");
        }

        // 1. Find Link
        const { data: link, error: linkError } = await supabase
            .from("affiliate_links")
            .select("id")
            .eq("code", code)
            .single();

        if (linkError || !link) {
            // Don't fail hard for tracking, just log
            console.warn(`Affiliate link not found for code: ${code}`);
            return new Response(JSON.stringify({ success: false }), {
                headers: { ...corsHeaders, "Content-Type": "application/json" },
                status: 200, // Return 200 to avoid client errors
            });
        }

        // 2. Record Click
        await supabase.from("affiliate_clicks").insert({
            affiliate_link_id: link.id,
            ip_address: ip,
            user_agent: user_agent,
            referer: referer,
        });

        return new Response(JSON.stringify({ success: true }), {
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
