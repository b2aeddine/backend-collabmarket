-- ============================================================================
-- MARKETPLACE V23 - EXTENSION FREELANCE & AFFILIATION
-- ============================================================================
-- Dépendances : marketplace_v22_fixed.sql doit être exécuté avant.

BEGIN;

-- ============================================================================
-- 1. TABLES FREELANCE
-- ============================================================================

-- 1.1 Freelancer Details
CREATE TABLE IF NOT EXISTS public.freelancer_details (
  id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  display_name TEXT CHECK (LENGTH(display_name) <= 100),
  tagline TEXT CHECK (LENGTH(tagline) <= 200),
  description TEXT CHECK (LENGTH(description) <= 5000),
  skills TEXT[], -- Array of strings
  languages JSONB, -- [{code: "fr", level: "native"}]
  experience_years INTEGER CHECK (experience_years >= 0),
  education JSONB,
  certifications JSONB,
  hourly_rate DECIMAL(10,2) CHECK (hourly_rate > 0),
  is_available BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 1.2 Gig Categories
CREATE TABLE IF NOT EXISTS public.gig_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_id UUID REFERENCES public.gig_categories(id) ON DELETE SET NULL,
  name TEXT NOT NULL UNIQUE CHECK (LENGTH(name) <= 100),
  slug TEXT NOT NULL UNIQUE CHECK (LENGTH(slug) <= 100),
  description TEXT CHECK (LENGTH(description) <= 1000),
  sort_order INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 1.3 Gigs
CREATE TABLE IF NOT EXISTS public.gigs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  freelancer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  category_id UUID REFERENCES public.gig_categories(id) ON DELETE SET NULL,
  title TEXT NOT NULL CHECK (LENGTH(title) <= 200),
  slug TEXT NOT NULL UNIQUE CHECK (LENGTH(slug) <= 250),
  description TEXT NOT NULL CHECK (LENGTH(description) <= 10000),
  base_price DECIMAL(10,2) NOT NULL CHECK (base_price > 0),
  min_delivery_days INTEGER NOT NULL CHECK (min_delivery_days > 0),
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','paused','blocked')),
  rating_average DECIMAL(3,2) DEFAULT 0 CHECK (rating_average >= 0 AND rating_average <= 5),
  rating_count INTEGER DEFAULT 0 CHECK (rating_count >= 0),
  total_orders INTEGER DEFAULT 0 CHECK (total_orders >= 0),
  is_affiliable BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 1.4 Gig Packages
CREATE TABLE IF NOT EXISTS public.gig_packages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  name TEXT NOT NULL CHECK (name IN ('Basic','Standard','Premium')),
  description TEXT CHECK (LENGTH(description) <= 1000),
  price DECIMAL(10,2) NOT NULL CHECK (price > 0),
  delivery_days INTEGER NOT NULL CHECK (delivery_days > 0),
  revisions INTEGER DEFAULT 0 CHECK (revisions >= -1), -- -1 for unlimited
  features TEXT[],
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(gig_id, name)
);

-- 1.5 Gig Media
CREATE TABLE IF NOT EXISTS public.gig_media (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  media_type TEXT NOT NULL CHECK (media_type IN ('image','video')),
  url TEXT NOT NULL,
  thumbnail_url TEXT,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 1.6 Gig Reviews
CREATE TABLE IF NOT EXISTS public.gig_reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  reviewer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  freelancer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment TEXT CHECK (LENGTH(comment) <= 2000),
  response TEXT CHECK (LENGTH(response) <= 2000),
  response_at TIMESTAMPTZ,
  is_visible BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(order_id)
);

-- ============================================================================
-- 2. SYSTEME D'AFFILIATION (COLLABMARKET)
-- ============================================================================

-- 2.1 Collabmarket Listings (Opt-in affiliation)
CREATE TABLE IF NOT EXISTS public.collabmarket_listings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  freelancer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  is_active BOOLEAN DEFAULT TRUE,
  client_discount_rate DECIMAL(5,2) DEFAULT 0 CHECK (client_discount_rate >= 0 AND client_discount_rate <= 50),
  agent_commission_rate DECIMAL(5,2) NOT NULL CHECK (agent_commission_rate >= 0 AND agent_commission_rate <= 50),
  platform_fee_rate DECIMAL(5,2) NOT NULL DEFAULT 5.0 CHECK (platform_fee_rate >= 0 AND platform_fee_rate <= 20),
  platform_cut_on_agent_rate DECIMAL(5,2) NOT NULL DEFAULT 20.0 CHECK (platform_cut_on_agent_rate >= 0 AND platform_cut_on_agent_rate <= 50),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2.2 Affiliate Links
