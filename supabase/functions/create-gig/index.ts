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
            Deno.env.get("SUPABASE_ANON_KEY") ?? "",
            { global: { headers: { Authorization: req.headers.get("Authorization")! } } }
        );

        const {
            gig,
            packages,
            media,
            affiliate_config
        } = await req.json();

        // Validation basique
        if (!gig || !packages || !media) {
            throw new Error("Missing required fields");
        }

        // Appel RPC atomique
        const { data, error } = await supabase.rpc("create_complete_gig", {
            p_gig: gig,
            p_packages: packages,
            p_media: media,
            p_affiliate_config: affiliate_config,
        });

        if (error) throw error;

        return new Response(JSON.stringify({ success: true, gig_id: data }), {
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
