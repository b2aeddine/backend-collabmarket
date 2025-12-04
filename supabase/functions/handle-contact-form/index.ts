// ==============================================================================
// HANDLE-CONTACT-FORM - V14.0 (CORRECTED)
// Gère la soumission du formulaire de contact
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { z } from "https://deno.land/x/zod@v3.22.4/mod.ts";
import { createHmac } from "https://deno.land/std@0.190.0/crypto/mod.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("ALLOWED_ORIGIN") || "https://collabmarket.fr",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-signature",
};

// Validation schema
const contactSchema = z.object({
  name: z.string().min(2, "Name must be at least 2 characters").max(100),
  email: z.string().email("Invalid email format").max(255),
  subject: z.string().max(200).optional(),
  message: z.string().min(10, "Message must be at least 10 characters").max(5000),
});

// Helper pour récupérer l'IP client
function getClientIp(req: Request): string {
  return (
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ||
    req.headers.get("x-real-ip") ||
    req.headers.get("cf-connecting-ip") ||
    "unknown"
  );
}

// Vérification HMAC optionnelle (pour anti-bot)
async function verifyHmac(body: string, signature: string | null, secret: string): Promise<boolean> {
  if (!signature || !secret) return true; // Skip si non configuré

  try {
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey(
      "raw",
      encoder.encode(secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"]
    );
    const sig = await crypto.subtle.sign("HMAC", key, encoder.encode(body));
    const expectedSig = Array.from(new Uint8Array(sig))
      .map(b => b.toString(16).padStart(2, "0"))
      .join("");
    
    return signature === expectedSig;
  } catch {
    return false;
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const rawBody = await req.text();
    const body = JSON.parse(rawBody);

    // Vérification HMAC optionnelle
    const hmacSecret = Deno.env.get("CONTACT_FORM_HMAC_SECRET");
    const signature = req.headers.get("x-signature");

    if (hmacSecret) {
      const isValid = await verifyHmac(rawBody, signature, hmacSecret);
      if (!isValid) {
        console.warn("[Contact Form] Invalid HMAC signature");
        throw new Error("Invalid request signature");
      }
    }

    // Validation Zod
    const validation = contactSchema.safeParse(body);
    if (!validation.success) {
      const errorMsg = validation.error.errors.map(e => `${e.path.join(".")}: ${e.message}`).join(", ");
      throw new Error(`Validation error: ${errorMsg}`);
    }

    const { name, email, subject, message } = validation.data;
    const clientIp = getClientIp(req);

    console.log(`[Contact Form] New submission from ${email} (IP: ${clientIp})`);

    // Client Admin (car pas d'auth utilisateur)
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Rate limiting simple par IP
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const { count: recentCount } = await supabase
      .from("contact_messages")
      .select("id", { count: "exact", head: true })
      .eq("ip_address", clientIp)
      .gte("created_at", oneHourAgo);

    if (recentCount && recentCount >= 5) {
      throw new Error("Too many submissions. Please try again later.");
    }

    // Insertion
    const { data, error } = await supabase
      .from("contact_messages")
      .insert({
        name,
        email,
        subject: subject || null,
        message,
        ip_address: clientIp,
        status: "new",
      })
      .select()
      .single();

    if (error) {
      console.error("DB Insert Error:", error);
      throw new Error("Failed to save message");
    }

    console.log(`[Contact Form] Message saved: ${data.id}`);

    // Optionnel: Notification par email (à implémenter)
    // await sendNotificationEmail(data);

    return new Response(JSON.stringify({
      success: true,
      message: "Your message has been sent successfully",
      id: data.id,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("[Contact Form Error]:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
