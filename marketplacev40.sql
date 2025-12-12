-- ============================================================================
-- COLLABMARKET V40.5 - PRODUCTION READY MULTI-ROLE SAAS EDITION
-- ============================================================================
-- [CHANGELOG V40.5]
-- [SEC] GRANT SELECT ON ALL TABLES remplacé par GRANTs ciblés (réduction surface d'attaque)
-- [SEC] creator_codes_public_read supprimé (anti-scraping, résolution via fonction SECURITY DEFINER)
-- [SEC] services_public_read: ajout is_service_role() pour accès backend complet
-- [SEC] Snapshots apply_to_offer(): whitelist colonnes au lieu de row_to_json(*) (anti-fuite)
-- [SEC] Harmonisation SET search_path=public sur toutes les fonctions SECURITY DEFINER
-- [FIX] amounts_coherence: tolérance 0.01 pour arrondis Stripe (évite rejets légitimes)
-- [FIX] services.slug: UNIQUE(seller_id, slug) au lieu de global (permet même slug cross-sellers)
-- [FEAT] withdrawal_allocations: table pour verrouillage partiel des revenus
-- [FEAT] request_withdrawal(): allocation FIFO des revenus (ne verrouille plus tout le solde)
--
-- [CHANGELOG V40.4]
-- [FIX] merchant_profiles: ajout colonne description (manquante pour v_merchant_public)
-- [FIX] agent_profiles: ajout colonnes marketing_channels, audience_description,
--       experience_level (manquantes pour v_agent_public)
-- [CONSTRAINT] orders.amounts_coherence: vérifie total ≈ subtotal - discount + platform_fee
-- [PERF] Index supplémentaires messages:
--       - idx_messages_sender_time (sender_id, created_at DESC)
--       - idx_messages_conversation_time (conversation_id, created_at DESC)
--
-- [CHANGELOG V40.3]
-- [FIX] orders: ajout colonnes order_number (auto-généré) et seller_notes
-- [FIX] influencer_profiles: ajout colonnes manquantes (content_types, platforms,
--       collaboration_types, audience_size_total, social_platforms, media_kit_url,
--       price_range_min/max, engagement_rate)
-- [FIX] v_influencer_public & v_seller_public: correction références colonnes
-- [SEC] social_links_public_read: restreint aux utilisateurs avec rôle influencer actif
-- [FEAT] target_roles: conversion de TEXT à TEXT[] pour flexibilité multi-rôle
--       - Validation dans apply_to_offer() du rôle de l'applicant
-- [TRIG] trg_influencer_requires_social: exige au moins 1 social_link pour influencer
-- [TRIG] trg_protect_role_deletion: empêche suppression si services/commandes actifs
-- [PERF] Index GIN ajoutés:
--       - freelance_profiles: skills, availability_status
--       - influencer_profiles: platforms, niche, social_platforms, audience_size
--       - global_offer_applications: profile_snapshot, services_snapshot
--
-- [CHANGELOG V40.2]
-- [ARCHI] Distinction services influencer/freelance:
--       - Nouvelle colonne service_role sur services (influencer/freelance)
--       - Vérification que le seller a le rôle correspondant via RLS
-- [SEC] Privacy profiles totalement refactorisée (CRITIQUE):
--       - profiles_authenticated_read supprimée (exposait toutes les colonnes)
--       - Seul le owner peut lire son propre profil complet
--       - Admins/service_role ont accès total
--       - user_roles et role-profiles restreints au owner/admin
-- [SEC] KYC/Stripe enforcement:
--       - services INSERT: vérifie rôle actif + KYC pour publier (sauf draft)
--       - global_offer_applications INSERT: KYC + Stripe requis pour postuler
--       - global_offers INSERT: restreint aux merchants
-- [FIX] Conversations unique bidirectionnelle:
--       - Colonnes canonical_p1/canonical_p2 avec LEAST/GREATEST
--       - Empêche les doublons (A,B) et (B,A)
-- [FEAT] Workflow complet appels d'offres:
--       - global_offers: selected_application_id, resulting_order_id
--       - global_offer_applications: snapshots profil/portfolio/services
--       - order_type 'offer' ajouté
--       - Fonctions create_order_from_application() et apply_to_offer()
-- [FIX] resolve_creator_code: vérifie que l'agent a le rôle 'agent' actif
-- [FIX] reverse_commissions: correction erreurs d'arrondis
--       - Ratio calculé sur montant RESTANT (pas total original)
--       - Évite les erreurs cumulées lors de remboursements multiples
-- [VIEWS] Nouvelles vues publiques sécurisées:
--       - v_freelance_public, v_influencer_public, v_merchant_public, v_agent_public
--       - v_seller_public (vue unifiée des vendeurs)
--
-- [CHANGELOG V40.1]
-- [FIX] reverse_commissions: support remboursements partiels avec pro-rata
-- [SEC] Vie privée profiles renforcée (GRANT SELECT profiles retiré pour anon)
--
-- [CHANGELOG V40.0]
-- [FIX] Colonnes client_discount_rate, acceptance_deadline ajoutées
-- [SEC] RLS complète, GRANT EXECUTE restreint
-- [ARCHI] Multi-rôles complet (Influencer, Merchant, Freelance, Agent)
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;

BEGIN;

-- ============================================================================
-- 1. FONCTIONS UTILITAIRES
-- ============================================================================

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.is_service_role()
RETURNS BOOLEAN LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN (
    current_user = 'postgres'
    OR COALESCE(current_setting('request.jwt.claims', true)::json->>'role', '') = 'service_role'
  );
EXCEPTION WHEN OTHERS THEN
  RETURN FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid());
$$;

-- ============================================================================
-- 2. RATE LIMITING & WEBHOOKS
-- ============================================================================

CREATE TABLE public.rate_limits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  identifier TEXT NOT NULL,
  endpoint TEXT NOT NULL,
  hits INTEGER DEFAULT 1,
  window_start TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (identifier, endpoint)
);
CREATE INDEX idx_rate_limits_cleanup ON public.rate_limits(window_start);

CREATE OR REPLACE FUNCTION public.check_rate_limit(
  p_identifier TEXT, 
  p_endpoint TEXT, 
  p_max_requests INTEGER DEFAULT 30, 
  p_window_seconds INTEGER DEFAULT 60
) RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_count INTEGER;
BEGIN
  DELETE FROM public.rate_limits WHERE window_start < NOW() - INTERVAL '1 hour';
  INSERT INTO public.rate_limits (identifier, endpoint, hits, window_start)
  VALUES (p_identifier, p_endpoint, 1, NOW())
  ON CONFLICT (identifier, endpoint) DO UPDATE SET
    hits = CASE 
      WHEN public.rate_limits.window_start < NOW() - (p_window_seconds || ' seconds')::INTERVAL THEN 1 
      ELSE public.rate_limits.hits + 1 
    END,
    window_start = CASE 
      WHEN public.rate_limits.window_start < NOW() - (p_window_seconds || ' seconds')::INTERVAL THEN NOW() 
      ELSE public.rate_limits.window_start 
    END
  RETURNING hits INTO v_count;
  RETURN v_count <= p_max_requests;
END;
$$;

CREATE TABLE public.processed_webhooks (
  event_id TEXT PRIMARY KEY,
  event_type TEXT NOT NULL,
  processed_at TIMESTAMPTZ DEFAULT NOW(),
  payload_hash TEXT
);
CREATE INDEX idx_webhooks_cleanup ON public.processed_webhooks(processed_at);

CREATE OR REPLACE FUNCTION public.check_webhook_replay(p_event_id TEXT, p_event_type TEXT, p_payload_hash TEXT DEFAULT NULL)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.processed_webhooks WHERE event_id = p_event_id) THEN RETURN FALSE; END IF;
  INSERT INTO public.processed_webhooks (event_id, event_type, payload_hash) VALUES (p_event_id, p_event_type, p_payload_hash);
  RETURN TRUE;
END;
$$;

-- ============================================================================
-- 3. PROFILS & GESTION MULTI-RÔLES
-- ============================================================================

CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username TEXT UNIQUE CHECK (username IS NULL OR username ~ '^[a-z0-9_]{3,30}$'),
  display_name TEXT CHECK (LENGTH(display_name) <= 100),
  first_name TEXT CHECK (LENGTH(first_name) <= 100),
  last_name TEXT CHECK (LENGTH(last_name) <= 100),
  contact_email TEXT CHECK (contact_email IS NULL OR contact_email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
  phone TEXT CHECK (LENGTH(phone) <= 20),
  city TEXT CHECK (LENGTH(city) <= 100),
  country TEXT DEFAULT 'FR' CHECK (LENGTH(country) = 2),
  bio TEXT CHECK (LENGTH(bio) <= 2000),
  avatar_url TEXT CHECK (LENGTH(avatar_url) <= 500),
  cover_url TEXT CHECK (LENGTH(cover_url) <= 500),
  website_url TEXT CHECK (LENGTH(website_url) <= 500),
  
  -- Compliance & Trust
  is_verified BOOLEAN DEFAULT FALSE,
  email_verified_at TIMESTAMPTZ,
  kyc_status TEXT DEFAULT 'pending' CHECK (kyc_status IN ('pending','incomplete','verified','rejected')),
  kyc_verified_at TIMESTAMPTZ,
  
  -- Stripe
  stripe_account_id TEXT,
  stripe_customer_id TEXT,
  stripe_charges_enabled BOOLEAN DEFAULT FALSE,
  stripe_payouts_enabled BOOLEAN DEFAULT FALSE,
  stripe_onboarding_completed BOOLEAN DEFAULT FALSE,
  
  -- Stats
  average_rating DECIMAL(3,2) DEFAULT 0 CHECK (average_rating >= 0 AND average_rating <= 5),
  total_reviews INTEGER DEFAULT 0 CHECK (total_reviews >= 0),
  completed_orders_count INTEGER DEFAULT 0 CHECK (completed_orders_count >= 0),
  
  -- RGPD
  data_retention_consent BOOLEAN DEFAULT FALSE,
  marketing_consent BOOLEAN DEFAULT FALSE,
  deletion_requested_at TIMESTAMPTZ,
  deletion_scheduled_for TIMESTAMPTZ,
  
  -- Onboarding
  onboarding_completed BOOLEAN DEFAULT FALSE,
  onboarding_step TEXT DEFAULT 'account_created',
  onboarding_data JSONB DEFAULT '{}'::jsonb,
  
  -- Meta
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_profiles_username ON public.profiles(username);
CREATE INDEX idx_profiles_kyc ON public.profiles(kyc_status) WHERE kyc_status != 'verified';

CREATE TABLE public.admins (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  permissions JSONB DEFAULT '{"all": true}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table multi-rôles (cœur du SaaS)
CREATE TABLE public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('influencer', 'freelance', 'merchant', 'agent')),
  status TEXT DEFAULT 'active' CHECK (status IN ('active', 'pending', 'suspended')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (user_id, role)
);
CREATE INDEX idx_user_roles_user ON public.user_roles(user_id);
CREATE INDEX idx_user_roles_role ON public.user_roles(role);

-- Trigger: Un influenceur doit avoir au moins 1 réseau social pour être actif
CREATE OR REPLACE FUNCTION public.check_influencer_social_links()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  -- Vérifie uniquement si on active le rôle influencer
  IF NEW.role = 'influencer' AND NEW.status = 'active' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.social_links
      WHERE user_id = NEW.user_id
    ) THEN
      RAISE EXCEPTION 'Un influenceur doit avoir au moins un réseau social configuré avant d''activer son rôle'
        USING ERRCODE = 'check_violation',
              HINT = 'Ajoutez au moins un réseau social via la table social_links';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_influencer_requires_social
BEFORE INSERT OR UPDATE ON public.user_roles
FOR EACH ROW
WHEN (NEW.role = 'influencer')
EXECUTE FUNCTION public.check_influencer_social_links();

-- Trigger: Empêcher la suppression d'un rôle avec des services ou commandes actifs
CREATE OR REPLACE FUNCTION public.protect_role_deletion()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_active_services INTEGER;
  v_active_orders_as_seller INTEGER;
  v_active_orders_as_buyer INTEGER;
