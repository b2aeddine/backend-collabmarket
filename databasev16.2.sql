-- ============================================================================
-- BACKEND MARKETPLACE INFLUENCEURS - VERSION PRODUCTION V16.2 (FULL & FIXED)
-- ============================================================================
-- - Base : V16.1
-- - Correctifs :
--   * Ordre et nommage des triggers sur orders (01_snapshot / 02_enforce / 03_calculate)
--   * Suppression du double calcul de net_amount dans enforce_order_creation_rules()
--   * Contrainte UNIQUE sur contestations → index partiel sur status pending/under_review
--   * get_encryption_key() → STABLE (au lieu de IMMUTABLE)
--   * SECURITY DEFINER + SET search_path = public sur toutes les fonctions sensibles
--   * increment_profile_view : rate-limit + uniquement authenticated (pas anon)
--   * Validation email dans contact_messages
--   * Index acceptance_deadline optimisé pour cron
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

BEGIN;

-- ============================================================================
-- 1. FONCTIONS UTILITAIRES & SÉCURITÉ
-- ============================================================================

-- Clé de chiffrement obligatoire
CREATE OR REPLACE FUNCTION public.get_encryption_key()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_key text;
BEGIN
  v_key := current_setting('app.encryption_key', true);
  IF v_key IS NULL OR LENGTH(v_key) < 32 THEN
    RAISE EXCEPTION 'CRITICAL: app.encryption_key not set or too short. Configure it via ALTER DATABASE.';
  END IF;
  RETURN v_key;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.get_encryption_key() FROM PUBLIC, authenticated, anon;

-- updated_at automatique
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- Service role (edge function / interne)
CREATE OR REPLACE FUNCTION public.is_service_role()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  RETURN (
    current_user = 'postgres'
    OR COALESCE(current_setting('request.jwt.claims', true)::json->>'role', '') = 'service_role'
  );
EXCEPTION WHEN OTHERS THEN
  RETURN FALSE;
END;
$$;

-- ============================================================================
-- 2. TABLES
-- ============================================================================

-- PROFILES
CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'influenceur'
    CHECK (role IN ('influenceur', 'commercant', 'admin')),
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
  stripe_identity_session_id TEXT,
  stripe_identity_last_status TEXT,
  stripe_identity_last_update TIMESTAMPTZ,
  identity_trust_score INTEGER DEFAULT 0,
  identity_verification_confidence CHAR(1)
    CHECK (identity_verification_confidence IS NULL OR identity_verification_confidence IN ('L','M','H')),
  identity_document_country TEXT CHECK (LENGTH(identity_document_country) <= 3),
  identity_verified_at TIMESTAMPTZ,
  connect_kyc_status TEXT DEFAULT 'none'
    CHECK (connect_kyc_status IN ('none','pending','verified','restricted','rejected')),
  connect_kyc_last_sync TIMESTAMPTZ,
  connect_kyc_source TEXT,

  average_rating DECIMAL(3,2) DEFAULT 0
    CHECK (average_rating >= 0 AND average_rating <= 5),
  total_reviews INTEGER DEFAULT 0 CHECK (total_reviews >= 0),
  completed_orders_count INTEGER DEFAULT 0 CHECK (completed_orders_count >= 0),

  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ADMINS
CREATE TABLE IF NOT EXISTS public.admins (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  permissions JSONB DEFAULT '{"all": true}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid());
$$;

-- Masquage email
CREATE OR REPLACE FUNCTION public.mask_email(p_enc bytea, p_owner uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  IF p_enc IS NULL THEN RETURN NULL; END IF;
  IF auth.uid() IS DISTINCT FROM p_owner AND NOT public.is_admin() THEN
    RETURN '***@***.***';
  END IF;
  BEGIN
    RETURN pgp_sym_decrypt(p_enc, public.get_encryption_key());
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END;
END;
$$;

-- Masquage téléphone
CREATE OR REPLACE FUNCTION public.mask_phone(p_enc bytea, p_owner uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  IF p_enc IS NULL THEN RETURN NULL; END IF;
  IF auth.uid() IS DISTINCT FROM p_owner AND NOT public.is_admin() THEN
    RETURN '**********';
  END IF;
  BEGIN
    RETURN pgp_sym_decrypt(p_enc, public.get_encryption_key());
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END;
END;
$$;

-- API RATE LIMITS
CREATE TABLE IF NOT EXISTS public.api_rate_limits (
  user_id UUID NOT NULL,
  endpoint TEXT NOT NULL,
  last_call TIMESTAMPTZ DEFAULT NOW(),
  call_count INTEGER DEFAULT 1,
  PRIMARY KEY (user_id, endpoint)
);

-- SYSTEM LOGS
CREATE TABLE IF NOT EXISTS public.system_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type TEXT NOT NULL CHECK (event_type IN (
    'cron','error','warning','info','security','stripe','workflow','notification'
  )),
  message TEXT,
  details JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- PAYMENT LOGS
CREATE TABLE IF NOT EXISTS public.payment_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stripe_session_id TEXT,
  stripe_payment_intent_id TEXT,
  event_type TEXT NOT NULL,
  event_data JSONB,
  order_id UUID,
  processed BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- CONTACT MESSAGES (avec validation email)
CREATE TABLE IF NOT EXISTS public.contact_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL CHECK (LENGTH(name) <= 200),
  email TEXT NOT NULL CHECK (LENGTH(email) <= 320 AND email ~ '^[^@]+@[^@]+\.[^@]+$'),
  subject TEXT CHECK (LENGTH(subject) <= 500),
  message TEXT NOT NULL CHECK (LENGTH(message) <= 5000),
  ip_address TEXT,
  status TEXT DEFAULT 'new' CHECK (status IN ('new','read','replied','archived')),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- CATEGORIES
CREATE TABLE IF NOT EXISTS public.categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE CHECK (LENGTH(name) <= 100),
  slug TEXT NOT NULL UNIQUE CHECK (LENGTH(slug) <= 100),
  description TEXT CHECK (LENGTH(description) <= 1000),
  icon_name TEXT CHECK (LENGTH(icon_name) <= 50),
  is_active BOOLEAN DEFAULT TRUE,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- SOCIAL LINKS
CREATE TABLE IF NOT EXISTS public.social_links (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  platform TEXT NOT NULL CHECK (LENGTH(platform) <= 50),
  username TEXT NOT NULL CHECK (LENGTH(username) <= 100),
  profile_url TEXT NOT NULL CHECK (LENGTH(profile_url) <= 500),
  followers INTEGER DEFAULT 0 CHECK (followers >= 0),
  engagement_rate DECIMAL(5,2) DEFAULT 0
    CHECK (engagement_rate >= 0 AND engagement_rate <= 100),
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id, platform)
);

-- OFFERS
CREATE TABLE IF NOT EXISTS public.offers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  category_id UUID REFERENCES public.categories(id) ON DELETE SET NULL,
  title TEXT NOT NULL CHECK (LENGTH(title) <= 200),
  description TEXT CHECK (LENGTH(description) <= 5000),
  price DECIMAL(10,2) NOT NULL CHECK (price > 0 AND price <= 100000),
  delivery_time TEXT CHECK (LENGTH(delivery_time) <= 100),
  delivery_days INTEGER CHECK (delivery_days IS NULL OR (delivery_days > 0 AND delivery_days <= 365)),
  is_popular BOOLEAN DEFAULT FALSE,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- CONVERSATIONS
CREATE TABLE IF NOT EXISTS public.conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  participant_1_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  participant_2_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  last_message_at TIMESTAMPTZ DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  CHECK (participant_1_id != participant_2_id)
);

DROP INDEX IF EXISTS ux_conversations_participants_canonical;
CREATE UNIQUE INDEX ux_conversations_participants_canonical
  ON public.conversations (
    LEAST(participant_1_id, participant_2_id),
    GREATEST(participant_1_id, participant_2_id)
  );

-- ORDERS
CREATE TABLE IF NOT EXISTS public.orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  offer_id UUID REFERENCES public.offers(id) ON DELETE SET NULL,

  -- Snapshot de l'offre
  offer_title TEXT,
  offer_description TEXT,
  offer_price_at_order DECIMAL(10,2),
  offer_category_id_at_order UUID,
  offer_category_name_at_order TEXT,
  offer_delivery_days_at_order INTEGER,

  -- Statut
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN (
      'pending',
      'payment_authorized',
      'accepted',
      'in_progress',
      'submitted',
      'review_pending',
      'completed',
      'finished',
      'cancelled',
      'disputed'
    )),

  -- Montants
  total_amount DECIMAL(10,2) NOT NULL CHECK (total_amount > 0),
  net_amount DECIMAL(10,2) NOT NULL CHECK (net_amount > 0),
  commission_rate DECIMAL(5,2) DEFAULT 5.0
    CHECK (commission_rate >= 0 AND commission_rate <= 50),

  -- Détails
  requirements TEXT CHECK (LENGTH(requirements) <= 5000),
  delivery_url TEXT CHECK (LENGTH(delivery_url) <= 1000),

  -- Stripe
  stripe_payment_intent_id TEXT,
  stripe_checkout_session_id TEXT,
  stripe_payment_status TEXT DEFAULT 'unpaid'
    CHECK (stripe_payment_status IN (
      'unpaid',
      'requires_payment_method',
      'requires_confirmation',
      'requires_capture',
      'processing',
      'requires_action',
      'canceled',
      'succeeded',
      'captured',
      'refunded',
      'partially_refunded'
    )),

  -- Timestamps
  payment_authorized_at TIMESTAMPTZ,
  captured_at TIMESTAMPTZ,
  acceptance_deadline TIMESTAMPTZ,
  merchant_confirm_deadline TIMESTAMPTZ,
  submitted_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ,

  -- Dispute
  dispute_reason TEXT CHECK (LENGTH(dispute_reason) <= 2000),
  dispute_opened_at TIMESTAMPTZ,
  dispute_resolved_at TIMESTAMPTZ,
  dispute_resolution TEXT
    CHECK (dispute_resolution IS NULL OR dispute_resolution IN ('refund_merchant','validate_influencer')),

  -- Meta
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),

  CONSTRAINT chk_net_lte_total CHECK (net_amount <= total_amount),
  CONSTRAINT chk_different_parties CHECK (merchant_id != influencer_id),
  CONSTRAINT chk_delivery_url_format CHECK (delivery_url IS NULL OR delivery_url ~ '^https?://')
);

