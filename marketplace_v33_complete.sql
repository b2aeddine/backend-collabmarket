-- ============================================================================
-- MARKETPLACE V28.2 FINAL - CAPABILITY ARCHITECTURE (SECURITY HARDENED)
-- ============================================================================
-- Base: V28 Final
-- Changes V28.2:
-- 1. RLS Hardening (Capability checks on revenues, details, links)
-- 2. Renamed freelancer_details -> seller_details
-- 3. Secured affiliate_conversions & platform_revenues (FORCE RLS)
-- 4. Frozen critical order fields (merchant_id, seller_id, total_amount)
-- 5. Added create_offer & generate_affiliate_link RPCs with auto-capability

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

BEGIN;

-- 1. UTILS & CONFIG
CREATE OR REPLACE FUNCTION public.update_updated_at_column() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

-- 2. CORE USERS & PROFILES
CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'influenceur', -- DEPRECATED: DO NOT USE. Replaced by user_capabilities.
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

-- CAPABILITIES
CREATE TABLE IF NOT EXISTS public.user_capabilities (
  user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
  capability TEXT NOT NULL CHECK (capability IN ('buyer', 'seller', 'agent', 'affiliate', 'admin')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (user_id, capability)
);

-- SELLER DETAILS (Renamed from freelancer_details)
CREATE TABLE IF NOT EXISTS public.seller_details (
  id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE, -- Linked to seller_id
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

-- 3. SECURITY TABLES
CREATE TABLE IF NOT EXISTS public.api_rate_limits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  endpoint TEXT NOT NULL,
  request_count INTEGER DEFAULT 1,
  last_request_at TIMESTAMPTZ DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id, endpoint)
);

-- 4. GIG SYSTEM (SELLER)
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
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
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

-- 5. AFFILIATION SYSTEM
CREATE TABLE IF NOT EXISTS public.collabmarket_listings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
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

-- 6. ORDERS & TRANSACTIONS
CREATE TABLE IF NOT EXISTS public.offers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  price DECIMAL(10,2) NOT NULL,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT, -- Buyer
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT, -- Seller
  
  -- Polymorphic References
  offer_id UUID REFERENCES public.offers(id) ON DELETE SET NULL,
  gig_id UUID REFERENCES public.gigs(id) ON DELETE SET NULL,
  gig_package_id UUID REFERENCES public.gig_packages(id) ON DELETE SET NULL,
  affiliate_link_id UUID REFERENCES public.affiliate_links(id) ON DELETE SET NULL,
  
  order_type TEXT NOT NULL CHECK (order_type IN ('influencer_offer', 'freelance_gig')),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','payment_authorized','accepted','in_progress','submitted','review_pending','completed','finished','cancelled','disputed')),
  
  total_amount DECIMAL(10,2) NOT NULL CHECK (total_amount > 0),
  net_amount DECIMAL(10,2) NOT NULL CHECK (net_amount > 0),
  
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
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  client_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  
  base_price DECIMAL(10,2) NOT NULL,
  client_discount DECIMAL(10,2) NOT NULL DEFAULT 0,
  platform_fee DECIMAL(10,2) NOT NULL DEFAULT 0,
  agent_commission DECIMAL(10,2) NOT NULL DEFAULT 0,
  platform_cut_on_agent DECIMAL(10,2) NOT NULL DEFAULT 0,
  seller_net DECIMAL(10,2) NOT NULL DEFAULT 0, -- Renamed from freelancer_net
  agent_net DECIMAL(10,2) NOT NULL DEFAULT 0,
  platform_revenue DECIMAL(10,2) NOT NULL DEFAULT 0,
  
  currency TEXT DEFAULT 'EUR',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(order_id)
);

-- 7. FINANCE (LEDGER & REVENUES)
CREATE TABLE IF NOT EXISTS public.ledger (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  type TEXT NOT NULL CHECK (type IN ('order_payment','affiliate_commission','platform_fee','withdrawal','refund','adjustment')),
  actor_type TEXT NOT NULL CHECK (actor_type IN ('seller','agent','platform','client')),
  actor_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  order_id UUID REFERENCES public.orders(id) ON DELETE SET NULL,
  gig_id UUID REFERENCES public.gigs(id) ON DELETE SET NULL,
  amount DECIMAL(10,2) NOT NULL,
  currency TEXT NOT NULL DEFAULT 'EUR',
  direction TEXT NOT NULL CHECK (direction IN ('credit','debit')),
  metadata JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.seller_revenues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
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
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','processing','completed','failed','cancelled')),
  stripe_transfer_id TEXT,
  stripe_payout_id TEXT,
  failure_reason TEXT,
  processed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 8. REVIEWS & MESSAGING
CREATE TABLE IF NOT EXISTS public.gig_reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  reviewer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
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

-- 9. INDEXES
CREATE INDEX idx_profiles_role ON public.profiles(role);
CREATE INDEX idx_gigs_seller ON public.gigs(seller_id);
CREATE INDEX idx_gigs_status ON public.gigs(status);
CREATE INDEX idx_gigs_search ON public.gigs USING GIN (to_tsvector('french', title || ' ' || description));
CREATE INDEX idx_collab_listings_active ON public.collabmarket_listings(is_active, gig_id);
CREATE INDEX idx_affiliate_links_code ON public.affiliate_links(code);
CREATE INDEX idx_orders_merchant ON public.orders(merchant_id);
CREATE INDEX idx_orders_seller ON public.orders(seller_id);
CREATE INDEX idx_orders_status ON public.orders(status);
CREATE INDEX idx_ledger_actor ON public.ledger(actor_id, actor_type);
CREATE INDEX idx_ledger_order ON public.ledger(order_id);
CREATE UNIQUE INDEX idx_payment_logs_idempotency ON public.payment_logs(stripe_payment_intent_id, event_type);
CREATE INDEX idx_rate_limits_user_endpoint ON public.api_rate_limits(user_id, endpoint);
CREATE INDEX idx_user_capabilities_user ON public.user_capabilities(user_id);

-- ============================================================================
-- FUNCTIONS
-- ============================================================================

-- 1. UTILS & SECURITY
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.profiles (id, role, first_name, email_encrypted)
  VALUES (NEW.id, 'influenceur', 'New User', NULL);
  
  -- AUTO-ASSIGN BUYER CAPABILITY
  INSERT INTO public.user_capabilities (user_id, capability)
  VALUES (NEW.id, 'buyer')
  ON CONFLICT DO NOTHING;
  
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.is_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid());
$$;