BEGIN
  -- Vérifier les services actifs pour ce rôle
  IF OLD.role IN ('influencer', 'freelance') THEN
    SELECT COUNT(*) INTO v_active_services
    FROM public.services
    WHERE seller_id = OLD.user_id
      AND service_role = OLD.role
      AND status IN ('active', 'pending', 'paused');

    IF v_active_services > 0 THEN
      RAISE EXCEPTION 'Impossible de supprimer le rôle %: % service(s) actif(s) trouvé(s)', OLD.role, v_active_services
        USING ERRCODE = 'restrict_violation',
              HINT = 'Archivez ou supprimez d''abord vos services';
    END IF;
  END IF;

  -- Vérifier les commandes actives (en tant que vendeur)
  SELECT COUNT(*) INTO v_active_orders_as_seller
  FROM public.orders
  WHERE seller_id = OLD.user_id
    AND status IN ('pending', 'accepted', 'in_progress', 'delivered', 'revision_requested');

  IF v_active_orders_as_seller > 0 THEN
    RAISE EXCEPTION 'Impossible de supprimer le rôle %: % commande(s) active(s) en tant que vendeur', OLD.role, v_active_orders_as_seller
      USING ERRCODE = 'restrict_violation',
            HINT = 'Terminez d''abord vos commandes en cours';
  END IF;

  -- Vérifier les commandes actives (en tant qu'acheteur/merchant)
  IF OLD.role = 'merchant' THEN
    SELECT COUNT(*) INTO v_active_orders_as_buyer
    FROM public.orders
    WHERE buyer_id = OLD.user_id
      AND status IN ('pending', 'accepted', 'in_progress', 'delivered', 'revision_requested');

    IF v_active_orders_as_buyer > 0 THEN
      RAISE EXCEPTION 'Impossible de supprimer le rôle merchant: % commande(s) active(s) en tant qu''acheteur', v_active_orders_as_buyer
        USING ERRCODE = 'restrict_violation',
              HINT = 'Terminez d''abord vos commandes en cours';
    END IF;
  END IF;

  -- Vérifier les conversions non résolues pour agent
  IF OLD.role = 'agent' THEN
    IF EXISTS (
      SELECT 1 FROM public.affiliate_conversions
      WHERE agent_id = OLD.user_id
        AND status = 'pending'
    ) THEN
      RAISE EXCEPTION 'Impossible de supprimer le rôle agent: conversions d''affiliation en attente'
        USING ERRCODE = 'restrict_violation',
              HINT = 'Attendez que les conversions soient résolues';
    END IF;
  END IF;

  RETURN OLD;
END;
$$;

CREATE TRIGGER trg_protect_role_deletion
BEFORE DELETE ON public.user_roles
FOR EACH ROW
EXECUTE FUNCTION public.protect_role_deletion();

-- Préférences dashboard
CREATE TABLE public.dashboard_preferences (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  last_active_role TEXT CHECK (last_active_role IN ('influencer', 'freelance', 'merchant', 'agent')),
  theme_preference TEXT DEFAULT 'light' CHECK (theme_preference IN ('light', 'dark', 'system')),
  notifications_enabled BOOLEAN DEFAULT TRUE,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Profils spécifiques par rôle
CREATE TABLE public.freelance_profiles (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  professional_title TEXT CHECK (LENGTH(professional_title) <= 100),
  tagline TEXT CHECK (LENGTH(tagline) <= 200),
  description TEXT CHECK (LENGTH(description) <= 2000),
  skills TEXT[] DEFAULT '{}',
  languages JSONB DEFAULT '[]'::jsonb,
  experience_years INTEGER CHECK (experience_years >= 0 AND experience_years <= 50),
  hourly_rate DECIMAL(10,2) CHECK (hourly_rate >= 0),
  availability_status TEXT DEFAULT 'available' CHECK (availability_status IN ('available', 'busy', 'unavailable')),
  response_time_hours INTEGER DEFAULT 24 CHECK (response_time_hours > 0),
  total_earnings DECIMAL(12,2) DEFAULT 0 CHECK (total_earnings >= 0),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
-- Index pour recherche par compétences
CREATE INDEX idx_freelance_skills ON public.freelance_profiles USING GIN (skills);
CREATE INDEX idx_freelance_availability ON public.freelance_profiles(availability_status);

CREATE TABLE public.influencer_profiles (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  niche TEXT[] DEFAULT '{}',
  content_types TEXT[] DEFAULT '{}',           -- Types de contenu: video, photo, story, reel, etc.
  platforms TEXT[] DEFAULT '{}',               -- Plateformes: instagram, tiktok, youtube, etc.
  collaboration_types TEXT[] DEFAULT '{}',     -- Types de collab: sponsored, review, unboxing, etc.
  audience_size_total INTEGER DEFAULT 0 CHECK (audience_size_total >= 0),
  social_platforms JSONB DEFAULT '{}'::jsonb,  -- Détail par plateforme {instagram: {username, followers}, ...}
  media_kit_url TEXT,
  -- Pricing
  price_range_min DECIMAL(10,2) CHECK (price_range_min >= 0),
  price_range_max DECIMAL(10,2) CHECK (price_range_max >= price_range_min),
  min_collaboration_price DECIMAL(10,2) CHECK (min_collaboration_price >= 0),  -- Legacy, utilisé pour compat
  engagement_rate DECIMAL(5,2) CHECK (engagement_rate >= 0 AND engagement_rate <= 100),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
-- Index pour filtrage par plateformes et recherche JSONB
CREATE INDEX idx_influencer_platforms ON public.influencer_profiles USING GIN (platforms);
CREATE INDEX idx_influencer_niche ON public.influencer_profiles USING GIN (niche);
CREATE INDEX idx_influencer_social_platforms ON public.influencer_profiles USING GIN (social_platforms jsonb_path_ops);
CREATE INDEX idx_influencer_audience_size ON public.influencer_profiles(audience_size_total DESC);

CREATE TABLE public.merchant_profiles (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  company_name TEXT CHECK (LENGTH(company_name) <= 200),
  description TEXT CHECK (LENGTH(description) <= 2000),  -- Description publique de l'entreprise
  vat_number TEXT CHECK (LENGTH(vat_number) <= 50),
  industry TEXT CHECK (LENGTH(industry) <= 100),
  company_size TEXT CHECK (company_size IN ('solo', 'small', 'medium', 'large', 'enterprise')),
  website_url TEXT,
  total_spend DECIMAL(12,2) DEFAULT 0 CHECK (total_spend >= 0),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.agent_profiles (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  agency_name TEXT CHECK (LENGTH(agency_name) <= 200),
  -- Infos publiques pour les agents affiliés
  marketing_channels TEXT[] DEFAULT '{}',  -- Canaux de marketing: blog, youtube, social, email, etc.
  audience_description TEXT CHECK (LENGTH(audience_description) <= 1000),  -- Description de l'audience cible
  experience_level TEXT CHECK (experience_level IN ('beginner', 'intermediate', 'advanced', 'expert')),
  -- Commission et stats
  commission_rate_default DECIMAL(5,2) DEFAULT 10.0 CHECK (commission_rate_default >= 0 AND commission_rate_default <= 50),
  total_generated_revenue DECIMAL(12,2) DEFAULT 0 CHECK (total_generated_revenue >= 0),
  total_conversions INTEGER DEFAULT 0 CHECK (total_conversions >= 0),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.social_links (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  platform TEXT NOT NULL CHECK (platform IN ('instagram', 'tiktok', 'youtube', 'twitter', 'linkedin', 'facebook', 'twitch', 'snapchat', 'pinterest', 'other')),
  username TEXT,
  url TEXT NOT NULL,
  followers_count INTEGER DEFAULT 0 CHECK (followers_count >= 0),
  is_verified BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (user_id, platform)
);
CREATE INDEX idx_social_links_user ON public.social_links(user_id);

-- ============================================================================
-- 4. CREATOR CODES (Affiliation)
-- ============================================================================

CREATE TABLE public.creator_codes (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  code TEXT NOT NULL UNIQUE CHECK (code ~ '^[A-Z2-9]{4,15}$'),
  is_active BOOLEAN DEFAULT TRUE,
  total_uses INTEGER DEFAULT 0 CHECK (total_uses >= 0),
  total_revenue DECIMAL(12,2) DEFAULT 0 CHECK (total_revenue >= 0),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_creator_codes_code ON public.creator_codes(code) WHERE is_active = TRUE;

-- Génération automatique de code créateur
CREATE OR REPLACE FUNCTION public.generate_creator_code(p_user_id UUID)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_base TEXT;
  v_suffix TEXT;
  v_code TEXT;
  v_charset TEXT := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_attempts INTEGER := 0;
BEGIN
  IF EXISTS(SELECT 1 FROM public.creator_codes WHERE user_id = p_user_id) THEN
    RETURN (SELECT code FROM public.creator_codes WHERE user_id = p_user_id);
  END IF;
  
  SELECT UPPER(regexp_replace(COALESCE(username, display_name, 'USER'), '[^a-zA-Z0-9]', '', 'g')) 
  INTO v_base FROM public.profiles WHERE id = p_user_id;
  
  IF v_base IS NULL OR v_base = '' THEN v_base := 'USER'; END IF;
  v_base := substring(v_base FROM 1 FOR 8);

  LOOP
    v_attempts := v_attempts + 1;
    IF v_attempts > 100 THEN RAISE EXCEPTION 'CODE_GENERATION_FAILED'; END IF;
    
    v_suffix := '';
    FOR i IN 1..3 LOOP 
      v_suffix := v_suffix || substr(v_charset, floor(random() * length(v_charset) + 1)::int, 1); 
    END LOOP;
    v_code := v_base || v_suffix;
    
    BEGIN
      INSERT INTO public.creator_codes(user_id, code) VALUES (p_user_id, v_code);
      EXIT;
    EXCEPTION WHEN unique_violation THEN CONTINUE; END;
  END LOOP;
  
  RETURN v_code;
END;
$$;

-- Immutabilité du code (empêche UPDATE et DELETE)
CREATE OR REPLACE FUNCTION public.prevent_creator_code_modification()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.code IS DISTINCT FROM OLD.code OR NEW.user_id IS DISTINCT FROM OLD.user_id THEN 
      RAISE EXCEPTION 'CREATOR_CODE_IMMUTABLE'; 
    END IF;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN 
    RAISE EXCEPTION 'CREATOR_CODE_CANNOT_BE_DELETED'; 
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_creator_codes_immutable 
BEFORE UPDATE OR DELETE ON public.creator_codes 
FOR EACH ROW EXECUTE FUNCTION public.prevent_creator_code_modification();

-- ============================================================================
-- 5. CATEGORIES
-- ============================================================================

CREATE TABLE public.categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_id UUID REFERENCES public.categories(id) ON DELETE SET NULL,
  name TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  description TEXT,
  icon TEXT,
  applicable_to TEXT[] DEFAULT ARRAY['freelance', 'influencer'],
  sort_order INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_categories_parent ON public.categories(parent_id);
CREATE INDEX idx_categories_slug ON public.categories(slug);

-- ============================================================================
-- 6. SERVICES (Unifiés gigs + offers)
-- ============================================================================

CREATE TABLE public.services (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  category_id UUID REFERENCES public.categories(id) ON DELETE SET NULL,
  -- Distinction influencer/freelance service
  service_role TEXT NOT NULL DEFAULT 'freelance' CHECK (service_role IN ('influencer', 'freelance')),
  title TEXT NOT NULL CHECK (LENGTH(title) >= 10 AND LENGTH(title) <= 200),
  slug TEXT NOT NULL,  -- Unique par seller (voir contrainte ci-dessous)
  description TEXT NOT NULL CHECK (LENGTH(description) >= 50),
  search_tags TEXT[] DEFAULT '{}',
  base_price DECIMAL(10,2) NOT NULL CHECK (base_price >= 5),
  min_delivery_days INTEGER NOT NULL CHECK (min_delivery_days >= 1),
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'pending_review', 'active', 'paused', 'rejected', 'deleted')),
  rejection_reason TEXT,
  rating_average DECIMAL(3,2) DEFAULT 0 CHECK (rating_average >= 0 AND rating_average <= 5),
  rating_count INTEGER DEFAULT 0 CHECK (rating_count >= 0),
  total_orders INTEGER DEFAULT 0 CHECK (total_orders >= 0),
  view_count INTEGER DEFAULT 0 CHECK (view_count >= 0),
  is_affiliable BOOLEAN DEFAULT FALSE,
  is_featured BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_services_seller ON public.services(seller_id);
CREATE INDEX idx_services_category ON public.services(category_id);
CREATE INDEX idx_services_status ON public.services(status);
CREATE INDEX idx_services_role ON public.services(service_role);
CREATE INDEX idx_services_active ON public.services(status, is_affiliable) WHERE status = 'active';
CREATE INDEX idx_services_search ON public.services USING GIN (to_tsvector('french', title || ' ' || description));
-- Slug unique par vendeur (permet à différents vendeurs d'avoir le même slug)
CREATE UNIQUE INDEX idx_services_seller_slug ON public.services(seller_id, slug);

CREATE TABLE public.service_packages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  service_id UUID NOT NULL REFERENCES public.services(id) ON DELETE CASCADE,
  name TEXT NOT NULL CHECK (name IN ('basic', 'standard', 'premium')),
  title TEXT CHECK (LENGTH(title) <= 100),
  description TEXT,
  price DECIMAL(10,2) NOT NULL CHECK (price >= 5),
  delivery_days INTEGER NOT NULL CHECK (delivery_days >= 1),
  revisions INTEGER DEFAULT 0 CHECK (revisions >= 0),
  features JSONB DEFAULT '[]'::jsonb,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (service_id, name)
);
CREATE INDEX idx_service_packages_service ON public.service_packages(service_id);

CREATE TABLE public.service_media (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  service_id UUID NOT NULL REFERENCES public.services(id) ON DELETE CASCADE,
  media_type TEXT NOT NULL CHECK (media_type IN ('image', 'video', 'audio', 'document')),
  url TEXT NOT NULL,
  thumbnail_url TEXT,
  sort_order INTEGER DEFAULT 0,
  is_primary BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_service_media_service ON public.service_media(service_id);

CREATE TABLE public.service_faqs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  service_id UUID NOT NULL REFERENCES public.services(id) ON DELETE CASCADE,
  question TEXT NOT NULL,
  answer TEXT NOT NULL,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.service_requirements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  service_id UUID NOT NULL REFERENCES public.services(id) ON DELETE CASCADE,
  question TEXT NOT NULL,
  type TEXT NOT NULL DEFAULT 'text' CHECK (type IN ('text', 'textarea', 'file', 'select', 'multiselect')),
  options JSONB,
  is_required BOOLEAN DEFAULT TRUE,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.service_extras (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  service_id UUID NOT NULL REFERENCES public.services(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  price DECIMAL(10,2) NOT NULL CHECK (price > 0),
  extra_delivery_days INTEGER DEFAULT 0 CHECK (extra_delivery_days >= 0),
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.service_tags (
  service_id UUID NOT NULL REFERENCES public.services(id) ON DELETE CASCADE,
  tag TEXT NOT NULL CHECK (LENGTH(tag) >= 2 AND LENGTH(tag) <= 30),
  PRIMARY KEY (service_id, tag)
);

-- ============================================================================
-- 7. GLOBAL OFFERS (Campagnes / Appels d'offres)
-- ============================================================================

CREATE TABLE public.global_offers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  author_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  title TEXT NOT NULL CHECK (LENGTH(title) >= 10 AND LENGTH(title) <= 200),
  description TEXT NOT NULL,
  budget_min DECIMAL(10,2) CHECK (budget_min >= 0),
  budget_max DECIMAL(10,2) CHECK (budget_max >= budget_min),
  target_roles TEXT[] DEFAULT ARRAY['influencer', 'freelance'] CHECK (
    target_roles IS NOT NULL
    AND array_length(target_roles, 1) > 0
    AND target_roles <@ ARRAY['influencer', 'freelance']::TEXT[]
  ),
  category_id UUID REFERENCES public.categories(id) ON DELETE SET NULL,
  requirements JSONB DEFAULT '[]'::jsonb,
  status TEXT DEFAULT 'open' CHECK (status IN ('draft', 'open', 'in_progress', 'closed', 'archived')),
  applicants_count INTEGER DEFAULT 0 CHECK (applicants_count >= 0),
  -- Workflow: application sélectionnée et commande liée
  selected_application_id UUID,  -- FK ajoutée après création de global_offer_applications
  resulting_order_id UUID,       -- FK ajoutée après création de orders
  deadline TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_global_offers_author ON public.global_offers(author_id);
CREATE INDEX idx_global_offers_status ON public.global_offers(status);
CREATE INDEX idx_global_offers_open ON public.global_offers(status, deadline) WHERE status = 'open';

CREATE TABLE public.global_offer_applications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  offer_id UUID NOT NULL REFERENCES public.global_offers(id) ON DELETE CASCADE,
  applicant_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  cover_letter TEXT,
  proposed_price DECIMAL(10,2),
  proposed_delivery_days INTEGER CHECK (proposed_delivery_days >= 1),
  -- Snapshots au moment de la candidature (RGPD: état au moment de l'apply)
  profile_snapshot JSONB,      -- username, display_name, bio, avatar, skills, etc.
  portfolio_snapshot JSONB,    -- items portfolio au moment de l'apply
  services_snapshot JSONB,     -- services actifs au moment de l'apply
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'shortlisted', 'accepted', 'rejected', 'withdrawn')),
  -- Flag si sélectionné pour créer la commande
  is_selected BOOLEAN DEFAULT FALSE,
  selected_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (offer_id, applicant_id)
);
CREATE INDEX idx_applications_offer ON public.global_offer_applications(offer_id);
CREATE INDEX idx_applications_applicant ON public.global_offer_applications(applicant_id);
CREATE INDEX idx_applications_selected ON public.global_offer_applications(offer_id) WHERE is_selected = TRUE;
-- Index GIN pour recherche dans les snapshots JSONB
CREATE INDEX idx_applications_profile_snapshot ON public.global_offer_applications USING GIN (profile_snapshot jsonb_path_ops);
CREATE INDEX idx_applications_services_snapshot ON public.global_offer_applications USING GIN (services_snapshot jsonb_path_ops);

-- Ajouter FK différée sur global_offers.selected_application_id
ALTER TABLE public.global_offers
  ADD CONSTRAINT fk_selected_application
  FOREIGN KEY (selected_application_id) REFERENCES public.global_offer_applications(id) ON DELETE SET NULL;

-- ============================================================================
-- 8. PORTFOLIO
-- ============================================================================

CREATE TABLE public.portfolio_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  title TEXT CHECK (LENGTH(title) <= 100),
  description TEXT CHECK (LENGTH(description) <= 1000),
  media_type TEXT NOT NULL CHECK (media_type IN ('image', 'video', 'audio', 'document', 'link')),
  media_url TEXT NOT NULL,
  thumbnail_url TEXT,
  external_url TEXT,
  category TEXT,
  tags TEXT[] DEFAULT '{}',
  sort_order INTEGER DEFAULT 0,
  is_featured BOOLEAN DEFAULT FALSE,
  view_count INTEGER DEFAULT 0 CHECK (view_count >= 0),
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_portfolio_user ON public.portfolio_items(user_id);

-- ============================================================================
-- 9. AFFILIATION
-- ============================================================================

CREATE TABLE public.affiliate_listings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  service_id UUID NOT NULL UNIQUE REFERENCES public.services(id) ON DELETE CASCADE,
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  is_active BOOLEAN DEFAULT TRUE,
  client_discount_rate DECIMAL(5,2) DEFAULT 0 CHECK (client_discount_rate >= 0 AND client_discount_rate <= 50),
  agent_commission_rate DECIMAL(5,2) NOT NULL DEFAULT 10.0 CHECK (agent_commission_rate >= 0 AND agent_commission_rate <= 50),
  platform_fee_rate DECIMAL(5,2) NOT NULL DEFAULT 5.0 CHECK (platform_fee_rate >= 0 AND platform_fee_rate <= 30),
  platform_cut_on_agent_rate DECIMAL(5,2) NOT NULL DEFAULT 20.0 CHECK (platform_cut_on_agent_rate >= 0 AND platform_cut_on_agent_rate <= 50),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_affiliate_listings_seller ON public.affiliate_listings(seller_id);
CREATE INDEX idx_affiliate_listings_active ON public.affiliate_listings(is_active) WHERE is_active = TRUE;

CREATE TABLE public.affiliate_links (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  url_slug TEXT NOT NULL UNIQUE,
  listing_id UUID NOT NULL REFERENCES public.affiliate_listings(id) ON DELETE CASCADE,
  agent_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  is_active BOOLEAN DEFAULT TRUE,
  click_count INTEGER DEFAULT 0 CHECK (click_count >= 0),
  conversion_count INTEGER DEFAULT 0 CHECK (conversion_count >= 0),
  total_revenue DECIMAL(12,2) DEFAULT 0 CHECK (total_revenue >= 0),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (listing_id, agent_id)
);
CREATE INDEX idx_affiliate_links_agent ON public.affiliate_links(agent_id);
CREATE INDEX idx_affiliate_links_listing ON public.affiliate_links(listing_id);
CREATE INDEX idx_affiliate_links_code ON public.affiliate_links(code) WHERE is_active = TRUE;

CREATE TABLE public.affiliate_clicks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  affiliate_link_id UUID NOT NULL REFERENCES public.affiliate_links(id) ON DELETE CASCADE,
  visitor_id TEXT,
  ip_hash TEXT,
  user_agent TEXT,
  referer TEXT,
  clicked_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_affiliate_clicks_link ON public.affiliate_clicks(affiliate_link_id);
CREATE INDEX idx_affiliate_clicks_date ON public.affiliate_clicks(clicked_at);

CREATE TABLE public.affiliate_conversions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  affiliate_link_id UUID NOT NULL REFERENCES public.affiliate_links(id) ON DELETE SET NULL,
  order_id UUID NOT NULL UNIQUE,
  agent_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE SET NULL,
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  buyer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  order_amount DECIMAL(10,2) NOT NULL CHECK (order_amount > 0),
  client_discount DECIMAL(10,2) DEFAULT 0 CHECK (client_discount >= 0),
  agent_commission_gross DECIMAL(10,2) DEFAULT 0 CHECK (agent_commission_gross >= 0),
  platform_cut_on_agent DECIMAL(10,2) DEFAULT 0 CHECK (platform_cut_on_agent >= 0),
  agent_commission_net DECIMAL(10,2) DEFAULT 0 CHECK (agent_commission_net >= 0),
  platform_fee DECIMAL(10,2) DEFAULT 0 CHECK (platform_fee >= 0),
  seller_revenue DECIMAL(10,2) DEFAULT 0 CHECK (seller_revenue >= 0),
  agent_commission_rate DECIMAL(5,2),
  platform_cut_rate DECIMAL(5,2),
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'reversed', 'partial_refund')),
  confirmed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_conversions_agent ON public.affiliate_conversions(agent_id);
CREATE INDEX idx_conversions_order ON public.affiliate_conversions(order_id);

-- ============================================================================
-- 10. ORDERS (COMMANDES)
-- ============================================================================

CREATE TABLE public.orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_number TEXT UNIQUE NOT NULL DEFAULT ('ORD-' || UPPER(encode(gen_random_bytes(6), 'hex'))),
  buyer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  service_id UUID REFERENCES public.services(id) ON DELETE SET NULL,
  global_offer_id UUID REFERENCES public.global_offers(id) ON DELETE SET NULL,
  package_id UUID REFERENCES public.service_packages(id) ON DELETE SET NULL,
  affiliate_link_id UUID REFERENCES public.affiliate_links(id) ON DELETE SET NULL,

  order_type TEXT NOT NULL DEFAULT 'standard' CHECK (order_type IN ('standard', 'custom', 'quote_request', 'offer')),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN (
    'pending', 'payment_authorized', 'accepted', 'in_progress', 'delivered',
    'revision_requested', 'completed', 'disputed', 'cancelled', 'refunded'
  )),

  -- Montants
  subtotal DECIMAL(10,2) NOT NULL CHECK (subtotal >= 0),
  discount_amount DECIMAL(10,2) DEFAULT 0 CHECK (discount_amount >= 0),
  platform_fee DECIMAL(10,2) DEFAULT 0 CHECK (platform_fee >= 0),
  total_amount DECIMAL(10,2) NOT NULL CHECK (total_amount > 0),
  seller_revenue DECIMAL(10,2) CHECK (seller_revenue >= 0),

  -- Requirements & Delivery
  requirements_responses JSONB DEFAULT '[]'::jsonb,
  selected_extras JSONB DEFAULT '[]'::jsonb,
  brief TEXT,                    -- Description/brief du client
  seller_notes TEXT,             -- Notes du vendeur (pour commandes offer/custom)
  delivery_message TEXT,
  delivery_files JSONB DEFAULT '[]'::jsonb,
  revision_count INTEGER DEFAULT 0 CHECK (revision_count >= 0),
  max_revisions INTEGER DEFAULT 2 CHECK (max_revisions >= 0),
  
  -- Stripe
  stripe_payment_intent_id TEXT UNIQUE,
  stripe_checkout_session_id TEXT,
  stripe_payment_status TEXT DEFAULT 'unpaid' CHECK (stripe_payment_status IN ('unpaid', 'pending', 'authorized', 'captured', 'failed', 'refunded')),
  
  -- Refunds
  refund_status TEXT DEFAULT 'none' CHECK (refund_status IN ('none', 'partial', 'full')),
  refund_amount DECIMAL(10,2) DEFAULT 0 CHECK (refund_amount >= 0),
  
  -- Deadlines & Timestamps
  delivery_deadline TIMESTAMPTZ,
  acceptance_deadline TIMESTAMPTZ,
  payment_authorized_at TIMESTAMPTZ,
  captured_at TIMESTAMPTZ,
  accepted_at TIMESTAMPTZ,
  delivered_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ,
  refunded_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  CONSTRAINT no_self_purchase CHECK (buyer_id <> seller_id),
  -- Cohérence des montants: total ≈ subtotal - discount + platform_fee (tolérance 0.01 pour arrondis)
  CONSTRAINT amounts_coherence CHECK (
    ABS(total_amount - (subtotal - COALESCE(discount_amount, 0) + COALESCE(platform_fee, 0))) < 0.01
  )
);
CREATE INDEX idx_orders_buyer ON public.orders(buyer_id);
CREATE INDEX idx_orders_seller ON public.orders(seller_id);
CREATE INDEX idx_orders_status ON public.orders(status);
CREATE INDEX idx_orders_service ON public.orders(service_id);
CREATE INDEX idx_orders_affiliate ON public.orders(affiliate_link_id) WHERE affiliate_link_id IS NOT NULL;
CREATE INDEX idx_orders_stripe ON public.orders(stripe_payment_intent_id) WHERE stripe_payment_intent_id IS NOT NULL;

CREATE TABLE public.order_status_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  old_status TEXT,
  new_status TEXT NOT NULL,
  changed_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  reason TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_order_history_order ON public.order_status_history(order_id);

CREATE TABLE public.order_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  sender_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  attachments JSONB DEFAULT '[]'::jsonb,
  is_system BOOLEAN DEFAULT FALSE,
  is_read BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_order_messages_order ON public.order_messages(order_id);

CREATE TABLE public.disputes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL UNIQUE REFERENCES public.orders(id) ON DELETE CASCADE,
  opened_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  reason TEXT NOT NULL CHECK (reason IN ('not_delivered', 'not_as_described', 'quality_issue', 'communication', 'other')),
  description TEXT NOT NULL,
  evidence_urls JSONB DEFAULT '[]'::jsonb,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'under_review', 'resolved_buyer', 'resolved_seller', 'closed')),
  resolution TEXT,
  resolution_notes TEXT,
  resolved_by UUID REFERENCES public.profiles(id),
  resolved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_disputes_order ON public.disputes(order_id);
CREATE INDEX idx_disputes_status ON public.disputes(status) WHERE status = 'open';

-- ============================================================================
-- 11. REVIEWS
-- ============================================================================

CREATE TABLE public.reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL UNIQUE REFERENCES public.orders(id) ON DELETE CASCADE,
  service_id UUID REFERENCES public.services(id) ON DELETE CASCADE,
  reviewer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  reviewed_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment TEXT CHECK (LENGTH(comment) <= 2000),
  response TEXT CHECK (LENGTH(response) <= 1000),
  response_at TIMESTAMPTZ,
  is_visible BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT review_parties_different CHECK (reviewer_id <> reviewed_id)
);
CREATE INDEX idx_reviews_service ON public.reviews(service_id);
CREATE INDEX idx_reviews_reviewed ON public.reviews(reviewed_id);

-- Trigger pour mettre à jour les stats de rating
CREATE OR REPLACE FUNCTION public.update_service_rating_on_review()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.service_id IS NOT NULL THEN
    UPDATE public.services SET
      rating_average = (SELECT COALESCE(AVG(rating), 0) FROM public.reviews WHERE service_id = NEW.service_id AND is_visible = TRUE),
      rating_count = (SELECT COUNT(*) FROM public.reviews WHERE service_id = NEW.service_id AND is_visible = TRUE)
    WHERE id = NEW.service_id;
  END IF;
  
  UPDATE public.profiles SET
    average_rating = (SELECT COALESCE(AVG(rating), 0) FROM public.reviews WHERE reviewed_id = NEW.reviewed_id AND is_visible = TRUE),
    total_reviews = (SELECT COUNT(*) FROM public.reviews WHERE reviewed_id = NEW.reviewed_id AND is_visible = TRUE)
  WHERE id = NEW.reviewed_id;
  
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_update_rating_on_review 
AFTER INSERT OR UPDATE ON public.reviews 
FOR EACH ROW EXECUTE FUNCTION public.update_service_rating_on_review();

-- ============================================================================
-- 12. FINANCE & LEDGER
-- ============================================================================

CREATE TABLE public.ledger_entries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_group_id UUID NOT NULL,
  order_id UUID REFERENCES public.orders(id) ON DELETE SET NULL,
  account_type TEXT NOT NULL CHECK (account_type IN ('escrow', 'seller_wallet', 'agent_wallet', 'platform_revenue', 'refund_source')),
  account_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  entry_type TEXT NOT NULL CHECK (entry_type IN ('debit', 'credit')),
  amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  currency TEXT DEFAULT 'EUR',
  description TEXT,
  metadata JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_ledger_group ON public.ledger_entries(transaction_group_id);
CREATE INDEX idx_ledger_order ON public.ledger_entries(order_id);
CREATE INDEX idx_ledger_account ON public.ledger_entries(account_type, account_id);

-- Immutabilité du ledger
CREATE OR REPLACE FUNCTION public.prevent_ledger_modification()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'LEDGER_ENTRIES_ARE_IMMUTABLE';
END;
$$;

CREATE TRIGGER trg_ledger_immutable 
BEFORE UPDATE OR DELETE ON public.ledger_entries 
FOR EACH ROW EXECUTE FUNCTION public.prevent_ledger_modification();

CREATE TABLE public.seller_revenues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  order_id UUID UNIQUE REFERENCES public.orders(id) ON DELETE RESTRICT,
  amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'available', 'withdrawn', 'reversed')),
  locked BOOLEAN DEFAULT FALSE,
  available_at TIMESTAMPTZ,
  withdrawn_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_seller_revenues_seller ON public.seller_revenues(seller_id);
