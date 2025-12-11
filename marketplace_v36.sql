
-- ============================================================================
-- MARKETPLACE V36.0 - FULL SCHEMA (FIVERR-LIKE + AFFILIATION RULES)
-- ============================================================================
-- Base: V35 architecture, simplified and adjusted
-- - Full schema creation from empty database
-- - Fiverr-like constraints (min price 5, delivery >= 1 day)
-- - Extras, Addons, Bundles
-- - Affiliate config with min 5% discount & commission, platform keeps 20% of agent commission
-- - Double-entry ledger & revenue caches
-- - RLS & restrictive grants
-- NOTE: This script assumes a Supabase-like environment with auth.users.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

BEGIN;

-- ============================================================================
-- 1. UTILS & SECURITY CONFIG
-- ============================================================================

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_encryption_key()
RETURNS text LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER AS $$
DECLARE
  v_key text;
BEGIN
  v_key := current_setting('app.encryption_key', true);
  IF v_key IS NULL OR LENGTH(v_key) < 32 THEN
    RAISE EXCEPTION 'CRITICAL: app.encryption_key not set or too short.';
  END IF;
  RETURN v_key;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.get_encryption_key() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.is_service_role()
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
BEGIN
  RETURN (current_user = 'postgres'
          OR COALESCE(current_setting('request.jwt.claims', true)::json->>'role', '') = 'service_role');
EXCEPTION WHEN OTHERS THEN
  RETURN FALSE;
END;
$$;

