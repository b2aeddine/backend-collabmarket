// ==============================================================================
// DISTRIBUTE-COMMISSIONS - V14.1 (SECURED)
// Distributes commissions for completed orders
// SECURITY: Requires CRON_SECRET or INTERNAL_SECRET - NOT publicly callable!
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, handleCorsOptions } from "../shared/utils/cors.ts";
import { verifyCronSecret } from "../shared/utils/auth.ts";

serve(async (req) => {
    if (req.method === "OPTIONS") {
        return handleCorsOptions();
    }

    try {
        // SECURITY: Verify cron/internal secret - this endpoint triggers money distribution!
        const authError = verifyCronSecret(req);
        if (authError) {
            console.warn("[Distribute Commissions] Unauthorized access attempt");
            return authError;
        }

        const supabase = createClient(
            Deno.env.get("SUPABASE_URL") ?? "",
            Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
        );

        const { order_id } = await req.json();

        if (!order_id) {
            throw new Error("Missing order_id");
        }

        // Validate UUID format
        const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
        if (!uuidRegex.test(order_id)) {
            throw new Error("Invalid order_id format");
        }

        console.log(`[Distribute Commissions] Processing order: ${order_id}`);

        const { data, error } = await supabase.rpc("distribute_commissions", {
            p_order_id: order_id,
        });

        if (error) {
            console.error(`[Distribute Commissions] RPC error for ${order_id}:`, error);
            throw error;
        }

        console.log(`[Distribute Commissions] Success for order: ${order_id}`);

        return new Response(JSON.stringify({
            success: true,
            order_id,
            result: data
        }), {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
            status: 200,
        });
    } catch (error: unknown) {
        const err = error as Error;
        console.error("[Distribute Commissions Error]:", err);
        return new Response(JSON.stringify({
            success: false,
            error: err.message
        }), {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
            status: 400,
        });
    }
});