CREATE INDEX idx_seller_revenues_status ON public.seller_revenues(status);

CREATE TABLE public.agent_revenues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  order_id UUID UNIQUE REFERENCES public.orders(id) ON DELETE RESTRICT,
  affiliate_link_id UUID REFERENCES public.affiliate_links(id) ON DELETE SET NULL,
  amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'available', 'withdrawn', 'reversed')),
  locked BOOLEAN DEFAULT FALSE,
  available_at TIMESTAMPTZ,
  withdrawn_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_agent_revenues_agent ON public.agent_revenues(agent_id);
CREATE INDEX idx_agent_revenues_status ON public.agent_revenues(status);

CREATE TABLE public.platform_revenues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID UNIQUE REFERENCES public.orders(id) ON DELETE SET NULL,
  amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  source TEXT NOT NULL CHECK (source IN ('platform_fee', 'agent_cut', 'other')),
  locked BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_platform_revenues_order ON public.platform_revenues(order_id);

CREATE TABLE public.withdrawals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  amount DECIMAL(10,2) NOT NULL CHECK (amount >= 5),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'cancelled')),
  stripe_transfer_id TEXT,
  stripe_payout_id TEXT,
  failure_reason TEXT,
  processed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_withdrawals_user ON public.withdrawals(user_id);
CREATE INDEX idx_withdrawals_status ON public.withdrawals(status);

-- Table pour allocation partielle des retraits (évite de verrouiller tout le solde)
CREATE TABLE public.withdrawal_allocations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  withdrawal_id UUID NOT NULL REFERENCES public.withdrawals(id) ON DELETE CASCADE,
  revenue_type TEXT NOT NULL CHECK (revenue_type IN ('seller', 'agent')),
  revenue_id UUID NOT NULL,  -- ID de seller_revenues ou agent_revenues
  allocated_amount DECIMAL(10,2) NOT NULL CHECK (allocated_amount > 0),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (withdrawal_id, revenue_type, revenue_id)
);
CREATE INDEX idx_withdrawal_allocations_withdrawal ON public.withdrawal_allocations(withdrawal_id);
CREATE INDEX idx_withdrawal_allocations_revenue ON public.withdrawal_allocations(revenue_type, revenue_id);

CREATE TABLE public.commission_runs (
  order_id UUID PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
  started_at TIMESTAMPTZ DEFAULT NOW(),
  completed BOOLEAN DEFAULT FALSE,
  completed_at TIMESTAMPTZ,
  result JSONB
);

CREATE TABLE public.reverse_runs (
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  refund_id TEXT NOT NULL,
  started_at TIMESTAMPTZ DEFAULT NOW(),
  completed BOOLEAN DEFAULT FALSE,
  completed_at TIMESTAMPTZ,
  amount DECIMAL(10,2),
  PRIMARY KEY (order_id, refund_id)
);

-- ============================================================================
-- 13. BANK ACCOUNTS
-- ============================================================================

CREATE TABLE public.bank_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  account_holder TEXT NOT NULL CHECK (LENGTH(account_holder) >= 2),
  iban TEXT NOT NULL,
  bic TEXT,
  bank_name TEXT,
  is_default BOOLEAN DEFAULT FALSE,
  is_verified BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_bank_accounts_user ON public.bank_accounts(user_id);

-- ============================================================================
-- 14. MESSAGING
-- ============================================================================

CREATE TABLE public.conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Colonnes générées pour ordre canonique (évite doublons A,B et B,A)
  participant_1_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  participant_2_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  -- Colonnes canoniques pour unicité (participant_1 < participant_2)
  canonical_p1 UUID GENERATED ALWAYS AS (LEAST(participant_1_id, participant_2_id)) STORED,
  canonical_p2 UUID GENERATED ALWAYS AS (GREATEST(participant_1_id, participant_2_id)) STORED,
  last_message_at TIMESTAMPTZ DEFAULT NOW(),
  participant_1_archived BOOLEAN DEFAULT FALSE,
  participant_2_archived BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT conversation_different CHECK (participant_1_id <> participant_2_id),
  UNIQUE (canonical_p1, canonical_p2)  -- Unicité sur colonnes canoniques
);
CREATE INDEX idx_conversations_p1 ON public.conversations(participant_1_id);
CREATE INDEX idx_conversations_p2 ON public.conversations(participant_2_id);
CREATE INDEX idx_conversations_canonical ON public.conversations(canonical_p1, canonical_p2);

CREATE TABLE public.messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  sender_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  attachments JSONB DEFAULT '[]'::jsonb,
  is_read BOOLEAN DEFAULT FALSE,
  read_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_messages_conversation ON public.messages(conversation_id);
CREATE INDEX idx_messages_unread ON public.messages(conversation_id, is_read) WHERE is_read = FALSE;
CREATE INDEX idx_messages_sender_time ON public.messages(sender_id, created_at DESC);
CREATE INDEX idx_messages_conversation_time ON public.messages(conversation_id, created_at DESC);

-- ============================================================================
-- 15. NOTIFICATIONS
-- ============================================================================

CREATE TABLE public.notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  type TEXT NOT NULL,
  title TEXT NOT NULL,
  content TEXT,
  data JSONB,
  is_read BOOLEAN DEFAULT FALSE,
  read_at TIMESTAMPTZ,
  action_url TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_notifications_user ON public.notifications(user_id);
CREATE INDEX idx_notifications_unread ON public.notifications(user_id, is_read) WHERE is_read = FALSE;

-- ============================================================================
-- 16. AUDIT & LOGS
-- ============================================================================

CREATE TABLE public.audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  event_name TEXT NOT NULL,
  table_name TEXT,
  record_id UUID,
  old_values JSONB,
  new_values JSONB,
  ip_address TEXT,
  user_agent TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_audit_logs_user ON public.audit_logs(user_id);
CREATE INDEX idx_audit_logs_event ON public.audit_logs(event_name);
CREATE INDEX idx_audit_logs_table ON public.audit_logs(table_name, record_id);

-- Immutabilité des audit logs
CREATE OR REPLACE FUNCTION public.prevent_audit_modification()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'AUDIT_LOGS_ARE_IMMUTABLE';
END;
$$;

CREATE TRIGGER trg_audit_immutable 
BEFORE UPDATE OR DELETE ON public.audit_logs 
FOR EACH ROW EXECUTE FUNCTION public.prevent_audit_modification();

CREATE OR REPLACE FUNCTION public.create_audit_log(
  p_event_name TEXT, 
  p_table_name TEXT DEFAULT NULL, 
  p_record_id UUID DEFAULT NULL, 
  p_old_values JSONB DEFAULT NULL, 
  p_new_values JSONB DEFAULT NULL
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO public.audit_logs (user_id, event_name, table_name, record_id, old_values, new_values)
  VALUES (auth.uid(), p_event_name, p_table_name, p_record_id, p_old_values, p_new_values)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE TABLE public.system_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  level TEXT NOT NULL CHECK (level IN ('debug', 'info', 'warn', 'error', 'fatal')),
  event_type TEXT NOT NULL,
  message TEXT,
  details JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_system_logs_level ON public.system_logs(level);
CREATE INDEX idx_system_logs_date ON public.system_logs(created_at);

CREATE TABLE public.payment_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stripe_event_id TEXT,
  stripe_payment_intent_id TEXT,
  event_type TEXT NOT NULL,
  event_data JSONB,
  order_id UUID REFERENCES public.orders(id) ON DELETE SET NULL,
  processed BOOLEAN DEFAULT FALSE,
  error TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_payment_logs_stripe ON public.payment_logs(stripe_event_id);
CREATE INDEX idx_payment_logs_order ON public.payment_logs(order_id);

CREATE TABLE public.contact_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  name TEXT NOT NULL,
  email TEXT NOT NULL,
  subject TEXT,
  message TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'read', 'replied', 'closed')),
  assigned_to UUID REFERENCES public.profiles(id),
  resolved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.job_queue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  job_type TEXT NOT NULL,
  payload JSONB NOT NULL,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
  priority INTEGER DEFAULT 0,
  attempts INTEGER DEFAULT 0,
  max_attempts INTEGER DEFAULT 3,
  last_error TEXT,
  run_at TIMESTAMPTZ DEFAULT NOW(),
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_job_queue_status ON public.job_queue(status, run_at) WHERE status = 'pending';

-- ============================================================================
-- 17. BUSINESS FUNCTIONS
-- ============================================================================

