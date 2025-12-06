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
            Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
        );

        // 1. AUTHENTICATION
        const authHeader = req.headers.get("Authorization");
        if (!authHeader) throw new Error("Missing Authorization Header");

        const { data: { user }, error: authError } = await supabase.auth.getUser(authHeader.replace("Bearer ", ""));
        if (authError || !user) throw new Error("Unauthorized");

        const { order_id } = await req.json();
        if (!order_id) throw new Error("Missing order_id");

        // 2. FETCH ORDER
        const { data: order, error: orderError } = await supabase
            .from("orders")
            .select("*")
            .eq("id", order_id)
            .single();

        if (orderError || !order) throw new Error("Order not found");

        // 3. SECURITY & STATE CHECKS
        // Only Buyer can confirm delivery manually.
        // (Auto-confirm is handled by Cron/Admin, which bypasses this or uses a different endpoint/logic)

        if (order.merchant_id !== user.id) {
            throw new Error("Unauthorized: Only the buyer can confirm delivery.");
        }

        // Status must be 'submitted' (Seller has delivered) or 'awaiting_delivery' (if skipping delivery step, but 'submitted' is better)
        // Let's allow 'submitted' and 'awaiting_delivery' (if user wants to close early).
        if (order.status !== "submitted" && order.status !== "awaiting_delivery") {
            throw new Error(`Cannot confirm delivery for order in state '${order.status}'. Must be 'submitted' or 'awaiting_delivery'.`);
        }

        // 4. UPDATE STATUS TO FINISHED
        const { error: updateError } = await supabase
            .from("orders")
            .update({
                status: "finished",
                completed_at: new Date().toISOString(),
                updated_at: new Date().toISOString()
            })
            .eq("id", order_id);

        if (updateError) throw updateError;

        // 5. DISTRIBUTE COMMISSIONS
        // We call the RPC function we created.
        // Note: The RPC handles idempotency and status checks.

        const { data: distResult, error: distError } = await supabase.rpc("distribute_commissions", {
            p_order_id: order_id
        });

        if (distError) {
            console.error("Distribution Error:", distError);
            // We don't fail the request because the order is already finished.
            // We log it and maybe queue a retry?
            // For now, just log. The system is consistent (Order Finished, Commission Pending).
            await supabase.from("system_logs").insert({
                event_type: "error",
                message: "Failed to distribute commissions after confirmation",
                details: { order_id, error: distError }
            });
        }

        // 6. LOG AUDIT
        await supabase.from("audit_logs").insert({
            user_id: user.id,
            event_name: "order_confirmed",
            table_name: "orders",
            record_id: order_id,
            new_values: { status: "finished" }
        });

        return new Response(JSON.stringify({ success: true, order_id }), {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
            status: 200,
        });

    } catch (error) {
        console.error(`Confirm Error: ${error.message}`);
        return new Response(JSON.stringify({ error: error.message }), {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
            status: 400,
        });
    }
});
