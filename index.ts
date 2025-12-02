// ==============================================================================
// AUTO-HANDLE-ORDERS - V14.0 (CORRECTED)
// Appelle la RPC handle_cron_deadlines pour gérer les deadlines automatiques
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

interface CronResult {
  success: boolean;
  cancelled: number;
  completed: number;
  total_processed: number;
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!supabaseUrl || !supabaseServiceKey) {
      throw new Error("Missing Environment Variables");
    }

    // Client Admin
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Appel RPC
    const { data, error } = await supabase.rpc("handle_cron_deadlines");

    if (error) throw error;

    // FIX: Typage correct du résultat
    const result = data as CronResult | null;

    if (!result) {
      return new Response(JSON.stringify({
        success: true,
        data: { cancelled: 0, completed: 0, total_processed: 0 },
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      });
    }

    // Logging intelligent
    if (result.total_processed > 0) {
      console.log(`[Cron Job] Processed: ${result.total_processed} (Cancelled: ${result.cancelled}, Completed: ${result.completed})`);
    } else {
      console.log("[Cron Job] No orders to process.");
    }

    return new Response(JSON.stringify({
      success: true,
      data: result,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("[Cron Job Error]", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 500,
    });
  }
});