CREATE TABLE IF NOT EXISTS public.affiliate_links (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE CHECK (LENGTH(code) >= 4 AND LENGTH(code) <= 20),
  url_slug TEXT NOT NULL UNIQUE CHECK (LENGTH(url_slug) <= 100),
  listing_id UUID NOT NULL REFERENCES public.collabmarket_listings(id) ON DELETE CASCADE,
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  agent_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2.3 Affiliate Clicks
CREATE TABLE IF NOT EXISTS public.affiliate_clicks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  affiliate_link_id UUID NOT NULL REFERENCES public.affiliate_links(id) ON DELETE CASCADE,
  ip_address TEXT,
  user_agent TEXT,
  referer TEXT,
  clicked_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2.4 Affiliate Conversions
CREATE TABLE IF NOT EXISTS public.affiliate_conversions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  affiliate_link_id UUID NOT NULL REFERENCES public.affiliate_links(id) ON DELETE SET NULL,
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  agent_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE SET NULL,
  freelancer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  client_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  
  -- Snapshot des montants calculés
  base_price DECIMAL(10,2) NOT NULL,
  client_discount DECIMAL(10,2) NOT NULL DEFAULT 0,
  platform_fee DECIMAL(10,2) NOT NULL DEFAULT 0,
  agent_commission DECIMAL(10,2) NOT NULL DEFAULT 0,
  platform_cut_on_agent DECIMAL(10,2) NOT NULL DEFAULT 0,
  freelancer_net DECIMAL(10,2) NOT NULL DEFAULT 0,
  agent_net DECIMAL(10,2) NOT NULL DEFAULT 0,
  platform_revenue DECIMAL(10,2) NOT NULL DEFAULT 0,
  
  currency TEXT DEFAULT 'EUR',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(order_id)
);

-- ============================================================================
-- 3. LEDGER & REVENUS DEDIES
-- ============================================================================