-- Helper: Enregistrement ledger
CREATE OR REPLACE FUNCTION public.record_ledger_entry(
  p_transaction_group_id UUID, 
  p_order_id UUID, 
  p_account_type TEXT, 
  p_account_id UUID, 
  p_entry_type TEXT, 
  p_amount DECIMAL, 
  p_description TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN NULL;
  END IF;
  
  INSERT INTO public.ledger_entries (transaction_group_id, order_id, account_type, account_id, entry_type, amount, description)
  VALUES (p_transaction_group_id, p_order_id, p_account_type, p_account_id, p_entry_type, p_amount, p_description)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Résolution du code créateur (Anti-fraude niveau 1)
CREATE OR REPLACE FUNCTION public.resolve_creator_code(p_code TEXT, p_service_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_creator public.creator_codes%ROWTYPE;
  v_listing public.affiliate_listings%ROWTYPE;
  v_affiliate_link public.affiliate_links%ROWTYPE;
  v_agent_id UUID;
  v_seller_id UUID;
  v_user_id UUID := auth.uid();
  v_rate_ok BOOLEAN;
  v_has_agent_role BOOLEAN;
BEGIN
  -- Validation des paramètres
  IF p_code IS NULL OR p_service_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_PARAMETERS');
  END IF;

  -- Rate limiting
  IF v_user_id IS NOT NULL THEN
    SELECT public.check_rate_limit(v_user_id::TEXT, 'resolve_creator_code', 30, 60) INTO v_rate_ok;
    IF NOT v_rate_ok THEN
      RETURN jsonb_build_object('success', false, 'error', 'RATE_LIMIT_EXCEEDED');
    END IF;
  END IF;

  -- Trouver le créateur
  SELECT * INTO v_creator FROM public.creator_codes WHERE code = UPPER(TRIM(p_code)) AND is_active = TRUE;
  IF v_creator.user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_CREATOR_CODE');
  END IF;
  v_agent_id := v_creator.user_id;

  -- Vérifier que l'agent a le rôle "agent" actif
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = v_agent_id AND role = 'agent' AND status = 'active'
  ) INTO v_has_agent_role;

  IF NOT v_has_agent_role THEN
    RETURN jsonb_build_object('success', false, 'error', 'AGENT_ROLE_NOT_ACTIVE');
  END IF;

  -- Anti-fraude: Auto-référencement interdit
  IF v_user_id IS NOT NULL AND v_agent_id = v_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'SELF_REFERRAL_FORBIDDEN');
  END IF;

  -- Trouver le listing affilié
  SELECT l.* INTO v_listing
  FROM public.affiliate_listings l
  JOIN public.services s ON s.id = l.service_id
  WHERE l.service_id = p_service_id
    AND l.is_active = TRUE
    AND s.is_affiliable = TRUE
    AND s.status = 'active'
  LIMIT 1;

  IF v_listing.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'TARGET_NOT_AFFILIABLE');
  END IF;

  -- Anti-fraude: Agent = Seller interdit
  SELECT seller_id INTO v_seller_id FROM public.services WHERE id = p_service_id;
  IF v_agent_id = v_seller_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'AGENT_IS_SELLER');
  END IF;

  -- Obtenir ou créer le lien affilié
  SELECT * INTO v_affiliate_link FROM public.affiliate_links WHERE listing_id = v_listing.id AND agent_id = v_agent_id LIMIT 1;

  IF v_affiliate_link.id IS NULL THEN
    INSERT INTO public.affiliate_links(code, url_slug, listing_id, agent_id)
    VALUES (encode(gen_random_bytes(6), 'hex'), encode(gen_random_bytes(6), 'hex'), v_listing.id, v_agent_id)
    RETURNING * INTO v_affiliate_link;
  END IF;

  -- Incrémenter le compteur d'utilisation
  UPDATE public.creator_codes SET total_uses = total_uses + 1, updated_at = NOW() WHERE user_id = v_agent_id;

  RETURN jsonb_build_object(
    'success', true,
    'affiliate_link_id', v_affiliate_link.id,
    'agent_id', v_agent_id,
    'discount_rate', v_listing.client_discount_rate,
    'code', v_affiliate_link.code
  );
END;
$$;

-- Validation anti-fraude pour commande (niveau 2)
CREATE OR REPLACE FUNCTION public.validate_order_affiliate(p_buyer_id UUID, p_affiliate_link_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_link public.affiliate_links%ROWTYPE;
  v_listing public.affiliate_listings%ROWTYPE;
BEGIN
  IF p_affiliate_link_id IS NULL THEN
    RETURN jsonb_build_object('valid', true, 'has_affiliate', false);
  END IF;
  
  SELECT * INTO v_link FROM public.affiliate_links WHERE id = p_affiliate_link_id AND is_active = TRUE;
  IF v_link.id IS NULL THEN
    RETURN jsonb_build_object('valid', false, 'error', 'INVALID_AFFILIATE_LINK');
  END IF;
  
  -- Anti-fraude: Buyer = Agent interdit
  IF v_link.agent_id = p_buyer_id THEN
    RETURN jsonb_build_object('valid', false, 'error', 'BUYER_IS_AGENT');
  END IF;
  
  SELECT * INTO v_listing FROM public.affiliate_listings WHERE id = v_link.listing_id AND is_active = TRUE;
  IF v_listing.id IS NULL THEN
    RETURN jsonb_build_object('valid', false, 'error', 'LISTING_INACTIVE');
  END IF;
  
  -- Anti-fraude: Buyer = Seller interdit
  IF v_listing.seller_id = p_buyer_id THEN
    RETURN jsonb_build_object('valid', false, 'error', 'BUYER_IS_SELLER');
  END IF;
  
  RETURN jsonb_build_object(
    'valid', true, 
    'has_affiliate', true,
    'agent_id', v_link.agent_id,
    'discount_rate', v_listing.client_discount_rate,
    'commission_rate', v_listing.agent_commission_rate
  );
END;
$$;

-- Distribution des commissions (Anti-fraude niveau 3)
CREATE OR REPLACE FUNCTION public.distribute_commissions(p_order_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_link public.affiliate_links%ROWTYPE;
  v_listing public.affiliate_listings%ROWTYPE;
  v_platform_amount DECIMAL;
  v_seller_amount DECIMAL;
  v_agent_gross DECIMAL := 0;
  v_agent_net DECIMAL := 0;
  v_platform_from_agent DECIMAL := 0;
  v_commission_rate DECIMAL := 0;
  v_platform_fee_rate DECIMAL := 5;
  v_platform_cut_on_agent_rate DECIMAL := 0;
  v_transaction_group_id UUID;
  v_is_fraud BOOLEAN := FALSE;
BEGIN
  -- Idempotence: vérifier si déjà traité
  INSERT INTO public.commission_runs(order_id, started_at) VALUES (p_order_id, NOW()) ON CONFLICT (order_id) DO NOTHING;
  IF EXISTS (SELECT 1 FROM public.commission_runs WHERE order_id = p_order_id AND completed = TRUE) THEN 
    RETURN jsonb_build_object('success', true, 'message', 'Already distributed'); 
  END IF;
  
  -- Récupérer la commande
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF v_order.id IS NULL OR v_order.status NOT IN ('completed') THEN 
    RAISE EXCEPTION 'INVALID_ORDER_STATUS'; 
  END IF;

  -- Traitement affiliation si présente
  IF v_order.affiliate_link_id IS NOT NULL THEN
    SELECT * INTO v_link FROM public.affiliate_links WHERE id = v_order.affiliate_link_id;
    SELECT * INTO v_listing FROM public.affiliate_listings WHERE id = v_link.listing_id;
    
    -- Anti-fraude niveau 3: détection agent = buyer
    IF v_link.agent_id = v_order.buyer_id THEN 
      v_is_fraud := TRUE; 
    END IF;
    
    IF NOT v_is_fraud AND v_listing.is_active THEN
      v_commission_rate := v_listing.agent_commission_rate;
      v_platform_fee_rate := v_listing.platform_fee_rate;
      v_platform_cut_on_agent_rate := v_listing.platform_cut_on_agent_rate;
    END IF;
  END IF;

  -- Calculs
  v_platform_amount := ROUND(v_order.total_amount * v_platform_fee_rate / 100, 2);
  v_agent_gross := ROUND(v_order.total_amount * v_commission_rate / 100, 2);
  v_platform_from_agent := ROUND(v_agent_gross * v_platform_cut_on_agent_rate / 100, 2);
  v_agent_net := GREATEST(v_agent_gross - v_platform_from_agent, 0);
  v_seller_amount := v_order.total_amount - v_agent_gross - v_platform_amount;
  v_platform_amount := v_platform_amount + v_platform_from_agent;
  IF v_seller_amount < 0 THEN v_seller_amount := 0; END IF;

  -- Écritures comptables
  v_transaction_group_id := gen_random_uuid();
  PERFORM public.record_ledger_entry(v_transaction_group_id, p_order_id, 'escrow', NULL, 'debit', v_order.total_amount, 'Release from escrow');
  PERFORM public.record_ledger_entry(v_transaction_group_id, p_order_id, 'seller_wallet', v_order.seller_id, 'credit', v_seller_amount, 'Seller revenue');
  PERFORM public.record_ledger_entry(v_transaction_group_id, p_order_id, 'platform_revenue', NULL, 'credit', v_platform_amount, 'Platform fee');
  
  -- Commission agent (si pas de fraude)
  IF v_agent_net > 0 AND NOT v_is_fraud AND v_link.id IS NOT NULL THEN
    PERFORM public.record_ledger_entry(v_transaction_group_id, p_order_id, 'agent_wallet', v_link.agent_id, 'credit', v_agent_net, 'Agent commission');
    
    INSERT INTO public.agent_revenues(agent_id, order_id, affiliate_link_id, amount, status, available_at) 
    VALUES (v_link.agent_id, p_order_id, v_order.affiliate_link_id, v_agent_net, 'pending', NOW() + INTERVAL '72 hours') 
    ON CONFLICT (order_id) DO NOTHING;
    
    INSERT INTO public.affiliate_conversions(affiliate_link_id, order_id, agent_id, seller_id, buyer_id, order_amount, agent_commission_gross, platform_cut_on_agent, agent_commission_net, platform_fee, seller_revenue, agent_commission_rate, platform_cut_rate, status, confirmed_at)
    VALUES (v_order.affiliate_link_id, p_order_id, v_link.agent_id, v_order.seller_id, v_order.buyer_id, v_order.total_amount, v_agent_gross, v_platform_from_agent, v_agent_net, v_platform_amount, v_seller_amount, v_commission_rate, v_platform_cut_on_agent_rate, 'confirmed', NOW()) 
    ON CONFLICT (order_id) DO NOTHING;
    
    UPDATE public.affiliate_links SET conversion_count = conversion_count + 1, total_revenue = total_revenue + v_order.total_amount WHERE id = v_order.affiliate_link_id;
    UPDATE public.creator_codes SET total_revenue = total_revenue + v_order.total_amount WHERE user_id = v_link.agent_id;
  END IF;

  -- Revenu vendeur
  INSERT INTO public.seller_revenues(seller_id, order_id, amount, status, available_at) 
  VALUES (v_order.seller_id, p_order_id, v_seller_amount, 'pending', NOW() + INTERVAL '72 hours') 
  ON CONFLICT (order_id) DO NOTHING;
  
  -- Revenu plateforme
  INSERT INTO public.platform_revenues(order_id, amount, source) 
  VALUES (p_order_id, v_platform_amount, 'platform_fee') 
  ON CONFLICT (order_id) DO NOTHING;
  
  -- Mise à jour commande
  UPDATE public.orders SET seller_revenue = v_seller_amount, platform_fee = v_platform_amount WHERE id = p_order_id;
  
  -- Marquer comme complété
  UPDATE public.commission_runs SET completed = TRUE, completed_at = NOW(), 
    result = jsonb_build_object('seller', v_seller_amount, 'platform', v_platform_amount, 'agent', v_agent_net, 'fraud_detected', v_is_fraud) 
  WHERE order_id = p_order_id;
  
  RETURN jsonb_build_object('success', true, 'seller', v_seller_amount, 'platform', v_platform_amount, 'agent', v_agent_net);
END;
$$;

-- Reverse commissions (remboursement) - Supporte remboursements partiels avec pro-rata
CREATE OR REPLACE FUNCTION public.reverse_commissions(p_order_id UUID, p_refund_id TEXT, p_amount DECIMAL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_seller_rev public.seller_revenues%ROWTYPE;
  v_agent_rev public.agent_revenues%ROWTYPE;
  v_platform_rev public.platform_revenues%ROWTYPE;
  v_group UUID;
  v_refund_status TEXT := 'full';
  v_refund_ratio DECIMAL;
  v_seller_refund DECIMAL := 0;
  v_agent_refund DECIMAL := 0;
  v_platform_refund DECIMAL := 0;
  v_total_previous_refunds DECIMAL := 0;
  v_remaining_amount DECIMAL;
BEGIN
  -- Validation du montant
  IF p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_REFUND_AMOUNT');
  END IF;

  -- Idempotence
  IF EXISTS(SELECT 1 FROM public.reverse_runs WHERE order_id = p_order_id AND refund_id = p_refund_id) THEN
    RETURN jsonb_build_object('success', true, 'message', 'Already reversed');
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF v_order.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
  END IF;

  -- Calculer les remboursements précédents pour cette commande
  SELECT COALESCE(SUM(amount), 0) INTO v_total_previous_refunds
  FROM public.reverse_runs
  WHERE order_id = p_order_id AND completed = TRUE;

  -- Vérifier qu'on ne rembourse pas plus que le montant restant
  v_remaining_amount := v_order.total_amount - v_total_previous_refunds;
  IF p_amount > v_remaining_amount THEN
    RETURN jsonb_build_object('success', false, 'error', 'REFUND_EXCEEDS_REMAINING',
      'remaining', v_remaining_amount, 'requested', p_amount);
  END IF;

  -- Déterminer si remboursement partiel ou total
  IF (v_total_previous_refunds + p_amount) < v_order.total_amount THEN
    v_refund_status := 'partial';
  END IF;

  -- Calculer le ratio de remboursement
  -- IMPORTANT: basé sur le montant RESTANT, pas le total original
  -- Cela évite les erreurs d'arrondis cumulés lors de remboursements multiples
  IF v_remaining_amount > 0 THEN
    v_refund_ratio := p_amount / v_remaining_amount;
  ELSE
    v_refund_ratio := 0;
  END IF;

  INSERT INTO public.reverse_runs(order_id, refund_id, amount) VALUES (p_order_id, p_refund_id, p_amount);
  v_group := gen_random_uuid();

  -- Reverser le revenu vendeur (pro-rata basé sur le remaining)
  SELECT * INTO v_seller_rev FROM public.seller_revenues WHERE order_id = p_order_id;
  IF v_seller_rev.id IS NOT NULL AND v_seller_rev.amount > 0 THEN
    -- Si remboursement complet ou le ratio est 1 (tout le restant), prendre tout le montant restant
    IF v_refund_status = 'full' OR v_refund_ratio >= 1 THEN
      v_seller_refund := v_seller_rev.amount;
    ELSE
      v_seller_refund := ROUND(v_seller_rev.amount * v_refund_ratio, 2);
    END IF;

    IF v_refund_status = 'full' THEN
      -- Remboursement complet: marquer comme reversed
      UPDATE public.seller_revenues SET status = 'reversed', locked = TRUE, updated_at = NOW() WHERE id = v_seller_rev.id;
    ELSE
      -- Remboursement partiel: réduire le montant disponible
      UPDATE public.seller_revenues SET
        amount = amount - v_seller_refund,
        updated_at = NOW()
      WHERE id = v_seller_rev.id;
    END IF;

    IF v_seller_refund > 0 THEN
      PERFORM public.record_ledger_entry(v_group, p_order_id, 'seller_wallet', v_seller_rev.seller_id, 'debit', v_seller_refund,
        CASE WHEN v_refund_status = 'partial' THEN 'Partial refund reversal' ELSE 'Refund reversal' END);
    END IF;
  END IF;

  -- Reverser le revenu agent (pro-rata basé sur le remaining)
  SELECT * INTO v_agent_rev FROM public.agent_revenues WHERE order_id = p_order_id;
  IF v_agent_rev.id IS NOT NULL AND v_agent_rev.amount > 0 THEN
    -- Même logique: si complet ou ratio >= 1, prendre tout
    IF v_refund_status = 'full' OR v_refund_ratio >= 1 THEN
      v_agent_refund := v_agent_rev.amount;
    ELSE
      v_agent_refund := ROUND(v_agent_rev.amount * v_refund_ratio, 2);
    END IF;

    IF v_refund_status = 'full' THEN
      UPDATE public.agent_revenues SET status = 'reversed', locked = TRUE, updated_at = NOW() WHERE id = v_agent_rev.id;
      -- Marquer la conversion comme reversed
      UPDATE public.affiliate_conversions SET status = 'reversed' WHERE order_id = p_order_id;
    ELSE
      UPDATE public.agent_revenues SET
        amount = amount - v_agent_refund,
        updated_at = NOW()
      WHERE id = v_agent_rev.id;
      -- Mettre à jour la conversion avec le montant réduit
      UPDATE public.affiliate_conversions SET
        agent_commission_net = agent_commission_net - v_agent_refund,
        status = 'partial_refund'
      WHERE order_id = p_order_id;
    END IF;

    IF v_agent_refund > 0 THEN
      PERFORM public.record_ledger_entry(v_group, p_order_id, 'agent_wallet', v_agent_rev.agent_id, 'debit', v_agent_refund,
        CASE WHEN v_refund_status = 'partial' THEN 'Partial refund reversal' ELSE 'Refund reversal' END);
    END IF;
  END IF;

  -- Reverser le revenu plateforme (pro-rata basé sur le remaining)
  SELECT * INTO v_platform_rev FROM public.platform_revenues WHERE order_id = p_order_id;
  IF v_platform_rev.id IS NOT NULL AND v_platform_rev.amount > 0 THEN
    -- Même logique
    IF v_refund_status = 'full' OR v_refund_ratio >= 1 THEN
      v_platform_refund := v_platform_rev.amount;
    ELSE
      v_platform_refund := ROUND(v_platform_rev.amount * v_refund_ratio, 2);
    END IF;

    IF v_refund_status = 'full' THEN
      UPDATE public.platform_revenues SET locked = TRUE WHERE id = v_platform_rev.id;
    ELSE
      UPDATE public.platform_revenues SET
        amount = amount - v_platform_refund
      WHERE id = v_platform_rev.id;
    END IF;

    IF v_platform_refund > 0 THEN
      PERFORM public.record_ledger_entry(v_group, p_order_id, 'platform_revenue', NULL, 'debit', v_platform_refund,
        CASE WHEN v_refund_status = 'partial' THEN 'Partial refund reversal' ELSE 'Refund reversal' END);
    END IF;
  END IF;

  -- Mettre à jour la commande
  UPDATE public.orders SET
    refund_status = v_refund_status,
    refund_amount = COALESCE(refund_amount, 0) + p_amount,
    refunded_at = NOW(),
    status = CASE WHEN v_refund_status = 'full' THEN 'refunded' ELSE status END
  WHERE id = p_order_id;

  -- Marquer comme complété
  UPDATE public.reverse_runs SET completed = TRUE, completed_at = NOW() WHERE order_id = p_order_id AND refund_id = p_refund_id;

  RETURN jsonb_build_object(
    'success', true,
    'refund_status', v_refund_status,
    'seller_refunded', v_seller_refund,
    'agent_refunded', v_agent_refund,
    'platform_refunded', v_platform_refund,
    'total_refunded', v_total_previous_refunds + p_amount,
    'remaining', v_order.total_amount - v_total_previous_refunds - p_amount
  );
END;
$$;

-- Créer une commande depuis une candidature acceptée (workflow offer)
-- Appelée par le commerçant pour transformer une candidature en commande
CREATE OR REPLACE FUNCTION public.create_order_from_application(
  p_application_id UUID,
  p_amount DECIMAL,
  p_brief TEXT DEFAULT NULL,
  p_delivery_days INTEGER DEFAULT 7
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_application public.global_offer_applications%ROWTYPE;
  v_offer public.global_offers%ROWTYPE;
  v_user_id UUID := auth.uid();
  v_order_id UUID;
  v_order_number TEXT;
BEGIN
  -- Récupérer l'application
  SELECT * INTO v_application FROM public.global_offer_applications WHERE id = p_application_id;
  IF v_application.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'APPLICATION_NOT_FOUND');
  END IF;

  -- Récupérer l'offre
  SELECT * INTO v_offer FROM public.global_offers WHERE id = v_application.offer_id;
  IF v_offer.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'OFFER_NOT_FOUND');
  END IF;

  -- Vérifier que l'utilisateur est l'auteur de l'offre (le merchant)
  IF v_offer.author_id != v_user_id AND NOT public.is_admin() AND NOT public.is_service_role() THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED');
  END IF;

  -- Vérifier que l'offre est ouverte
  IF v_offer.status NOT IN ('open', 'in_progress') THEN
    RETURN jsonb_build_object('success', false, 'error', 'OFFER_NOT_OPEN');
  END IF;

  -- Vérifier que l'application n'est pas déjà sélectionnée
  IF v_application.is_selected THEN
    RETURN jsonb_build_object('success', false, 'error', 'APPLICATION_ALREADY_SELECTED');
  END IF;

  -- Vérifier le montant
  IF p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_AMOUNT');
  END IF;

  -- Créer la commande (order_number auto-généré via DEFAULT)
  INSERT INTO public.orders (
    buyer_id,
    seller_id,
    global_offer_id,
    order_type,
    status,
    subtotal,
    total_amount,
    brief,
    delivery_deadline,
    acceptance_deadline
  ) VALUES (
    v_offer.author_id,           -- Le merchant est l'acheteur
    v_application.applicant_id,  -- Le candidat est le vendeur
    v_offer.id,
    'offer',
    'pending',                   -- En attente d'acceptation par le vendeur
    p_amount,
    p_amount,
    COALESCE(p_brief, v_offer.title || ' - ' || v_offer.description),
    NOW() + (p_delivery_days || ' days')::INTERVAL,
    NOW() + INTERVAL '48 hours'  -- 48h pour accepter
  ) RETURNING id, order_number INTO v_order_id, v_order_number;

  -- Marquer l'application comme sélectionnée
  UPDATE public.global_offer_applications SET
    is_selected = TRUE,
    selected_at = NOW(),
    status = 'accepted',
    updated_at = NOW()
  WHERE id = p_application_id;

  -- Mettre à jour l'offre
  UPDATE public.global_offers SET
    selected_application_id = p_application_id,
    resulting_order_id = v_order_id,
    status = 'in_progress',
    updated_at = NOW()
  WHERE id = v_offer.id;

  -- Logger dans l'historique
  INSERT INTO public.order_status_history (order_id, old_status, new_status, changed_by, reason)
  VALUES (v_order_id, NULL, 'pending', v_user_id, 'Order created from offer application');

  RETURN jsonb_build_object(
    'success', true,
    'order_id', v_order_id,
    'order_number', v_order_number,
    'seller_id', v_application.applicant_id,
    'buyer_id', v_offer.author_id,
    'amount', p_amount
  );
END;
$$;

-- Fonction pour qu'un candidat remplisse les snapshots lors de sa candidature
CREATE OR REPLACE FUNCTION public.apply_to_offer(
  p_offer_id UUID,
  p_cover_letter TEXT DEFAULT NULL,
  p_proposed_price DECIMAL DEFAULT NULL,
  p_proposed_delivery_days INTEGER DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_offer public.global_offers%ROWTYPE;
  v_profile_snapshot JSONB;
  v_portfolio_snapshot JSONB;
  v_services_snapshot JSONB;
  v_application_id UUID;
BEGIN
  -- Vérifier que l'utilisateur est connecté
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED');
  END IF;

  -- Récupérer l'offre
  SELECT * INTO v_offer FROM public.global_offers WHERE id = p_offer_id;
  IF v_offer.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'OFFER_NOT_FOUND');
  END IF;

  -- Vérifier que l'offre est ouverte
  IF v_offer.status != 'open' THEN
    RETURN jsonb_build_object('success', false, 'error', 'OFFER_NOT_OPEN');
  END IF;

  -- Vérifier qu'on n'a pas déjà postulé
  IF EXISTS (SELECT 1 FROM public.global_offer_applications WHERE offer_id = p_offer_id AND applicant_id = v_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'ALREADY_APPLIED');
  END IF;

  -- Vérifier KYC + Stripe (déjà vérifié par RLS, mais double-check)
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = v_user_id AND kyc_status = 'verified' AND stripe_onboarding_completed = TRUE
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'KYC_OR_STRIPE_NOT_VERIFIED');
  END IF;

  -- Vérifier que l'utilisateur a un rôle correspondant aux target_roles de l'offre
  IF v_offer.target_roles IS NOT NULL AND array_length(v_offer.target_roles, 1) > 0 THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.user_roles ur
      WHERE ur.user_id = v_user_id
        AND ur.status = 'active'
        AND ur.role = ANY(v_offer.target_roles)
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'ROLE_NOT_MATCHING',
        'required_roles', v_offer.target_roles);
    END IF;
  END IF;

  -- Créer le snapshot du profil (WHITELIST: colonnes publiques uniquement, pas de row_to_json(*))
  SELECT jsonb_build_object(
    'username', p.username,
    'display_name', p.display_name,
    'bio', p.bio,
    'avatar_url', p.avatar_url,
    'city', p.city,
    'country', p.country,
    'is_verified', p.is_verified,
    'average_rating', p.average_rating,
    'total_reviews', p.total_reviews,
    'completed_orders_count', p.completed_orders_count,
    -- Freelance profile (colonnes publiques whitelistées)
    'freelance', (SELECT jsonb_build_object(
      'professional_title', fp.professional_title,
      'tagline', fp.tagline,
      'skills', fp.skills,
      'experience_years', fp.experience_years,
      'hourly_rate', fp.hourly_rate,
      'availability_status', fp.availability_status
    ) FROM public.freelance_profiles fp WHERE fp.user_id = v_user_id),
    -- Influencer profile (colonnes publiques whitelistées)
    'influencer', (SELECT jsonb_build_object(
      'niche', ip.niche,
      'content_types', ip.content_types,
      'platforms', ip.platforms,
      'collaboration_types', ip.collaboration_types,
      'audience_size_total', ip.audience_size_total,
      'engagement_rate', ip.engagement_rate,
      'price_range_min', ip.price_range_min,
      'price_range_max', ip.price_range_max
    ) FROM public.influencer_profiles ip WHERE ip.user_id = v_user_id),
    -- Social links (colonnes publiques uniquement)
    'social_links', (SELECT jsonb_agg(jsonb_build_object(
      'platform', sl.platform,
      'username', sl.username,
      'profile_url', sl.profile_url,
      'followers_count', sl.followers_count,
      'is_verified', sl.is_verified
    )) FROM public.social_links sl WHERE sl.user_id = v_user_id)
  ) INTO v_profile_snapshot
  FROM public.profiles p
  WHERE p.id = v_user_id;

  -- Créer le snapshot du portfolio (colonnes publiques whitelistées)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', pi.id,
    'title', pi.title,
    'description', pi.description,
    'media_type', pi.media_type,
    'media_url', pi.media_url,
    'thumbnail_url', pi.thumbnail_url,
    'external_url', pi.external_url,
    'category', pi.category,
    'tags', pi.tags,
    'is_featured', pi.is_featured
  )), '[]'::jsonb) INTO v_portfolio_snapshot
  FROM public.portfolio_items pi
  WHERE pi.user_id = v_user_id AND pi.is_active = TRUE;

  -- Créer le snapshot des services
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', s.id,
    'title', s.title,
    'description', LEFT(s.description, 500),
    'base_price', s.base_price,
    'service_role', s.service_role,
    'rating_average', s.rating_average,
    'total_orders', s.total_orders
  )), '[]'::jsonb) INTO v_services_snapshot
  FROM public.services s
  WHERE s.seller_id = v_user_id AND s.status = 'active';

  -- Créer la candidature
  INSERT INTO public.global_offer_applications (
    offer_id,
    applicant_id,
    cover_letter,
    proposed_price,
    proposed_delivery_days,
    profile_snapshot,
    portfolio_snapshot,
    services_snapshot,
    status
  ) VALUES (
    p_offer_id,
    v_user_id,
    p_cover_letter,
    p_proposed_price,
    p_proposed_delivery_days,
    v_profile_snapshot,
    v_portfolio_snapshot,
    v_services_snapshot,
    'pending'
  ) RETURNING id INTO v_application_id;

  -- Incrémenter le compteur de candidats
  UPDATE public.global_offers SET applicants_count = applicants_count + 1, updated_at = NOW()
  WHERE id = p_offer_id;

  RETURN jsonb_build_object(
    'success', true,
    'application_id', v_application_id
  );