-- MESSAGES
CREATE TABLE IF NOT EXISTS public.messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  sender_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  receiver_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  content TEXT NOT NULL CHECK (LENGTH(content) > 0 AND LENGTH(content) <= 5000),
  is_read BOOLEAN DEFAULT FALSE,
  read_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- REVENUES (ledger)
CREATE TABLE IF NOT EXISTS public.revenues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  net_amount DECIMAL(10,2) NOT NULL CHECK (net_amount > 0),
  commission DECIMAL(10,2) NOT NULL CHECK (commission >= 0),
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','available','withdrawn','cancelled')),
  available_at TIMESTAMPTZ,
  withdrawn_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT uq_revenues_order UNIQUE(order_id),
  CONSTRAINT chk_revenue_math CHECK (ABS(net_amount + commission - amount) < 0.01)
);

-- WITHDRAWALS
CREATE TABLE IF NOT EXISTS public.withdrawals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  fee DECIMAL(10,2) DEFAULT 0 CHECK (fee >= 0),
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','processing','completed','failed','cancelled')),
  iban_last4 TEXT CHECK (iban_last4 IS NULL OR LENGTH(iban_last4) = 4),
  stripe_transfer_id TEXT,
  stripe_payout_id TEXT,
  failure_reason TEXT CHECK (LENGTH(failure_reason) <= 1000),
  processed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- FAVORITES
CREATE TABLE IF NOT EXISTS public.favorites (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(merchant_id, influencer_id),
  CONSTRAINT chk_not_self CHECK (merchant_id != influencer_id)
);

-- NOTIFICATIONS
CREATE TABLE IF NOT EXISTS public.notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK (LENGTH(type) <= 50),
  title TEXT NOT NULL CHECK (LENGTH(title) <= 200),
  content TEXT NOT NULL CHECK (LENGTH(content) <= 2000),
  is_read BOOLEAN DEFAULT FALSE,
  read_at TIMESTAMPTZ,
  related_type TEXT
    CHECK (related_type IS NULL OR related_type IN ('order','message','review','withdrawal','dispute','contestation','system')),
  related_id UUID,
  action_url TEXT CHECK (LENGTH(action_url) <= 500),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- AUDIT ORDERS
CREATE TABLE IF NOT EXISTS public.audit_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  old_status TEXT,
  new_status TEXT NOT NULL,
  changed_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  change_source TEXT DEFAULT 'user'
    CHECK (change_source IN ('user','system','admin','stripe','cron')),
  change_reason TEXT CHECK (LENGTH(change_reason) <= 500),
  metadata JSONB,
  changed_at TIMESTAMPTZ DEFAULT NOW()
);

-- REVIEWS
CREATE TABLE IF NOT EXISTS public.reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  merchant_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  rating INTEGER NOT NULL CHECK (rating >= 1 AND rating <= 5),
  comment TEXT CHECK (LENGTH(comment) <= 2000),
  response TEXT CHECK (LENGTH(response) <= 2000),
  response_at TIMESTAMPTZ,
  is_visible BOOLEAN DEFAULT TRUE,
  moderated_at TIMESTAMPTZ,
  moderated_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  moderation_reason TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT uq_review_order UNIQUE(order_id)
);

-- BANK_ACCOUNTS
CREATE TABLE IF NOT EXISTS public.bank_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  account_holder TEXT NOT NULL CHECK (LENGTH(account_holder) <= 200),
  iban TEXT NOT NULL CHECK (LENGTH(iban) >= 15 AND LENGTH(iban) <= 34),
  bic TEXT CHECK (LENGTH(bic) <= 11),
  bank_name TEXT CHECK (LENGTH(bank_name) <= 200),
  is_default BOOLEAN DEFAULT FALSE,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- PORTFOLIO_ITEMS
CREATE TABLE IF NOT EXISTS public.portfolio_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  title TEXT CHECK (LENGTH(title) <= 200),
  description TEXT CHECK (LENGTH(description) <= 1000),
  media_type TEXT DEFAULT 'image' CHECK (media_type IN ('image','video','link')),
  media_url TEXT NOT NULL CHECK (LENGTH(media_url) <= 1000),
  thumbnail_url TEXT CHECK (LENGTH(thumbnail_url) <= 1000),
  link_url TEXT CHECK (LENGTH(link_url) <= 1000),
  display_order INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- CONTESTATIONS (sans contrainte UNIQUE, on mettra un index partiel après)
CREATE TABLE IF NOT EXISTS public.contestations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  merchant_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  reason TEXT NOT NULL CHECK (LENGTH(reason) <= 2000),
  evidence_url TEXT CHECK (LENGTH(evidence_url) <= 1000),
  evidence_description TEXT CHECK (LENGTH(evidence_description) <= 2000),
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','under_review','accepted','rejected')),
  admin_notes TEXT CHECK (LENGTH(admin_notes) <= 2000),
  decided_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  decided_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================================
-- 3. INDEXES
-- ============================================================================

-- Profiles
CREATE INDEX IF NOT EXISTS idx_profiles_role ON public.profiles(role);
CREATE INDEX IF NOT EXISTS idx_profiles_stripe ON public.profiles(stripe_account_id) WHERE stripe_account_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_profiles_verified ON public.profiles(is_verified) WHERE is_verified = TRUE;
CREATE INDEX IF NOT EXISTS idx_profiles_rating ON public.profiles(average_rating DESC) WHERE role = 'influenceur';
CREATE INDEX IF NOT EXISTS idx_profiles_city_rating
  ON public.profiles(city, average_rating DESC)
  WHERE role = 'influenceur' AND is_verified = TRUE;
CREATE INDEX IF NOT EXISTS idx_profiles_search
  ON public.profiles USING GIN (
    (COALESCE(first_name,'')||' '||COALESCE(last_name,'')||' '||
     COALESCE(bio,'')||' '||COALESCE(city,'')) gin_trgm_ops
  );

