-- ============================================================================
-- MARKETPLACE V25 FULL - PART 1: SCHEMA
-- ============================================================================
-- Ce script installe la structure complète de la base de données Collabmarket V25.
-- Il inclut : Marketplace Influenceurs, Marketplace Freelance, Affiliation, Ledger.

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

BEGIN;

-- 1. UTILITAIRES & CONFIG
CREATE OR REPLACE FUNCTION public.update_updated_at_column() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

CREATE OR REPLACE FUNCTION public.is_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid());
$$;

CREATE OR REPLACE FUNCTION public.is_service_role() RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN RETURN (current_user = 'postgres' OR COALESCE(current_setting('request.jwt.claims', true)::json->>'role', '') = 'service_role');
EXCEPTION WHEN OTHERS THEN RETURN FALSE; END;
$$;

-- 2. CORE USERS & PROFILES
CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'influenceur' CHECK (role IN ('influenceur', 'commercant', 'admin')),
  first_name TEXT CHECK (LENGTH(first_name) <= 100),
  last_name TEXT CHECK (LENGTH(last_name) <= 100),
  email_encrypted BYTEA,
  phone_encrypted BYTEA,
  city TEXT CHECK (LENGTH(city) <= 100),
  bio TEXT CHECK (LENGTH(bio) <= 2000),
  avatar_url TEXT CHECK (LENGTH(avatar_url) <= 500),
  is_verified BOOLEAN DEFAULT FALSE,
  profile_views INTEGER DEFAULT 0 CHECK (profile_views >= 0),
  profile_share_count INTEGER DEFAULT 0 CHECK (profile_share_count >= 0),
  stripe_account_id TEXT,
  stripe_customer_id TEXT,
  average_rating DECIMAL(3,2) DEFAULT 0 CHECK (average_rating >= 0 AND average_rating <= 5),
  total_reviews INTEGER DEFAULT 0 CHECK (total_reviews >= 0),
  completed_orders_count INTEGER DEFAULT 0 CHECK (completed_orders_count >= 0),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.admins (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  permissions JSONB DEFAULT '{"all": true}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.freelancer_details (
  id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  display_name TEXT CHECK (LENGTH(display_name) <= 100),
  tagline TEXT CHECK (LENGTH(tagline) <= 200),
  description TEXT CHECK (LENGTH(description) <= 5000),
  skills TEXT[], 
  languages JSONB, 
  experience_years INTEGER CHECK (experience_years >= 0),
  education JSONB,
  certifications JSONB,
  hourly_rate DECIMAL(10,2) CHECK (hourly_rate > 0),
  is_available BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. GIG SYSTEM (FREELANCE)
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

CREATE TABLE IF NOT EXISTS public.gig_packages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  name TEXT NOT NULL CHECK (name IN ('Basic','Standard','Premium')),
  description TEXT CHECK (LENGTH(description) <= 1000),
  price DECIMAL(10,2) NOT NULL CHECK (price > 0),
  delivery_days INTEGER NOT NULL CHECK (delivery_days > 0),
  revisions INTEGER DEFAULT 0 CHECK (revisions >= -1),
  features TEXT[],
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(gig_id, name)
);

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

CREATE TABLE IF NOT EXISTS public.gig_faqs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  question TEXT NOT NULL CHECK (LENGTH(question) <= 300),
  answer TEXT NOT NULL CHECK (LENGTH(answer) <= 1000),
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.gig_requirements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  question TEXT NOT NULL CHECK (LENGTH(question) <= 500),
  type TEXT NOT NULL DEFAULT 'text' CHECK (type IN ('text','file','multiple_choice')),
  is_required BOOLEAN DEFAULT TRUE,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.gig_tags (
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  tag TEXT NOT NULL CHECK (LENGTH(tag) <= 50),
  PRIMARY KEY (gig_id, tag)
);

-- 4. AFFILIATION SYSTEM
CREATE TABLE IF NOT EXISTS public.collabmarket_listings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  freelancer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  is_active BOOLEAN DEFAULT TRUE,
  client_discount_rate DECIMAL(5,2) DEFAULT 0 CHECK (client_discount_rate >= 0 AND client_discount_rate <= 50),
  agent_commission_rate DECIMAL(5,2) NOT NULL CHECK (agent_commission_rate >= 0 AND agent_commission_rate <= 30),
  platform_fee_rate DECIMAL(5,2) NOT NULL DEFAULT 5.0 CHECK (platform_fee_rate >= 0 AND platform_fee_rate <= 15),
  platform_cut_on_agent_rate DECIMAL(5,2) NOT NULL DEFAULT 20.0 CHECK (platform_cut_on_agent_rate >= 0 AND platform_cut_on_agent_rate <= 50),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

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

CREATE TABLE IF NOT EXISTS public.affiliate_clicks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  affiliate_link_id UUID NOT NULL REFERENCES public.affiliate_links(id) ON DELETE CASCADE,
  ip_address TEXT,
  user_agent TEXT,
  referer TEXT,
  clicked_at TIMESTAMPTZ DEFAULT NOW()
);

