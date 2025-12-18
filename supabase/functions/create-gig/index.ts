// ==============================================================================
// CREATE-GIG (CREATE-SERVICE) - V15.0 (SCHEMA V40 ALIGNED)
// Creates a service with packages atomically
// ALIGNED: Uses create_complete_gig RPC which creates services/service_packages
// NOTE: "gig" is legacy terminology, internally creates "service"
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { z } from "https://deno.land/x/zod@v3.22.4/mod.ts";
import { corsHeaders, handleCorsOptions, corsResponse, corsErrorResponse } from "../shared/utils/cors.ts";

// Validation schema
const packageSchema = z.object({
  name: z.string().min(1).max(100),
  description: z.string().max(1000).optional(),
  price: z.number().min(5).max(50000), // 5€ minimum, 50k€ max
  delivery_days: z.number().int().min(1).max(365),
  revisions: z.number().int().min(0).max(99).default(0),
});

const serviceSchema = z.object({
  // Accepts both "gig" (legacy) and "service" (v40) terminology
  title: z.string().min(5).max(100),
  description: z.string().min(50).max(5000),
  category_id: z.string().uuid(),
  packages: z.array(packageSchema).min(1).max(3),
  tags: z.array(z.string().max(50)).max(10).optional(),
  requirements: z.array(z.object({
    question: z.string().max(500),
    type: z.enum(['text', 'textarea', 'select', 'file']).default('text'),
    required: z.boolean().default(true),
    options: z.array(z.string()).optional(),
  })).max(10).optional(),
});

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return handleCorsOptions();
  }

  try {
    const body = await req.json();
    const authHeader = req.headers.get("Authorization");

    if (!authHeader) {
      return corsErrorResponse("Missing Authorization Header", 401);
    }

    // Support both old and new field names
    const input = {
      title: body.gig?.title || body.service?.title || body.title,
      description: body.gig?.description || body.service?.description || body.description,
      category_id: body.gig?.category_id || body.service?.category_id || body.category_id,
      packages: body.packages || body.gig?.packages || body.service?.packages || [],
      tags: body.media?.tags || body.tags || [],
      requirements: body.affiliate_config?.requirements || body.requirements || [],
    };

    // Validation
    const validation = serviceSchema.safeParse(input);
    if (!validation.success) {
      const errorMsg = validation.error.errors.map(e => `${e.path.join(".")}: ${e.message}`).join(", ");
      return corsErrorResponse(`Validation error: ${errorMsg}`, 400);
    }

    const { title, description, category_id, packages, tags, requirements } = validation.data;

    // Init Client Supabase (User Context)
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) {
      return corsErrorResponse("Unauthorized", 401);
    }

    // Call atomic RPC (creates service + packages in transaction)
    // Note: RPC is named "create_complete_gig" for backwards compat but creates services
    const { data: serviceId, error: rpcError } = await supabase.rpc("create_complete_gig", {
      p_title: title,
      p_description: description,
      p_category_id: category_id,
      p_packages: packages,
      p_tags: tags || null,
      p_requirements: requirements ? { items: requirements } : null,
    });

    if (rpcError) {
      console.error("RPC Error:", rpcError);
      // Handle specific error messages
      if (rpcError.message.includes('KYC')) {
        return corsErrorResponse("You must complete KYC verification before creating services", 403);
      }
      if (rpcError.message.includes('Stripe')) {
        return corsErrorResponse("You must complete Stripe onboarding before creating services", 403);
      }
      return corsErrorResponse(rpcError.message, 400);
    }

    console.log(`Service created: ${serviceId} by user ${user.id}`);

    return corsResponse({
      success: true,
      serviceId: serviceId, // v40 terminology
      gig_id: serviceId,    // Legacy compatibility
      message: "Service created successfully",
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("Error in create-gig:", err);
    return corsErrorResponse(err.message, 500);
  }
});