CREATE OR REPLACE FUNCTION public.is_service_role() RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN RETURN (current_user = 'postgres' OR COALESCE(current_setting('request.jwt.claims', true)::json->>'role', '') = 'service_role');
EXCEPTION WHEN OTHERS THEN RETURN FALSE; END;
$$;

-- RATE LIMITING FUNCTION
CREATE OR REPLACE FUNCTION public.apply_rate_limit(p_endpoint TEXT, p_limit INTEGER DEFAULT 10, p_window_seconds INTEGER DEFAULT 60)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_count INTEGER;
BEGIN
  IF v_user_id IS NULL THEN RETURN; END IF;

  INSERT INTO public.api_rate_limits (user_id, endpoint, request_count, last_request_at)
  VALUES (v_user_id, p_endpoint, 1, NOW())
  ON CONFLICT (user_id, endpoint)
  DO UPDATE SET
    request_count = CASE
      WHEN public.api_rate_limits.last_request_at < NOW() - (p_window_seconds || ' seconds')::INTERVAL THEN 1
      ELSE public.api_rate_limits.request_count + 1
    END,
    last_request_at = NOW()
  RETURNING request_count INTO v_count;

  IF v_count > p_limit THEN
    RAISE EXCEPTION 'Rate limit exceeded for endpoint %', p_endpoint;
  END IF;
END;
$$;

-- SECURE ENCRYPTION KEY CHECK
CREATE OR REPLACE FUNCTION public.get_encryption_key()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_key TEXT;
BEGIN
  v_key := current_setting('app.encryption_key', true);
  IF v_key IS NULL OR LENGTH(v_key) < 32 THEN
    RAISE EXCEPTION 'CRITICAL: app.encryption_key not set or too short (min 32 chars). Security risk.';
  END IF;
  RETURN v_key;
END;
$$;