END;
$$;

-- Mise à jour du statut de commande (state machine)
CREATE OR REPLACE FUNCTION public.update_order_status(
  p_order_id UUID,
  p_new_status TEXT,
  p_reason TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_user_id UUID := auth.uid();
  v_allowed_transitions JSONB;
  v_is_allowed BOOLEAN;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF v_order.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
  END IF;
  
  -- Vérifier les permissions
  IF NOT (v_user_id = v_order.buyer_id OR v_user_id = v_order.seller_id OR public.is_admin() OR public.is_service_role()) THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED');
  END IF;
  
  -- Transitions autorisées
  v_allowed_transitions := '{
    "pending": ["payment_authorized", "cancelled"],
    "payment_authorized": ["accepted", "cancelled"],
    "accepted": ["in_progress", "cancelled"],
    "in_progress": ["delivered", "cancelled"],
    "delivered": ["revision_requested", "completed", "disputed"],
    "revision_requested": ["in_progress", "disputed"],
    "completed": ["disputed"],
    "disputed": ["completed", "refunded"],
    "cancelled": [],
    "refunded": []
  }'::JSONB;
  
  -- Vérifier si la transition est autorisée (admin/service_role peuvent forcer)
  v_is_allowed := (v_allowed_transitions->v_order.status) ? p_new_status;
  IF NOT v_is_allowed AND NOT (public.is_admin() OR public.is_service_role()) THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_TRANSITION', 'current', v_order.status, 'requested', p_new_status);
  END IF;
  
  -- Enregistrer l'historique
  INSERT INTO public.order_status_history(order_id, old_status, new_status, changed_by, reason)
  VALUES (p_order_id, v_order.status, p_new_status, v_user_id, p_reason);
  
  -- Mettre à jour la commande
  UPDATE public.orders SET 
    status = p_new_status,
    accepted_at = CASE WHEN p_new_status = 'accepted' THEN NOW() ELSE accepted_at END,
    delivered_at = CASE WHEN p_new_status = 'delivered' THEN NOW() ELSE delivered_at END,
    completed_at = CASE WHEN p_new_status = 'completed' THEN NOW() ELSE completed_at END,
    cancelled_at = CASE WHEN p_new_status = 'cancelled' THEN NOW() ELSE cancelled_at END,
    updated_at = NOW()
  WHERE id = p_order_id;
  
  -- Déclencher la distribution si complété
  IF p_new_status = 'completed' THEN
    PERFORM public.distribute_commissions(p_order_id);
  END IF;
  
  RETURN jsonb_build_object('success', true, 'old_status', v_order.status, 'new_status', p_new_status);
END;
$$;

-- Demande de retrait
CREATE OR REPLACE FUNCTION public.request_withdrawal(p_amount DECIMAL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_available_seller DECIMAL;
  v_available_agent DECIMAL;
  v_total_available DECIMAL;
  v_withdrawal_id UUID;
  v_remaining DECIMAL;
  v_revenue RECORD;
  v_to_allocate DECIMAL;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED');
  END IF;

  IF p_amount < 5 THEN
    RETURN jsonb_build_object('success', false, 'error', 'MINIMUM_WITHDRAWAL_5_EUR');
  END IF;

  -- Calculer le solde disponible (non verrouillé)
  SELECT COALESCE(SUM(amount), 0) INTO v_available_seller
  FROM public.seller_revenues
  WHERE seller_id = v_user_id AND status = 'available' AND locked = FALSE;

  SELECT COALESCE(SUM(amount), 0) INTO v_available_agent
  FROM public.agent_revenues
  WHERE agent_id = v_user_id AND status = 'available' AND locked = FALSE;

  v_total_available := v_available_seller + v_available_agent;

  IF p_amount > v_total_available THEN
    RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_BALANCE', 'available', v_total_available);
  END IF;

  -- Créer le retrait
  INSERT INTO public.withdrawals(user_id, amount, status)
  VALUES (v_user_id, p_amount, 'pending')
  RETURNING id INTO v_withdrawal_id;

  -- Allocation partielle: verrouiller seulement ce qui est nécessaire
  v_remaining := p_amount;

  -- 1) D'abord allouer depuis seller_revenues (FIFO par date)
  FOR v_revenue IN
    SELECT id, amount FROM public.seller_revenues
    WHERE seller_id = v_user_id AND status = 'available' AND locked = FALSE
    ORDER BY available_at ASC
  LOOP
    EXIT WHEN v_remaining <= 0;

    v_to_allocate := LEAST(v_revenue.amount, v_remaining);

    -- Créer l'allocation
    INSERT INTO public.withdrawal_allocations(withdrawal_id, revenue_type, revenue_id, allocated_amount)
    VALUES (v_withdrawal_id, 'seller', v_revenue.id, v_to_allocate);

    -- Verrouiller la ligne de revenu
    UPDATE public.seller_revenues SET locked = TRUE WHERE id = v_revenue.id;

    v_remaining := v_remaining - v_to_allocate;
  END LOOP;

  -- 2) Ensuite allouer depuis agent_revenues si besoin
  FOR v_revenue IN
    SELECT id, amount FROM public.agent_revenues
    WHERE agent_id = v_user_id AND status = 'available' AND locked = FALSE
    ORDER BY available_at ASC
  LOOP
    EXIT WHEN v_remaining <= 0;

    v_to_allocate := LEAST(v_revenue.amount, v_remaining);

    -- Créer l'allocation
    INSERT INTO public.withdrawal_allocations(withdrawal_id, revenue_type, revenue_id, allocated_amount)
    VALUES (v_withdrawal_id, 'agent', v_revenue.id, v_to_allocate);

    -- Verrouiller la ligne de revenu
    UPDATE public.agent_revenues SET locked = TRUE WHERE id = v_revenue.id;

    v_remaining := v_remaining - v_to_allocate;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'withdrawal_id', v_withdrawal_id, 'amount', p_amount);
END;
$$;

-- Stats vendeur
CREATE OR REPLACE FUNCTION public.get_seller_stats(p_seller_id UUID DEFAULT NULL) 
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_seller_id UUID;
BEGIN
  v_seller_id := COALESCE(p_seller_id, auth.uid());
  IF v_seller_id IS NULL THEN RETURN '{}'::JSONB; END IF;
  
  RETURN jsonb_build_object(
    'total_services', (SELECT COUNT(*) FROM public.services WHERE seller_id = v_seller_id),
    'active_services', (SELECT COUNT(*) FROM public.services WHERE seller_id = v_seller_id AND status = 'active'),
    'total_orders', (SELECT COUNT(*) FROM public.orders WHERE seller_id = v_seller_id),
    'completed_orders', (SELECT COUNT(*) FROM public.orders WHERE seller_id = v_seller_id AND status = 'completed'),
    'total_revenue', (SELECT COALESCE(SUM(amount), 0) FROM public.seller_revenues WHERE seller_id = v_seller_id),
    'pending_balance', (SELECT COALESCE(SUM(amount), 0) FROM public.seller_revenues WHERE seller_id = v_seller_id AND status = 'pending'),
    'available_balance', (SELECT COALESCE(SUM(amount), 0) FROM public.seller_revenues WHERE seller_id = v_seller_id AND status = 'available' AND locked = FALSE)
  );
END;
$$;