-- ============================================================================
-- 2. USERS & CAPABILITIES
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'influenceur', -- Legacy
  first_name TEXT CHECK (LENGTH(first_name) <= 100),
  last_name TEXT CHECK (LENGTH(last_name) <= 100),
  email_encrypted BYTEA,
  phone_encrypted BYTEA,
  city TEXT CHECK (LENGTH(city) <= 100),
  bio TEXT CHECK (LENGTH(bio) <= 2000),
  avatar_url TEXT CHECK (LENGTH(avatar_url) <= 500),
  is_verified BOOLEAN DEFAULT FALSE,
  profile_views INTEGER DEFAULT 0,
  profile_share_count INTEGER DEFAULT 0,
  stripe_account_id TEXT,
  stripe_customer_id TEXT,
  average_rating DECIMAL(3,2) DEFAULT 0,
  total_reviews INTEGER DEFAULT 0,
  completed_orders_count INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.admins (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  permissions JSONB DEFAULT '{"all": true}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid());
$$;

CREATE TABLE IF NOT EXISTS public.user_capabilities (
  user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
  capability TEXT NOT NULL CHECK (capability IN ('buyer','seller','agent','affiliate','admin')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (user_id, capability)
);

CREATE TABLE IF NOT EXISTS public.seller_details (
  id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  display_name TEXT,
  tagline TEXT,
  description TEXT,
  skills TEXT[],
  languages JSONB,
  experience_years INTEGER,
  education JSONB,
  certifications JSONB,
  hourly_rate DECIMAL(10,2),
  is_available BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.api_rate_limits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  endpoint TEXT NOT NULL,
  request_count INTEGER DEFAULT 1,
  last_request_at TIMESTAMPTZ DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (user_id, endpoint)
);

-- ============================================================================
-- 3. GIG SYSTEM (FIVERR-LIKE)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.gig_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_id UUID REFERENCES public.gig_categories(id) ON DELETE SET NULL,
  name TEXT NOT NULL UNIQUE,
  slug TEXT NOT NULL UNIQUE,
  description TEXT,
  sort_order INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.gigs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  category_id UUID REFERENCES public.gig_categories(id) ON DELETE SET NULL,
  title TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  description TEXT NOT NULL,
  base_price DECIMAL(10,2) NOT NULL CHECK (base_price >= 5), -- Fiverr min price
  min_delivery_days INTEGER NOT NULL CHECK (min_delivery_days >= 1),
  status TEXT NOT NULL DEFAULT 'draft',
  rating_average DECIMAL(3,2) DEFAULT 0,
  rating_count INTEGER DEFAULT 0,
  total_orders INTEGER DEFAULT 0,
  is_affiliable BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.gig_packages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  name TEXT NOT NULL, -- 'Basic','Standard','Premium' or custom
  description TEXT,
  price DECIMAL(10,2) NOT NULL CHECK (price >= 5), -- Fiverr min price
  delivery_days INTEGER NOT NULL CHECK (delivery_days >= 1),
  revisions INTEGER DEFAULT 0,
  features TEXT[],
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (gig_id, name)
);

CREATE TABLE IF NOT EXISTS public.gig_media (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  media_type TEXT NOT NULL, -- image / video
  url TEXT NOT NULL,
  thumbnail_url TEXT,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.gig_faqs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  question TEXT NOT NULL,
  answer TEXT NOT NULL,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.gig_requirements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  question TEXT NOT NULL,
  type TEXT NOT NULL DEFAULT 'text', -- text/file/multiple_choice
  is_required BOOLEAN DEFAULT TRUE,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.gig_tags (
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  tag TEXT NOT NULL,
  PRIMARY KEY (gig_id, tag)
);

-- Fiverr-like Extras (A)
CREATE TABLE IF NOT EXISTS public.gig_extras (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  price DECIMAL(10,2) NOT NULL CHECK (price >= 5), -- min 5
  extra_delivery_days INTEGER DEFAULT 0 CHECK (extra_delivery_days >= 0),
  is_active BOOLEAN DEFAULT TRUE,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Fiverr-like Addons (C)
CREATE TABLE IF NOT EXISTS public.gig_addons (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  price DECIMAL(10,2) NOT NULL CHECK (price >= 5),
  is_mandatory BOOLEAN DEFAULT FALSE,
  is_active BOOLEAN DEFAULT TRUE,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Fiverr-like Bundles (B)
CREATE TABLE IF NOT EXISTS public.gig_bundles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  total_price DECIMAL(10,2) NOT NULL CHECK (total_price >= 5),
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.gig_bundle_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bundle_id UUID NOT NULL REFERENCES public.gig_bundles(id) ON DELETE CASCADE,
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  gig_package_id UUID REFERENCES public.gig_packages(id) ON DELETE SET NULL,
  quantity INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================================
-- 4. AFFILIATION & OFFERS
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.collabmarket_listings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  is_active BOOLEAN DEFAULT TRUE,
  client_discount_rate DECIMAL(5,2)
    CHECK (client_discount_rate IS NULL OR (client_discount_rate >= 5 AND client_discount_rate <= 50)), -- min 5%
  agent_commission_rate DECIMAL(5,2) NOT NULL
    CHECK (agent_commission_rate >= 5 AND agent_commission_rate <= 30), -- min 5%
  platform_fee_rate DECIMAL(5,2) NOT NULL DEFAULT 5.0
    CHECK (platform_fee_rate >= 0 AND platform_fee_rate <= 20),
  platform_cut_on_agent_rate DECIMAL(5,2) NOT NULL DEFAULT 20.0
    CHECK (platform_cut_on_agent_rate >= 0 AND platform_cut_on_agent_rate <= 100),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.affiliate_links (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  url_slug TEXT NOT NULL UNIQUE,
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

CREATE TABLE IF NOT EXISTS public.offers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  price DECIMAL(10,2) NOT NULL CHECK (price >= 5),
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================================
-- 5. ORDERS & AFFILIATE CONVERSIONS
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  offer_id UUID REFERENCES public.offers(id) ON DELETE SET NULL,
  gig_id UUID REFERENCES public.gigs(id) ON DELETE SET NULL,
  gig_package_id UUID REFERENCES public.gig_packages(id) ON DELETE SET NULL,
  affiliate_link_id UUID REFERENCES public.affiliate_links(id) ON DELETE SET NULL,
  order_type TEXT NOT NULL CHECK (order_type IN ('influencer_offer','freelance_gig')),
  status TEXT NOT NULL DEFAULT 'pending',
  total_amount DECIMAL(10,2) NOT NULL CHECK (total_amount > 0),
  net_amount DECIMAL(10,2) NOT NULL CHECK (net_amount > 0),
  requirements TEXT,
  delivery_url TEXT,
  stripe_payment_intent_id TEXT,
  stripe_checkout_session_id TEXT,
  stripe_payment_status TEXT DEFAULT 'unpaid',
  refund_status TEXT DEFAULT 'none',
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
  client_discount DECIMAL(10,2) DEFAULT 0,
  platform_fee DECIMAL(10,2) DEFAULT 0,
  agent_commission DECIMAL(10,2) DEFAULT 0,
  platform_cut_on_agent DECIMAL(10,2) DEFAULT 0,
  seller_net DECIMAL(10,2) DEFAULT 0,
  agent_net DECIMAL(10,2) DEFAULT 0,
  platform_revenue DECIMAL(10,2) DEFAULT 0,
  currency TEXT DEFAULT 'EUR',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (order_id)
);

-- ============================================================================
-- 6. LEDGER & REVENUES
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.commission_runs (
  order_id UUID PRIMARY KEY,
  run_started_at TIMESTAMPTZ DEFAULT NOW(),
  completed BOOLEAN DEFAULT FALSE,
  completed_at TIMESTAMPTZ,
  details JSONB
);

CREATE TABLE IF NOT EXISTS public.reverse_runs (
  order_id UUID NOT NULL,
  refund_id TEXT NOT NULL,
  run_started_at TIMESTAMPTZ DEFAULT NOW(),
  completed BOOLEAN DEFAULT FALSE,
  completed_at TIMESTAMPTZ,
  amount DECIMAL(10,2),
  PRIMARY KEY (order_id, refund_id)
);

CREATE TABLE IF NOT EXISTS public.processed_events (
  event_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  order_id UUID,
  processed_at TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (event_id, event_type)
);

DO $$ BEGIN
  CREATE TYPE public.ledger_entry_type AS ENUM ('debit','credit');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE public.ledger_account_type AS ENUM ('user_wallet','platform_fees','escrow','agent_commission','stripe_fees');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

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

CREATE TABLE IF NOT EXISTS public.seller_revenues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  order_id UUID REFERENCES public.orders(id) ON DELETE RESTRICT,
  source_type TEXT DEFAULT 'gig',
  amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  status TEXT NOT NULL DEFAULT 'pending',
  locked BOOLEAN DEFAULT FALSE,
  available_at TIMESTAMPTZ,
  withdrawn_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (order_id)
);

CREATE TABLE IF NOT EXISTS public.agent_revenues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  order_id UUID REFERENCES public.orders(id) ON DELETE RESTRICT,
  affiliate_link_id UUID REFERENCES public.affiliate_links(id) ON DELETE SET NULL,
  amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  status TEXT NOT NULL DEFAULT 'pending',
  locked BOOLEAN DEFAULT FALSE,
  available_at TIMESTAMPTZ,
  withdrawn_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (order_id)
);

CREATE TABLE IF NOT EXISTS public.platform_revenues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID REFERENCES public.orders(id) ON DELETE SET NULL,
  amount DECIMAL(10,2) NOT NULL,
  source TEXT NOT NULL,
  locked BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (order_id)
);

CREATE TABLE IF NOT EXISTS public.withdrawals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  status TEXT NOT NULL DEFAULT 'pending',
  stripe_transfer_id TEXT,
  stripe_payout_id TEXT,
  failure_reason TEXT,
  processed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================================
-- 7. REVIEWS, MESSAGES, BANK & PORTFOLIO
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.gig_reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gig_id UUID NOT NULL REFERENCES public.gigs(id) ON DELETE CASCADE,
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  reviewer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment TEXT,
  response TEXT,
  response_at TIMESTAMPTZ,
  is_visible BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (order_id)
);