-- 3.1 Ledger (Grand Livre)
CREATE TABLE IF NOT EXISTS public.ledger (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  type TEXT NOT NULL CHECK (type IN ('order_payment','affiliate_commission','platform_fee','withdrawal','refund','adjustment')),
  actor_type TEXT NOT NULL CHECK (actor_type IN ('freelancer','agent','platform','client')),
  actor_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  order_id UUID REFERENCES public.orders(id) ON DELETE SET NULL,
  gig_id UUID REFERENCES public.gigs(id) ON DELETE SET NULL,
  amount DECIMAL(10,2) NOT NULL, -- Peut être négatif pour un débit, ou utiliser direction
  currency TEXT NOT NULL DEFAULT 'EUR',
  direction TEXT NOT NULL CHECK (direction IN ('credit','debit')),
  metadata JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3.2 Revenus Spécifiques (Separation of Concerns)
CREATE TABLE IF NOT EXISTS public.freelancer_revenues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  freelancer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  order_id UUID REFERENCES public.orders(id) ON DELETE RESTRICT,
  source_type TEXT DEFAULT 'gig',
  amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','available','withdrawn','cancelled')),
  available_at TIMESTAMPTZ,
  withdrawn_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.agent_revenues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  order_id UUID REFERENCES public.orders(id) ON DELETE RESTRICT,
  affiliate_link_id UUID REFERENCES public.affiliate_links(id) ON DELETE SET NULL,
  amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','available','withdrawn','cancelled')),
  available_at TIMESTAMPTZ,
  withdrawn_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.platform_revenues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID REFERENCES public.orders(id) ON DELETE SET NULL,
  amount DECIMAL(10,2) NOT NULL,
  source TEXT NOT NULL, -- 'fee', 'commission_cut'
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================================
-- 4. MODIFICATION ORDERS
-- ============================================================================

ALTER TABLE public.orders 
  ADD COLUMN IF NOT EXISTS gig_id UUID REFERENCES public.gigs(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS gig_package_id UUID REFERENCES public.gig_packages(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS affiliate_link_id UUID REFERENCES public.affiliate_links(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS order_type TEXT NOT NULL DEFAULT 'influencer' CHECK (order_type IN ('influencer','freelance'));

-- ============================================================================
-- 5. INDEXES
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_gigs_freelancer ON public.gigs(freelancer_id);
CREATE INDEX IF NOT EXISTS idx_gigs_category ON public.gigs(category_id);
CREATE INDEX IF NOT EXISTS idx_gigs_status ON public.gigs(status);
CREATE INDEX IF NOT EXISTS idx_gigs_search ON public.gigs USING GIN (to_tsvector('french', title || ' ' || description));

CREATE INDEX IF NOT EXISTS idx_collab_listings_active ON public.collabmarket_listings(is_active, gig_id);
CREATE INDEX IF NOT EXISTS idx_affiliate_links_code ON public.affiliate_links(code);
CREATE INDEX IF NOT EXISTS idx_affiliate_links_agent ON public.affiliate_links(agent_id);

CREATE INDEX IF NOT EXISTS idx_ledger_actor ON public.ledger(actor_id, actor_type);
CREATE INDEX IF NOT EXISTS idx_ledger_order ON public.ledger(order_id);

-- ============================================================================
-- 6. RLS POLICIES
-- ============================================================================

ALTER TABLE public.freelancer_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gigs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_packages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_media ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.collabmarket_listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_clicks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_conversions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.freelancer_revenues ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_revenues ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_revenues ENABLE ROW LEVEL SECURITY;

-- Freelancer Details
CREATE POLICY "freelancer_details_read_public" ON public.freelancer_details FOR SELECT USING (true);
CREATE POLICY "freelancer_details_write_own" ON public.freelancer_details FOR ALL USING (id = auth.uid());

-- Gigs & Packages & Media
CREATE POLICY "gigs_read_public" ON public.gigs FOR SELECT USING (status = 'active' OR freelancer_id = auth.uid());
CREATE POLICY "gigs_write_own" ON public.gigs FOR ALL USING (freelancer_id = auth.uid());

CREATE POLICY "gig_packages_read_public" ON public.gig_packages FOR SELECT USING (true);
CREATE POLICY "gig_packages_write_own" ON public.gig_packages FOR ALL USING (EXISTS (SELECT 1 FROM public.gigs WHERE id = gig_id AND freelancer_id = auth.uid()));

CREATE POLICY "gig_media_read_public" ON public.gig_media FOR SELECT USING (true);
CREATE POLICY "gig_media_write_own" ON public.gig_media FOR ALL USING (EXISTS (SELECT 1 FROM public.gigs WHERE id = gig_id AND freelancer_id = auth.uid()));

-- Collabmarket Listings
CREATE POLICY "collab_listings_read_public" ON public.collabmarket_listings FOR SELECT USING (is_active = true OR freelancer_id = auth.uid());
CREATE POLICY "collab_listings_write_own" ON public.collabmarket_listings FOR ALL USING (freelancer_id = auth.uid());

-- Affiliate Links
CREATE POLICY "affiliate_links_read_own" ON public.affiliate_links FOR SELECT USING (agent_id = auth.uid() OR public.is_admin());
CREATE POLICY "affiliate_links_write_own" ON public.affiliate_links FOR ALL USING (agent_id = auth.uid());

-- Affiliate Conversions
CREATE POLICY "affiliate_conversions_read_participants" ON public.affiliate_conversions FOR SELECT USING (auth.uid() IN (agent_id, freelancer_id) OR public.is_admin());

-- Ledger & Revenues (Strict)
CREATE POLICY "ledger_read_admin" ON public.ledger FOR SELECT USING (public.is_admin());
CREATE POLICY "freelancer_revenues_read_own" ON public.freelancer_revenues FOR SELECT USING (freelancer_id = auth.uid() OR public.is_admin());
CREATE POLICY "agent_revenues_read_own" ON public.agent_revenues FOR SELECT USING (agent_id = auth.uid() OR public.is_admin());
CREATE POLICY "platform_revenues_read_admin" ON public.platform_revenues FOR SELECT USING (public.is_admin());

-- ============================================================================
-- 7. TRIGGERS UPDATED_AT
-- ============================================================================

CREATE TRIGGER trg_updated_at_freelancer_details BEFORE UPDATE ON public.freelancer_details FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trg_updated_at_gigs BEFORE UPDATE ON public.gigs FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trg_updated_at_collab_listings BEFORE UPDATE ON public.collabmarket_listings FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trg_updated_at_affiliate_links BEFORE UPDATE ON public.affiliate_links FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

COMMIT;