-- Stats agent
CREATE OR REPLACE FUNCTION public.get_agent_stats(p_agent_id UUID DEFAULT NULL) 
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_agent_id UUID;
BEGIN
  v_agent_id := COALESCE(p_agent_id, auth.uid());
  IF v_agent_id IS NULL THEN RETURN '{}'::JSONB; END IF;
  
  RETURN jsonb_build_object(
    'total_links', (SELECT COUNT(*) FROM public.affiliate_links WHERE agent_id = v_agent_id),
    'total_clicks', (SELECT COALESCE(SUM(click_count), 0) FROM public.affiliate_links WHERE agent_id = v_agent_id),
    'total_conversions', (SELECT COUNT(*) FROM public.affiliate_conversions WHERE agent_id = v_agent_id AND status = 'confirmed'),
    'total_commission', (SELECT COALESCE(SUM(amount), 0) FROM public.agent_revenues WHERE agent_id = v_agent_id),
    'pending_balance', (SELECT COALESCE(SUM(amount), 0) FROM public.agent_revenues WHERE agent_id = v_agent_id AND status = 'pending'),
    'available_balance', (SELECT COALESCE(SUM(amount), 0) FROM public.agent_revenues WHERE agent_id = v_agent_id AND status = 'available' AND locked = FALSE)
  );
END;
$$;

-- Stats plateforme (admin only)
CREATE OR REPLACE FUNCTION public.get_platform_stats() 
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  
  RETURN jsonb_build_object(
    'total_users', (SELECT COUNT(*) FROM public.profiles),
    'verified_users', (SELECT COUNT(*) FROM public.profiles WHERE is_verified = TRUE),
    'total_services', (SELECT COUNT(*) FROM public.services),
    'active_services', (SELECT COUNT(*) FROM public.services WHERE status = 'active'),
    'total_orders', (SELECT COUNT(*) FROM public.orders),
    'completed_orders', (SELECT COUNT(*) FROM public.orders WHERE status = 'completed'),
    'total_gmv', (SELECT COALESCE(SUM(total_amount), 0) FROM public.orders WHERE status = 'completed'),
    'platform_revenue', (SELECT COALESCE(SUM(amount), 0) FROM public.platform_revenues)
  );
END;
$$;

-- ============================================================================
-- 18. CRON FUNCTIONS
-- ============================================================================

CREATE OR REPLACE FUNCTION public.release_pending_revenues()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.seller_revenues
  SET status = 'available', updated_at = NOW()
  WHERE status = 'pending' AND available_at <= NOW() AND locked = FALSE;

  UPDATE public.agent_revenues
  SET status = 'available', updated_at = NOW()
  WHERE status = 'pending' AND available_at <= NOW() AND locked = FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION public.auto_complete_orders()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.orders
  SET status = 'completed', completed_at = NOW(), updated_at = NOW()
  WHERE status = 'delivered' AND delivered_at < NOW() - INTERVAL '72 hours';

  -- Distribuer les commissions pour les commandes auto-complétées
  PERFORM public.distribute_commissions(id)
  FROM public.orders
  WHERE status = 'completed' AND completed_at >= NOW() - INTERVAL '1 minute';
END;
$$;

CREATE OR REPLACE FUNCTION public.auto_cancel_expired_orders()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.orders
  SET status = 'cancelled', cancelled_at = NOW(), updated_at = NOW()
  WHERE status = 'payment_authorized'
    AND acceptance_deadline IS NOT NULL
    AND acceptance_deadline < NOW();
END;
$$;

CREATE OR REPLACE FUNCTION public.cleanup_old_data()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM public.processed_webhooks WHERE processed_at < NOW() - INTERVAL '7 days';
  DELETE FROM public.rate_limits WHERE window_start < NOW() - INTERVAL '1 hour';
  DELETE FROM public.system_logs WHERE created_at < NOW() - INTERVAL '30 days' AND level IN ('debug', 'info');
END;
$$;

-- ============================================================================
-- 19. RGPD FUNCTIONS
-- ============================================================================

CREATE OR REPLACE FUNCTION public.export_user_data(p_user_id UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_user_id UUID;
  v_result JSONB;
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());
  IF v_user_id IS NULL THEN RETURN NULL; END IF;
  
  -- Vérifier que c'est bien l'utilisateur ou un admin
  IF v_user_id != auth.uid() AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'UNAUTHORIZED';
  END IF;
  
  SELECT jsonb_build_object(
    'profile', (SELECT row_to_json(p.*) FROM public.profiles p WHERE id = v_user_id),
    'roles', (SELECT COALESCE(jsonb_agg(row_to_json(r.*)), '[]'::jsonb) FROM public.user_roles r WHERE user_id = v_user_id),
    'services', (SELECT COALESCE(jsonb_agg(row_to_json(s.*)), '[]'::jsonb) FROM public.services s WHERE seller_id = v_user_id),
    'orders_as_buyer', (SELECT COALESCE(jsonb_agg(row_to_json(o.*)), '[]'::jsonb) FROM public.orders o WHERE buyer_id = v_user_id),
    'orders_as_seller', (SELECT COALESCE(jsonb_agg(row_to_json(o.*)), '[]'::jsonb) FROM public.orders o WHERE seller_id = v_user_id),
    'reviews_given', (SELECT COALESCE(jsonb_agg(row_to_json(r.*)), '[]'::jsonb) FROM public.reviews r WHERE reviewer_id = v_user_id),
    'reviews_received', (SELECT COALESCE(jsonb_agg(row_to_json(r.*)), '[]'::jsonb) FROM public.reviews r WHERE reviewed_id = v_user_id),
    'creator_code', (SELECT row_to_json(c.*) FROM public.creator_codes c WHERE user_id = v_user_id),
    'affiliate_links', (SELECT COALESCE(jsonb_agg(row_to_json(l.*)), '[]'::jsonb) FROM public.affiliate_links l WHERE agent_id = v_user_id),
    'exported_at', NOW()
  ) INTO v_result;
  
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.request_account_deletion(p_user_id UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_user_id UUID;
  v_pending_orders INTEGER;
  v_pending_withdrawals INTEGER;
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());
  IF v_user_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED'); END IF;
  
  -- Vérifier que c'est bien l'utilisateur ou un admin
  IF v_user_id != auth.uid() AND NOT public.is_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED');
  END IF;
  
  -- Vérifier les commandes en cours
  SELECT COUNT(*) INTO v_pending_orders 
  FROM public.orders 
  WHERE (buyer_id = v_user_id OR seller_id = v_user_id) 
    AND status NOT IN ('completed', 'cancelled', 'refunded');
  
  IF v_pending_orders > 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'PENDING_ORDERS_EXIST', 'count', v_pending_orders);
  END IF;
  
  -- Vérifier les retraits en cours
  SELECT COUNT(*) INTO v_pending_withdrawals 
  FROM public.withdrawals 
  WHERE user_id = v_user_id AND status IN ('pending', 'processing');
  
  IF v_pending_withdrawals > 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'PENDING_WITHDRAWALS_EXIST', 'count', v_pending_withdrawals);
  END IF;
  
  -- Planifier la suppression (30 jours)
  UPDATE public.profiles SET 
    deletion_requested_at = NOW(),
    deletion_scheduled_for = NOW() + INTERVAL '30 days',
    updated_at = NOW()
  WHERE id = v_user_id;
  
  RETURN jsonb_build_object('success', true, 'scheduled_for', NOW() + INTERVAL '30 days');
END;
$$;

-- ============================================================================
-- 20. VIEWS (IA/RAG Safe)
-- ============================================================================

CREATE OR REPLACE VIEW public.v_services_public AS
SELECT 
  s.id, s.seller_id, s.category_id, s.title, s.slug, s.description,
  s.base_price, s.min_delivery_days, s.status, s.rating_average, s.rating_count,
  s.total_orders, s.is_affiliable, s.created_at,
  p.username as seller_username, p.display_name as seller_display_name, p.avatar_url as seller_avatar,
  c.name as category_name, c.slug as category_slug
FROM public.services s
LEFT JOIN public.profiles p ON p.id = s.seller_id
LEFT JOIN public.categories c ON c.id = s.category_id
WHERE s.status = 'active';

CREATE OR REPLACE VIEW public.v_profiles_public AS
SELECT 
  p.id, p.username, p.display_name, p.bio, p.avatar_url, p.cover_url,
  p.city, p.country, p.is_verified, p.average_rating, p.total_reviews,
  p.completed_orders_count, p.created_at
FROM public.profiles p
WHERE p.deletion_requested_at IS NULL;

CREATE OR REPLACE VIEW public.v_user_balance AS
SELECT
  p.id as user_id,
  COALESCE((SELECT SUM(amount) FROM public.seller_revenues WHERE seller_id = p.id AND status = 'pending'), 0) as seller_pending,
  COALESCE((SELECT SUM(amount) FROM public.seller_revenues WHERE seller_id = p.id AND status = 'available' AND locked = FALSE), 0) as seller_available,
  COALESCE((SELECT SUM(amount) FROM public.agent_revenues WHERE agent_id = p.id AND status = 'pending'), 0) as agent_pending,
  COALESCE((SELECT SUM(amount) FROM public.agent_revenues WHERE agent_id = p.id AND status = 'available' AND locked = FALSE), 0) as agent_available
FROM public.profiles p;

-- Vues publiques sécurisées pour les role-profiles (colonnes filtrées)
CREATE OR REPLACE VIEW public.v_freelance_public AS
SELECT
  fp.user_id,
  fp.professional_title,
  fp.tagline,
  fp.description,
  fp.skills,
  fp.languages,
  fp.experience_years,
  fp.hourly_rate,
  fp.availability_status,
  fp.response_time_hours,
  fp.created_at
FROM public.freelance_profiles fp
JOIN public.profiles p ON p.id = fp.user_id
WHERE p.deletion_requested_at IS NULL;

CREATE OR REPLACE VIEW public.v_influencer_public AS
SELECT
  ip.user_id,
  ip.niche,
  ip.content_types,
  ip.platforms,
  ip.collaboration_types,
  ip.audience_size_total,
  ip.engagement_rate,
  ip.social_platforms,  -- liens réseaux sociaux publics
  ip.media_kit_url,
  ip.price_range_min,
  ip.price_range_max,
  ip.created_at
FROM public.influencer_profiles ip
JOIN public.profiles p ON p.id = ip.user_id
WHERE p.deletion_requested_at IS NULL;

CREATE OR REPLACE VIEW public.v_merchant_public AS
SELECT
  mp.user_id,
  mp.company_name,  -- nom public OK
  mp.industry,
  mp.company_size,
  mp.website_url,
  mp.description,
  mp.created_at
  -- Exclut: vat_number, legal_address, etc.
FROM public.merchant_profiles mp
JOIN public.profiles p ON p.id = mp.user_id
WHERE p.deletion_requested_at IS NULL;

CREATE OR REPLACE VIEW public.v_agent_public AS
SELECT
  ap.user_id,
  ap.marketing_channels,
  ap.audience_description,
  ap.experience_level,
  ap.created_at
FROM public.agent_profiles ap
JOIN public.profiles p ON p.id = ap.user_id
WHERE p.deletion_requested_at IS NULL;

-- Vue unifiée pour l'affichage des vendeurs (freelance + influencer)
CREATE OR REPLACE VIEW public.v_seller_public AS
SELECT
  p.id as user_id,
  p.username,
  p.display_name,
  p.bio,
  p.avatar_url,
  p.city,
  p.country,
  p.is_verified,
  p.average_rating,
  p.total_reviews,
  p.completed_orders_count,
  -- Freelance info
  fp.professional_title,
  fp.skills,
  fp.experience_years,
  fp.hourly_rate,
  fp.availability_status,
  -- Influencer info
  ip.niche,
  ip.audience_size_total,
  ip.engagement_rate,
  ip.platforms as influencer_platforms,
  ip.content_types,
  -- Roles actifs
  ARRAY(SELECT ur.role FROM public.user_roles ur WHERE ur.user_id = p.id AND ur.status = 'active') as active_roles
FROM public.profiles p
LEFT JOIN public.freelance_profiles fp ON fp.user_id = p.id
LEFT JOIN public.influencer_profiles ip ON ip.user_id = p.id
WHERE p.deletion_requested_at IS NULL
  AND EXISTS (SELECT 1 FROM public.user_roles ur WHERE ur.user_id = p.id AND ur.role IN ('freelance', 'influencer') AND ur.status = 'active');

-- ============================================================================
-- 21. TRIGGERS (update_updated_at)
-- ============================================================================

CREATE TRIGGER update_profiles_modtime BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_freelance_profiles_modtime BEFORE UPDATE ON public.freelance_profiles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_influencer_profiles_modtime BEFORE UPDATE ON public.influencer_profiles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_merchant_profiles_modtime BEFORE UPDATE ON public.merchant_profiles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_agent_profiles_modtime BEFORE UPDATE ON public.agent_profiles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_dashboard_prefs_modtime BEFORE UPDATE ON public.dashboard_preferences FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_social_links_modtime BEFORE UPDATE ON public.social_links FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_creator_codes_modtime BEFORE UPDATE ON public.creator_codes FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_categories_modtime BEFORE UPDATE ON public.categories FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_services_modtime BEFORE UPDATE ON public.services FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_global_offers_modtime BEFORE UPDATE ON public.global_offers FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_global_offer_apps_modtime BEFORE UPDATE ON public.global_offer_applications FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_portfolio_modtime BEFORE UPDATE ON public.portfolio_items FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_affiliate_listings_modtime BEFORE UPDATE ON public.affiliate_listings FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_affiliate_links_modtime BEFORE UPDATE ON public.affiliate_links FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_orders_modtime BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_disputes_modtime BEFORE UPDATE ON public.disputes FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_reviews_modtime BEFORE UPDATE ON public.reviews FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_seller_revenues_modtime BEFORE UPDATE ON public.seller_revenues FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_agent_revenues_modtime BEFORE UPDATE ON public.agent_revenues FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_withdrawals_modtime BEFORE UPDATE ON public.withdrawals FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_bank_accounts_modtime BEFORE UPDATE ON public.bank_accounts FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_contact_messages_modtime BEFORE UPDATE ON public.contact_messages FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================================================
-- 22. ROW LEVEL SECURITY (RLS) - COMPLET
-- ============================================================================

-- Activation RLS sur TOUTES les tables
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dashboard_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.freelance_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.influencer_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.merchant_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.social_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creator_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.services ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_packages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_media ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_faqs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_requirements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_extras ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.global_offers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.global_offer_applications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.portfolio_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_clicks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_conversions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_status_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.disputes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.seller_revenues ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_revenues ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_revenues ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.withdrawals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commission_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reverse_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contact_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.job_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rate_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.processed_webhooks ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- 23. POLICIES
-- ============================================================================

-- PROFILES
-- SÉCURITÉ: La table profiles contient des données sensibles (email, phone, kyc_status, stripe_*)
-- Les utilisateurs authentifiés NE DOIVENT PAS avoir accès direct à profiles d'autres users
-- Utiliser v_profiles_public pour l'affichage public (colonnes filtrées)
CREATE POLICY "profiles_owner_read" ON public.profiles FOR SELECT
  USING (auth.uid() = id);  -- Un user peut SEULEMENT lire son propre profil complet
CREATE POLICY "profiles_admin_read" ON public.profiles FOR SELECT
  USING (public.is_admin() OR public.is_service_role());  -- Admins/service_role ont accès total
CREATE POLICY "profiles_owner_update" ON public.profiles FOR UPDATE USING (auth.uid() = id);
CREATE POLICY "profiles_owner_insert" ON public.profiles FOR INSERT WITH CHECK (auth.uid() = id);

-- ADMINS
CREATE POLICY "admins_admin_read" ON public.admins FOR SELECT USING (public.is_admin() OR public.is_service_role());
CREATE POLICY "admins_service_write" ON public.admins FOR ALL USING (public.is_service_role());

-- USER_ROLES
-- SÉCURITÉ: Ne pas exposer tous les rôles de tous les utilisateurs
-- Seul le owner peut voir/gérer ses rôles, admins peuvent voir
CREATE POLICY "user_roles_owner_read" ON public.user_roles FOR SELECT
  USING (auth.uid() = user_id OR public.is_admin() OR public.is_service_role());
CREATE POLICY "user_roles_owner_manage" ON public.user_roles FOR ALL USING (auth.uid() = user_id);

-- DASHBOARD_PREFERENCES
CREATE POLICY "dashboard_prefs_owner" ON public.dashboard_preferences FOR ALL USING (auth.uid() = user_id);

-- ROLE PROFILES (freelance, influencer, merchant, agent)
-- SÉCURITÉ: Limiter les données exposées publiquement
-- Les colonnes sensibles (company_name, vat_number, etc.) ne doivent pas être publiques

-- Freelance: seul owner + admin peuvent lire toutes les colonnes
-- Pour public: utiliser une vue v_freelance_public si nécessaire
CREATE POLICY "freelance_profiles_owner_read" ON public.freelance_profiles FOR SELECT
  USING (auth.uid() = user_id OR public.is_admin() OR public.is_service_role());
CREATE POLICY "freelance_profiles_owner_manage" ON public.freelance_profiles FOR ALL USING (auth.uid() = user_id);

-- Influencer: idem
CREATE POLICY "influencer_profiles_owner_read" ON public.influencer_profiles FOR SELECT
  USING (auth.uid() = user_id OR public.is_admin() OR public.is_service_role());
CREATE POLICY "influencer_profiles_owner_manage" ON public.influencer_profiles FOR ALL USING (auth.uid() = user_id);

-- Merchant: données business sensibles (vat, company)
CREATE POLICY "merchant_profiles_owner_read" ON public.merchant_profiles FOR SELECT
  USING (auth.uid() = user_id OR public.is_admin() OR public.is_service_role());
