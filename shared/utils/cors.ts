// Shared CORS configuration
export const corsHeaders = {
    "Access-Control-Allow-Origin": Deno.env.get("ALLOWED_ORIGIN") || "https://collabmarket.fr",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, stripe-signature",
    "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

export function handleCors(req: Request): Response | null {
    if (req.method === "OPTIONS") {
        return new Response(null, { headers: corsHeaders });
    }
    return null;
}