-- 2. GIG RPCs
CREATE OR REPLACE FUNCTION public.create_complete_gig(
  p_gig JSONB,
  p_packages JSONB[],
  p_media JSONB[],
  p_affiliate_config JSONB DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_gig_id UUID;
  v_pkg JSONB;
  v_med JSONB;
BEGIN
  PERFORM public.apply_rate_limit('create_complete_gig', 5, 3600);

  INSERT INTO public.gigs (
    seller_id, category_id, title, slug, description, base_price, min_delivery_days, status, is_affiliable
  ) VALUES (
    auth.uid(),
    (p_gig->>'category_id')::UUID,
    p_gig->>'title',
    p_gig->>'slug',
    p_gig->>'description',
    (p_gig->>'base_price')::DECIMAL,
    (p_gig->>'min_delivery_days')::INT,
    COALESCE(p_gig->>'status', 'draft'),
    COALESCE((p_gig->>'is_affiliable')::BOOLEAN, false)
  ) RETURNING id INTO v_gig_id;

  -- AUTO-ASSIGN SELLER CAPABILITY
  INSERT INTO public.user_capabilities (user_id, capability)
  VALUES (auth.uid(), 'seller')
  ON CONFLICT DO NOTHING;

  FOREACH v_pkg IN ARRAY p_packages
  LOOP
    INSERT INTO public.gig_packages (
      gig_id, name, description, price, delivery_days, revisions, features
    ) VALUES (
      v_gig_id,
      v_pkg->>'name',
      v_pkg->>'description',
      (v_pkg->>'price')::DECIMAL,
      (v_pkg->>'delivery_days')::INT,
      (v_pkg->>'revisions')::INT,
      ARRAY(SELECT jsonb_array_elements_text(v_pkg->'features'))
    );
  END LOOP;

  FOREACH v_med IN ARRAY p_media
  LOOP
    INSERT INTO public.gig_media (
      gig_id, media_type, url, thumbnail_url, sort_order
    ) VALUES (
      v_gig_id,
      v_med->>'media_type',
      v_med->>'url',
      v_med->>'thumbnail_url',
      (v_med->>'sort_order')::INT
    );
  END LOOP;

  IF p_affiliate_config IS NOT NULL AND (p_gig->>'is_affiliable')::BOOLEAN THEN
    INSERT INTO public.collabmarket_listings (
      gig_id, seller_id, client_discount_rate, agent_commission_rate, platform_fee_rate, platform_cut_on_agent_rate
    ) VALUES (
      v_gig_id,
      auth.uid(),
      (p_affiliate_config->>'client_discount_rate')::DECIMAL,
      (p_affiliate_config->>'agent_commission_rate')::DECIMAL,
      COALESCE((p_affiliate_config->>'platform_fee_rate')::DECIMAL, 5.0),
      COALESCE((p_affiliate_config->>'platform_cut_on_agent_rate')::DECIMAL, 20.0)
    );
  END IF;

  RETURN v_gig_id;
END;
$$;

-- NEW: CREATE OFFER RPC
CREATE OR REPLACE FUNCTION public.create_offer(
  p_title TEXT,
  p_price DECIMAL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_id UUID;
BEGIN
  IF p_price <= 0 THEN
    RAISE EXCEPTION 'Price must be greater than zero';
  END IF;

  INSERT INTO public.offers (seller_id, title, price)
  VALUES (auth.uid(), p_title, p_price)
  RETURNING id INTO v_id;

  INSERT INTO public.user_capabilities (user_id, capability)
  VALUES (auth.uid(), 'seller')
  ON CONFLICT DO NOTHING;

  RETURN v_id;
END;
$$;

-- NEW: GENERATE AFFILIATE LINK RPC
CREATE OR REPLACE FUNCTION public.generate_affiliate_link(
  p_listing_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_id UUID;
  v_code TEXT := substr(encode(gen_random_bytes(4), 'hex'), 1, 8);
BEGIN
  INSERT INTO public.affiliate_links (listing_id, gig_id, agent_id, code, url_slug)
  SELECT l.id, l.gig_id, auth.uid(), v_code, v_code
  FROM public.collabmarket_listings l
  WHERE l.id = p_listing_id
  RETURNING id INTO v_id;

  INSERT INTO public.user_capabilities (user_id, capability)
  VALUES (auth.uid(), 'agent')
  ON CONFLICT DO NOTHING;

  RETURN v_id;
END;
$$;





-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- 0. AUTO ASSIGN SELLER CAPABILITY
CREATE OR REPLACE FUNCTION public.trg_auto_assign_seller_capability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.user_capabilities (user_id, capability)
  VALUES (NEW.seller_id, 'seller')
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_offer_assign_seller_cap AFTER INSERT ON public.offers FOR EACH ROW EXECUTE FUNCTION public.trg_auto_assign_seller_capability();
CREATE TRIGGER trg_gig_assign_seller_cap AFTER INSERT ON public.gigs FOR EACH ROW EXECUTE FUNCTION public.trg_auto_assign_seller_capability();

-- 1. SYNC STRIPE STATUS TO ORDER
CREATE OR REPLACE FUNCTION public.sync_stripe_status_to_order() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.stripe_payment_status = 'requires_capture' AND OLD.stripe_payment_status != 'requires_capture' AND NEW.status = 'pending' THEN
    NEW.status := 'payment_authorized';
    NEW.payment_authorized_at := NOW();
  ELSIF NEW.stripe_payment_status IN ('captured', 'succeeded') AND OLD.stripe_payment_status NOT IN ('captured', 'succeeded') THEN
    IF NEW.status = 'pending' THEN
       NEW.status := 'payment_authorized';
       NEW.payment_authorized_at := NOW();
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_sync_stripe_status BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.sync_stripe_status_to_order();

-- 2. VALIDATE ORDER INTEGRITY & FREEZE CRITICAL FIELDS
CREATE OR REPLACE FUNCTION public.validate_order_integrity_and_freeze() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_gig_status TEXT;
  v_listing_active BOOLEAN;
BEGIN
  -- Freeze Checks
  IF TG_OP = 'UPDATE' THEN
    IF NEW.merchant_id IS DISTINCT FROM OLD.merchant_id THEN RAISE EXCEPTION 'merchant_id is immutable'; END IF;
    IF NEW.seller_id IS DISTINCT FROM OLD.seller_id THEN RAISE EXCEPTION 'seller_id is immutable'; END IF;
    IF NEW.total_amount IS DISTINCT FROM OLD.total_amount THEN RAISE EXCEPTION 'total_amount is immutable'; END IF;
  END IF;

  -- Integrity Checks
  IF NEW.order_type = 'freelance_gig' AND TG_OP = 'INSERT' THEN
    SELECT status INTO v_gig_status FROM public.gigs WHERE id = NEW.gig_id;
    IF v_gig_status != 'active' THEN RAISE EXCEPTION 'Gig is not active'; END IF;
    IF NEW.affiliate_link_id IS NOT NULL THEN
       SELECT is_active INTO v_listing_active FROM public.collabmarket_listings 
       WHERE id = (SELECT listing_id FROM public.affiliate_links WHERE id = NEW.affiliate_link_id);
       IF v_listing_active IS NOT TRUE THEN RAISE EXCEPTION 'Affiliate listing is not active'; END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_validate_order_integrity BEFORE INSERT OR UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.validate_order_integrity_and_freeze();

-- 3. PREVENT FINANCIAL MODIFICATION
CREATE OR REPLACE FUNCTION public.prevent_financial_field_update() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF (OLD.agent_commission_rate != NEW.agent_commission_rate OR OLD.client_discount_rate != NEW.client_discount_rate) THEN
    IF EXISTS (
      SELECT 1 FROM public.affiliate_conversions ac
      JOIN public.affiliate_links al ON ac.affiliate_link_id = al.id
      WHERE al.listing_id = OLD.id
    ) THEN
       RAISE EXCEPTION 'Cannot modify commission rates after sales have occurred. Deactivate and create a new listing.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_prevent_financial_update BEFORE UPDATE ON public.collabmarket_listings FOR EACH ROW EXECUTE FUNCTION public.prevent_financial_field_update();

-- 4. IMMUTABLE LEDGER
CREATE OR REPLACE FUNCTION public.prevent_ledger_modification() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Ledger is immutable'; END;
$$;
CREATE TRIGGER trg_ledger_immutable BEFORE UPDATE OR DELETE ON public.ledger FOR EACH ROW EXECUTE FUNCTION public.prevent_ledger_modification();

-- 5. LOCKED REVENUES
CREATE OR REPLACE FUNCTION public.prevent_revenue_modification() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.locked = TRUE THEN RAISE EXCEPTION 'Cannot modify locked revenue entry'; END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_lock_seller_revenues BEFORE UPDATE OR DELETE ON public.seller_revenues FOR EACH ROW EXECUTE FUNCTION public.prevent_revenue_modification();
CREATE TRIGGER trg_lock_agent_revenues BEFORE UPDATE OR DELETE ON public.agent_revenues FOR EACH ROW EXECUTE FUNCTION public.prevent_revenue_modification();
CREATE TRIGGER trg_lock_platform_revenues BEFORE UPDATE OR DELETE ON public.platform_revenues FOR EACH ROW EXECUTE FUNCTION public.prevent_revenue_modification();

-- 6. TIMESTAMP UPDATES
CREATE TRIGGER update_profiles_updated_at BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_seller_details_updated_at BEFORE UPDATE ON public.seller_details FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_gigs_updated_at BEFORE UPDATE ON public.gigs FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_gig_packages_updated_at BEFORE UPDATE ON public.gig_packages FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_listings_updated_at BEFORE UPDATE ON public.collabmarket_listings FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_orders_updated_at BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================================================
-- RLS (SECURITY)
-- ============================================================================

-- 1. ENABLE RLS
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_capabilities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.seller_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gigs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_packages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_media ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_faqs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_requirements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.collabmarket_listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_clicks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_conversions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.seller_revenues ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_revenues ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_revenues ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.withdrawals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.api_rate_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.offers ENABLE ROW LEVEL SECURITY;

-- FORCE RLS (CRITICAL)
ALTER TABLE public.platform_revenues FORCE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_conversions FORCE ROW LEVEL SECURITY;

-- 2. POLICIES

-- PROFILES (Private + View)
CREATE POLICY "Users see own private profile" ON public.profiles FOR SELECT USING (auth.uid() = id);
CREATE POLICY "Users can insert their own profile" ON public.profiles FOR INSERT WITH CHECK (auth.uid() = id);
CREATE POLICY "Users can update own profile" ON public.profiles FOR UPDATE USING (auth.uid() = id);

-- ADMINS
CREATE POLICY "Admins viewable by admins" ON public.admins FOR SELECT USING (public.is_admin());

-- CAPABILITIES
CREATE POLICY "Users view own capabilities" ON public.user_capabilities FOR SELECT USING (auth.uid() = user_id);

-- SELLER DETAILS (Public Read, Seller Update)
CREATE POLICY "Public seller details" ON public.seller_details FOR SELECT USING (true);
CREATE POLICY "Sellers update own seller_details" ON public.seller_details FOR ALL USING (
  auth.uid() = id
  AND EXISTS (SELECT 1 FROM public.user_capabilities WHERE user_id = auth.uid() AND capability = 'seller')
);

-- API RATE LIMITS
CREATE POLICY "Users view own limits" ON public.api_rate_limits FOR SELECT USING (auth.uid() = user_id);

-- GIGS (Seller Owned + Capability Check)
CREATE POLICY "Public active gigs" ON public.gigs FOR SELECT USING (status = 'active' OR auth.uid() = seller_id);
CREATE POLICY "Sellers manage own gigs" ON public.gigs FOR ALL USING (
  auth.uid() = seller_id 
  AND EXISTS (SELECT 1 FROM public.user_capabilities WHERE user_id = auth.uid() AND capability = 'seller')
);

-- GIG PACKAGES/MEDIA/FAQS/REQS/TAGS
CREATE POLICY "Public gig components" ON public.gig_packages FOR SELECT USING (true);
CREATE POLICY "Sellers manage packages" ON public.gig_packages FOR ALL USING (
  EXISTS (SELECT 1 FROM public.gigs WHERE id = gig_id AND seller_id = auth.uid())
  AND EXISTS (SELECT 1 FROM public.user_capabilities WHERE user_id = auth.uid() AND capability = 'seller')
);

CREATE POLICY "Public gig media" ON public.gig_media FOR SELECT USING (true);
CREATE POLICY "Sellers manage media" ON public.gig_media FOR ALL USING (
  EXISTS (SELECT 1 FROM public.gigs WHERE id = gig_id AND seller_id = auth.uid())
  AND EXISTS (SELECT 1 FROM public.user_capabilities WHERE user_id = auth.uid() AND capability = 'seller')
);

CREATE POLICY "Public gig faqs" ON public.gig_faqs FOR SELECT USING (true);
CREATE POLICY "Sellers manage faqs" ON public.gig_faqs FOR ALL USING (
  EXISTS (SELECT 1 FROM public.gigs WHERE id = gig_id AND seller_id = auth.uid())
  AND EXISTS (SELECT 1 FROM public.user_capabilities WHERE user_id = auth.uid() AND capability = 'seller')
);

CREATE POLICY "Public gig reqs" ON public.gig_requirements FOR SELECT USING (true);
CREATE POLICY "Sellers manage reqs" ON public.gig_requirements FOR ALL USING (
  EXISTS (SELECT 1 FROM public.gigs WHERE id = gig_id AND seller_id = auth.uid())
  AND EXISTS (SELECT 1 FROM public.user_capabilities WHERE user_id = auth.uid() AND capability = 'seller')
);

CREATE POLICY "Public gig tags" ON public.gig_tags FOR SELECT USING (true);
CREATE POLICY "Sellers manage tags" ON public.gig_tags FOR ALL USING (
  EXISTS (SELECT 1 FROM public.gigs WHERE id = gig_id AND seller_id = auth.uid())
  AND EXISTS (SELECT 1 FROM public.user_capabilities WHERE user_id = auth.uid() AND capability = 'seller')
);

-- OFFERS
CREATE POLICY "Public active offers" ON public.offers FOR SELECT USING (is_active = TRUE);
CREATE POLICY "Sellers manage their offers" ON public.offers FOR ALL USING (
    auth.uid() = seller_id
    AND EXISTS (SELECT 1 FROM public.user_capabilities WHERE user_id = auth.uid() AND capability = 'seller')
);

-- COLLABMARKET LISTINGS
CREATE POLICY "Public active listings" ON public.collabmarket_listings FOR SELECT USING (is_active = true OR auth.uid() = seller_id);
CREATE POLICY "Sellers manage listings" ON public.collabmarket_listings FOR ALL USING (
  auth.uid() = seller_id
  AND EXISTS (SELECT 1 FROM public.user_capabilities WHERE user_id = auth.uid() AND capability = 'seller')
);

-- AFFILIATE LINKS
CREATE POLICY "Public affiliate links" ON public.affiliate_links FOR SELECT USING (true);
CREATE POLICY "Agents manage own links" ON public.affiliate_links FOR ALL USING (
  auth.uid() = agent_id
  AND EXISTS (SELECT 1 FROM public.user_capabilities WHERE user_id = auth.uid() AND capability = 'agent')
);

-- AFFILIATE CLICKS
CREATE POLICY "Public insert clicks" ON public.affiliate_clicks FOR INSERT WITH CHECK (true);
CREATE POLICY "Agents view own clicks" ON public.affiliate_clicks FOR SELECT USING (EXISTS (SELECT 1 FROM public.affiliate_links WHERE id = affiliate_link_id AND agent_id = auth.uid()));

-- AFFILIATE CONVERSIONS (Strict)
CREATE POLICY "Agents & Sellers view related conversions" ON public.affiliate_conversions FOR SELECT USING (
  auth.uid() = seller_id 
  OR auth.uid() = agent_id
  OR public.is_admin()
);

-- ORDERS (Buyer or Seller)
CREATE POLICY "Users view own orders" ON public.orders FOR SELECT USING (auth.uid() = merchant_id OR auth.uid() = seller_id);
CREATE POLICY "Users create orders" ON public.orders FOR INSERT WITH CHECK (auth.uid() = merchant_id);
CREATE POLICY "Users update own orders" ON public.orders FOR UPDATE USING (auth.uid() = merchant_id OR auth.uid() = seller_id);

-- LEDGER (Strict)
CREATE POLICY "Admins view ledger" ON public.ledger FOR SELECT USING (public.is_admin());

-- REVENUES
CREATE POLICY "Sellers view own revenues" ON public.seller_revenues FOR SELECT USING (
  auth.uid() = seller_id
  AND EXISTS (SELECT 1 FROM public.user_capabilities WHERE user_id = auth.uid() AND capability = 'seller')
);
CREATE POLICY "Agents view own revenues" ON public.agent_revenues FOR SELECT USING (
  auth.uid() = agent_id
  AND EXISTS (SELECT 1 FROM public.user_capabilities WHERE user_id = auth.uid() AND capability = 'agent')
);
CREATE POLICY "Admins view platform revenues" ON public.platform_revenues FOR SELECT USING (public.is_admin());

-- WITHDRAWALS
CREATE POLICY "Users view own withdrawals" ON public.withdrawals FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users create withdrawals" ON public.withdrawals FOR INSERT WITH CHECK (auth.uid() = user_id);

-- REVIEWS
CREATE POLICY "Public reviews" ON public.gig_reviews FOR SELECT USING (is_visible = true);
CREATE POLICY "Users create reviews" ON public.gig_reviews FOR INSERT WITH CHECK (auth.uid() = reviewer_id);

-- CONVERSATIONS
CREATE POLICY "Users read own conversations"
ON public.conversations
FOR SELECT USING (
  auth.uid() = participant_1_id OR auth.uid() = participant_2_id
);

-- MESSAGES
CREATE POLICY "Users send messages"
ON public.messages
FOR INSERT WITH CHECK (auth.uid() = sender_id);

CREATE POLICY "Users read own messages"
ON public.messages
FOR SELECT USING (auth.uid() = sender_id OR auth.uid() = receiver_id);

-- SELLER DETAILS (Insert)
CREATE POLICY "Sellers create seller_details"
ON public.seller_details
FOR INSERT WITH CHECK (
  auth.uid() = id AND
  EXISTS (
    SELECT 1 FROM public.user_capabilities
    WHERE user_id = auth.uid() AND capability = 'seller'
  )
);

-- API RATE LIMITS (Insert)
CREATE POLICY "Users insert own limits"
ON public.api_rate_limits
FOR INSERT WITH CHECK (auth.uid() = user_id);

-- VIEWS
CREATE OR REPLACE VIEW public.public_profiles AS
SELECT 
  id, role, first_name, last_name, city, bio, avatar_url, is_verified, 
  average_rating, total_reviews, created_at 
FROM public.profiles;

-- ============================================================================
-- GRANTS
-- ============================================================================
GRANT USAGE ON SCHEMA public TO postgres, anon, authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA public TO postgres, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO postgres, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;
GRANT SELECT ON public.public_profiles TO anon, authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO postgres, anon, authenticated, service_role;

-- INITIAL DATA
INSERT INTO public.gig_categories (name, slug, description) VALUES
('Graphisme & Design', 'graphisme-design', 'Logos, Web Design, Illustration'),
('Marketing Digital', 'marketing-digital', 'SEO, Social Media, Ads'),
('Rédaction & Traduction', 'redaction-traduction', 'Articles, Traduction, Correction'),
('Vidéo & Animation', 'video-animation', 'Montage, Motion Design'),
('Programmation & Tech', 'programmation-tech', 'Web Dev, Mobile Apps, Scripts'),
('Musique & Audio', 'musique-audio', 'Voix off, Mixage, Production'),
('Business', 'business', 'Plan d''affaires, Conseils juridiques'),
('Loisirs & Lifestyle', 'loisirs-lifestyle', 'Coaching, Astrologie, Gaming')
ON CONFLICT (slug) DO NOTHING;

COMMIT;
-- ============================================================================
-- MARKETPLACE V33.0 - FINAL PRODUCTION RELEASE
-- ============================================================================
-- Description: Consolidated script for Security, Idempotency, Financial Logic,
-- and Optimizations.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. SECURITY HARDENING (GRANTS)
-- ============================================================================

-- Revoke dangerous broad grants
REVOKE ALL ON SCHEMA public FROM authenticated, anon;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM authenticated, anon;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM authenticated, anon;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM authenticated, anon;

-- Base Schema Access
GRANT USAGE ON SCHEMA public TO postgres, service_role;
GRANT USAGE ON SCHEMA public TO anon, authenticated;

-- Function Access
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO anon;

-- Sequence Access
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated, service_role;

-- Selective Table Grants (Frontend Compatibility)
GRANT SELECT ON TABLE public.profiles TO anon, authenticated;
GRANT SELECT ON TABLE public.gigs TO anon, authenticated;
GRANT SELECT ON TABLE public.gig_packages TO anon, authenticated;
GRANT SELECT ON TABLE public.gig_requirements TO anon, authenticated;
GRANT SELECT ON TABLE public.gig_tags TO anon, authenticated;
GRANT SELECT ON TABLE public.gig_categories TO anon, authenticated;
GRANT SELECT ON TABLE public.gig_reviews TO anon, authenticated;

-- Authenticated Write Access (Protected by RLS)
GRANT UPDATE ON TABLE public.profiles TO authenticated;
GRANT INSERT, UPDATE, DELETE ON TABLE public.gigs TO authenticated;
GRANT INSERT, UPDATE, DELETE ON TABLE public.gig_packages TO authenticated;
GRANT INSERT, UPDATE, DELETE ON TABLE public.gig_requirements TO authenticated;
GRANT INSERT, UPDATE, DELETE ON TABLE public.gig_tags TO authenticated;
GRANT INSERT, UPDATE ON TABLE public.orders TO authenticated;
GRANT SELECT ON TABLE public.orders TO authenticated;
GRANT INSERT, SELECT ON TABLE public.messages TO authenticated;
GRANT INSERT, UPDATE ON TABLE public.gig_reviews TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.offers TO authenticated;
GRANT INSERT, UPDATE ON TABLE public.affiliate_links TO authenticated;

-- Sensitive Tables (Service Role Only)
REVOKE ALL ON TABLE public.ledger FROM authenticated, anon;
REVOKE ALL ON TABLE public.seller_revenues FROM authenticated, anon;
REVOKE ALL ON TABLE public.platform_revenues FROM authenticated, anon;
REVOKE ALL ON TABLE public.affiliate_conversions FROM authenticated, anon;

GRANT SELECT ON TABLE public.ledger TO authenticated;
GRANT SELECT ON TABLE public.seller_revenues TO authenticated;
GRANT SELECT ON TABLE public.platform_revenues TO service_role;
GRANT SELECT ON TABLE public.affiliate_conversions TO authenticated;

-- ============================================================================
-- 2. IDEMPOTENCY & LEDGER SCHEMA
-- ============================================================================

-- Processed Events
CREATE TABLE IF NOT EXISTS public.processed_events (
  event_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  order_id UUID,
  processed_at TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (event_id, event_type)
);
CREATE INDEX IF NOT EXISTS idx_processed_events_order ON public.processed_events(order_id);

-- Commission Runs
CREATE TABLE IF NOT EXISTS public.commission_runs (
  order_id UUID PRIMARY KEY,
  run_started_at TIMESTAMPTZ DEFAULT NOW(),
  completed BOOLEAN DEFAULT FALSE,
  completed_at TIMESTAMPTZ,
  details JSONB
);

-- Reverse Runs
CREATE TABLE IF NOT EXISTS public.reverse_runs (
  order_id UUID NOT NULL,
  refund_id TEXT NOT NULL,
  run_started_at TIMESTAMPTZ DEFAULT NOW(),
  completed BOOLEAN DEFAULT FALSE,
  completed_at TIMESTAMPTZ,
  amount DECIMAL(10,2),
  PRIMARY KEY (order_id, refund_id)
);

-- Double-Entry Ledger
DO $$ BEGIN
    CREATE TYPE public.ledger_entry_type AS ENUM ('debit', 'credit');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE public.ledger_account_type AS ENUM ('user_wallet', 'platform_fees', 'escrow', 'agent_commission', 'stripe_fees');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

CREATE TABLE IF NOT EXISTS public.ledger_entries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_group_id UUID NOT NULL,
  order_id UUID REFERENCES public.orders(id) ON DELETE SET NULL,
  account_type public.ledger_account_type NOT NULL,
  account_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  entry_type public.ledger_entry_type NOT NULL,
  amount DECIMAL(10,2) NOT NULL CHECK (amount >= 0),
  currency TEXT DEFAULT 'EUR',
  description TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ledger_entries_group ON public.ledger_entries(transaction_group_id);
CREATE INDEX IF NOT EXISTS idx_ledger_entries_account ON public.ledger_entries(account_id, account_type);
CREATE INDEX IF NOT EXISTS idx_ledger_entries_order ON public.ledger_entries(order_id);

ALTER TABLE public.ledger_entries ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users view own ledger entries" ON public.ledger_entries;
CREATE POLICY "Users view own ledger entries" ON public.ledger_entries FOR SELECT TO authenticated USING (account_id = auth.uid());
DROP POLICY IF EXISTS "Service Role full access ledger" ON public.ledger_entries;
CREATE POLICY "Service Role full access ledger" ON public.ledger_entries FOR ALL TO service_role USING (true) WITH CHECK (true);

-- Audit Logs
CREATE TABLE IF NOT EXISTS public.audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  event_name TEXT NOT NULL,
  table_name TEXT,
  record_id UUID,
  old_values JSONB,
  new_values JSONB,
  ip_address TEXT,
  user_agent TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  hash TEXT
);

CREATE OR REPLACE FUNCTION public.prevent_audit_modification() RETURNS TRIGGER AS $$
BEGIN RAISE EXCEPTION 'Audit logs are immutable.'; END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_protect_audit_logs ON public.audit_logs;
CREATE TRIGGER trg_protect_audit_logs BEFORE UPDATE OR DELETE ON public.audit_logs FOR EACH ROW EXECUTE FUNCTION public.prevent_audit_modification();

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins view audit logs" ON public.audit_logs;
CREATE POLICY "Admins view audit logs" ON public.audit_logs FOR SELECT TO authenticated USING (public.is_admin());

-- Job Queue
DO $$ BEGIN
    CREATE TYPE public.job_status AS ENUM ('pending', 'processing', 'completed', 'failed');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

CREATE TABLE IF NOT EXISTS public.job_queue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  job_type TEXT NOT NULL,
  payload JSONB NOT NULL,
  status public.job_status DEFAULT 'pending',
  attempts INTEGER DEFAULT 0,
  last_error TEXT,
  run_at TIMESTAMPTZ DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_job_queue_status ON public.job_queue(status, run_at);

DROP TRIGGER IF EXISTS update_job_queue_modtime ON public.job_queue;
CREATE TRIGGER update_job_queue_modtime BEFORE UPDATE ON public.job_queue FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

GRANT SELECT ON public.processed_events TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.commission_runs TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.reverse_runs TO service_role;
GRANT SELECT ON public.ledger_entries TO service_role;
GRANT INSERT ON public.audit_logs TO authenticated, service_role;
GRANT SELECT ON public.audit_logs TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.job_queue TO service_role;

-- ============================================================================
-- 3. FINANCIAL LOGIC (FUNCTIONS)
-- ============================================================================

-- Helper: Record Ledger Entry
CREATE OR REPLACE FUNCTION public.record_ledger_entry(
  p_transaction_group_id UUID,
  p_order_id UUID,
  p_account_type public.ledger_account_type,
  p_account_id UUID,
  p_entry_type public.ledger_entry_type,
  p_amount DECIMAL,
  p_description TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO public.ledger_entries (transaction_group_id, order_id, account_type, account_id, entry_type, amount, description)
  VALUES (p_transaction_group_id, p_order_id, p_account_type, p_account_id, p_entry_type, p_amount, p_description)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- 3. FINANCIAL LOGIC (CENTRAL RPC)
-- Official function for marketplace commissions:
-- distribute_commissions_v2()
CREATE OR REPLACE FUNCTION public.distribute_commissions_v2(p_order_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_order RECORD;
  v_gig RECORD;
  v_offer RECORD;
  v_affiliate_link RECORD;
  v_commission_rate DECIMAL := 0.05;
  v_affiliate_rate DECIMAL := 0.0;
  v_platform_amount DECIMAL;
  v_seller_amount DECIMAL;
  v_affiliate_amount DECIMAL := 0;
  v_agent_net DECIMAL := 0;
  v_transaction_group_id UUID;
BEGIN
  INSERT INTO public.commission_runs(order_id, run_started_at) VALUES (p_order_id, NOW()) ON CONFLICT (order_id) DO NOTHING;
  IF EXISTS (SELECT 1 FROM public.commission_runs WHERE order_id = p_order_id AND completed = TRUE) THEN
    RETURN jsonb_build_object('success', true, 'message', 'Already distributed');
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF v_order IS NULL THEN RAISE EXCEPTION 'Order not found'; END IF;

  IF v_order.status NOT IN ('completed', 'finished') THEN RAISE EXCEPTION 'Invalid order status: %', v_order.status; END IF;
  IF v_order.status = 'cancelled' THEN RAISE EXCEPTION 'Order is cancelled'; END IF;
  IF v_order.stripe_payment_status NOT IN ('succeeded', 'captured') THEN RAISE EXCEPTION 'Payment not captured'; END IF;

  IF v_order.gig_id IS NOT NULL THEN
    SELECT * INTO v_gig FROM public.gigs WHERE id = v_order.gig_id;
    IF v_gig.seller_id != v_order.seller_id THEN RAISE EXCEPTION 'Seller mismatch'; END IF;
  ELSIF v_order.offer_id IS NOT NULL THEN
    SELECT * INTO v_offer FROM public.offers WHERE id = v_order.offer_id;
  END IF;

  v_platform_amount := ROUND(v_order.total_amount * v_commission_rate, 2);
  v_seller_amount := v_order.total_amount - v_platform_amount;

  IF v_order.affiliate_link_id IS NOT NULL THEN
    SELECT * INTO v_affiliate_link FROM public.affiliate_links WHERE id = v_order.affiliate_link_id;
    IF v_affiliate_link IS NOT NULL THEN
       v_affiliate_rate := 0.10; 
       v_affiliate_amount := ROUND(v_platform_amount * v_affiliate_rate, 2);
       v_agent_net := v_affiliate_amount;
       v_platform_amount := v_platform_amount - v_affiliate_amount;
    END IF;
  END IF;

  IF (v_seller_amount + v_platform_amount + v_affiliate_amount) != v_order.total_amount THEN
    v_platform_amount := v_order.total_amount - v_seller_amount - v_affiliate_amount;
  END IF;

  v_transaction_group_id := gen_random_uuid();
  PERFORM public.record_ledger_entry(v_transaction_group_id, p_order_id, 'escrow', NULL, 'debit', v_order.total_amount, 'Release funds from Escrow');
  PERFORM public.record_ledger_entry(v_transaction_group_id, p_order_id, 'user_wallet', v_order.seller_id, 'credit', v_seller_amount, 'Order Revenue');
  PERFORM public.record_ledger_entry(v_transaction_group_id, p_order_id, 'platform_fees', NULL, 'credit', v_platform_amount, 'Platform Commission');
  IF v_affiliate_amount > 0 THEN
    PERFORM public.record_ledger_entry(v_transaction_group_id, p_order_id, 'agent_commission', v_affiliate_link.agent_id, 'credit', v_affiliate_amount, 'Affiliate Commission');
    -- INSERT INTO public.affiliate_conversions(affiliate_link_id, order_id, total_amount, commission_rate, agent_net, platform_revenue)
    -- VALUES (v_order.affiliate_link_id, p_order_id, v_order.total_amount, v_affiliate_rate, v_agent_net, v_platform_amount) ON CONFLICT (order_id) DO NOTHING;
  END IF;

  INSERT INTO public.seller_revenues(
    seller_id,
    order_id,
    source_type,
    amount,
    status,
    available_at
  ) VALUES (
    v_order.seller_id,
    p_order_id,
    'gig',
    v_seller_amount,
    'pending',
    NOW() + INTERVAL '72 hours'
  )
  ON CONFLICT (order_id)
  DO UPDATE SET
    amount = EXCLUDED.amount,
    status = 'pending',
    available_at = EXCLUDED.available_at;

  INSERT INTO public.platform_revenues(order_id, amount, source) VALUES (p_order_id, v_platform_amount, 'commission') ON CONFLICT (order_id) DO NOTHING;

  UPDATE public.commission_runs SET completed = TRUE, completed_at = NOW(), details = jsonb_build_object('seller_amount', v_seller_amount) WHERE order_id = p_order_id;
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN RAISE; END;
$$;

-- Auto-Confirm Cron
CREATE OR REPLACE FUNCTION public.auto_confirm_orders() RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE public.orders SET status = 'finished', updated_at = NOW() WHERE status = 'submitted' AND submitted_at < (NOW() - INTERVAL '72 hours');
END;
$$;

-- Reverse Commissions
CREATE OR REPLACE FUNCTION public.reverse_commissions(p_order_id UUID, p_refund_id TEXT, p_refund_amount DECIMAL) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_conv public.affiliate_conversions%ROWTYPE;
  v_transaction_group_id UUID;
BEGIN
  IF EXISTS (SELECT 1 FROM public.reverse_runs WHERE order_id = p_order_id AND refund_id = p_refund_id) THEN
     RETURN jsonb_build_object('success', true, 'message', 'Already reversed');
  END IF;
  
  INSERT INTO public.reverse_runs(order_id, refund_id, run_started_at, amount) VALUES (p_order_id, p_refund_id, NOW(), p_refund_amount);
  
  SELECT * INTO v_conv FROM public.affiliate_conversions WHERE order_id = p_order_id;

  v_transaction_group_id := gen_random_uuid();
  
  -- Refund Seller (Debit)
  PERFORM public.record_ledger_entry(v_transaction_group_id, p_order_id, 'user_wallet', v_conv.seller_id, 'debit', v_conv.seller_net, 'Refund Debit: Seller');
  UPDATE public.seller_revenues SET status = 'cancelled', locked = TRUE WHERE order_id = p_order_id;
  
  -- Refund Agent (Debit) if applicable
  IF v_conv.agent_id IS NOT NULL THEN
     PERFORM public.record_ledger_entry(v_transaction_group_id, p_order_id, 'agent_commission', v_conv.agent_id, 'debit', v_conv.agent_net, 'Refund Debit: Agent');
     UPDATE public.agent_revenues SET status = 'cancelled', locked = TRUE WHERE order_id = p_order_id;
  END IF;

  -- Platform Fee handling (Debit/Credit logic depending on policy - Assuming platform keeps fee or refunds it? 
  -- Legacy didn't refund platform fee explicitly in ledger but logic implies rollback. 
  -- We will debit platform fee for correctness.)
  PERFORM public.record_ledger_entry(v_transaction_group_id, p_order_id, 'platform_fees', NULL, 'debit', v_conv.platform_revenue, 'Refund Debit: Platform');

  -- Update Order Status
  UPDATE public.orders SET refund_status = 'full', refund_amount = p_refund_amount, refunded_at = NOW(), status = 'cancelled' WHERE id = p_order_id;
  
  UPDATE public.reverse_runs SET completed = TRUE, completed_at = NOW() WHERE order_id = p_order_id AND refund_id = p_refund_id;
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN RAISE; END;
$$;

-- ============================================================================
-- 4. OPTIMIZATIONS & VIEWS
-- ============================================================================

CREATE OR REPLACE VIEW public.public_affiliate_links AS
SELECT id, code, url_slug, listing_id, gig_id, is_active, created_at FROM public.affiliate_links WHERE is_active = TRUE;

REVOKE SELECT ON public.affiliate_links FROM anon, authenticated;
GRANT SELECT ON public.public_affiliate_links TO anon, authenticated;
GRANT SELECT ON public.affiliate_links TO authenticated; -- RLS restricted

DROP POLICY IF EXISTS "Agents manage own links" ON public.affiliate_links;
CREATE POLICY "Agents manage own links" ON public.affiliate_links FOR ALL TO authenticated USING (agent_id = auth.uid());

CREATE INDEX IF NOT EXISTS idx_orders_gig_package ON public.orders(gig_package_id);
CREATE INDEX IF NOT EXISTS idx_seller_revenues_seller_status ON public.seller_revenues(seller_id, status);
CREATE INDEX IF NOT EXISTS idx_orders_status_submitted ON public.orders(status, submitted_at) WHERE status = 'submitted';
CREATE INDEX IF NOT EXISTS idx_orders_payment_status ON public.orders(stripe_payment_status);

COMMIT;