CREATE POLICY "merchant_profiles_owner_manage" ON public.merchant_profiles FOR ALL USING (auth.uid() = user_id);

-- Agent: idem
CREATE POLICY "agent_profiles_owner_read" ON public.agent_profiles FOR SELECT
  USING (auth.uid() = user_id OR public.is_admin() OR public.is_service_role());
CREATE POLICY "agent_profiles_owner_manage" ON public.agent_profiles FOR ALL USING (auth.uid() = user_id);

-- SOCIAL_LINKS
-- Social links publics uniquement pour les influenceurs (les freelances gardent les leurs privés)
CREATE POLICY "social_links_public_read" ON public.social_links FOR SELECT USING (
  auth.uid() = user_id  -- Owner peut toujours voir les siens
  OR public.is_admin()
  OR public.is_service_role()
  -- Public seulement si l'utilisateur est influenceur
  OR EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = social_links.user_id
      AND ur.role = 'influencer'
      AND ur.status = 'active'
  )
);
CREATE POLICY "social_links_owner_manage" ON public.social_links FOR ALL USING (auth.uid() = user_id);

-- CREATOR_CODES
-- Pas de lecture publique listable (anti-scraping)
-- La résolution se fait uniquement via resolve_creator_code() qui est SECURITY DEFINER
CREATE POLICY "creator_codes_owner_read" ON public.creator_codes FOR SELECT
  USING (auth.uid() = user_id);
CREATE POLICY "creator_codes_admin_read" ON public.creator_codes FOR SELECT
  USING (public.is_admin() OR public.is_service_role());
CREATE POLICY "creator_codes_service_manage" ON public.creator_codes FOR ALL
  USING (public.is_service_role());

-- CATEGORIES
CREATE POLICY "categories_public_read" ON public.categories FOR SELECT USING (is_active = TRUE);
CREATE POLICY "categories_admin_manage" ON public.categories FOR ALL USING (public.is_admin() OR public.is_service_role());

-- SERVICES
-- SÉCURITÉ: Pour INSERT, vérifier que le seller a le rôle correspondant (influencer/freelance)
-- et que son KYC est vérifié + Stripe onboarding complété (pour publier/encaisser)
CREATE POLICY "services_public_read" ON public.services FOR SELECT USING (
  status = 'active'
  OR auth.uid() = seller_id
  OR public.is_admin()
  OR public.is_service_role()
);
CREATE POLICY "services_seller_insert" ON public.services FOR INSERT WITH CHECK (
  auth.uid() = seller_id
  -- Vérifier que le seller a le rôle correspondant au service_role
  AND EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid()
      AND ur.role = NEW.service_role  -- influencer ou freelance selon service
      AND ur.status = 'active'
  )
  -- KYC et Stripe requis pour publier (status != draft)
  AND (
    NEW.status = 'draft'  -- Brouillon toujours autorisé
    OR EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = auth.uid()
        AND p.kyc_status = 'verified'
        AND p.stripe_onboarding_completed = TRUE
    )
  )
);
CREATE POLICY "services_seller_update" ON public.services FOR UPDATE USING (auth.uid() = seller_id OR public.is_admin());
CREATE POLICY "services_seller_delete" ON public.services FOR DELETE USING (auth.uid() = seller_id OR public.is_admin());

-- SERVICE_PACKAGES
CREATE POLICY "service_packages_public_read" ON public.service_packages FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.services s WHERE s.id = service_id AND (s.status = 'active' OR s.seller_id = auth.uid()))
);
CREATE POLICY "service_packages_seller_manage" ON public.service_packages FOR ALL USING (
  EXISTS (SELECT 1 FROM public.services s WHERE s.id = service_id AND s.seller_id = auth.uid())
);

-- SERVICE_MEDIA
CREATE POLICY "service_media_public_read" ON public.service_media FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.services s WHERE s.id = service_id AND (s.status = 'active' OR s.seller_id = auth.uid()))
);
CREATE POLICY "service_media_seller_manage" ON public.service_media FOR ALL USING (
  EXISTS (SELECT 1 FROM public.services s WHERE s.id = service_id AND s.seller_id = auth.uid())
);

-- SERVICE_FAQS
CREATE POLICY "service_faqs_public_read" ON public.service_faqs FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.services s WHERE s.id = service_id AND (s.status = 'active' OR s.seller_id = auth.uid()))
);
CREATE POLICY "service_faqs_seller_manage" ON public.service_faqs FOR ALL USING (
  EXISTS (SELECT 1 FROM public.services s WHERE s.id = service_id AND s.seller_id = auth.uid())
);

-- SERVICE_REQUIREMENTS
CREATE POLICY "service_requirements_public_read" ON public.service_requirements FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.services s WHERE s.id = service_id AND (s.status = 'active' OR s.seller_id = auth.uid()))
);
CREATE POLICY "service_requirements_seller_manage" ON public.service_requirements FOR ALL USING (
  EXISTS (SELECT 1 FROM public.services s WHERE s.id = service_id AND s.seller_id = auth.uid())
);

-- SERVICE_EXTRAS
CREATE POLICY "service_extras_public_read" ON public.service_extras FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.services s WHERE s.id = service_id AND (s.status = 'active' OR s.seller_id = auth.uid()))
);
CREATE POLICY "service_extras_seller_manage" ON public.service_extras FOR ALL USING (
  EXISTS (SELECT 1 FROM public.services s WHERE s.id = service_id AND s.seller_id = auth.uid())
);

-- SERVICE_TAGS
CREATE POLICY "service_tags_public_read" ON public.service_tags FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.services s WHERE s.id = service_id AND (s.status = 'active' OR s.seller_id = auth.uid()))
);
CREATE POLICY "service_tags_seller_manage" ON public.service_tags FOR ALL USING (
  EXISTS (SELECT 1 FROM public.services s WHERE s.id = service_id AND s.seller_id = auth.uid())
);

-- GLOBAL_OFFERS
-- SÉCURITÉ: Seuls les merchants peuvent créer des appels d'offres
CREATE POLICY "global_offers_public_read" ON public.global_offers FOR SELECT
  USING (status IN ('open', 'in_progress') OR auth.uid() = author_id OR public.is_admin());
CREATE POLICY "global_offers_author_insert" ON public.global_offers FOR INSERT WITH CHECK (
  auth.uid() = author_id
  -- Vérifier que l'auteur a le rôle merchant actif
  AND EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid()
      AND ur.role = 'merchant'
      AND ur.status = 'active'
  )
);
CREATE POLICY "global_offers_author_update" ON public.global_offers FOR UPDATE USING (auth.uid() = author_id OR public.is_admin());
CREATE POLICY "global_offers_author_delete" ON public.global_offers FOR DELETE USING (auth.uid() = author_id OR public.is_admin());

-- GLOBAL_OFFER_APPLICATIONS
-- SÉCURITÉ: Pour postuler, l'utilisateur doit avoir KYC vérifié + Stripe onboarding
CREATE POLICY "applications_parties_read" ON public.global_offer_applications FOR SELECT USING (
  auth.uid() = applicant_id OR EXISTS (SELECT 1 FROM public.global_offers o WHERE o.id = offer_id AND o.author_id = auth.uid()) OR public.is_admin()
);
CREATE POLICY "applications_applicant_insert" ON public.global_offer_applications FOR INSERT WITH CHECK (
  auth.uid() = applicant_id
  -- KYC et Stripe requis pour postuler
  AND EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.kyc_status = 'verified'
      AND p.stripe_onboarding_completed = TRUE
  )
  -- Vérifier que l'utilisateur a le rôle approprié (influencer ou freelance)
  AND EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid()
      AND ur.role IN ('influencer', 'freelance')
      AND ur.status = 'active'
  )
);
CREATE POLICY "applications_parties_update" ON public.global_offer_applications FOR UPDATE USING (
  auth.uid() = applicant_id OR EXISTS (SELECT 1 FROM public.global_offers o WHERE o.id = offer_id AND o.author_id = auth.uid()) OR public.is_admin()
);

-- PORTFOLIO_ITEMS
CREATE POLICY "portfolio_public_read" ON public.portfolio_items FOR SELECT USING (is_active = TRUE OR auth.uid() = user_id);
CREATE POLICY "portfolio_owner_manage" ON public.portfolio_items FOR ALL USING (auth.uid() = user_id);

-- AFFILIATE_LISTINGS
CREATE POLICY "affiliate_listings_public_read" ON public.affiliate_listings FOR SELECT USING (
  is_active = TRUE OR auth.uid() = seller_id
);
CREATE POLICY "affiliate_listings_seller_manage" ON public.affiliate_listings FOR ALL USING (auth.uid() = seller_id);

-- AFFILIATE_LINKS
CREATE POLICY "affiliate_links_parties_read" ON public.affiliate_links FOR SELECT USING (
  auth.uid() = agent_id OR EXISTS (SELECT 1 FROM public.affiliate_listings l WHERE l.id = listing_id AND l.seller_id = auth.uid())
);
CREATE POLICY "affiliate_links_agent_manage" ON public.affiliate_links FOR ALL USING (auth.uid() = agent_id);
CREATE POLICY "affiliate_links_service_manage" ON public.affiliate_links FOR ALL USING (public.is_service_role());

-- AFFILIATE_CLICKS
CREATE POLICY "affiliate_clicks_parties_read" ON public.affiliate_clicks FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.affiliate_links l WHERE l.id = affiliate_link_id AND (l.agent_id = auth.uid() OR EXISTS (SELECT 1 FROM public.affiliate_listings al WHERE al.id = l.listing_id AND al.seller_id = auth.uid())))
);
CREATE POLICY "affiliate_clicks_service_insert" ON public.affiliate_clicks FOR INSERT WITH CHECK (public.is_service_role());

-- AFFILIATE_CONVERSIONS
CREATE POLICY "conversions_parties_read" ON public.affiliate_conversions FOR SELECT USING (
  auth.uid() = agent_id OR auth.uid() = seller_id OR public.is_admin()
);
CREATE POLICY "conversions_service_manage" ON public.affiliate_conversions FOR ALL USING (public.is_service_role());

-- ORDERS
CREATE POLICY "orders_parties_read" ON public.orders FOR SELECT USING (auth.uid() = buyer_id OR auth.uid() = seller_id OR public.is_admin());
CREATE POLICY "orders_buyer_insert" ON public.orders FOR INSERT WITH CHECK (auth.uid() = buyer_id);
CREATE POLICY "orders_parties_update" ON public.orders FOR UPDATE USING (auth.uid() = buyer_id OR auth.uid() = seller_id OR public.is_admin() OR public.is_service_role());

-- ORDER_STATUS_HISTORY
CREATE POLICY "order_history_parties_read" ON public.order_status_history FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id AND (o.buyer_id = auth.uid() OR o.seller_id = auth.uid())) OR public.is_admin()
);
CREATE POLICY "order_history_service_insert" ON public.order_status_history FOR INSERT WITH CHECK (public.is_service_role() OR public.is_admin());

-- ORDER_MESSAGES
CREATE POLICY "order_messages_parties_read" ON public.order_messages FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id AND (o.buyer_id = auth.uid() OR o.seller_id = auth.uid()))
);
CREATE POLICY "order_messages_parties_insert" ON public.order_messages FOR INSERT WITH CHECK (
  auth.uid() = sender_id AND EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id AND (o.buyer_id = auth.uid() OR o.seller_id = auth.uid()))
);

-- DISPUTES
CREATE POLICY "disputes_parties_read" ON public.disputes FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id AND (o.buyer_id = auth.uid() OR o.seller_id = auth.uid())) OR public.is_admin()
);
CREATE POLICY "disputes_parties_insert" ON public.disputes FOR INSERT WITH CHECK (
  EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id AND (o.buyer_id = auth.uid() OR o.seller_id = auth.uid()))
);
CREATE POLICY "disputes_admin_update" ON public.disputes FOR UPDATE USING (public.is_admin() OR public.is_service_role());

-- REVIEWS
CREATE POLICY "reviews_public_read" ON public.reviews FOR SELECT USING (is_visible = TRUE OR auth.uid() = reviewer_id OR auth.uid() = reviewed_id);
CREATE POLICY "reviews_reviewer_insert" ON public.reviews FOR INSERT WITH CHECK (auth.uid() = reviewer_id);
CREATE POLICY "reviews_reviewed_update" ON public.reviews FOR UPDATE USING (auth.uid() = reviewed_id);

-- LEDGER_ENTRIES (très sensible)
CREATE POLICY "ledger_admin_read" ON public.ledger_entries FOR SELECT USING (public.is_admin() OR public.is_service_role());
CREATE POLICY "ledger_service_insert" ON public.ledger_entries FOR INSERT WITH CHECK (public.is_service_role());

-- SELLER_REVENUES
CREATE POLICY "seller_revenues_owner_read" ON public.seller_revenues FOR SELECT USING (auth.uid() = seller_id OR public.is_admin());
CREATE POLICY "seller_revenues_service_manage" ON public.seller_revenues FOR ALL USING (public.is_service_role());

-- AGENT_REVENUES
CREATE POLICY "agent_revenues_owner_read" ON public.agent_revenues FOR SELECT USING (auth.uid() = agent_id OR public.is_admin());
CREATE POLICY "agent_revenues_service_manage" ON public.agent_revenues FOR ALL USING (public.is_service_role());

-- PLATFORM_REVENUES
CREATE POLICY "platform_revenues_admin_read" ON public.platform_revenues FOR SELECT USING (public.is_admin() OR public.is_service_role());
CREATE POLICY "platform_revenues_service_manage" ON public.platform_revenues FOR ALL USING (public.is_service_role());

-- WITHDRAWALS
CREATE POLICY "withdrawals_owner_read" ON public.withdrawals FOR SELECT USING (auth.uid() = user_id OR public.is_admin());
CREATE POLICY "withdrawals_service_manage" ON public.withdrawals FOR ALL USING (public.is_service_role());

-- COMMISSION_RUNS
CREATE POLICY "commission_runs_admin_read" ON public.commission_runs FOR SELECT USING (public.is_admin() OR public.is_service_role());
CREATE POLICY "commission_runs_service_manage" ON public.commission_runs FOR ALL USING (public.is_service_role());

-- REVERSE_RUNS
CREATE POLICY "reverse_runs_admin_read" ON public.reverse_runs FOR SELECT USING (public.is_admin() OR public.is_service_role());
CREATE POLICY "reverse_runs_service_manage" ON public.reverse_runs FOR ALL USING (public.is_service_role());

-- BANK_ACCOUNTS (très sensible)
CREATE POLICY "bank_accounts_owner_read" ON public.bank_accounts FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "bank_accounts_owner_insert" ON public.bank_accounts FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "bank_accounts_owner_update" ON public.bank_accounts FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "bank_accounts_owner_delete" ON public.bank_accounts FOR DELETE USING (auth.uid() = user_id);

-- CONVERSATIONS
CREATE POLICY "conversations_participant_read" ON public.conversations FOR SELECT USING (
  auth.uid() = participant_1_id OR auth.uid() = participant_2_id
);
CREATE POLICY "conversations_participant_insert" ON public.conversations FOR INSERT WITH CHECK (
  auth.uid() = participant_1_id OR auth.uid() = participant_2_id
);
CREATE POLICY "conversations_participant_update" ON public.conversations FOR UPDATE USING (
  auth.uid() = participant_1_id OR auth.uid() = participant_2_id
);

-- MESSAGES
CREATE POLICY "messages_participant_read" ON public.messages FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.conversations c WHERE c.id = conversation_id AND (c.participant_1_id = auth.uid() OR c.participant_2_id = auth.uid()))
);
CREATE POLICY "messages_sender_insert" ON public.messages FOR INSERT WITH CHECK (
  auth.uid() = sender_id AND EXISTS (SELECT 1 FROM public.conversations c WHERE c.id = conversation_id AND (c.participant_1_id = auth.uid() OR c.participant_2_id = auth.uid()))
);

-- NOTIFICATIONS
CREATE POLICY "notifications_owner_read" ON public.notifications FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "notifications_owner_update" ON public.notifications FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "notifications_service_insert" ON public.notifications FOR INSERT WITH CHECK (public.is_service_role());

-- AUDIT_LOGS
CREATE POLICY "audit_logs_admin_read" ON public.audit_logs FOR SELECT USING (public.is_admin() OR public.is_service_role());
CREATE POLICY "audit_logs_service_insert" ON public.audit_logs FOR INSERT WITH CHECK (public.is_service_role());

-- SYSTEM_LOGS
CREATE POLICY "system_logs_admin_read" ON public.system_logs FOR SELECT USING (public.is_admin() OR public.is_service_role());
CREATE POLICY "system_logs_service_manage" ON public.system_logs FOR ALL USING (public.is_service_role());

-- PAYMENT_LOGS
CREATE POLICY "payment_logs_admin_read" ON public.payment_logs FOR SELECT USING (public.is_admin() OR public.is_service_role());
CREATE POLICY "payment_logs_service_manage" ON public.payment_logs FOR ALL USING (public.is_service_role());

-- CONTACT_MESSAGES
CREATE POLICY "contact_messages_owner_read" ON public.contact_messages FOR SELECT USING (auth.uid() = user_id OR public.is_admin());
CREATE POLICY "contact_messages_insert" ON public.contact_messages FOR INSERT WITH CHECK (true);
CREATE POLICY "contact_messages_admin_update" ON public.contact_messages FOR UPDATE USING (public.is_admin());

-- JOB_QUEUE
CREATE POLICY "job_queue_service_manage" ON public.job_queue FOR ALL USING (public.is_service_role());