CREATE TABLE IF NOT EXISTS public.conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  participant_1_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  participant_2_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  last_message_at TIMESTAMPTZ DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  CHECK (participant_1_id <> participant_2_id)
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
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.job_queue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  job_type TEXT NOT NULL,
  payload JSONB NOT NULL,
  status TEXT DEFAULT 'pending',
  attempts INTEGER DEFAULT 0,
  last_error TEXT,
  run_at TIMESTAMPTZ DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.bank_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  account_holder TEXT NOT NULL,
  iban TEXT NOT NULL,
  bic TEXT,
  bank_name TEXT,
  is_default BOOLEAN DEFAULT FALSE,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.portfolio_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  title TEXT,
  description TEXT,
  media_type TEXT,
  media_url TEXT NOT NULL,
  thumbnail_url TEXT,
  link_url TEXT,
  display_order INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.contestations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  merchant_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  reason TEXT NOT NULL,
  evidence_url TEXT,
  evidence_description TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  admin_notes TEXT,
  decided_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  decided_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================================
-- 8. FUNCTIONS & RPCs
-- ============================================================================

CREATE OR REPLACE FUNCTION public.apply_rate_limit(
  p_endpoint TEXT,
  p_limit INTEGER DEFAULT 10,
  p_window_seconds INTEGER DEFAULT 60
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_count INTEGER;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO public.api_rate_limits (user_id, endpoint, request_count, last_request_at)
  VALUES (v_user_id, p_endpoint, 1, NOW())
  ON CONFLICT (user_id, endpoint)
  DO UPDATE SET
    request_count = CASE
      WHEN public.api_rate_limits.last_request_at < NOW() - (p_window_seconds || ' seconds')::INTERVAL
      THEN 1
      ELSE public.api_rate_limits.request_count + 1
    END,
    last_request_at = NOW()
  RETURNING request_count INTO v_count;

  IF v_count > p_limit THEN
    RAISE EXCEPTION 'Rate limit exceeded for endpoint %', p_endpoint;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_ledger_entry(
  p_transaction_group_id UUID,
  p_order_id UUID,
  p_account_type public.ledger_account_type,
  p_account_id UUID,
  p_entry_type public.ledger_entry_type,
  p_amount DECIMAL,
  p_description TEXT
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER AS $$
DECLARE
  v_id UUID;
BEGIN
  INSERT INTO public.ledger_entries (
    transaction_group_id, order_id, account_type, account_id,
    entry_type, amount, description
  ) VALUES (
    p_transaction_group_id, p_order_id, p_account_type, p_account_id,
    p_entry_type, p_amount, p_description
  )
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Distribute commissions with listing rates (min 5% rules already validated by constraints)
CREATE OR REPLACE FUNCTION public.distribute_commissions_v2(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_order            public.orders%ROWTYPE;
  v_link             public.affiliate_links%ROWTYPE;
  v_listing          public.collabmarket_listings%ROWTYPE;
  v_platform_amount  DECIMAL;
  v_seller_amount    DECIMAL;
  v_agent_gross      DECIMAL := 0;
  v_agent_net        DECIMAL := 0;
  v_platform_from_agent DECIMAL := 0;
  v_client_discount_rate DECIMAL := 0;
  v_commission_rate       DECIMAL := 0;
  v_platform_fee_rate     DECIMAL := 0;
  v_transaction_group_id  UUID;
  v_base_price            DECIMAL;
  v_client_discount_amount DECIMAL := 0;
BEGIN
  -- Idempotency
  INSERT INTO public.commission_runs(order_id, run_started_at)
  VALUES (p_order_id, NOW())
  ON CONFLICT (order_id) DO NOTHING;

  IF EXISTS (SELECT 1 FROM public.commission_runs WHERE order_id = p_order_id AND completed = TRUE) THEN
    RETURN jsonb_build_object('success', true, 'message', 'Already distributed');
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF v_order IS NULL THEN
    RAISE EXCEPTION 'Order not found';
  END IF;

  IF v_order.status NOT IN ('completed','finished') THEN
    RAISE EXCEPTION 'Invalid order status for commission distribution';
  END IF;

  -- Default: no affiliate → simple platform fee 5%
  v_commission_rate   := 0;
  v_platform_fee_rate := 5;
  v_client_discount_rate := 0;

  IF v_order.affiliate_link_id IS NOT NULL THEN
    SELECT * INTO v_link FROM public.affiliate_links WHERE id = v_order.affiliate_link_id;
    IF v_link IS NULL THEN
      RAISE EXCEPTION 'Affiliate link missing for order %', p_order_id;
    END IF;
    SELECT * INTO v_listing FROM public.collabmarket_listings WHERE id = v_link.listing_id;
    IF v_listing IS NULL THEN
      RAISE EXCEPTION 'Listing missing for order %', p_order_id;
    END IF;

    v_commission_rate       := v_listing.agent_commission_rate;
    v_platform_fee_rate     := v_listing.platform_fee_rate;
    v_client_discount_rate  := COALESCE(v_listing.client_discount_rate, 0);
  END IF;

  -- Math based on amount actually paid (total_amount)
  v_platform_amount := ROUND(v_order.total_amount * v_platform_fee_rate / 100, 2);
  v_agent_gross     := ROUND(v_order.total_amount * v_commission_rate / 100, 2);
  v_platform_from_agent := ROUND(v_agent_gross * v_listing.platform_cut_on_agent_rate / 100, 2);
  v_agent_net       := GREATEST(v_agent_gross - v_platform_from_agent, 0);
  v_seller_amount   := v_order.total_amount - v_agent_gross - v_platform_amount;

  IF v_seller_amount < 0 THEN
    v_seller_amount := 0;
  END IF;

  v_platform_amount := v_platform_amount + v_platform_from_agent;
  v_base_price := v_order.total_amount;
  v_client_discount_amount := ROUND(v_base_price * v_client_discount_rate / 100, 2);

  v_transaction_group_id := gen_random_uuid();

  -- Ledger entries
  PERFORM public.record_ledger_entry(
    v_transaction_group_id, p_order_id,
    'escrow', NULL, 'debit', v_order.total_amount,
    'Release Escrow'
  );

  PERFORM public.record_ledger_entry(
    v_transaction_group_id, p_order_id,
    'user_wallet', v_order.seller_id, 'credit', v_seller_amount,
    'Seller Revenue'
  );

  PERFORM public.record_ledger_entry(
    v_transaction_group_id, p_order_id,
    'platform_fees', NULL, 'credit', v_platform_amount,
    'Platform Revenue'
  );

  IF v_agent_net > 0 AND v_order.affiliate_link_id IS NOT NULL THEN
    PERFORM public.record_ledger_entry(
      v_transaction_group_id, p_order_id,
      'agent_commission', v_link.agent_id, 'credit', v_agent_net,
      'Affiliate Commission (net)'
    );

    INSERT INTO public.agent_revenues(
      agent_id, order_id, affiliate_link_id, amount, status, available_at
    ) VALUES (
      v_link.agent_id, p_order_id, v_order.affiliate_link_id,
      v_agent_net, 'pending', NOW() + INTERVAL '72 hours'
    )
    ON CONFLICT (order_id) DO NOTHING;
  END IF;

  -- Seller revenue cache
  INSERT INTO public.seller_revenues(
    seller_id, order_id, source_type, amount, status, available_at
  ) VALUES (
    v_order.seller_id, p_order_id, 'gig', v_seller_amount,
    'pending', NOW() + INTERVAL '72 hours'
  )
  ON CONFLICT (order_id) DO NOTHING;

  -- Platform revenue cache
  INSERT INTO public.platform_revenues(order_id, amount, source)
  VALUES (p_order_id, v_platform_amount, 'commission')
  ON CONFLICT (order_id) DO NOTHING;

  -- Affiliate conversion history (if any)
  IF v_order.affiliate_link_id IS NOT NULL THEN
    INSERT INTO public.affiliate_conversions(
      affiliate_link_id, order_id, gig_id, agent_id, seller_id, client_id,
      base_price, client_discount, platform_fee, agent_commission,
      platform_cut_on_agent, seller_net, agent_net, platform_revenue
    ) VALUES (
      v_order.affiliate_link_id, p_order_id, v_order.gig_id,
      v_link.agent_id, v_order.seller_id, v_order.merchant_id,
      v_base_price, v_client_discount_amount,
      v_platform_amount, v_agent_gross,
      v_platform_from_agent, v_seller_amount, v_agent_net, v_platform_amount
    )
    ON CONFLICT (order_id) DO NOTHING;
  END IF;

  UPDATE public.commission_runs
  SET completed = TRUE,
      completed_at = NOW(),
      details = jsonb_build_object(
        'seller_amount', v_seller_amount,
        'platform_amount', v_platform_amount,
        'agent_net', v_agent_net
      )
  WHERE order_id = p_order_id;

  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.reverse_commissions(
  p_order_id UUID,
  p_refund_id TEXT,
  p_refund_amount DECIMAL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER AS $$
DECLARE
  v_transaction_group_id UUID;
  v_seller_rev RECORD;
  v_agent_rev RECORD;
  v_plat_rev  RECORD;
BEGIN
  IF EXISTS (SELECT 1 FROM public.reverse_runs WHERE order_id = p_order_id AND refund_id = p_refund_id) THEN
    RETURN jsonb_build_object('success', true, 'message', 'Already reversed');
  END IF;

  INSERT INTO public.reverse_runs(order_id, refund_id, run_started_at, amount)
  VALUES (p_order_id, p_refund_id, NOW(), p_refund_amount);

  v_transaction_group_id := gen_random_uuid();

  SELECT * INTO v_seller_rev FROM public.seller_revenues WHERE order_id = p_order_id;
  SELECT * INTO v_agent_rev  FROM public.agent_revenues  WHERE order_id = p_order_id;
  SELECT * INTO v_plat_rev   FROM public.platform_revenues WHERE order_id = p_order_id;

  IF v_seller_rev IS NOT NULL THEN
    PERFORM public.record_ledger_entry(
      v_transaction_group_id, p_order_id,
      'user_wallet', v_seller_rev.seller_id, 'debit', v_seller_rev.amount,
      'Refund Seller'
    );
    UPDATE public.seller_revenues
    SET status = 'cancelled', locked = TRUE
    WHERE order_id = p_order_id;
  END IF;

  IF v_agent_rev IS NOT NULL THEN
    PERFORM public.record_ledger_entry(
      v_transaction_group_id, p_order_id,
      'agent_commission', v_agent_rev.agent_id, 'debit', v_agent_rev.amount,
      'Refund Agent'
    );
    UPDATE public.agent_revenues
    SET status = 'cancelled', locked = TRUE
    WHERE order_id = p_order_id;
  END IF;

  IF v_plat_rev IS NOT NULL THEN
    PERFORM public.record_ledger_entry(
      v_transaction_group_id, p_order_id,
      'platform_fees', NULL, 'debit', v_plat_rev.amount,
      'Refund Platform'
    );
    UPDATE public.platform_revenues
    SET locked = TRUE
    WHERE order_id = p_order_id;
  END IF;

  UPDATE public.orders
  SET refund_status = 'full',
      refund_amount = p_refund_amount,
      refunded_at = NOW(),
      status = 'cancelled'
  WHERE id = p_order_id;

  UPDATE public.reverse_runs
  SET completed = TRUE, completed_at = NOW()
  WHERE order_id = p_order_id AND refund_id = p_refund_id;

  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.create_offer(
  p_title TEXT,
  p_price DECIMAL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_id UUID;
BEGIN
  IF p_price <= 0 THEN
    RAISE EXCEPTION 'Price must be positive';
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
    seller_id, category_id, title, slug, description,
    base_price, min_delivery_days, status, is_affiliable
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
  )
  RETURNING id INTO v_gig_id;

  INSERT INTO public.user_capabilities (user_id, capability)
  VALUES (auth.uid(), 'seller')
  ON CONFLICT DO NOTHING;

  FOREACH v_pkg IN ARRAY p_packages LOOP
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

  FOREACH v_med IN ARRAY p_media LOOP
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
    INSERT INTO public.collabmarket_listings(
      gig_id, seller_id, client_discount_rate,
      agent_commission_rate, platform_fee_rate, platform_cut_on_agent_rate
    ) VALUES (
      v_gig_id,
      auth.uid(),
      (p_affiliate_config->>'client_discount_rate')::DECIMAL,
      (p_affiliate_config->>'agent_commission_rate')::DECIMAL,
      COALESCE((p_affiliate_config->>'platform_fee_rate')::DECIMAL, 5.0),
      20.0
    );
  END IF;

  RETURN v_gig_id;
END;
$$;

-- Sync Stripe status
CREATE OR REPLACE FUNCTION public.sync_stripe_status_to_order()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER AS $$
BEGIN
  -- Prevent clients from changing stripe_payment_status
  IF NOT public.is_service_role()
     AND NEW.stripe_payment_status IS DISTINCT FROM OLD.stripe_payment_status THEN
    NEW.stripe_payment_status := OLD.stripe_payment_status;
  END IF;

  IF NEW.stripe_payment_status = 'requires_capture'
     AND OLD.stripe_payment_status IS DISTINCT FROM 'requires_capture' THEN
    NEW.status := 'payment_authorized';
    NEW.payment_authorized_at := NOW();
  ELSIF NEW.stripe_payment_status IN ('captured','succeeded')
        AND OLD.stripe_payment_status NOT IN ('captured','succeeded') THEN
    IF NEW.status = 'pending' THEN
      NEW.status := 'payment_authorized';
      NEW.payment_authorized_at := NOW();
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sync_stripe_status
BEFORE UPDATE ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.sync_stripe_status_to_order();

-- Freeze order fields
CREATE OR REPLACE FUNCTION public.validate_order_integrity_and_freeze()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.merchant_id IS DISTINCT FROM OLD.merchant_id
       OR NEW.seller_id IS DISTINCT FROM OLD.seller_id
       OR NEW.total_amount IS DISTINCT FROM OLD.total_amount THEN
      RAISE EXCEPTION 'Critical order fields are immutable';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_order_integrity
BEFORE INSERT OR UPDATE ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.validate_order_integrity_and_freeze();

-- Immutable ledger & audit
CREATE OR REPLACE FUNCTION public.prevent_ledger_modification()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Ledger is immutable';
END;
$$;

CREATE TRIGGER trg_ledger_immutable
BEFORE UPDATE OR DELETE ON public.ledger_entries
FOR EACH ROW EXECUTE FUNCTION public.prevent_ledger_modification();

CREATE OR REPLACE FUNCTION public.prevent_audit_modification()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Audit logs are immutable.';
END;
$$;

CREATE TRIGGER trg_protect_audit_logs
BEFORE UPDATE OR DELETE ON public.audit_logs
FOR EACH ROW EXECUTE FUNCTION public.prevent_audit_modification();

-- Revenue locks
CREATE OR REPLACE FUNCTION public.prevent_revenue_modification()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.locked = TRUE THEN
    RAISE EXCEPTION 'Revenue locked';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_lock_seller_revenues
BEFORE UPDATE OR DELETE ON public.seller_revenues
FOR EACH ROW EXECUTE FUNCTION public.prevent_revenue_modification();

CREATE TRIGGER trg_lock_agent_revenues
BEFORE UPDATE OR DELETE ON public.agent_revenues
FOR EACH ROW EXECUTE FUNCTION public.prevent_revenue_modification();

CREATE TRIGGER trg_lock_platform_revenues
BEFORE UPDATE OR DELETE ON public.platform_revenues
FOR EACH ROW EXECUTE FUNCTION public.prevent_revenue_modification();

-- Timestamp triggers
CREATE TRIGGER update_profiles_modtime
BEFORE UPDATE ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_orders_modtime
BEFORE UPDATE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_gigs_modtime
BEFORE UPDATE ON public.gigs
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_job_queue_modtime
BEFORE UPDATE ON public.job_queue
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================================================
-- 9. RLS
-- ============================================================================

-- Enable RLS
ALTER TABLE public.profiles            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admins              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_capabilities   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.seller_details      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gigs                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_packages        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_media           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_faqs            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_requirements    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_tags            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_extras          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_addons          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_bundles         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_bundle_items    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.collabmarket_listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_links     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_clicks    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_conversions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger_entries      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.seller_revenues     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_revenues      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_revenues   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.withdrawals         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_reviews         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.api_rate_limits     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.offers              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_logs         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_logs        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.job_queue           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commission_runs     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reverse_runs        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.processed_events    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_accounts       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.portfolio_items     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contestations       ENABLE ROW LEVEL SECURITY;

-- Views
CREATE OR REPLACE VIEW public.public_profiles AS
SELECT id, role, first_name, last_name, city, bio, avatar_url, is_verified,
       average_rating, total_reviews, created_at
FROM public.profiles;

CREATE OR REPLACE VIEW public.public_affiliate_links AS
SELECT id, code, url_slug, listing_id, gig_id, is_active, created_at
FROM public.affiliate_links
WHERE is_active = TRUE;

-- Policies (main ones)

-- Profiles
CREATE POLICY "Users see own private profile"
ON public.profiles FOR SELECT
USING (auth.uid() = id);

CREATE POLICY "Users update own profile"
ON public.profiles FOR UPDATE
USING (auth.uid() = id);

-- Orders
CREATE POLICY "Users view own orders"
ON public.orders FOR SELECT
USING (auth.uid() = merchant_id OR auth.uid() = seller_id);

CREATE POLICY "Buyers create orders"
ON public.orders FOR INSERT
WITH CHECK (auth.uid() = merchant_id);

-- Gigs & packages
CREATE POLICY "Public active gigs"
ON public.gigs FOR SELECT
USING (status = 'active' OR auth.uid() = seller_id);

CREATE POLICY "Sellers manage own gigs"
ON public.gigs FOR ALL
USING (auth.uid() = seller_id);

CREATE POLICY "Public packages"
ON public.gig_packages FOR SELECT
USING (true);

CREATE POLICY "Sellers manage packages"
ON public.gig_packages FOR ALL
USING (EXISTS (
  SELECT 1 FROM public.gigs g WHERE g.id = gig_id AND g.seller_id = auth.uid()
));

-- Extras / Addons / Bundles
CREATE POLICY "Public extras"
ON public.gig_extras FOR SELECT USING (true);

CREATE POLICY "Sellers manage extras"
ON public.gig_extras FOR ALL
USING (EXISTS (
  SELECT 1 FROM public.gigs g WHERE g.id = gig_id AND g.seller_id = auth.uid()
));

CREATE POLICY "Public addons"
ON public.gig_addons FOR SELECT USING (true);

CREATE POLICY "Sellers manage addons"
ON public.gig_addons FOR ALL
USING (EXISTS (
  SELECT 1 FROM public.gigs g WHERE g.id = gig_id AND g.seller_id = auth.uid()
));

CREATE POLICY "Public bundles"
ON public.gig_bundles FOR SELECT USING (is_active = TRUE OR seller_id = auth.uid());

CREATE POLICY "Sellers manage bundles"
ON public.gig_bundles FOR ALL USING (seller_id = auth.uid());

CREATE POLICY "Public bundle items"
ON public.gig_bundle_items FOR SELECT USING (true);

CREATE POLICY "Sellers manage bundle items"
ON public.gig_bundle_items FOR ALL
USING (EXISTS (
  SELECT 1 FROM public.gig_bundles b WHERE b.id = bundle_id AND b.seller_id = auth.uid()
));

-- Finance
CREATE POLICY "Sellers view own revenues"
ON public.seller_revenues FOR SELECT
USING (seller_id = auth.uid());

CREATE POLICY "Agents view own revenues"
ON public.agent_revenues FOR SELECT
USING (agent_id = auth.uid());

CREATE POLICY "Admins view ledger"
ON public.ledger_entries FOR SELECT
USING (public.is_admin());

CREATE POLICY "Admins view platform"
ON public.platform_revenues FOR SELECT
USING (public.is_admin());

-- Reviews
CREATE POLICY "Public reviews"
ON public.gig_reviews FOR SELECT USING (is_visible = TRUE);

CREATE POLICY "Buyers create reviews"
ON public.gig_reviews FOR INSERT
WITH CHECK (auth.uid() = reviewer_id);

CREATE POLICY "Sellers reply to reviews"
ON public.gig_reviews FOR UPDATE
USING (auth.uid() = seller_id);

-- Messages
CREATE POLICY "Users read own messages"
ON public.messages FOR SELECT
USING (auth.uid() = sender_id OR auth.uid() = receiver_id);

CREATE POLICY "Users send messages"
ON public.messages FOR INSERT
WITH CHECK (auth.uid() = sender_id);

-- Contestations
CREATE POLICY "Users view contestations"
ON public.contestations FOR SELECT
USING (auth.uid() = influencer_id OR auth.uid() = merchant_id);

CREATE POLICY "Users create contestations"
ON public.contestations FOR INSERT
WITH CHECK (auth.uid() = influencer_id);

-- Rate limits
CREATE POLICY "Users view own limits"
ON public.api_rate_limits FOR SELECT
USING (auth.uid() = user_id);

-- Bank & portfolio
CREATE POLICY "Users manage bank"
ON public.bank_accounts FOR ALL
USING (auth.uid() = user_id);

CREATE POLICY "Users manage portfolio"
ON public.portfolio_items FOR ALL
USING (auth.uid() = influencer_id);

-- ============================================================================
-- 10. GRANTS, INDEXES & SEED DATA
-- ============================================================================

-- Revoke broad access
REVOKE ALL ON SCHEMA public FROM authenticated, anon;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM authenticated, anon;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM authenticated, anon;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM authenticated, anon;

-- Schema usage
GRANT USAGE ON SCHEMA public TO postgres, service_role, authenticated, anon;

-- Views
GRANT SELECT ON public.public_profiles TO anon, authenticated;
GRANT SELECT ON public.public_affiliate_links TO anon, authenticated;

-- Read-only public content
GRANT SELECT ON TABLE public.gigs TO anon, authenticated;
GRANT SELECT ON TABLE public.gig_packages TO anon, authenticated;
GRANT SELECT ON TABLE public.gig_media TO anon, authenticated;
GRANT SELECT ON TABLE public.gig_faqs TO anon, authenticated;
GRANT SELECT ON TABLE public.gig_requirements TO anon, authenticated;
GRANT SELECT ON TABLE public.gig_tags TO anon, authenticated;
GRANT SELECT ON TABLE public.gig_reviews TO anon, authenticated;
GRANT SELECT ON TABLE public.gig_categories TO anon, authenticated;
GRANT SELECT ON TABLE public.offers TO anon, authenticated;
GRANT SELECT ON TABLE public.seller_details TO anon, authenticated;
GRANT SELECT ON TABLE public.gig_extras TO anon, authenticated;
GRANT SELECT ON TABLE public.gig_addons TO anon, authenticated;
GRANT SELECT ON TABLE public.gig_bundles TO anon, authenticated;
GRANT SELECT ON TABLE public.gig_bundle_items TO anon, authenticated;

-- Authenticated CRUD via RLS
GRANT INSERT, UPDATE ON TABLE public.profiles TO authenticated;
GRANT INSERT, UPDATE, DELETE ON TABLE public.gigs TO authenticated;
GRANT INSERT, UPDATE, DELETE ON TABLE public.gig_packages TO authenticated;
GRANT INSERT, UPDATE, DELETE ON TABLE public.gig_media TO authenticated;
GRANT INSERT, UPDATE, DELETE ON TABLE public.gig_faqs TO authenticated;
GRANT INSERT, UPDATE, DELETE ON TABLE public.gig_requirements TO authenticated;
GRANT INSERT, UPDATE, DELETE ON TABLE public.gig_tags TO authenticated;
GRANT INSERT, UPDATE, DELETE ON TABLE public.gig_extras TO authenticated;
GRANT INSERT, UPDATE, DELETE ON TABLE public.gig_addons TO authenticated;
GRANT INSERT, UPDATE, DELETE ON TABLE public.gig_bundles TO authenticated;
GRANT INSERT, UPDATE, DELETE ON TABLE public.gig_bundle_items TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.orders TO authenticated;
GRANT SELECT, INSERT ON TABLE public.messages TO authenticated;
GRANT SELECT, INSERT ON TABLE public.conversations TO authenticated;
GRANT INSERT, UPDATE ON TABLE public.gig_reviews TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.bank_accounts TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.portfolio_items TO authenticated;
GRANT SELECT, INSERT ON TABLE public.contestations TO authenticated;
GRANT SELECT ON TABLE public.seller_revenues TO authenticated;
GRANT SELECT ON TABLE public.agent_revenues TO authenticated;
GRANT SELECT, INSERT ON TABLE public.withdrawals TO authenticated;
GRANT SELECT, INSERT ON TABLE public.affiliate_links TO authenticated;

-- Functions
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated, service_role;

-- Sequences
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated, service_role;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_orders_package ON public.orders(gig_package_id);
CREATE INDEX IF NOT EXISTS idx_profiles_role ON public.profiles(role);
CREATE INDEX IF NOT EXISTS idx_gigs_search ON public.gigs
USING GIN (to_tsvector('french', title || ' ' || description));
CREATE INDEX IF NOT EXISTS idx_ledger_group ON public.ledger_entries(transaction_group_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_payment_logs_idempotency
ON public.payment_logs(stripe_payment_intent_id, event_type);

-- Categories seed
INSERT INTO public.gig_categories (name, slug, description) VALUES
('Graphisme & Design', 'graphisme-design', 'Logos, Web Design, Illustration'),
('Marketing Digital', 'marketing-digital', 'SEO, Social Media, Ads'),
('Programmation', 'programmation', 'Web, Mobile, Scripts')
ON CONFLICT (slug) DO NOTHING;

COMMIT;