-- Orders
CREATE INDEX IF NOT EXISTS idx_orders_merchant ON public.orders(merchant_id);
CREATE INDEX IF NOT EXISTS idx_orders_influencer ON public.orders(influencer_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON public.orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_merchant_status ON public.orders(merchant_id, status);
CREATE INDEX IF NOT EXISTS idx_orders_influencer_status ON public.orders(influencer_id, status);
CREATE INDEX IF NOT EXISTS idx_orders_merchant_created ON public.orders(merchant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_stripe_intent ON public.orders(stripe_payment_intent_id) WHERE stripe_payment_intent_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_orders_created ON public.orders(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_acceptance_deadline_pending
  ON public.orders(acceptance_deadline ASC)
  WHERE status = 'payment_authorized' AND acceptance_deadline IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_orders_merchant_deadline
  ON public.orders(merchant_confirm_deadline) WHERE status IN ('submitted','review_pending');
CREATE INDEX IF NOT EXISTS idx_orders_category_snapshot
  ON public.orders(offer_category_id_at_order) WHERE offer_category_id_at_order IS NOT NULL;

-- Offers
CREATE INDEX IF NOT EXISTS idx_offers_influencer ON public.offers(influencer_id);
CREATE INDEX IF NOT EXISTS idx_offers_category ON public.offers(category_id) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_offers_active ON public.offers(is_active, created_at DESC);

-- Messages
CREATE INDEX IF NOT EXISTS idx_messages_conversation ON public.messages(conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_unread ON public.messages(receiver_id, is_read) WHERE is_read = FALSE;
CREATE INDEX IF NOT EXISTS idx_messages_conv_unread ON public.messages(conversation_id, receiver_id) WHERE is_read = FALSE;

-- Revenues
CREATE INDEX IF NOT EXISTS idx_revenues_influencer ON public.revenues(influencer_id);
CREATE INDEX IF NOT EXISTS idx_revenues_status ON public.revenues(influencer_id, status);
CREATE INDEX IF NOT EXISTS idx_revenues_available ON public.revenues(influencer_id, created_at) WHERE status = 'available';
CREATE INDEX IF NOT EXISTS idx_revenues_influencer_created ON public.revenues(influencer_id, created_at DESC);

-- Withdrawals
CREATE INDEX IF NOT EXISTS idx_withdrawals_influencer ON public.withdrawals(influencer_id);
CREATE INDEX IF NOT EXISTS idx_withdrawals_status ON public.withdrawals(status, created_at);
CREATE INDEX IF NOT EXISTS idx_withdrawals_influencer_status ON public.withdrawals(influencer_id, status);

-- Notifications
CREATE INDEX IF NOT EXISTS idx_notifications_user ON public.notifications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_unread ON public.notifications(user_id) WHERE is_read = FALSE;

-- Reviews
CREATE INDEX IF NOT EXISTS idx_reviews_influencer
  ON public.reviews(influencer_id, created_at DESC)
  WHERE is_visible = TRUE;
CREATE INDEX IF NOT EXISTS idx_reviews_merchant ON public.reviews(merchant_id);

-- Audit
CREATE INDEX IF NOT EXISTS idx_audit_order ON public.audit_orders(order_id, changed_at DESC);

-- Logs
CREATE INDEX IF NOT EXISTS idx_logs_type ON public.system_logs(event_type, created_at DESC);

-- Bank accounts
CREATE INDEX IF NOT EXISTS idx_bank_accounts_user ON public.bank_accounts(user_id);
CREATE INDEX IF NOT EXISTS idx_bank_accounts_default ON public.bank_accounts(user_id, is_default) WHERE is_default = TRUE;

-- Portfolio
CREATE INDEX IF NOT EXISTS idx_portfolio_influencer ON public.portfolio_items(influencer_id);
CREATE INDEX IF NOT EXISTS idx_portfolio_active
  ON public.portfolio_items(influencer_id, display_order) WHERE is_active = TRUE;

-- Contestations
CREATE INDEX IF NOT EXISTS idx_contestations_order ON public.contestations(order_id);
CREATE INDEX IF NOT EXISTS idx_contestations_status ON public.contestations(status);
CREATE INDEX IF NOT EXISTS idx_contestations_pending
  ON public.contestations(created_at DESC)
  WHERE status IN ('pending', 'under_review');

-- Unicité "une contestation active par commande"
CREATE UNIQUE INDEX IF NOT EXISTS uq_contestation_order_active
ON public.contestations(order_id)
WHERE status IN ('pending','under_review');

-- Un seul compte par défaut par user
CREATE UNIQUE INDEX IF NOT EXISTS ux_bank_accounts_one_default_per_user
ON public.bank_accounts(user_id)
WHERE is_default = TRUE;

-- ============================================================================
-- 4. FONCTIONS MÉTIER & SÉCURITÉ
-- ============================================================================

-- Rate Limiting générique
CREATE OR REPLACE FUNCTION public.apply_rate_limit(p_endpoint text, p_limit int DEFAULT 30)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_user uuid := auth.uid();
  v_count int;
BEGIN
  IF v_user IS NULL THEN
    RETURN;
  END IF;

  p_limit := CASE p_endpoint
    WHEN 'messages' THEN 60
    WHEN 'orders' THEN 10
    WHEN 'reviews' THEN 5
    WHEN 'withdrawals' THEN 3
    WHEN 'contestations' THEN 5
    WHEN 'profile_view' THEN 100
    ELSE p_limit
  END;

  INSERT INTO public.api_rate_limits (user_id, endpoint, last_call, call_count)
  VALUES (v_user, p_endpoint, NOW(), 1)
  ON CONFLICT (user_id, endpoint) DO UPDATE SET
    call_count = CASE
      WHEN api_rate_limits.last_call > NOW() - INTERVAL '1 minute'
        THEN api_rate_limits.call_count + 1
      ELSE 1
    END,
    last_call = NOW()
  RETURNING call_count INTO v_count;

  IF v_count > p_limit THEN
    RAISE EXCEPTION 'Rate limit exceeded for %', p_endpoint;
  END IF;
END;
$$;

-- Rate limit messages
CREATE OR REPLACE FUNCTION public.check_message_rate_limit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.apply_rate_limit('messages');
  RETURN NEW;
END;
$$;

-- Protection champs sensibles profil
CREATE OR REPLACE FUNCTION public.protect_sensitive_profile_fields()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT public.is_admin() AND NOT public.is_service_role() THEN
    IF NEW.stripe_account_id IS DISTINCT FROM OLD.stripe_account_id
       OR NEW.is_verified IS DISTINCT FROM OLD.is_verified
       OR NEW.role IS DISTINCT FROM OLD.role
    THEN
      RAISE EXCEPTION 'Security violation: Cannot modify sensitive fields (Stripe/Verified/Role)';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- Matrice transitions
CREATE OR REPLACE FUNCTION public.validate_order_status_transition(
  p_old TEXT,
  p_new TEXT,
  p_role TEXT,
  p_stripe TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE AS $$
BEGIN
  IF p_old = p_new THEN
    RETURN TRUE;
  END IF;

  -- Admin : tout, mais completed/finished seulement si Stripe capturé/succeeded
  IF p_role = 'admin' THEN
    IF p_new IN ('completed','finished')
       AND p_stripe IS NOT NULL
       AND p_stripe NOT IN ('captured','succeeded')
    THEN
      RETURN FALSE;
    END IF;
    RETURN TRUE;
  END IF;

  -- Rôles techniques
  IF p_role IN ('system','cron','stripe') THEN
    RETURN TRUE;
  END IF;

  -- Règles Merchant
  IF p_role = 'merchant' THEN
    RETURN CASE
      WHEN p_old = 'pending' AND p_new = 'cancelled' THEN TRUE
      WHEN p_old = 'submitted' AND p_new IN ('completed','review_pending','disputed') THEN TRUE
      WHEN p_old = 'review_pending' AND p_new IN ('completed','disputed') THEN TRUE
      WHEN p_old = 'completed' AND p_new = 'disputed' THEN TRUE
      ELSE FALSE
    END;
  END IF;

  -- Règles Influenceur (PAS de passage manuel vers accepted)
  IF p_role = 'influencer' THEN
    RETURN CASE
      WHEN p_old = 'payment_authorized' AND p_new = 'cancelled' THEN TRUE
      WHEN p_old = 'accepted' AND p_new = 'in_progress' THEN TRUE
      WHEN p_old = 'accepted' AND p_new = 'cancelled' THEN TRUE
      WHEN p_old = 'in_progress' AND p_new = 'submitted' THEN TRUE
      WHEN p_old = 'review_pending' AND p_new = 'submitted' THEN TRUE
      ELSE FALSE
    END;
  END IF;

  RETURN FALSE;
END;
$$;

-- Calcul montants
CREATE OR REPLACE FUNCTION public.calculate_order_amounts()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  NEW.total_amount := ROUND(NEW.total_amount, 2);
  NEW.commission_rate := COALESCE(NEW.commission_rate, 5.0);

  IF NEW.net_amount IS NULL
     OR NEW.net_amount <= 0
     OR (TG_OP = 'UPDATE' AND OLD.total_amount IS DISTINCT FROM NEW.total_amount)
  THEN
    NEW.net_amount := ROUND(NEW.total_amount * (1 - NEW.commission_rate / 100), 2);
  END IF;

  IF NEW.net_amount > NEW.total_amount THEN
    RAISE EXCEPTION 'net > total';
  END IF;

  RETURN NEW;
END;
$$;

-- Règles de création d'order (sans recalcul net_amount)
CREATE OR REPLACE FUNCTION public.enforce_order_creation_rules()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  NEW.status := 'pending';
  NEW.stripe_payment_status := 'unpaid';
  NEW.stripe_payment_intent_id := NULL;
  RETURN NEW;
END;
$$;

-- Snapshot offre
CREATE OR REPLACE FUNCTION public.snapshot_offer_on_order_create()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
  v_offer RECORD;
BEGIN
  IF TG_OP = 'INSERT' AND NEW.offer_id IS NOT NULL THEN
    SELECT o.title, o.description, o.price, o.category_id, o.delivery_days, c.name AS category_name
    INTO v_offer
    FROM public.offers o
    LEFT JOIN public.categories c ON c.id = o.category_id
    WHERE o.id = NEW.offer_id;

    IF FOUND THEN
      NEW.offer_title := COALESCE(NEW.offer_title, v_offer.title);
      NEW.offer_description := COALESCE(NEW.offer_description, v_offer.description);
      NEW.offer_price_at_order := COALESCE(NEW.offer_price_at_order, v_offer.price);
      NEW.offer_category_id_at_order := COALESCE(NEW.offer_category_id_at_order, v_offer.category_id);
      NEW.offer_category_name_at_order := COALESCE(NEW.offer_category_name_at_order, v_offer.category_name);
      NEW.offer_delivery_days_at_order := COALESCE(NEW.offer_delivery_days_at_order, v_offer.delivery_days);
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- Sync Stripe -> Order
CREATE OR REPLACE FUNCTION public.sync_stripe_status_to_order()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  IF NEW.stripe_payment_status IS DISTINCT FROM OLD.stripe_payment_status THEN
    IF NOT public.is_service_role() THEN
      NEW.stripe_payment_status := OLD.stripe_payment_status;
      RETURN NEW;
    END IF;
  END IF;

  IF NEW.stripe_payment_status = 'requires_capture'
     AND OLD.stripe_payment_status IS DISTINCT FROM 'requires_capture'
  THEN
    IF NEW.status = 'pending' THEN
      NEW.status := 'payment_authorized';
      NEW.payment_authorized_at := NOW();
      NEW.acceptance_deadline := NOW() + INTERVAL '48 hours';
    END IF;

  ELSIF NEW.stripe_payment_status IN ('captured','succeeded')
        AND OLD.stripe_payment_status NOT IN ('captured','succeeded')
  THEN
    NEW.captured_at := NOW();

  ELSIF NEW.stripe_payment_status = 'canceled'
        AND OLD.stripe_payment_status = 'requires_capture'
  THEN
    IF NEW.status NOT IN ('cancelled','disputed') THEN
      NEW.status := 'cancelled';
      NEW.cancelled_at := NOW();
    END IF;

  ELSIF NEW.stripe_payment_status IN ('refunded','partially_refunded')
        AND OLD.stripe_payment_status NOT IN ('refunded','partially_refunded')
  THEN
    IF NEW.status NOT IN ('cancelled','disputed') THEN
      NEW.status := 'cancelled';
      NEW.cancelled_at := NOW();
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- Audit orders
CREATE OR REPLACE FUNCTION public.audit_order_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO public.audit_orders (
      order_id, old_status, new_status, changed_by, change_source, metadata
    )
    VALUES (
      NEW.id,
      OLD.status,
      NEW.status,
      auth.uid(),
      CASE
        WHEN public.is_service_role() THEN 'system'
        WHEN public.is_admin() THEN 'admin'
        ELSE 'user'
      END,
      jsonb_build_object(
        'stripe_status', NEW.stripe_payment_status,
        'ts', NOW()
      )
    );
  END IF;
  RETURN NEW;
END;
$$;

-- HTTP webhook notify
CREATE OR REPLACE FUNCTION public.notify_order_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_url TEXT;
  v_key TEXT;
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    v_url := current_setting('app.supabase_url', true);
    v_key := current_setting('app.service_role_key', true);

    IF v_url IS NOT NULL AND v_key IS NOT NULL
       AND v_url <> '' AND v_key <> ''
    THEN
      PERFORM net.http_post(
        url := v_url || '/functions/v1/notify-order-events',
        headers := jsonb_build_object(
          'Content-Type','application/json',
          'Authorization','Bearer '||v_key
        ),
        body := jsonb_build_object(
          'orderId', NEW.id,
          'oldStatus', OLD.status,
          'newStatus', NEW.status,
          'merchantId', NEW.merchant_id,
          'influencerId', NEW.influencer_id,
          'stripePaymentIntent', NEW.stripe_payment_intent_id
        )
      );
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- Create notification helper
CREATE OR REPLACE FUNCTION public.create_notification(
  p_user UUID,
  p_type TEXT,
  p_title TEXT,
  p_content TEXT,
  p_rel_type TEXT DEFAULT NULL,
  p_rel_id UUID DEFAULT NULL,
  p_url TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_id UUID;
BEGIN
  INSERT INTO public.notifications (
    user_id, type, title, content, related_type, related_id, action_url
  )
  VALUES (p_user, p_type, p_title, p_content, p_rel_type, p_rel_id, p_url)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- Auto notify order status
CREATE OR REPLACE FUNCTION public.auto_notify_order_status()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_title TEXT;
  v_content TEXT;
  v_user UUID;
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    CASE NEW.status
      WHEN 'payment_authorized' THEN
        v_user := NEW.influencer_id;
        v_title := 'Nouvelle commande!';
        v_content := 'Vous avez 48h pour accepter.';
      WHEN 'accepted' THEN
        v_user := NEW.merchant_id;
        v_title := 'Commande acceptée';
        v_content := 'L''influenceur a accepté.';
      WHEN 'cancelled' THEN
        v_user := CASE WHEN OLD.status = 'payment_authorized'
                       THEN NEW.merchant_id
                       ELSE NEW.influencer_id
                  END;
        v_title := 'Commande annulée';
        v_content := 'La commande a été annulée.';
      WHEN 'submitted' THEN
        v_user := NEW.merchant_id;
        v_title := 'Livraison reçue!';
        v_content := 'Vous avez 48h pour valider.';
      WHEN 'review_pending' THEN
        v_user := NEW.influencer_id;
        v_title := 'Modifications demandées';
        v_content := 'Le merchant demande des modifications.';
      WHEN 'completed' THEN
        v_user := NEW.influencer_id;
        v_title := 'Commande validée!';
        v_content := 'Prestation validée.';
      WHEN 'disputed' THEN
        v_user := NEW.influencer_id;
        v_title := 'Litige ouvert';
        v_content := 'Un litige a été ouvert.';
      WHEN 'finished' THEN
        v_user := NEW.influencer_id;
        v_title := 'Fonds disponibles!';
        v_content := 'Fonds disponibles pour retrait.';
      ELSE
        v_user := NULL;
    END CASE;

    IF v_user IS NOT NULL THEN
      PERFORM public.create_notification(
        v_user,
        'order_status',
        v_title,
        v_content,
        'order',
        NEW.id,
        '/orders/'||NEW.id::text
      );
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- Update influencer stats on review
CREATE OR REPLACE FUNCTION public.update_influencer_stats_on_review()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_avg DECIMAL(3,2);
  v_count INTEGER;
BEGIN
  IF TG_OP = 'INSERT'
     OR (TG_OP = 'UPDATE' AND OLD.rating IS DISTINCT FROM NEW.rating)
  THEN
    SELECT AVG(rating)::DECIMAL(3,2), COUNT(*)
    INTO v_avg, v_count
    FROM public.reviews
    WHERE influencer_id = NEW.influencer_id
      AND is_visible = TRUE;

    UPDATE public.profiles
    SET average_rating = COALESCE(v_avg,0),
        total_reviews = COALESCE(v_count,0),
        updated_at = NOW()
    WHERE id = NEW.influencer_id;
  END IF;
  RETURN NEW;
END;
$$;

-- Canonicalize conversation
CREATE OR REPLACE FUNCTION public.canonicalize_conversation()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.participant_1_id > NEW.participant_2_id THEN
    SELECT NEW.participant_2_id, NEW.participant_1_id
    INTO NEW.participant_1_id, NEW.participant_2_id;
  END IF;
  RETURN NEW;
END;
$$;

-- Check message integrity
CREATE OR REPLACE FUNCTION public.check_message_integrity()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
  v_p1 UUID;
  v_p2 UUID;
BEGIN
  IF NEW.sender_id = NEW.receiver_id THEN
    RAISE EXCEPTION 'Cannot message yourself';
  END IF;

  SELECT participant_1_id, participant_2_id
  INTO v_p1, v_p2
  FROM public.conversations
  WHERE id = NEW.conversation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Conversation not found';
  END IF;

  IF NEW.sender_id NOT IN (v_p1, v_p2)
     OR NEW.receiver_id NOT IN (v_p1, v_p2)
  THEN
    RAISE EXCEPTION 'Not in conversation';
  END IF;

  RETURN NEW;
END;
$$;

-- Update conversation timestamp
CREATE OR REPLACE FUNCTION public.update_conversation_timestamp()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE public.conversations
  SET last_message_at = NOW()
  WHERE id = NEW.conversation_id;
  RETURN NEW;
END;
$$;

-- Single default bank account (avec index unique déjà créé)
CREATE OR REPLACE FUNCTION public.ensure_single_default_bank_account()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.is_default = TRUE THEN
    UPDATE public.bank_accounts
    SET is_default = FALSE,
        updated_at = NOW()
    WHERE user_id = NEW.user_id
      AND id <> NEW.id
      AND is_default = TRUE;
  END IF;
  RETURN NEW;
END;
$$;

-- Safe update order status
CREATE OR REPLACE FUNCTION public.safe_update_order_status(
  p_order_id UUID,
  p_new_status TEXT,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_actor UUID := auth.uid();
  v_role TEXT;
  v_valid BOOLEAN;
BEGIN
  PERFORM public.apply_rate_limit('safe_update_order_status');

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found: %', p_order_id;
  END IF;

  IF public.is_admin() THEN
    v_role := 'admin';
  ELSIF v_actor = v_order.merchant_id THEN
    v_role := 'merchant';
  ELSIF v_actor = v_order.influencer_id THEN
    v_role := 'influencer';
  ELSE
    RAISE EXCEPTION 'Access denied';
  END IF;

  v_valid := public.validate_order_status_transition(
    v_order.status, p_new_status, v_role, v_order.stripe_payment_status
  );
  IF NOT v_valid THEN
    RAISE EXCEPTION 'Invalid transition: % -> % (%)',
      v_order.status, p_new_status, v_role;
  END IF;

  IF p_new_status = 'accepted' AND v_role = 'influencer' THEN
    RAISE EXCEPTION 'Use the dedicated accept-order API (Stripe Capture) to accept orders.';
  END IF;

  UPDATE public.orders
  SET status = p_new_status,
      updated_at = NOW(),
      submitted_at = CASE WHEN p_new_status = 'submitted' THEN NOW() ELSE submitted_at END,
      completed_at = CASE WHEN p_new_status = 'completed' THEN NOW() ELSE completed_at END,
      cancelled_at = CASE WHEN p_new_status = 'cancelled' THEN NOW() ELSE cancelled_at END,
      merchant_confirm_deadline = CASE
        WHEN p_new_status IN ('submitted','review_pending')
          THEN NOW() + INTERVAL '48 hours'
        ELSE merchant_confirm_deadline
      END,
      dispute_reason = CASE
        WHEN p_new_status = 'disputed' THEN p_reason
        ELSE dispute_reason
      END,
      dispute_opened_at = CASE
        WHEN p_new_status = 'disputed' THEN NOW()
        ELSE dispute_opened_at
      END
  WHERE id = p_order_id;

  IF p_new_status = 'completed'
     AND v_order.status NOT IN ('completed','finished')
  THEN
    INSERT INTO public.revenues (
      influencer_id, order_id, amount, net_amount, commission, status
    )
    VALUES (
      v_order.influencer_id,
      p_order_id,
      v_order.total_amount,
      v_order.net_amount,
      v_order.total_amount - v_order.net_amount,
      'pending'
    )
    ON CONFLICT (order_id) DO NOTHING;
  END IF;

  IF p_new_status = 'finished' THEN
    UPDATE public.revenues
    SET status = 'available',
        available_at = NOW(),
        updated_at = NOW()
    WHERE order_id = p_order_id
      AND status = 'pending';

    UPDATE public.profiles
    SET completed_orders_count = completed_orders_count + 1,
        updated_at = NOW()
    WHERE id = v_order.influencer_id;
  END IF;

  IF p_new_status = 'cancelled'
     AND v_order.status = 'accepted'
     AND v_role = 'influencer'
  THEN
    INSERT INTO public.system_logs (event_type, message, details)
    VALUES (
      'workflow',
      'Order cancelled by influencer after acceptance',
      jsonb_build_object(
        'order_id', p_order_id,
        'influencer_id', v_order.influencer_id,
        'payment_intent', v_order.stripe_payment_intent_id,
        'action_required', 'cancel_authorization_or_refund',
        'reason', p_reason
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE,
    'order_id', p_order_id,
    'old_status', v_order.status,
    'new_status', p_new_status,
    'actor_role', v_role
  );
END;
$$;

-- Submit delivery
CREATE OR REPLACE FUNCTION public.submit_delivery(
  p_order_id UUID,
  p_delivery_url TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_order RECORD;
  v_user UUID := auth.uid();
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Auth required';
  END IF;

  IF p_delivery_url IS NULL OR TRIM(p_delivery_url) = '' THEN
    RAISE EXCEPTION 'Delivery URL required';
  END IF;

  IF p_delivery_url !~ '^https?://' THEN
    RAISE EXCEPTION 'Invalid URL format';
  END IF;

  IF LENGTH(p_delivery_url) > 1000 THEN
    RAISE EXCEPTION 'URL too long';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found';
  END IF;

  IF v_order.influencer_id <> v_user THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  IF v_order.status NOT IN ('accepted','in_progress','review_pending') THEN
    RAISE EXCEPTION 'Cannot submit for status: %', v_order.status;
  END IF;

  IF v_order.stripe_payment_status NOT IN ('captured','succeeded') THEN
    RAISE EXCEPTION 'Payment not captured';
  END IF;

  UPDATE public.orders
  SET delivery_url = p_delivery_url,
      status = 'submitted',
      submitted_at = NOW(),
      merchant_confirm_deadline = NOW() + INTERVAL '48 hours',
      updated_at = NOW()
  WHERE id = p_order_id;

  PERFORM public.create_notification(
    v_order.merchant_id,
    'delivery_submitted',
    'Livraison reçue!',
    'Vous avez 48h pour valider.',
    'order',
    p_order_id,
    '/orders/'||p_order_id::text
  );

  RETURN jsonb_build_object(
    'success', TRUE,
    'order_id', p_order_id,
    'new_status', 'submitted'
  );
END;
$$;

-- Handle cron deadlines
CREATE OR REPLACE FUNCTION public.handle_cron_deadlines()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  rec RECORD;
  v_cancelled INT := 0;
  v_completed INT := 0;
BEGIN
  IF NOT public.is_service_role() THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  FOR rec IN
    SELECT id, stripe_payment_intent_id
    FROM public.orders
    WHERE status = 'payment_authorized'
      AND acceptance_deadline < NOW()
    ORDER BY acceptance_deadline ASC
    LIMIT 500
  LOOP
    UPDATE public.orders
    SET status = 'cancelled',
        cancelled_at = NOW(),
        updated_at = NOW()
    WHERE id = rec.id;

    INSERT INTO public.system_logs (event_type, message, details)
    VALUES (
      'cron',
      'Order cancelled - timeout',
      jsonb_build_object(
        'order_id', rec.id,
        'payment_intent', rec.stripe_payment_intent_id,
        'action', 'cancel_authorization'
      )
    );

    v_cancelled := v_cancelled + 1;
  END LOOP;

  FOR rec IN
    SELECT id, influencer_id, total_amount, net_amount
    FROM public.orders
    WHERE status IN ('submitted','review_pending')
      AND merchant_confirm_deadline < NOW()
    ORDER BY merchant_confirm_deadline ASC
    LIMIT 500
  LOOP
    UPDATE public.orders
    SET status = 'completed',
        completed_at = NOW(),
        updated_at = NOW()
    WHERE id = rec.id;

    INSERT INTO public.revenues (
      influencer_id, order_id, amount, net_amount, commission, status
    )
    VALUES (
      rec.influencer_id,
      rec.id,
      rec.total_amount,
      rec.net_amount,
      rec.total_amount - rec.net_amount,
      'pending'
    )
    ON CONFLICT (order_id) DO NOTHING;

    INSERT INTO public.system_logs (event_type, message, details)
    VALUES (
      'cron',
      'Order auto-completed',
      jsonb_build_object('order_id', rec.id)
    );

    v_completed := v_completed + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'success', TRUE,
    'cancelled', v_cancelled,
    'completed', v_completed,
    'executed_at', NOW()
  );
END;
$$;

-- Request withdrawal
CREATE OR REPLACE FUNCTION public.request_withdrawal(p_amount DECIMAL)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_user UUID := auth.uid();
  v_avail DECIMAL;
  v_pend DECIMAL;
  v_eff DECIMAL;
  v_id UUID;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Auth required';
  END IF;

  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be positive';
  END IF;

  IF p_amount < 10 THEN
    RAISE EXCEPTION 'Minimum withdrawal: 10€';
  END IF;

  PERFORM public.apply_rate_limit('withdrawals');

  PERFORM 1
  FROM public.profiles
  WHERE id = v_user
  FOR UPDATE;

  SELECT COALESCE(SUM(net_amount), 0)
  INTO v_avail
  FROM public.revenues
  WHERE influencer_id = v_user
    AND status = 'available';

  SELECT COALESCE(SUM(amount), 0)
  INTO v_pend
  FROM public.withdrawals
  WHERE influencer_id = v_user
    AND status IN ('pending','processing');

  v_eff := v_avail - v_pend;

  IF p_amount > v_eff THEN
    RAISE EXCEPTION 'Insufficient balance. Available: %, Requested: %',
      v_eff, p_amount;
  END IF;

  INSERT INTO public.withdrawals (influencer_id, amount, status)
  VALUES (v_user, p_amount, 'pending')
  RETURNING id INTO v_id;

  PERFORM public.create_notification(
    v_user,
    'withdrawal_requested',
    'Demande de retrait',
    'Retrait de '||p_amount||'€ en cours.',
    'withdrawal',
    v_id,
    '/wallet'
  );

  RETURN v_id;
END;
$$;

-- Finalize revenue withdrawal (FIFO)
CREATE OR REPLACE FUNCTION public.finalize_revenue_withdrawal(
  p_influencer_id UUID,
  p_amount DECIMAL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  rec RECORD;
  v_rem DECIMAL := p_amount;
  v_cnt INT := 0;
  v_tot DECIMAL := 0;
BEGIN
  IF NOT public.is_service_role() THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  FOR rec IN
    SELECT id, net_amount
    FROM public.revenues
    WHERE influencer_id = p_influencer_id
      AND status = 'available'
    ORDER BY created_at ASC
  LOOP
    EXIT WHEN v_rem <= 0;

    IF rec.net_amount <= v_rem THEN
      UPDATE public.revenues
      SET status = 'withdrawn',
          withdrawn_at = NOW(),
          updated_at = NOW()
      WHERE id = rec.id;

      v_rem := v_rem - rec.net_amount;
      v_tot := v_tot + rec.net_amount;
      v_cnt := v_cnt + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'success', v_rem < 0.01,
    'processed_count', v_cnt,
    'processed_amount', v_tot,
    'remaining', v_rem
  );
END;
$$;

-- Revert revenue withdrawal
CREATE OR REPLACE FUNCTION public.revert_revenue_withdrawal(
  p_influencer_id UUID,
  p_amount DECIMAL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  rec RECORD;
  v_rem DECIMAL := p_amount;
  v_cnt INT := 0;
  v_tot DECIMAL := 0;
BEGIN
  IF NOT public.is_service_role() THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  FOR rec IN
    SELECT id, net_amount
    FROM public.revenues
    WHERE influencer_id = p_influencer_id
      AND status = 'withdrawn'
    ORDER BY withdrawn_at DESC
  LOOP
    EXIT WHEN v_rem <= 0;

    IF rec.net_amount <= v_rem THEN
      UPDATE public.revenues
      SET status = 'available',
          withdrawn_at = NULL,
          updated_at = NOW()
      WHERE id = rec.id;

      v_rem := v_rem - rec.net_amount;
      v_tot := v_tot + rec.net_amount;
      v_cnt := v_cnt + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'success', TRUE,
    'reverted_count', v_cnt,
    'reverted_amount', v_tot
  );
END;
$$;

-- Get available balance
CREATE OR REPLACE FUNCTION public.get_available_balance()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_user UUID := auth.uid();
  v_avail DECIMAL;
  v_pend_rev DECIMAL;
  v_pend_with DECIMAL;
  v_total DECIMAL;
  v_withdrawn DECIMAL;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Auth required';
  END IF;

  SELECT COALESCE(SUM(net_amount), 0)
  INTO v_avail
  FROM public.revenues
  WHERE influencer_id = v_user
    AND status = 'available';

  SELECT COALESCE(SUM(net_amount), 0)
  INTO v_pend_rev
  FROM public.revenues
  WHERE influencer_id = v_user
    AND status = 'pending';

  SELECT COALESCE(SUM(amount), 0)
  INTO v_pend_with
  FROM public.withdrawals
  WHERE influencer_id = v_user
    AND status IN ('pending','processing');

  SELECT COALESCE(SUM(net_amount), 0)
  INTO v_total
  FROM public.revenues
  WHERE influencer_id = v_user;

  SELECT COALESCE(SUM(net_amount), 0)
  INTO v_withdrawn
  FROM public.revenues
  WHERE influencer_id = v_user
    AND status = 'withdrawn';

  RETURN jsonb_build_object(
    'available', v_avail - v_pend_with,
    'pending_revenues', v_pend_rev,
    'pending_withdrawals', v_pend_with,
    'total_earned', v_total,
    'total_withdrawn', v_withdrawn
  );
END;
$$;

-- Admin resolve dispute
CREATE OR REPLACE FUNCTION public.admin_resolve_dispute(
  p_order_id UUID,
  p_resolution TEXT,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_order public.orders%ROWTYPE;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Admin required';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found';
  END IF;

  IF v_order.status <> 'disputed' THEN
    RAISE EXCEPTION 'Not disputed';
  END IF;

  IF p_resolution NOT IN ('refund_merchant','validate_influencer') THEN
    RAISE EXCEPTION 'Invalid resolution';
  END IF;

  IF p_resolution = 'refund_merchant' THEN
    UPDATE public.orders
    SET status = 'cancelled',
        cancelled_at = NOW(),
        dispute_resolved_at = NOW(),
        dispute_resolution = p_resolution,
        updated_at = NOW()
    WHERE id = p_order_id;

    UPDATE public.revenues
    SET status = 'cancelled',
        updated_at = NOW()
    WHERE order_id = p_order_id;

    INSERT INTO public.system_logs (event_type, message, details)
    VALUES (
      'workflow',
      'Dispute - refund required',
      jsonb_build_object(
        'order_id', p_order_id,
        'payment_intent', v_order.stripe_payment_intent_id,
        'action', 'refund',
        'reason', p_reason
      )
    );

  ELSE
    UPDATE public.orders
    SET status = 'finished',
        completed_at = COALESCE(completed_at, NOW()),
        dispute_resolved_at = NOW(),
        dispute_resolution = p_resolution,
        updated_at = NOW()
    WHERE id = p_order_id;

    INSERT INTO public.revenues (
      influencer_id, order_id, amount, net_amount, commission, status, available_at
    )
    VALUES (
      v_order.influencer_id,
      p_order_id,
      v_order.total_amount,
      v_order.net_amount,
      v_order.total_amount - v_order.net_amount,
      'available',
      NOW()
    )
    ON CONFLICT (order_id) DO UPDATE
      SET status = 'available',
          available_at = NOW(),
          updated_at = NOW();
  END IF;

  PERFORM public.create_notification(
    CASE WHEN p_resolution = 'refund_merchant'
         THEN v_order.merchant_id
         ELSE v_order.influencer_id
    END,
    'dispute_resolved',
    'Litige résolu',
    CASE
      WHEN p_resolution = 'refund_merchant'
        THEN 'Résolu en votre faveur.'
      ELSE 'Fonds disponibles.'
    END,
    'order',
    p_order_id
  );

  RETURN jsonb_build_object(
    'success', TRUE,
    'order_id', p_order_id,
    'resolution', p_resolution,
    'new_status', CASE
      WHEN p_resolution = 'refund_merchant' THEN 'cancelled'
      ELSE 'finished'
    END
  );
END;
$$;

-- Create review
CREATE OR REPLACE FUNCTION public.create_review(
  p_order_id UUID,
  p_rating INTEGER,
  p_comment TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_order RECORD;
  v_user UUID := auth.uid();
  v_id UUID;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Auth required';
  END IF;

  PERFORM public.apply_rate_limit('reviews');

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found';
  END IF;

  IF v_order.merchant_id <> v_user THEN
    RAISE EXCEPTION 'Only merchant can review';
  END IF;

  IF v_order.status NOT IN ('completed','finished') THEN
    RAISE EXCEPTION 'Order not completed';
  END IF;

  IF p_rating < 1 OR p_rating > 5 THEN
    RAISE EXCEPTION 'Rating 1-5';
  END IF;

  INSERT INTO public.reviews (
    order_id, merchant_id, influencer_id, rating, comment
  )
  VALUES (
    p_order_id, v_user, v_order.influencer_id, p_rating, p_comment
  )
  RETURNING id INTO v_id;

  PERFORM public.create_notification(
    v_order.influencer_id,
    'new_review',
    'Nouvel avis!',
    'Avis '||p_rating||'/5 reçu.',
    'review',
    v_id
  );

  RETURN v_id;
END;
$$;

-- Respond to review
CREATE OR REPLACE FUNCTION public.respond_to_review(
  p_review_id UUID,
  p_response TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_review RECORD;
  v_user UUID := auth.uid();
BEGIN
  SELECT * INTO v_review
  FROM public.reviews
  WHERE id = p_review_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Review not found';
  END IF;

  IF v_review.influencer_id <> v_user THEN
    RAISE EXCEPTION 'Only influencer can respond';
  END IF;

  IF v_review.response IS NOT NULL THEN
    RAISE EXCEPTION 'Already responded';
  END IF;

  UPDATE public.reviews
  SET response = p_response,
      response_at = NOW(),
      updated_at = NOW()
  WHERE id = p_review_id;

  RETURN TRUE;
END;
$$;

-- Create contestation
CREATE OR REPLACE FUNCTION public.create_contestation(
  p_order_id UUID,
  p_reason TEXT,
  p_evidence_url TEXT DEFAULT NULL,
  p_evidence_desc TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_order RECORD;
  v_user UUID := auth.uid();
  v_id UUID;
  v_existing UUID;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Auth required';
  END IF;

  PERFORM public.apply_rate_limit('contestations');

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found';
  END IF;

  IF v_order.influencer_id <> v_user THEN
    RAISE EXCEPTION 'Only influencer can contest';
  END IF;

  IF v_order.status NOT IN ('disputed','review_pending') THEN
    RAISE EXCEPTION 'Can only contest disputed or review_pending. Current: %', v_order.status;
  END IF;

  SELECT id INTO v_existing
  FROM public.contestations
  WHERE order_id = p_order_id
    AND status IN ('pending','under_review');

  IF v_existing IS NOT NULL THEN
    RAISE EXCEPTION 'Contestation already pending';
  END IF;

  INSERT INTO public.contestations (
    order_id, influencer_id, merchant_id,
    reason, evidence_url, evidence_description
  )
  VALUES (
    p_order_id, v_user, v_order.merchant_id,
    p_reason, p_evidence_url, p_evidence_desc
  )
  RETURNING id INTO v_id;

  PERFORM public.create_notification(
    v_order.merchant_id,
    'contestation_created',
    'Contestation reçue',
    'L''influenceur conteste.',
    'contestation',
    v_id
  );

  INSERT INTO public.system_logs (event_type, message, details)
  VALUES (
    'workflow',
    'Contestation created',
    jsonb_build_object(
      'contestation_id', v_id,
      'order_id', p_order_id
    )
  );

  RETURN v_id;
END;
$$;

-- Admin resolve contestation
CREATE OR REPLACE FUNCTION public.admin_resolve_contestation(
  p_contestation_id UUID,
  p_status TEXT,
  p_admin_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_cont RECORD;
  v_order RECORD;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Admin required';
  END IF;

  SELECT * INTO v_cont
  FROM public.contestations
  WHERE id = p_contestation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contestation not found';
  END IF;

  IF v_cont.status NOT IN ('pending','under_review') THEN
    RAISE EXCEPTION 'Already resolved';
  END IF;

  IF p_status NOT IN ('accepted','rejected') THEN
    RAISE EXCEPTION 'Invalid status';
  END IF;

  UPDATE public.contestations
  SET status = p_status,
      admin_notes = p_admin_notes,
      decided_by = auth.uid(),
      decided_at = NOW(),
      updated_at = NOW()
  WHERE id = p_contestation_id;

  IF p_status = 'accepted' THEN
    SELECT * INTO v_order
    FROM public.orders
    WHERE id = v_cont.order_id;

    IF v_order.status = 'disputed' THEN
      PERFORM public.admin_resolve_dispute(
        v_order.id,
        'validate_influencer',
        'Contestation accepted'
      );
    END IF;
  END IF;

  PERFORM public.create_notification(
    v_cont.influencer_id,
    'contestation_resolved',
    CASE WHEN p_status = 'accepted'
         THEN 'Contestation acceptée'
         ELSE 'Contestation refusée'
    END,
    CASE WHEN p_status = 'accepted'
         THEN 'Acceptée.'
         ELSE 'Refusée.'
    END,
    'contestation',
    p_contestation_id
  );

  RETURN jsonb_build_object(
    'success', TRUE,
    'contestation_id', p_contestation_id,
    'status', p_status
  );
END;
$$;

-- Increment profile view (auth only, rate limited)
CREATE OR REPLACE FUNCTION public.increment_profile_view(p_profile_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_new INTEGER;
BEGIN
  PERFORM public.apply_rate_limit('profile_view', 100);

  UPDATE public.profiles
  SET profile_views = profile_views + 1
  WHERE id = p_profile_id
  RETURNING profile_views INTO v_new;

  RETURN COALESCE(v_new, 0);
END;
$$;

-- Increment profile share
CREATE OR REPLACE FUNCTION public.increment_profile_share(p_profile_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_new INTEGER;
BEGIN
  UPDATE public.profiles
  SET profile_share_count = profile_share_count + 1
  WHERE id = p_profile_id
  RETURNING profile_share_count INTO v_new;

  RETURN COALESCE(v_new, 0);
END;
$$;

-- Mark all notifications read
CREATE OR REPLACE FUNCTION public.mark_all_notifications_read()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_user UUID := auth.uid();
  v_count INTEGER;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Auth required';
  END IF;

  UPDATE public.notifications
  SET is_read = TRUE,
      read_at = NOW(),
      updated_at = NOW()
  WHERE user_id = v_user
    AND is_read = FALSE;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  RETURN v_count;
END;
$$;

-- Cleanup notifications per user
CREATE OR REPLACE FUNCTION public.cleanup_old_notifications(p_days INTEGER DEFAULT 30)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_user UUID := auth.uid();
  v_count INTEGER;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Auth required';
  END IF;

  DELETE FROM public.notifications
  WHERE user_id = v_user
    AND is_read = TRUE
    AND read_at < NOW() - (p_days || ' days')::INTERVAL;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  RETURN v_count;
END;
$$;

-- Cleanup logs pour cron
CREATE OR REPLACE FUNCTION public.cleanup_old_logs()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_sys INT;
  v_pay INT;
  v_rate INT;
BEGIN
  IF NOT public.is_service_role() THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  DELETE FROM public.system_logs
  WHERE created_at < NOW() - INTERVAL '30 days';
  GET DIAGNOSTICS v_sys = ROW_COUNT;

  DELETE FROM public.payment_logs
  WHERE processed = TRUE
    AND created_at < NOW() - INTERVAL '90 days';
  GET DIAGNOSTICS v_pay = ROW_COUNT;

  DELETE FROM public.api_rate_limits
  WHERE last_call < NOW() - INTERVAL '1 day';
  GET DIAGNOSTICS v_rate = ROW_COUNT;

  RETURN jsonb_build_object(
    'sys', v_sys,
    'pay', v_pay,
    'rate', v_rate
  );
END;
$$;

-- Auth triggers : création profil
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_role TEXT;
  v_phone TEXT;
  v_key TEXT;
BEGIN
  v_role := COALESCE(NEW.raw_user_meta_data->>'role', 'influenceur');
  IF v_role NOT IN ('influenceur','commercant') THEN
    v_role := 'influenceur';
  END IF;

  v_phone := NEW.raw_user_meta_data->>'phone';
  v_key := public.get_encryption_key();

  INSERT INTO public.profiles (
    id, email_encrypted, phone_encrypted, role, first_name, last_name
  )
  VALUES (
    NEW.id,
    pgp_sym_encrypt(NEW.email, v_key),
    CASE
      WHEN v_phone IS NOT NULL AND v_phone <> ''
        THEN pgp_sym_encrypt(v_phone, v_key)
      ELSE NULL
    END,
    v_role,
    SUBSTRING(COALESCE(NEW.raw_user_meta_data->>'first_name',''),1,100),
    SUBSTRING(COALESCE(NEW.raw_user_meta_data->>'last_name',''),1,100)
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.handle_user_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_phone TEXT;
  v_key TEXT;
BEGIN
  IF OLD.email IS DISTINCT FROM NEW.email
     OR OLD.raw_user_meta_data IS DISTINCT FROM NEW.raw_user_meta_data
  THEN
    v_phone := NEW.raw_user_meta_data->>'phone';
    v_key := public.get_encryption_key();

    UPDATE public.profiles
    SET email_encrypted = pgp_sym_encrypt(NEW.email, v_key),
        phone_encrypted = CASE
          WHEN v_phone IS NOT NULL AND v_phone <> ''
            THEN pgp_sym_encrypt(v_phone, v_key)
          ELSE phone_encrypted
        END,
        first_name = COALESCE(NULLIF(NEW.raw_user_meta_data->>'first_name',''), first_name),
        last_name = COALESCE(NULLIF(NEW.raw_user_meta_data->>'last_name',''), last_name),
        updated_at = NOW()
    WHERE id = NEW.id;
  END IF;

  RETURN NEW;
END;
$$;

-- ============================================================================
-- 5. TRIGGERS
-- ============================================================================

-- Profils
DROP TRIGGER IF EXISTS trg_profiles_updated_at ON public.profiles;
CREATE TRIGGER trg_profiles_updated_at
BEFORE UPDATE ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_profiles_protect_sensitive ON public.profiles;
CREATE TRIGGER trg_profiles_protect_sensitive
BEFORE UPDATE ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.protect_sensitive_profile_fields();

-- Offers
DROP TRIGGER IF EXISTS trg_offers_updated_at ON public.offers;
CREATE TRIGGER trg_offers_updated_at
BEFORE UPDATE ON public.offers
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Orders : ordre correct 01_snapshot → 02_enforce → 03_calculate
DROP TRIGGER IF EXISTS trg_orders_snapshot_offer ON public.orders;
DROP TRIGGER IF EXISTS trg_orders_00_enforce_creation ON public.orders;
DROP TRIGGER IF EXISTS trg_orders_calculate_amounts ON public.orders;

CREATE TRIGGER trg_orders_01_snapshot_offer
BEFORE INSERT ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.snapshot_offer_on_order_create();

CREATE TRIGGER trg_orders_02_enforce_creation
BEFORE INSERT ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.enforce_order_creation_rules();

CREATE TRIGGER trg_orders_03_calculate_amounts
BEFORE INSERT OR UPDATE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.calculate_order_amounts();

DROP TRIGGER IF EXISTS trg_orders_sync_stripe ON public.orders;
CREATE TRIGGER trg_orders_sync_stripe
BEFORE UPDATE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.sync_stripe_status_to_order();

DROP TRIGGER IF EXISTS trg_orders_updated_at ON public.orders;
CREATE TRIGGER trg_orders_updated_at
BEFORE UPDATE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_orders_audit ON public.orders;
CREATE TRIGGER trg_orders_audit
AFTER UPDATE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.audit_order_status_change();

DROP TRIGGER IF EXISTS trg_orders_notify_webhook ON public.orders;
CREATE TRIGGER trg_orders_notify_webhook
AFTER UPDATE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.notify_order_change();

DROP TRIGGER IF EXISTS trg_orders_auto_notify ON public.orders;
CREATE TRIGGER trg_orders_auto_notify
AFTER UPDATE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.auto_notify_order_status();

-- Conversations
DROP TRIGGER IF EXISTS trg_conversations_canonicalize ON public.conversations;
CREATE TRIGGER trg_conversations_canonicalize
BEFORE INSERT ON public.conversations
FOR EACH ROW EXECUTE FUNCTION public.canonicalize_conversation();

-- Messages
DROP TRIGGER IF EXISTS trg_messages_rate_limit ON public.messages;
CREATE TRIGGER trg_messages_rate_limit
BEFORE INSERT ON public.messages
FOR EACH ROW EXECUTE FUNCTION public.check_message_rate_limit();

DROP TRIGGER IF EXISTS trg_messages_check_integrity ON public.messages;
CREATE TRIGGER trg_messages_check_integrity
BEFORE INSERT ON public.messages
FOR EACH ROW EXECUTE FUNCTION public.check_message_integrity();

DROP TRIGGER IF EXISTS trg_messages_update_conv ON public.messages;
CREATE TRIGGER trg_messages_update_conv
AFTER INSERT ON public.messages
FOR EACH ROW EXECUTE FUNCTION public.update_conversation_timestamp();

-- Revenues
DROP TRIGGER IF EXISTS trg_revenues_updated_at ON public.revenues;
CREATE TRIGGER trg_revenues_updated_at
BEFORE UPDATE ON public.revenues
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Withdrawals
DROP TRIGGER IF EXISTS trg_withdrawals_updated_at ON public.withdrawals;
CREATE TRIGGER trg_withdrawals_updated_at
BEFORE UPDATE ON public.withdrawals
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Reviews
DROP TRIGGER IF EXISTS trg_reviews_updated_at ON public.reviews;
CREATE TRIGGER trg_reviews_updated_at
BEFORE UPDATE ON public.reviews
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_reviews_update_stats ON public.reviews;
CREATE TRIGGER trg_reviews_update_stats
AFTER INSERT OR UPDATE ON public.reviews
FOR EACH ROW EXECUTE FUNCTION public.update_influencer_stats_on_review();

-- Notifications
DROP TRIGGER IF EXISTS trg_notifications_updated_at ON public.notifications;
CREATE TRIGGER trg_notifications_updated_at
BEFORE UPDATE ON public.notifications
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Social links
DROP TRIGGER IF EXISTS trg_social_links_updated_at ON public.social_links;
CREATE TRIGGER trg_social_links_updated_at
BEFORE UPDATE ON public.social_links
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Bank accounts
DROP TRIGGER IF EXISTS trg_bank_accounts_updated_at ON public.bank_accounts;
CREATE TRIGGER trg_bank_accounts_updated_at
BEFORE UPDATE ON public.bank_accounts
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_bank_accounts_single_default ON public.bank_accounts;
CREATE TRIGGER trg_bank_accounts_single_default
AFTER INSERT OR UPDATE ON public.bank_accounts
FOR EACH ROW EXECUTE FUNCTION public.ensure_single_default_bank_account();

-- Portfolio
DROP TRIGGER IF EXISTS trg_portfolio_updated_at ON public.portfolio_items;
CREATE TRIGGER trg_portfolio_updated_at
BEFORE UPDATE ON public.portfolio_items
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Contestations
DROP TRIGGER IF EXISTS trg_contestations_updated_at ON public.contestations;
CREATE TRIGGER trg_contestations_updated_at
BEFORE UPDATE ON public.contestations
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Auth triggers
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

DROP TRIGGER IF EXISTS on_auth_user_updated ON auth.users;
CREATE TRIGGER on_auth_user_updated
AFTER UPDATE ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_user_update();

-- ============================================================================
-- 6. VIEWS
-- ============================================================================

CREATE OR REPLACE VIEW public.public_profiles AS
SELECT
  id,
  role,
  first_name,
  last_name,
  city,
  bio,
  avatar_url,
  is_verified,
  profile_views,
  profile_share_count,
  average_rating,
  total_reviews,
  completed_orders_count,
  created_at,
  public.mask_email(email_encrypted, id) AS email,
  public.mask_phone(phone_encrypted, id) AS phone
FROM public.profiles;

CREATE OR REPLACE VIEW public.dashboard_stats AS
SELECT
  (SELECT COUNT(*) FROM public.profiles WHERE role = 'influenceur') AS total_influencers,
  (SELECT COUNT(*) FROM public.profiles WHERE role = 'commercant') AS total_merchants,
  (SELECT COUNT(*) FROM public.profiles WHERE role = 'influenceur' AND is_verified = TRUE) AS verified_influencers,
  (SELECT COUNT(*) FROM public.orders WHERE status IN ('completed','finished')) AS completed_orders,
  (SELECT COUNT(*) FROM public.orders WHERE status = 'disputed') AS disputed_orders,
  (SELECT COUNT(*) FROM public.orders WHERE status IN ('pending','payment_authorized','accepted','in_progress','submitted','review_pending')) AS active_orders,
  (SELECT COUNT(*) FROM public.contestations WHERE status = 'pending') AS pending_contestations,
  (SELECT COALESCE(SUM(amount), 0) FROM public.revenues) AS total_volume,
  (SELECT COALESCE(SUM(commission), 0) FROM public.revenues) AS total_commission,
  (SELECT COALESCE(SUM(net_amount), 0) FROM public.revenues WHERE status = 'available') AS available_for_withdrawal,
  (SELECT COALESCE(SUM(amount), 0) FROM public.withdrawals WHERE status = 'completed') AS total_withdrawn;

CREATE OR REPLACE VIEW public.public_reviews AS
SELECT
  r.id,
  r.order_id,
  r.influencer_id,
  r.rating,
  r.comment,
  r.response,
  r.response_at,
  r.created_at,
  p.first_name AS merchant_first_name,
  p.avatar_url AS merchant_avatar
FROM public.reviews r
JOIN public.profiles p ON p.id = r.merchant_id
WHERE r.is_visible = TRUE;

CREATE OR REPLACE VIEW public.public_portfolio AS
SELECT
  id,
  influencer_id,
  title,
  description,
  media_type,
  media_url,
  thumbnail_url,
  link_url,
  display_order,
  created_at
FROM public.portfolio_items
WHERE is_active = TRUE;

-- ============================================================================
-- 7. ROW LEVEL SECURITY (RLS)
-- ============================================================================

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.api_rate_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contact_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.social_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.offers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.revenues ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.withdrawals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.favorites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.portfolio_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contestations ENABLE ROW LEVEL SECURITY;

-- Profiles
REVOKE SELECT ON public.profiles FROM authenticated, anon;
GRANT SELECT ON public.public_profiles TO anon, authenticated;
GRANT SELECT ON public.profiles TO authenticated;

DROP POLICY IF EXISTS "profiles_select_own" ON public.profiles;
CREATE POLICY "profiles_select_own"
ON public.profiles
FOR SELECT
USING (id = auth.uid() OR public.is_admin());

DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles;
CREATE POLICY "profiles_update_own"
ON public.profiles
FOR UPDATE
USING (id = auth.uid())
WITH CHECK (id = auth.uid());

-- Admins
DROP POLICY IF EXISTS "admins_select" ON public.admins;
CREATE POLICY "admins_select"
ON public.admins
FOR SELECT
USING (public.is_admin());

-- Rate limits
DROP POLICY IF EXISTS "rate_limits_none" ON public.api_rate_limits;
CREATE POLICY "rate_limits_none"
ON public.api_rate_limits
FOR ALL
USING (FALSE);

-- System logs
DROP POLICY IF EXISTS "logs_admin" ON public.system_logs;
CREATE POLICY "logs_admin"
ON public.system_logs
FOR SELECT
USING (public.is_admin());

-- Payment logs
DROP POLICY IF EXISTS "payment_logs_admin" ON public.payment_logs;
CREATE POLICY "payment_logs_admin"
ON public.payment_logs
FOR ALL
USING (public.is_admin());

-- Contact messages
DROP POLICY IF EXISTS "contact_insert" ON public.contact_messages;
CREATE POLICY "contact_insert"
ON public.contact_messages
FOR INSERT
WITH CHECK (TRUE);

DROP POLICY IF EXISTS "contact_admin" ON public.contact_messages;
CREATE POLICY "contact_admin"
ON public.contact_messages
FOR SELECT
USING (public.is_admin());

-- Categories
DROP POLICY IF EXISTS "categories_select" ON public.categories;
CREATE POLICY "categories_select"
ON public.categories
FOR SELECT
USING (is_active = TRUE OR public.is_admin());

DROP POLICY IF EXISTS "categories_admin" ON public.categories;
CREATE POLICY "categories_admin"
ON public.categories
FOR ALL
USING (public.is_admin());

-- Social links
DROP POLICY IF EXISTS "social_public" ON public.social_links;
CREATE POLICY "social_public"
ON public.social_links
FOR SELECT
USING (is_active = TRUE OR user_id = auth.uid());

DROP POLICY IF EXISTS "social_own" ON public.social_links;
CREATE POLICY "social_own"
ON public.social_links
FOR ALL
USING (user_id = auth.uid());

-- Offers
DROP POLICY IF EXISTS "offers_public" ON public.offers;
CREATE POLICY "offers_public"
ON public.offers
FOR SELECT
USING (is_active = TRUE OR influencer_id = auth.uid() OR public.is_admin());

DROP POLICY IF EXISTS "offers_own" ON public.offers;
CREATE POLICY "offers_own"
ON public.offers
FOR ALL
USING (influencer_id = auth.uid());

DROP POLICY IF EXISTS "offers_admin" ON public.offers;
CREATE POLICY "offers_admin"
ON public.offers
FOR ALL
USING (public.is_admin());

-- Conversations
DROP POLICY IF EXISTS "conv_participants" ON public.conversations;
CREATE POLICY "conv_participants"
ON public.conversations
FOR SELECT
USING (
  auth.uid() IN (participant_1_id, participant_2_id)
  OR public.is_admin()
);

DROP POLICY IF EXISTS "conv_create" ON public.conversations;
CREATE POLICY "conv_create"
ON public.conversations
FOR INSERT
WITH CHECK (auth.uid() IN (participant_1_id, participant_2_id));

-- Messages
DROP POLICY IF EXISTS "msg_participants" ON public.messages;
CREATE POLICY "msg_participants"
ON public.messages
FOR SELECT
USING (
  auth.uid() IN (sender_id, receiver_id)
  OR public.is_admin()
);

DROP POLICY IF EXISTS "msg_send" ON public.messages;
CREATE POLICY "msg_send"
ON public.messages
FOR INSERT
WITH CHECK (sender_id = auth.uid());

DROP POLICY IF EXISTS "msg_read" ON public.messages;
CREATE POLICY "msg_read"
ON public.messages
FOR UPDATE
USING (receiver_id = auth.uid())
WITH CHECK (receiver_id = auth.uid());

-- Orders
DROP POLICY IF EXISTS "orders_select" ON public.orders;
CREATE POLICY "orders_select"
ON public.orders
FOR SELECT
USING (
  auth.uid() IN (merchant_id, influencer_id)
  OR public.is_admin()
);

DROP POLICY IF EXISTS "orders_insert" ON public.orders;
CREATE POLICY "orders_insert"
ON public.orders
FOR INSERT
WITH CHECK (merchant_id = auth.uid());
-- Pas de policy UPDATE: updates via RPC / fonctions only

-- Revenues
DROP POLICY IF EXISTS "revenues_select" ON public.revenues;
CREATE POLICY "revenues_select"
ON public.revenues
FOR SELECT
USING (influencer_id = auth.uid() OR public.is_admin());

DROP POLICY IF EXISTS "revenues_no_insert" ON public.revenues;
CREATE POLICY "revenues_no_insert"
ON public.revenues
FOR INSERT
WITH CHECK (FALSE);

DROP POLICY IF EXISTS "revenues_no_update" ON public.revenues;
CREATE POLICY "revenues_no_update"
ON public.revenues
FOR UPDATE
USING (FALSE);

-- Withdrawals
DROP POLICY IF EXISTS "withdrawals_select" ON public.withdrawals;
CREATE POLICY "withdrawals_select"
ON public.withdrawals
FOR SELECT
USING (influencer_id = auth.uid() OR public.is_admin());

DROP POLICY IF EXISTS "withdrawals_no_insert" ON public.withdrawals;
CREATE POLICY "withdrawals_no_insert"
ON public.withdrawals
FOR INSERT
WITH CHECK (FALSE);

-- Favorites
DROP POLICY IF EXISTS "favorites_own" ON public.favorites;
CREATE POLICY "favorites_own"
ON public.favorites
FOR ALL
USING (merchant_id = auth.uid());

-- Notifications
DROP POLICY IF EXISTS "notif_own" ON public.notifications;
CREATE POLICY "notif_own"
ON public.notifications
FOR SELECT
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "notif_update" ON public.notifications;
CREATE POLICY "notif_update"
ON public.notifications
FOR UPDATE
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "notif_delete" ON public.notifications;
CREATE POLICY "notif_delete"
ON public.notifications
FOR DELETE
USING (user_id = auth.uid());

-- Audit orders
DROP POLICY IF EXISTS "audit_parties" ON public.audit_orders;
CREATE POLICY "audit_parties"
ON public.audit_orders
FOR SELECT
USING (
  public.is_admin()
  OR EXISTS (
    SELECT 1
    FROM public.orders
    WHERE orders.id = audit_orders.order_id
      AND auth.uid() IN (orders.merchant_id, orders.influencer_id)
  )
);

-- Reviews
DROP POLICY IF EXISTS "reviews_public" ON public.reviews;
CREATE POLICY "reviews_public"
ON public.reviews
FOR SELECT
USING (
  is_visible = TRUE
  OR merchant_id = auth.uid()
  OR influencer_id = auth.uid()
  OR public.is_admin()
);

DROP POLICY IF EXISTS "reviews_create" ON public.reviews;
CREATE POLICY "reviews_create"
ON public.reviews
FOR INSERT
WITH CHECK (FALSE);

DROP POLICY IF EXISTS "reviews_update" ON public.reviews;
CREATE POLICY "reviews_update"
ON public.reviews
FOR UPDATE
USING (influencer_id = auth.uid() OR public.is_admin());

-- Bank accounts
DROP POLICY IF EXISTS "bank_accounts_own" ON public.bank_accounts;
CREATE POLICY "bank_accounts_own"
ON public.bank_accounts
FOR ALL
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "bank_accounts_admin" ON public.bank_accounts;
CREATE POLICY "bank_accounts_admin"
ON public.bank_accounts
FOR SELECT
USING (public.is_admin());

-- Portfolio items
DROP POLICY IF EXISTS "portfolio_select" ON public.portfolio_items;
CREATE POLICY "portfolio_select"
ON public.portfolio_items
FOR SELECT
USING (is_active = TRUE OR influencer_id = auth.uid() OR public.is_admin());

DROP POLICY IF EXISTS "portfolio_insert" ON public.portfolio_items;
CREATE POLICY "portfolio_insert"
ON public.portfolio_items
FOR INSERT
WITH CHECK (influencer_id = auth.uid());

DROP POLICY IF EXISTS "portfolio_update" ON public.portfolio_items;
CREATE POLICY "portfolio_update"
ON public.portfolio_items
FOR UPDATE
USING (influencer_id = auth.uid())
WITH CHECK (influencer_id = auth.uid());

DROP POLICY IF EXISTS "portfolio_delete" ON public.portfolio_items;
CREATE POLICY "portfolio_delete"
ON public.portfolio_items
FOR DELETE
USING (public.is_admin());

-- Contestations
DROP POLICY IF EXISTS "contestations_parties" ON public.contestations;
CREATE POLICY "contestations_parties"
ON public.contestations
FOR SELECT
USING (
  auth.uid() IN (influencer_id, merchant_id)
  OR public.is_admin()
);

DROP POLICY IF EXISTS "contestations_create" ON public.contestations;
CREATE POLICY "contestations_create"
ON public.contestations
FOR INSERT
WITH CHECK (influencer_id = auth.uid());

DROP POLICY IF EXISTS "contestations_admin" ON public.contestations;
CREATE POLICY "contestations_admin"
ON public.contestations
FOR UPDATE
USING (public.is_admin());

-- ============================================================================
-- 8. INITIAL DATA
-- ============================================================================

INSERT INTO public.categories (name, slug, icon_name, description, sort_order)
VALUES
  ('Story Instagram', 'story-instagram', 'instagram', 'Story temporaire 24h', 10),
  ('Post Instagram', 'post-instagram', 'image', 'Publication permanente feed', 20),
  ('Reel Instagram', 'reel-instagram', 'video', 'Vidéo courte verticale', 30),
  ('Vidéo TikTok', 'video-tiktok', 'tiktok', 'Vidéo courte TikTok', 40),
  ('Story Snapchat', 'story-snapchat', 'snapchat', 'Story Snapchat', 50),
  ('UGC Vidéo', 'ugc-video', 'camera', 'Contenu vidéo généré', 60),
  ('UGC Photo', 'ugc-photo', 'camera', 'Contenu photo généré', 70),
  ('Post LinkedIn', 'post-linkedin', 'linkedin', 'Publication LinkedIn', 80),
  ('Thread Twitter/X', 'thread-twitter', 'twitter', 'Thread X/Twitter', 90),
  ('Vidéo YouTube', 'video-youtube', 'youtube', 'Vidéo YouTube', 100),
  ('Short YouTube', 'short-youtube', 'youtube', 'Short YouTube', 110),
  ('Post Facebook', 'post-facebook', 'facebook', 'Publication Facebook', 120)
ON CONFLICT (slug) DO UPDATE
SET name = EXCLUDED.name,
    description = EXCLUDED.description,
    sort_order = EXCLUDED.sort_order;

-- ============================================================================
-- 9. GRANTS
-- ============================================================================

GRANT SELECT ON public.public_profiles TO anon, authenticated;
GRANT SELECT ON public.public_reviews TO anon, authenticated;
GRANT SELECT ON public.public_portfolio TO anon, authenticated;
GRANT SELECT ON public.dashboard_stats TO authenticated;

GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.increment_profile_view(UUID) TO authenticated; -- PAS anon
GRANT EXECUTE ON FUNCTION public.increment_profile_share(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.safe_update_order_status(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_delivery(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_withdrawal(DECIMAL) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_available_balance() TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_review(UUID, INTEGER, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.respond_to_review(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_contestation(UUID, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resolve_dispute(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resolve_contestation(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_all_notifications_read() TO authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_old_notifications(INTEGER) TO authenticated;

COMMIT;

-- ============================================================================
-- FIN DU SCRIPT V16.2 (FULL & FIXED)
-- ============================================================================```

Tu peux utiliser **exactement ce script** comme première migration dans Supabase.

Si tu veux, ensuite on pourra faire ensemble les **Edge Functions Stripe** qui se branchent sur :

- `safe_update_order_status` pour passer à `accepted` après capture.
- `handle_cron_deadlines` et `cleanup_old_logs` via `pg_cron` ou des CRON Edge.
::contentReference[oaicite:0]{index=0}
