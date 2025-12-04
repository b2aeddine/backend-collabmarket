// ==============================================================================
// SEARCH-INFLUENCERS - V14.0 (CORRECTED)
// Recherche d'influenceurs avec filtres
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { z } from "https://deno.land/x/zod@v3.22.4/mod.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("ALLOWED_ORIGIN") || "https://collabmarket.fr",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Validation schema
const searchSchema = z.object({
  query: z.string().max(200).optional(),
  category: z.string().uuid().optional(),
  city: z.string().max(100).optional(),
  minFollowers: z.number().min(0).optional(),
  maxPrice: z.number().min(0).optional(),
  isVerified: z.boolean().optional(),
  platform: z.string().max(50).optional(),
  page: z.number().min(1).default(1),
  limit: z.number().min(1).max(50).default(20),
  sortBy: z.enum(["relevance", "followers", "price_asc", "price_desc", "newest"]).default("relevance"),
});

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // Parse query params pour GET ou body pour POST
    let params: Record<string, unknown> = {};
    
    if (req.method === "GET") {
      const url = new URL(req.url);
      params = Object.fromEntries(url.searchParams.entries());
      // Convertir les types
      if (params.page) params.page = parseInt(params.page as string);
      if (params.limit) params.limit = parseInt(params.limit as string);
      if (params.minFollowers) params.minFollowers = parseInt(params.minFollowers as string);
      if (params.maxPrice) params.maxPrice = parseFloat(params.maxPrice as string);
      if (params.isVerified) params.isVerified = params.isVerified === "true";
    } else {
      params = await req.json();
    }

    // Validation
    const validation = searchSchema.safeParse(params);
    if (!validation.success) {
      const errorMsg = validation.error.errors.map(e => `${e.path.join(".")}: ${e.message}`).join(", ");
      throw new Error(`Validation error: ${errorMsg}`);
    }

    const { query, category, city, minFollowers, maxPrice, isVerified, platform, page, limit, sortBy } = validation.data;

    console.log(`[Search Influencers] Query: "${query || ''}", Page: ${page}, Limit: ${limit}`);

    // Client public (pas besoin d'auth pour la recherche)
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!
    );

    // Construction de la requête
    let queryBuilder = supabase
      .from("profiles")
      .select(`
        id,
        first_name,
        last_name,
        city,
        bio,
        avatar_url,
        is_verified,
        profile_views,
        created_at,
        social_links (
          platform,
          username,
          profile_url,
          followers
        ),
        offers!inner (
          id,
          title,
          price,
          category_id,
          is_active
        )
      `, { count: "exact" })
      .eq("role", "influenceur");

    // Filtres
    if (isVerified !== undefined) {
      queryBuilder = queryBuilder.eq("is_verified", isVerified);
    }

    if (city) {
      queryBuilder = queryBuilder.ilike("city", `%${city}%`);
    }

    if (query) {
      // Recherche full-text sur nom, bio, ville
      queryBuilder = queryBuilder.or(`first_name.ilike.%${query}%,last_name.ilike.%${query}%,bio.ilike.%${query}%,city.ilike.%${query}%`);
    }

    // Filtre par catégorie (via offers)
    if (category) {
      queryBuilder = queryBuilder.eq("offers.category_id", category);
    }

    // Filtre prix max
    if (maxPrice) {
      queryBuilder = queryBuilder.lte("offers.price", maxPrice);
    }

    // Pagination
    const offset = (page - 1) * limit;
    queryBuilder = queryBuilder.range(offset, offset + limit - 1);

    // Tri
    switch (sortBy) {
      case "newest":
        queryBuilder = queryBuilder.order("created_at", { ascending: false });
        break;
      case "followers":
        // Tri par followers nécessite une logique différente
        queryBuilder = queryBuilder.order("profile_views", { ascending: false });
        break;
      case "price_asc":
        queryBuilder = queryBuilder.order("offers(price)", { ascending: true });
        break;
      case "price_desc":
        queryBuilder = queryBuilder.order("offers(price)", { ascending: false });
        break;
      default:
        // Relevance = par défaut tri par views
        queryBuilder = queryBuilder.order("profile_views", { ascending: false });
    }

    const { data: influencers, count, error } = await queryBuilder;

    if (error) {
      console.error("Search Error:", error);
      throw new Error("Search failed");
    }

    // Post-traitement pour filtrer par followers si nécessaire
    let results = influencers || [];
    
    if (minFollowers || platform) {
      results = results.filter(inf => {
        const socialLinks = inf.social_links as Array<{ platform: string; followers: number }> || [];
        
        if (platform) {
          const hasplatform = socialLinks.some(sl => sl.platform.toLowerCase() === platform.toLowerCase());
          if (!hasplatform) return false;
        }
        
        if (minFollowers) {
          const totalFollowers = socialLinks.reduce((sum, sl) => sum + (sl.followers || 0), 0);
          if (totalFollowers < minFollowers) return false;
        }
        
        return true;
      });
    }

    // Formater la réponse
    const formattedResults = results.map(inf => ({
      id: inf.id,
      firstName: inf.first_name,
      lastName: inf.last_name,
      city: inf.city,
      bio: inf.bio,
      avatarUrl: inf.avatar_url,
      isVerified: inf.is_verified,
      profileViews: inf.profile_views,
      socialLinks: inf.social_links,
      offers: (inf.offers as Array<{ id: string; title: string; price: number; is_active: boolean }>)
        .filter(o => o.is_active)
        .map(o => ({
          id: o.id,
          title: o.title,
          price: o.price,
        })),
      minPrice: Math.min(...(inf.offers as Array<{ price: number }>).map(o => o.price)),
    }));

    return new Response(JSON.stringify({
      success: true,
      data: formattedResults,
      pagination: {
        page,
        limit,
        total: count || 0,
        totalPages: Math.ceil((count || 0) / limit),
      },
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("[Search Influencers Error]:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
