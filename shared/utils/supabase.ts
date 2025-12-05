import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

export function createSupabaseClient(req: Request) {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
        throw new Error("Missing Authorization Header");
    }

    return createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_ANON_KEY")!,
        { global: { headers: { Authorization: authHeader } } }
    );
}

export function createSupabaseAdmin() {
    return createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );
}