-- 5. ORDERS & TRANSACTIONS
CREATE TABLE IF NOT EXISTS public.offers ( -- Legacy/Influencer Offers
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  price DECIMAL(10,2) NOT NULL,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  
  -- Polymorphic References
  offer_id UUID REFERENCES public.offers(id) ON DELETE SET NULL,
  gig_id UUID REFERENCES public.gigs(id) ON DELETE SET NULL,
  gig_package_id UUID REFERENCES public.gig_packages(id) ON DELETE SET NULL,
  affiliate_link_id UUID REFERENCES public.affiliate_links(id) ON DELETE SET NULL,
  
  order_type TEXT NOT NULL CHECK (order_type IN ('influencer_offer', 'freelance_gig')),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','payment_authorized','accepted','in_progress','submitted','review_pending','completed','finished','cancelled','disputed')),
  
  total_amount DECIMAL(10,2) NOT NULL CHECK (total_amount > 0), -- Paid by client
  net_amount DECIMAL(10,2) NOT NULL CHECK (net_amount > 0), -- Base amount (Package Price)
  
  requirements TEXT,
  delivery_url TEXT CHECK (delivery_url IS NULL OR delivery_url ~* '^https?://'),
  
  stripe_payment_intent_id TEXT,
  stripe_checkout_session_id TEXT,
  stripe_payment_status TEXT DEFAULT 'unpaid' CHECK (stripe_payment_status IN ('unpaid','requires_capture','requires_action','captured','succeeded','canceled','refunded')),
  
  refund_status TEXT DEFAULT 'none' CHECK (refund_status IN ('none','partial','full')),
  refund_amount DECIMAL(10,2) DEFAULT 0,
  refunded_at TIMESTAMPTZ,
  
  payment_authorized_at TIMESTAMPTZ,
  accepted_at TIMESTAMPTZ,
  submitted_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ,
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.affiliate_conversions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  affiliate_link_id UUID NOT NULL REFERENCES public.affiliate_links(id) ON DELETE SET NULL,
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  agent_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE SET NULL,
  freelancer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  client_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  
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

-- 6. FINANCE (LEDGER & REVENUES)
CREATE TABLE IF NOT EXISTS public.ledger (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  type TEXT NOT NULL CHECK (type IN ('order_payment','affiliate_commission','platform_fee','withdrawal','refund','adjustment')),
  actor_type TEXT NOT NULL CHECK (actor_type IN ('freelancer','agent','platform','client')),
  actor_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  order_id UUID REFERENCES public.orders(id) ON DELETE SET NULL,
  gig_id UUID REFERENCES public.gigs(id) ON DELETE SET NULL,
  amount DECIMAL(10,2) NOT NULL,
  currency TEXT NOT NULL DEFAULT 'EUR',
  direction TEXT NOT NULL CHECK (direction IN ('credit','debit')),
  metadata JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.freelancer_revenues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  freelancer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  order_id UUID REFERENCES public.orders(id) ON DELETE RESTRICT,
  source_type TEXT DEFAULT 'gig',
  amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','available','withdrawn','cancelled')),
  locked BOOLEAN DEFAULT FALSE,
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
  locked BOOLEAN DEFAULT FALSE,
  available_at TIMESTAMPTZ,
  withdrawn_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.platform_revenues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID REFERENCES public.orders(id) ON DELETE SET NULL,
  amount DECIMAL(10,2) NOT NULL,
  source TEXT NOT NULL,
  locked BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.withdrawals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT, -- Shared for Freelancer & Agent
  amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','processing','completed','failed','cancelled')),
  stripe_transfer_id TEXT,
  stripe_payout_id TEXT,
  failure_reason TEXT,
  processed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 7. REVIEWS & MESSAGING
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

CREATE TABLE IF NOT EXISTS public.conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  participant_1_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  participant_2_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  last_message_at TIMESTAMPTZ DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  CHECK (participant_1_id != participant_2_id)
);

CREATE TABLE IF NOT EXISTS public.messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  sender_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  receiver_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  is_read BOOLEAN DEFAULT FALSE,
  read_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  type TEXT NOT NULL,
  title TEXT NOT NULL,
  content TEXT NOT NULL,
  is_read BOOLEAN DEFAULT FALSE,
  read_at TIMESTAMPTZ,
  related_type TEXT,
  related_id UUID,
  action_url TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.system_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type TEXT NOT NULL,
  message TEXT,
  details JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.payment_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stripe_payment_intent_id TEXT,
  event_type TEXT NOT NULL,
  event_data JSONB,
  order_id UUID,
  processed BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 8. INDEXES
CREATE INDEX idx_profiles_role ON public.profiles(role);
CREATE INDEX idx_gigs_freelancer ON public.gigs(freelancer_id);
CREATE INDEX idx_gigs_status ON public.gigs(status);
CREATE INDEX idx_gigs_search ON public.gigs USING GIN (to_tsvector('french', title || ' ' || description));
CREATE INDEX idx_collab_listings_active ON public.collabmarket_listings(is_active, gig_id);
CREATE INDEX idx_affiliate_links_code ON public.affiliate_links(code);
CREATE INDEX idx_orders_merchant ON public.orders(merchant_id);
CREATE INDEX idx_orders_influencer ON public.orders(influencer_id);
CREATE INDEX idx_orders_status ON public.orders(status);
CREATE INDEX idx_ledger_actor ON public.ledger(actor_id, actor_type);
CREATE INDEX idx_ledger_order ON public.ledger(order_id);
CREATE UNIQUE INDEX idx_payment_logs_idempotency ON public.payment_logs(stripe_payment_intent_id, event_type);

COMMIT;