-- RATE_LIMITS
CREATE POLICY "rate_limits_service_manage" ON public.rate_limits FOR ALL USING (public.is_service_role());

-- PROCESSED_WEBHOOKS
CREATE POLICY "webhooks_service_manage" ON public.processed_webhooks FOR ALL USING (public.is_service_role());

-- ============================================================================
-- 24. GRANTS (Sécurisés)
-- ============================================================================

-- Grants de base
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;

-- SELECT pour anon (lecture publique limitée par RLS)
-- NOTE: public.profiles n'est PAS accordé à anon - utiliser v_profiles_public à la place
-- Cela empêche l'exposition des colonnes sensibles (email, phone, kyc_status, stripe_*, etc.)
GRANT SELECT ON public.categories TO anon;
GRANT SELECT ON public.services TO anon;
GRANT SELECT ON public.service_packages TO anon;
GRANT SELECT ON public.service_media TO anon;
GRANT SELECT ON public.service_faqs TO anon;
GRANT SELECT ON public.reviews TO anon;
GRANT SELECT ON public.global_offers TO anon;
GRANT SELECT ON public.v_services_public TO anon;
GRANT SELECT ON public.v_profiles_public TO anon;  -- Vue sécurisée avec colonnes filtrées
-- Nouvelles vues publiques pour les role-profiles
GRANT SELECT ON public.v_freelance_public TO anon;
GRANT SELECT ON public.v_influencer_public TO anon;
GRANT SELECT ON public.v_merchant_public TO anon;
GRANT SELECT ON public.v_agent_public TO anon;
GRANT SELECT ON public.v_seller_public TO anon;

-- Grants SELECT ciblés pour authenticated (au lieu de ALL TABLES)
-- Principe: accès uniquement aux tables nécessaires, RLS fait le filtrage
GRANT SELECT ON public.profiles TO authenticated;
GRANT SELECT ON public.user_roles TO authenticated;
GRANT SELECT ON public.dashboard_preferences TO authenticated;
GRANT SELECT ON public.freelance_profiles TO authenticated;
GRANT SELECT ON public.influencer_profiles TO authenticated;
GRANT SELECT ON public.merchant_profiles TO authenticated;
GRANT SELECT ON public.agent_profiles TO authenticated;
GRANT SELECT ON public.social_links TO authenticated;
GRANT SELECT ON public.categories TO authenticated;
GRANT SELECT ON public.services TO authenticated;
GRANT SELECT ON public.service_packages TO authenticated;
GRANT SELECT ON public.service_media TO authenticated;
GRANT SELECT ON public.service_faqs TO authenticated;
GRANT SELECT ON public.service_requirements TO authenticated;
GRANT SELECT ON public.service_extras TO authenticated;
GRANT SELECT ON public.service_tags TO authenticated;
GRANT SELECT ON public.global_offers TO authenticated;
GRANT SELECT ON public.global_offer_applications TO authenticated;
GRANT SELECT ON public.portfolio_items TO authenticated;
GRANT SELECT ON public.affiliate_listings TO authenticated;
GRANT SELECT ON public.affiliate_links TO authenticated;
GRANT SELECT ON public.affiliate_conversions TO authenticated;
GRANT SELECT ON public.orders TO authenticated;
GRANT SELECT ON public.order_messages TO authenticated;
GRANT SELECT ON public.order_status_history TO authenticated;
GRANT SELECT ON public.disputes TO authenticated;
GRANT SELECT ON public.reviews TO authenticated;
GRANT SELECT ON public.seller_revenues TO authenticated;
GRANT SELECT ON public.agent_revenues TO authenticated;
GRANT SELECT ON public.withdrawals TO authenticated;
GRANT SELECT ON public.bank_accounts TO authenticated;
GRANT SELECT ON public.conversations TO authenticated;
GRANT SELECT ON public.messages TO authenticated;
GRANT SELECT ON public.notifications TO authenticated;
-- Tables sensibles: PAS de GRANT SELECT pour authenticated
-- (ledger_entries, platform_revenues, audit_logs, processed_webhooks, etc.)
-- Vues publiques accessibles
GRANT SELECT ON public.v_profiles_public TO authenticated;
GRANT SELECT ON public.v_freelance_public TO authenticated;
GRANT SELECT ON public.v_influencer_public TO authenticated;
GRANT SELECT ON public.v_merchant_public TO authenticated;
GRANT SELECT ON public.v_agent_public TO authenticated;
GRANT SELECT ON public.v_seller_public TO authenticated;

-- Grants INSERT/UPDATE/DELETE pour authenticated
GRANT INSERT, UPDATE ON public.profiles TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.user_roles TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.dashboard_preferences TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.freelance_profiles TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.influencer_profiles TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.merchant_profiles TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.agent_profiles TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.social_links TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.services TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.service_packages TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.service_media TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.service_faqs TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.service_requirements TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.service_extras TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.service_tags TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.global_offers TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.global_offer_applications TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.portfolio_items TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.affiliate_listings TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.affiliate_links TO authenticated;
GRANT INSERT, UPDATE ON public.orders TO authenticated;
GRANT INSERT ON public.order_messages TO authenticated;
GRANT INSERT ON public.disputes TO authenticated;
GRANT INSERT, UPDATE ON public.reviews TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.bank_accounts TO authenticated;
GRANT INSERT, UPDATE ON public.conversations TO authenticated;
GRANT INSERT ON public.messages TO authenticated;
GRANT UPDATE ON public.notifications TO authenticated;
GRANT INSERT ON public.contact_messages TO authenticated;

-- Grants EXECUTE: fonctions safe pour authenticated
GRANT EXECUTE ON FUNCTION public.resolve_creator_code(TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.validate_order_affiliate(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_order_status(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_order_from_application(UUID, DECIMAL, TEXT, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.apply_to_offer(UUID, TEXT, DECIMAL, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_withdrawal(DECIMAL) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_seller_stats(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_agent_stats(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.generate_creator_code(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.export_user_data(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_account_deletion(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_rate_limit(TEXT, TEXT, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_audit_log(TEXT, TEXT, UUID, JSONB, JSONB) TO authenticated;

-- Fonctions sensibles: service_role uniquement
GRANT EXECUTE ON FUNCTION public.distribute_commissions(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.reverse_commissions(UUID, TEXT, DECIMAL) TO service_role;
GRANT EXECUTE ON FUNCTION public.record_ledger_entry(UUID, UUID, TEXT, UUID, TEXT, DECIMAL, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_platform_stats() TO service_role;
GRANT EXECUTE ON FUNCTION public.release_pending_revenues() TO service_role;
GRANT EXECUTE ON FUNCTION public.auto_complete_orders() TO service_role;
GRANT EXECUTE ON FUNCTION public.auto_cancel_expired_orders() TO service_role;
GRANT EXECUTE ON FUNCTION public.cleanup_old_data() TO service_role;
GRANT EXECUTE ON FUNCTION public.check_webhook_replay(TEXT, TEXT, TEXT) TO service_role;

-- ============================================================================
-- 25. SEED DATA (TAXONOMIE COMPLÈTE)
-- ============================================================================

DO $$ 
DECLARE
  v_design UUID; v_marketing UUID; v_redaction UUID; v_video UUID; v_audio UUID;
  v_dev UUID; v_data UUID; v_nocode UUID; v_ecom UUID; v_business UUID; v_coaching UUID;
  v_sc UUID;
BEGIN
  -- Design & Création visuelle
  INSERT INTO public.categories (name, slug, description, icon, sort_order, applicable_to) 
  VALUES ('Design & Création visuelle', 'design-creation-visuelle', 'Logos, branding, webdesign et art visuel.', 'palette', 1, ARRAY['freelance']) 
  RETURNING id INTO v_design;

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Logos & Identité de marque', 'logos-identite-marque', v_design, 'pen-tool', 1) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Logo minimaliste', 'logo-minimaliste', v_sc, 'circle', 1),
    ('Logo signature manuscrite', 'logo-signature', v_sc, 'edit-3', 2),
    ('Logo 3D', 'logo-3d', v_sc, 'box', 3),
    ('Refonte de logo', 'refonte-logo', v_sc, 'refresh-cw', 4);

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Branding & Charte graphique', 'branding-charte', v_design, 'book', 2) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Charte graphique complète', 'charte-complete', v_sc, 'layout', 1),
    ('Palette de couleurs & typographies', 'couleurs-typo', v_sc, 'droplet', 2);

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Webdesign & UI', 'webdesign-ui', v_design, 'monitor', 3) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Maquettes de site vitrine', 'maquettes-site', v_sc, 'browser', 1),
    ('Design de landing page', 'design-landing-page', v_sc, 'mouse-pointer', 2),
    ('Design de tableau de bord SaaS', 'design-dashboard', v_sc, 'sidebar', 3);

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Visuels réseaux sociaux', 'visuels-social', v_design, 'instagram', 4) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Templates Instagram / TikTok', 'templates-social', v_sc, 'image', 1),
    ('Miniatures YouTube', 'miniatures-youtube', v_sc, 'youtube', 2);

  -- Marketing digital & Acquisition
  INSERT INTO public.categories (name, slug, description, icon, sort_order, applicable_to) 
  VALUES ('Marketing digital & Acquisition', 'marketing-digital', 'Stratégies d''acquisition, SEO, SEA et growth.', 'trending-up', 2, ARRAY['freelance', 'influencer']) 
  RETURNING id INTO v_marketing;

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Publicité Meta / TikTok / Google', 'ads', v_marketing, 'target', 1) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Création de campagnes publicitaires', 'creation-campagnes', v_sc, 'plus-circle', 1),
    ('Optimisation & scaling de campagnes', 'optimisation-ads', v_sc, 'bar-chart-2', 2);

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Social Media Management', 'social-media', v_marketing, 'smartphone', 2) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Stratégie réseaux sociaux', 'strategie-social', v_sc, 'map-pin', 1),
    ('Community management', 'community-management', v_sc, 'message-circle', 2);

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('SEO & Contenu organique', 'seo', v_marketing, 'search', 3) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Audit SEO complet', 'audit-seo', v_sc, 'file-text', 1),
    ('Recherche de mots-clés', 'mots-cles', v_sc, 'key', 2);

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Marketing d''influence & UGC', 'influence-ugc', v_marketing, 'user-check', 4) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Campagne d''influence', 'campagne-influence', v_sc, 'star', 1),
    ('Brief créateur UGC', 'brief-ugc', v_sc, 'file', 2);

  -- Vidéo, Animation & UGC
  INSERT INTO public.categories (name, slug, description, icon, sort_order, applicable_to) 
  VALUES ('Vidéo, Animation & UGC', 'video-animation', 'Montage, motion design et contenus vidéo.', 'video', 3, ARRAY['freelance', 'influencer']) 
  RETURNING id INTO v_video;

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Montage vidéo', 'montage', v_video, 'scissors', 1) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Montage pour réseaux sociaux', 'montage-social', v_sc, 'smartphone', 1),
    ('Montage YouTube', 'montage-youtube', v_sc, 'youtube', 2);

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('UGC & contenus créateurs', 'ugc-contenus', v_video, 'user', 2) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Vidéos UGC produits', 'videos-ugc', v_sc, 'shopping-bag', 1),
    ('Témoignages clients vidéos', 'temoignages-video', v_sc, 'smile', 2);

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Motion design & animation', 'motion-design', v_video, 'film', 3) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Animations logo', 'animations-logo', v_sc, 'zap', 1),
    ('Vidéos explicatives animées', 'videos-explicatives', v_sc, 'info', 2);

  -- Audio, Musique & Voix off
  INSERT INTO public.categories (name, slug, description, icon, sort_order, applicable_to) 
  VALUES ('Audio, Musique & Voix off', 'audio-musique', 'Voix, mixage et production sonore.', 'music', 4, ARRAY['freelance']) 
  RETURNING id INTO v_audio;

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Voix off & narration', 'voix-off', v_audio, 'mic', 1) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Voix off publicitaire', 'voix-pub', v_sc, 'volume-2', 1),
    ('Voix off e-learning', 'voix-elearning', v_sc, 'book', 2);

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Podcasts & audio', 'podcasts', v_audio, 'headphones', 2) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Montage & mixage podcast', 'mixage-podcast', v_sc, 'sliders', 1),
    ('Jingles', 'jingles', v_sc, 'music', 2);

  -- Développement
  INSERT INTO public.categories (name, slug, description, icon, sort_order, applicable_to) 
  VALUES ('Développement Web & Mobile', 'developpement', 'Code, applications et sites web.', 'code', 5, ARRAY['freelance']) 
  RETURNING id INTO v_dev;

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Sites vitrines & blogs', 'sites-vitrines', v_dev, 'layout', 1) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Site vitrine sur mesure', 'site-sur-mesure', v_sc, 'monitor', 1),
    ('Intégration Figma → code', 'figma-code', v_sc, 'code', 2);

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Applications web & SaaS', 'apps-saas', v_dev, 'server', 2) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Développement back-end API', 'backend-api', v_sc, 'database', 1),
    ('Développement front-end SPA', 'frontend-spa', v_sc, 'chrome', 2);

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Applications mobiles', 'apps-mobiles', v_dev, 'smartphone', 3) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('App mobile cross-platform', 'app-cross-platform', v_sc, 'layers', 1);

  -- Data, IA & Automatisation
  INSERT INTO public.categories (name, slug, description, icon, sort_order, applicable_to) 
  VALUES ('Data, IA & Automatisation', 'data-ia', 'Intelligence artificielle, données et scripts.', 'cpu', 6, ARRAY['freelance']) 
  RETURNING id INTO v_data;

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Assistants IA & chatbots', 'chatbots', v_data, 'message-square', 1) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Création d''assistant IA', 'assistant-ia', v_sc, 'user', 1),
    ('Chatbot e-commerce', 'chatbot-ecom', v_sc, 'shopping-cart', 2);

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Tableaux de bord & analytics', 'data-analytics', v_data, 'bar-chart', 2) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Dashboard business (BI)', 'dashboard-bi', v_sc, 'pie-chart', 1);

  -- NoCode & Automatisation
  INSERT INTO public.categories (name, slug, description, icon, sort_order, applicable_to) 
  VALUES ('NoCode & Automatisation', 'nocode-saas', 'Création sans code et connecteurs.', 'zap', 7, ARRAY['freelance']) 
  RETURNING id INTO v_nocode;

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Sites NoCode', 'sites-nocode', v_nocode, 'layout', 1) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Site marketing sur Webflow', 'webflow', v_sc, 'monitor', 1);

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Automatisations workflow', 'automatisations', v_nocode, 'git-commit', 2) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Scénarios Zapier/Make', 'scenarios-auto', v_sc, 'zap', 1);

  -- E-commerce & Retail
  INSERT INTO public.categories (name, slug, description, icon, sort_order, applicable_to) 
  VALUES ('E-commerce & Retail', 'ecommerce-retail', 'Boutiques et marketplaces.', 'shopping-cart', 8, ARRAY['freelance']) 
  RETURNING id INTO v_ecom;

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Création de boutique', 'creation-boutique', v_ecom, 'shopping-bag', 1) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Boutique en ligne', 'boutique-ecom', v_sc, 'plus-square', 1),
    ('Optimisation fiches produits', 'opti-fiches', v_sc, 'tag', 2);

  -- Business, Finance & Opérations
  INSERT INTO public.categories (name, slug, description, icon, sort_order, applicable_to) 
  VALUES ('Business & Finance', 'business-finance', 'Gestion, juridique et stratégie.', 'briefcase', 9, ARRAY['freelance']) 
  RETURNING id INTO v_business;

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Stratégie & business plan', 'strategie', v_business, 'compass', 1) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Business plan complet', 'business-plan', v_sc, 'file-text', 1),
    ('Analyse de marché', 'analyse-marche', v_sc, 'bar-chart', 2);

  -- Coaching & Formation
  INSERT INTO public.categories (name, slug, description, icon, sort_order, applicable_to) 
  VALUES ('Coaching & Formation', 'coaching-formation', 'Accompagnement personnel et professionnel.', 'user-plus', 10, ARRAY['freelance', 'influencer']) 
  RETURNING id INTO v_coaching;

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Coaching business', 'coaching-business', v_coaching, 'briefcase', 1) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Coaching lancement d''activité', 'lancement-activite', v_sc, 'rocket', 1);

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Coaching créateurs', 'coaching-createurs', v_coaching, 'instagram', 2) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Coaching contenu & branding', 'coaching-contenu', v_sc, 'camera', 1);

  -- Rédaction & Traduction
  INSERT INTO public.categories (name, slug, description, icon, sort_order, applicable_to) 
  VALUES ('Rédaction & Traduction', 'redaction-traduction', 'Contenus textuels et copywriting.', 'edit-3', 11, ARRAY['freelance']) 
  RETURNING id INTO v_redaction;

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Rédaction web & blog', 'redaction-web', v_redaction, 'file-text', 1) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Articles de blog', 'articles-blog', v_sc, 'align-left', 1),
    ('Fiches produits e-commerce', 'fiches-produits', v_sc, 'shopping-bag', 2);

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Copywriting de vente', 'copywriting', v_redaction, 'dollar-sign', 2) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Pages de vente', 'copy-pages-vente', v_sc, 'monitor', 1),
    ('Emails de lancement', 'emails-lancement', v_sc, 'mail', 2);

  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES ('Traduction', 'traduction', v_redaction, 'globe', 3) RETURNING id INTO v_sc;
  INSERT INTO public.categories (name, slug, parent_id, icon, sort_order) VALUES 
    ('Traduction FR ↔ EN', 'trad-fr-en', v_sc, 'flag', 1);

END $$;

COMMIT;
