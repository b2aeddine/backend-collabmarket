-- ============================================================================
-- BACKEND MARKETPLACE INFLUENCEURS - VERSION PRODUCTION V21.0 (FINAL)
-- PARTIE 1 : SCHEMA
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

BEGIN;

-- 1. FONCTIONS UTILITAIRES & SÃ‰CURITÃ‰
CREATE OR REPLACE FUNCTION public.get_encryption_key() RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_key text;
BEGIN
  v_key := current_setting('app.encryption_key', true);
  IF v_key IS NULL OR LENGTH(v_key) < 32 THEN RAISE EXCEPTION 'CRITICAL: app.encryption_key not set'; END IF;
  RETURN v_key;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.get_encryption_key() FROM PUBLIC, authenticated, anon;

CREATE OR REPLACE FUNCTION public.update_updated_at_column() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

CREATE OR REPLACE FUNCTION public.is_service_role() RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN RETURN (current_user = 'postgres' OR COALESCE(current_setting('request.jwt.claims', true)::json->>'role', '') = 'service_role');
EXCEPTION WHEN OTHERS THEN RETURN FALSE; END;
$$;

-- 2. TABLES
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
  stripe_identity_session_id TEXT,
  stripe_identity_last_status TEXT,
  stripe_identity_last_update TIMESTAMPTZ,
  identity_trust_score INTEGER DEFAULT 0,
  identity_verification_confidence CHAR(1) CHECK (identity_verification_confidence IS NULL OR identity_verification_confidence IN ('L','M','H')),
  identity_document_country TEXT CHECK (LENGTH(identity_document_country) <= 3),
  identity_verified_at TIMESTAMPTZ,
  connect_kyc_status TEXT DEFAULT 'none' CHECK (connect_kyc_status IN ('none','pending','verified','restricted','rejected')),
  connect_kyc_last_sync TIMESTAMPTZ,
  connect_kyc_source TEXT,
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

CREATE OR REPLACE FUNCTION public.is_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid());
$$;

CREATE OR REPLACE FUNCTION public.mask_email(p_enc bytea, p_owner uuid) RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_enc IS NULL THEN RETURN NULL; END IF;
  IF auth.uid() IS DISTINCT FROM p_owner AND NOT public.is_admin() THEN RETURN '***@***.***'; END IF;
  BEGIN RETURN pgp_sym_decrypt(p_enc, public.get_encryption_key()); EXCEPTION WHEN OTHERS THEN RETURN NULL; END;
END;
$$;

CREATE OR REPLACE FUNCTION public.mask_phone(p_enc bytea, p_owner uuid) RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_enc IS NULL THEN RETURN NULL; END IF;
  IF auth.uid() IS DISTINCT FROM p_owner AND NOT public.is_admin() THEN RETURN '**********'; END IF;
  BEGIN RETURN pgp_sym_decrypt(p_enc, public.get_encryption_key()); EXCEPTION WHEN OTHERS THEN RETURN NULL; END;
END;
$$;

CREATE TABLE IF NOT EXISTS public.api_rate_limits (
  user_id UUID NOT NULL,
  endpoint TEXT NOT NULL,
  last_call TIMESTAMPTZ DEFAULT NOW(),
  call_count INTEGER DEFAULT 1,
  PRIMARY KEY (user_id, endpoint)
);

CREATE TABLE IF NOT EXISTS public.system_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type TEXT NOT NULL CHECK (event_type IN ('cron','error','warning','info','security','stripe','workflow','notification')),
  message TEXT,
  details JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

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

CREATE TABLE IF NOT EXISTS public.contact_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL CHECK (LENGTH(name) <= 200),
  email TEXT NOT NULL CHECK (LENGTH(email) <= 320),
  subject TEXT CHECK (LENGTH(subject) <= 500),
  message TEXT NOT NULL CHECK (LENGTH(message) <= 5000),
  ip_address TEXT,
  status TEXT DEFAULT 'new' CHECK (status IN ('new','read','replied','archived')),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

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

CREATE TABLE IF NOT EXISTS public.social_links (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  platform TEXT NOT NULL CHECK (LENGTH(platform) <= 50),
  username TEXT NOT NULL CHECK (LENGTH(username) <= 100),
  profile_url TEXT NOT NULL CHECK (LENGTH(profile_url) <= 500),
  followers INTEGER DEFAULT 0 CHECK (followers >= 0),
  engagement_rate DECIMAL(5,2) DEFAULT 0,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id, platform)
);

CREATE TABLE IF NOT EXISTS public.offers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  category_id UUID REFERENCES public.categories(id) ON DELETE SET NULL,
  title TEXT NOT NULL CHECK (LENGTH(title) <= 200),
  description TEXT CHECK (LENGTH(description) <= 5000),
  price DECIMAL(10,2) NOT NULL CHECK (price > 0),
  delivery_time TEXT CHECK (LENGTH(delivery_time) <= 100),
  delivery_days INTEGER CHECK (delivery_days IS NULL OR delivery_days > 0),
  is_popular BOOLEAN DEFAULT FALSE,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  participant_1_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  participant_2_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  last_message_at TIMESTAMPTZ DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  CHECK (participant_1_id != participant_2_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_conversations_participants_canonical ON public.conversations (LEAST(participant_1_id, participant_2_id), GREATEST(participant_1_id, participant_2_id));

CREATE TABLE IF NOT EXISTS public.orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  offer_id UUID REFERENCES public.offers(id) ON DELETE SET NULL,
  offer_title TEXT,
  offer_description TEXT,
  offer_price_at_order DECIMAL(10,2),
  offer_category_id_at_order UUID,
  offer_category_name_at_order TEXT,
  offer_delivery_days_at_order INTEGER,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','payment_authorized','accepted','in_progress','submitted','review_pending','completed','finished','cancelled','disputed')),
  total_amount DECIMAL(10,2) NOT NULL CHECK (total_amount > 0),
  net_amount DECIMAL(10,2) NOT NULL CHECK (net_amount > 0),
  commission_rate DECIMAL(5,2) DEFAULT 5.0,
  requirements TEXT,
  delivery_url TEXT,
  stripe_payment_intent_id TEXT,
  stripe_checkout_session_id TEXT,
  stripe_payment_status TEXT DEFAULT 'unpaid',
  payment_authorized_at TIMESTAMPTZ,
  captured_at TIMESTAMPTZ,
  accepted_at TIMESTAMPTZ,
  acceptance_deadline TIMESTAMPTZ,
  merchant_confirm_deadline TIMESTAMPTZ,
  submitted_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ,
  dispute_reason TEXT,
  dispute_opened_at TIMESTAMPTZ,
  dispute_resolved_at TIMESTAMPTZ,
  dispute_resolution TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
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

-- FIX V21: Ajout de amount_withdrawn
CREATE TABLE IF NOT EXISTS public.revenues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  net_amount DECIMAL(10,2) NOT NULL CHECK (net_amount > 0),
  commission DECIMAL(10,2) NOT NULL CHECK (commission >= 0),
  amount_withdrawn DECIMAL(10,2) DEFAULT 0 CHECK (amount_withdrawn >= 0),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','available','withdrawn','cancelled')),
  available_at TIMESTAMPTZ,
  withdrawn_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT uq_revenues_order UNIQUE(order_id),
  CONSTRAINT chk_revenue_math CHECK (ABS(net_amount + commission - amount) < 0.01),
  CONSTRAINT chk_withdrawn_lte_net CHECK (amount_withdrawn <= net_amount)
);

CREATE TABLE IF NOT EXISTS public.withdrawals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  fee DECIMAL(10,2) DEFAULT 0 CHECK (fee >= 0),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','processing','completed','failed','cancelled')),
  iban_last4 TEXT,
  stripe_transfer_id TEXT,
  stripe_payout_id TEXT,
  failure_reason TEXT,
  processed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.favorites (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(merchant_id, influencer_id)
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

CREATE TABLE IF NOT EXISTS public.audit_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  old_status TEXT,
  new_status TEXT NOT NULL,
  changed_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  change_source TEXT DEFAULT 'user',
  change_reason TEXT,
  metadata JSONB,
  changed_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  merchant_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  rating INTEGER NOT NULL CHECK (rating >= 1 AND rating <= 5),
  comment TEXT,
  response TEXT,
  response_at TIMESTAMPTZ,
  is_visible BOOLEAN DEFAULT TRUE,
  moderated_at TIMESTAMPTZ,
  moderated_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  moderation_reason TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT uq_review_order UNIQUE(order_id)
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
  media_type TEXT DEFAULT 'image',
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

-- 3. INDEXES
CREATE INDEX IF NOT EXISTS idx_profiles_role ON public.profiles(role);
CREATE INDEX IF NOT EXISTS idx_profiles_stripe ON public.profiles(stripe_account_id) WHERE stripe_account_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_profiles_verified ON public.profiles(is_verified) WHERE is_verified = TRUE;
CREATE INDEX IF NOT EXISTS idx_profiles_rating ON public.profiles(average_rating DESC) WHERE role = 'influenceur';
CREATE INDEX IF NOT EXISTS idx_profiles_city_rating ON public.profiles(city, average_rating DESC) WHERE role = 'influenceur' AND is_verified = TRUE;
CREATE INDEX IF NOT EXISTS idx_profiles_search ON public.profiles USING GIN ((COALESCE(first_name,'')||' '||COALESCE(last_name,'')||' '||COALESCE(bio,'')||' '||COALESCE(city,'')) gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_orders_merchant ON public.orders(merchant_id);
CREATE INDEX IF NOT EXISTS idx_orders_influencer ON public.orders(influencer_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON public.orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_merchant_status ON public.orders(merchant_id, status);
CREATE INDEX IF NOT EXISTS idx_orders_influencer_status ON public.orders(influencer_id, status);
CREATE INDEX IF NOT EXISTS idx_orders_merchant_created ON public.orders(merchant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_stripe_intent ON public.orders(stripe_payment_intent_id) WHERE stripe_payment_intent_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_orders_created ON public.orders(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_category_snapshot ON public.orders(offer_category_id_at_order) WHERE offer_category_id_at_order IS NOT NULL;
CREATE INDEX idx_orders_acceptance_deadline ON public.orders(acceptance_deadline ASC) WHERE status = 'payment_authorized' AND acceptance_deadline IS NOT NULL;
CREATE INDEX idx_orders_merchant_deadline ON public.orders(merchant_confirm_deadline ASC) WHERE status IN ('submitted','review_pending') AND merchant_confirm_deadline IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_offers_influencer ON public.offers(influencer_id);
CREATE INDEX IF NOT EXISTS idx_offers_category ON public.offers(category_id) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_offers_active ON public.offers(is_active, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_conversation ON public.messages(conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_unread ON public.messages(receiver_id, is_read) WHERE is_read = FALSE;
CREATE INDEX IF NOT EXISTS idx_messages_conv_unread ON public.messages(conversation_id, receiver_id) WHERE is_read = FALSE;
CREATE INDEX IF NOT EXISTS idx_revenues_influencer ON public.revenues(influencer_id);
CREATE INDEX IF NOT EXISTS idx_revenues_status ON public.revenues(influencer_id, status);
CREATE INDEX IF NOT EXISTS idx_revenues_available ON public.revenues(influencer_id, created_at) WHERE status = 'available';
CREATE INDEX IF NOT EXISTS idx_revenues_influencer_created ON public.revenues(influencer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_withdrawals_influencer ON public.withdrawals(influencer_id);
CREATE INDEX IF NOT EXISTS idx_withdrawals_status ON public.withdrawals(status, created_at);
CREATE INDEX IF NOT EXISTS idx_withdrawals_influencer_status ON public.withdrawals(influencer_id, status);
CREATE INDEX IF NOT EXISTS idx_notifications_user ON public.notifications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_unread ON public.notifications(user_id) WHERE is_read = FALSE;
CREATE INDEX IF NOT EXISTS idx_reviews_influencer ON public.reviews(influencer_id, created_at DESC) WHERE is_visible = TRUE;
CREATE INDEX IF NOT EXISTS idx_reviews_merchant ON public.reviews(merchant_id);
CREATE INDEX IF NOT EXISTS idx_audit_order ON public.audit_orders(order_id, changed_at DESC);
CREATE INDEX IF NOT EXISTS idx_logs_type ON public.system_logs(event_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bank_accounts_user ON public.bank_accounts(user_id);
CREATE INDEX IF NOT EXISTS idx_bank_accounts_default ON public.bank_accounts(user_id, is_default) WHERE is_default = TRUE;
CREATE INDEX IF NOT EXISTS idx_portfolio_influencer ON public.portfolio_items(influencer_id);
CREATE INDEX IF NOT EXISTS idx_portfolio_active ON public.portfolio_items(influencer_id, display_order) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_contestations_order ON public.contestations(order_id);
CREATE INDEX IF NOT EXISTS idx_contestations_status ON public.contestations(status);
CREATE INDEX IF NOT EXISTS idx_contestations_pending ON public.contestations(created_at DESC) WHERE status IN ('pending', 'under_review');
CREATE UNIQUE INDEX uq_contestation_order_active ON public.contestations(order_id) WHERE status IN ('pending','under_review');
CREATE UNIQUE INDEX IF NOT EXISTS ux_bank_accounts_one_default_per_user ON public.bank_accounts(user_id) WHERE is_default = TRUE;
-- ============================================================================
-- PARTIE 2 : LOGIQUE METIER (FONCTIONS & RPC)
-- ============================================================================

-- 4. TRIGGERS HELPERS
CREATE OR REPLACE FUNCTION public.apply_rate_limit(p_endpoint text, p_limit int DEFAULT 30) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_user uuid := auth.uid(); v_count int;
BEGIN
  IF v_user IS NULL THEN RETURN; END IF;
  INSERT INTO public.api_rate_limits (user_id, endpoint, last_call, call_count) VALUES (v_user, p_endpoint, NOW(), 1)
  ON CONFLICT (user_id, endpoint) DO UPDATE SET call_count = CASE WHEN api_rate_limits.last_call > NOW() - INTERVAL '1 minute' THEN api_rate_limits.call_count + 1 ELSE 1 END, last_call = NOW() RETURNING call_count INTO v_count;
  IF v_count > p_limit THEN RAISE EXCEPTION 'Rate limit exceeded for %', p_endpoint; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.check_message_rate_limit() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN PERFORM public.apply_rate_limit('send_message', 20); RETURN NEW; END;
$$;

CREATE OR REPLACE FUNCTION public.protect_sensitive_profile_fields() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.email_encrypted IS DISTINCT FROM OLD.email_encrypted) OR (NEW.phone_encrypted IS DISTINCT FROM OLD.phone_encrypted) THEN
    IF auth.uid() IS DISTINCT FROM NEW.id AND NOT public.is_admin() THEN RAISE EXCEPTION 'Unauthorized modification of sensitive fields'; END IF;
  END IF;
  IF (NEW.role IS DISTINCT FROM OLD.role) OR (NEW.is_verified IS DISTINCT FROM OLD.is_verified) OR (NEW.stripe_account_id IS DISTINCT FROM OLD.stripe_account_id) THEN
    IF NOT public.is_admin() AND NOT public.is_service_role() THEN RAISE EXCEPTION 'Unauthorized modification of system fields'; END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.validate_order_status_transition() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = NEW.status THEN RETURN NEW; END IF;
  IF OLD.status = 'pending' AND NEW.status NOT IN ('payment_authorized', 'cancelled') THEN RAISE EXCEPTION 'Invalid transition from pending to %', NEW.status; END IF;
  IF OLD.status = 'payment_authorized' AND NEW.status NOT IN ('accepted', 'cancelled') THEN RAISE EXCEPTION 'Invalid transition from payment_authorized to %', NEW.status; END IF;
  IF OLD.status = 'accepted' AND NEW.status NOT IN ('in_progress', 'cancelled') THEN RAISE EXCEPTION 'Invalid transition from accepted to %', NEW.status; END IF;
  IF OLD.status = 'in_progress' AND NEW.status NOT IN ('submitted', 'cancelled') THEN RAISE EXCEPTION 'Invalid transition from in_progress to %', NEW.status; END IF;
  IF OLD.status = 'submitted' AND NEW.status NOT IN ('review_pending', 'completed', 'disputed') THEN RAISE EXCEPTION 'Invalid transition from submitted to %', NEW.status; END IF;
  IF OLD.status = 'review_pending' AND NEW.status NOT IN ('submitted', 'disputed') THEN RAISE EXCEPTION 'Invalid transition from review_pending to %', NEW.status; END IF;
  IF OLD.status = 'completed' AND NEW.status NOT IN ('finished', 'disputed') THEN RAISE EXCEPTION 'Invalid transition from completed to %', NEW.status; END IF;
  IF OLD.status IN ('cancelled', 'finished') THEN RAISE EXCEPTION 'Cannot change status from final state %', OLD.status; END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.calculate_order_amounts() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.commission_rate IS NULL THEN NEW.commission_rate := 5.0; END IF;
  NEW.net_amount := ROUND((NEW.total_amount * (1 - NEW.commission_rate / 100.0)), 2);
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.enforce_order_creation_rules() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.merchant_id = NEW.influencer_id THEN RAISE EXCEPTION 'Self-ordering not allowed'; END IF;
  IF NEW.total_amount < 5.0 THEN RAISE EXCEPTION 'Minimum order amount is 5.00'; END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.snapshot_offer_on_order_create() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_offer RECORD; v_cat_name TEXT;
BEGIN
  IF NEW.offer_id IS NOT NULL THEN
    SELECT * INTO v_offer FROM public.offers WHERE id = NEW.offer_id;
    IF FOUND THEN
      NEW.offer_title := v_offer.title;
      NEW.offer_description := v_offer.description;
      NEW.offer_price_at_order := v_offer.price;
      NEW.offer_category_id_at_order := v_offer.category_id;
      NEW.offer_delivery_days_at_order := v_offer.delivery_days;
      IF v_offer.category_id IS NOT NULL THEN
        SELECT name INTO v_cat_name FROM public.categories WHERE id = v_offer.category_id;
        NEW.offer_category_name_at_order := v_cat_name;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_stripe_status_to_order() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.stripe_payment_status = 'paid' AND OLD.stripe_payment_status != 'paid' AND NEW.status = 'pending' THEN
    NEW.status := 'payment_authorized';
    NEW.payment_authorized_at := NOW();
    NEW.acceptance_deadline := NOW() + INTERVAL '48 hours';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.audit_order_status_change() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF (OLD.status IS DISTINCT FROM NEW.status) THEN
    INSERT INTO public.audit_orders (order_id, old_status, new_status, changed_by, change_source)
    VALUES (NEW.id, OLD.status, NEW.status, auth.uid(), CASE WHEN public.is_service_role() THEN 'system' ELSE 'user' END);
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_notification(p_user_id UUID, p_type TEXT, p_title TEXT, p_content TEXT, p_rel_type TEXT DEFAULT NULL, p_rel_id UUID DEFAULT NULL, p_url TEXT DEFAULT NULL) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO public.notifications (user_id, type, title, content, related_type, related_id, action_url)
  VALUES (p_user_id, p_type, p_title, p_content, p_rel_type, p_rel_id, p_url) RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.auto_notify_order_status() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NEW.status = 'payment_authorized' AND OLD.status != 'payment_authorized' THEN
    PERFORM public.create_notification(NEW.influencer_id, 'order_new', 'Nouvelle commande !', 'Vous avez reÃ§u une nouvelle commande de ' || NEW.total_amount || 'â‚¬', 'order', NEW.id, '/dashboard/orders/' || NEW.id);
  ELSIF NEW.status = 'accepted' AND OLD.status != 'accepted' THEN
    PERFORM public.create_notification(NEW.merchant_id, 'order_accepted', 'Commande acceptÃ©e', 'L''influenceur a acceptÃ© votre commande.', 'order', NEW.id, '/dashboard/orders/' || NEW.id);
  ELSIF NEW.status = 'submitted' AND OLD.status != 'submitted' THEN
    PERFORM public.create_notification(NEW.merchant_id, 'order_submitted', 'Livraison reÃ§ue !', 'L''influenceur a livrÃ© sa prestation. Veuillez valider.', 'order', NEW.id, '/dashboard/orders/' || NEW.id);
  ELSIF NEW.status = 'completed' AND OLD.status != 'completed' THEN
    PERFORM public.create_notification(NEW.influencer_id, 'order_completed', 'Commande validÃ©e !', 'Le client a validÃ© la commande. Les fonds sont disponibles.', 'order', NEW.id, '/dashboard/wallet');
  ELSIF NEW.status = 'cancelled' AND OLD.status != 'cancelled' THEN
    PERFORM public.create_notification(NEW.merchant_id, 'order_cancelled', 'Commande annulÃ©e', 'La commande a Ã©tÃ© annulÃ©e.', 'order', NEW.id);
    PERFORM public.create_notification(NEW.influencer_id, 'order_cancelled', 'Commande annulÃ©e', 'La commande a Ã©tÃ© annulÃ©e.', 'order', NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_influencer_stats_on_review() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_avg DECIMAL(3,2); v_count INT;
BEGIN
  IF (TG_OP = 'INSERT') OR (TG_OP = 'UPDATE' AND (NEW.rating IS DISTINCT FROM OLD.rating OR NEW.is_visible IS DISTINCT FROM OLD.is_visible)) THEN
    SELECT COALESCE(AVG(rating), 0), COUNT(*) INTO v_avg, v_count FROM public.reviews WHERE influencer_id = NEW.influencer_id AND is_visible = TRUE;
    UPDATE public.profiles SET average_rating = v_avg, total_reviews = v_count WHERE id = NEW.influencer_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.canonicalize_conversation() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.participant_1_id > NEW.participant_2_id THEN
    DECLARE temp UUID; BEGIN temp := NEW.participant_1_id; NEW.participant_1_id := NEW.participant_2_id; NEW.participant_2_id := temp; END;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.check_message_integrity() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_p1 UUID; v_p2 UUID;
BEGIN
  SELECT participant_1_id, participant_2_id INTO v_p1, v_p2 FROM public.conversations WHERE id = NEW.conversation_id;
  IF NEW.sender_id NOT IN (v_p1, v_p2) THEN RAISE EXCEPTION 'Sender not in conversation'; END IF;
  IF NEW.receiver_id NOT IN (v_p1, v_p2) THEN RAISE EXCEPTION 'Receiver not in conversation'; END IF;
  IF NEW.sender_id = NEW.receiver_id THEN RAISE EXCEPTION 'Self-messaging not allowed'; END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_conversation_timestamp() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN UPDATE public.conversations SET last_message_at = NOW() WHERE id = NEW.conversation_id; RETURN NEW; END;
$$;

CREATE OR REPLACE FUNCTION public.ensure_single_default_bank_account() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.is_default = TRUE THEN UPDATE public.bank_accounts SET is_default = FALSE WHERE user_id = NEW.user_id AND id != NEW.id; END IF;
  RETURN NEW;
END;
$$;

-- 5. RPC FONCTIONS

-- V21: get_available_balance (Updated)
CREATE OR REPLACE FUNCTION public.get_available_balance() RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_user UUID := auth.uid(); v_avail DECIMAL; v_pend_with DECIMAL; v_total DECIMAL; v_withdrawn DECIMAL;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Auth required'; END IF;
  SELECT COALESCE(SUM(net_amount - amount_withdrawn), 0) INTO v_avail FROM public.revenues WHERE influencer_id = v_user AND status IN ('available', 'withdrawn') AND amount_withdrawn < net_amount;
  SELECT COALESCE(SUM(amount), 0) INTO v_pend_with FROM public.withdrawals WHERE influencer_id = v_user AND status IN ('pending','processing');
  SELECT COALESCE(SUM(net_amount), 0) INTO v_total FROM public.revenues WHERE influencer_id = v_user;
  SELECT COALESCE(SUM(amount_withdrawn), 0) INTO v_withdrawn FROM public.revenues WHERE influencer_id = v_user;
  RETURN jsonb_build_object('available', GREATEST(v_avail - v_pend_with, 0), 'pending_withdrawals', v_pend_with, 'total_earned', v_total, 'total_withdrawn', v_withdrawn);
END;
$$;

-- V21: request_withdrawal (Updated)
CREATE OR REPLACE FUNCTION public.request_withdrawal(p_amount DECIMAL) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_user UUID := auth.uid(); v_avail DECIMAL; v_pend DECIMAL; v_eff DECIMAL; v_id UUID;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Auth required'; END IF;
  IF p_amount < 10 THEN RAISE EXCEPTION 'Minimum withdrawal: 10â‚¬'; END IF;
  PERFORM public.apply_rate_limit('withdrawals');
  PERFORM 1 FROM public.profiles WHERE id = v_user FOR UPDATE;
  SELECT COALESCE(SUM(net_amount - amount_withdrawn), 0) INTO v_avail FROM public.revenues WHERE influencer_id = v_user AND amount_withdrawn < net_amount;
  SELECT COALESCE(SUM(amount), 0) INTO v_pend FROM public.withdrawals WHERE influencer_id = v_user AND status IN ('pending','processing');
  v_eff := v_avail - v_pend;
  IF p_amount > v_eff THEN RAISE EXCEPTION 'Insufficient balance. Available: %, Requested: %', v_eff, p_amount; END IF;
  INSERT INTO public.withdrawals (influencer_id, amount, status) VALUES (v_user, p_amount, 'pending') RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- V21: confirm_withdrawal_success (NEW Atomic)
CREATE OR REPLACE FUNCTION public.confirm_withdrawal_success(p_withdrawal_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_withdrawal RECORD; v_remaining DECIMAL; rec RECORD; v_take DECIMAL;
BEGIN
  IF NOT public.is_service_role() THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  SELECT * INTO v_withdrawal FROM public.withdrawals WHERE id = p_withdrawal_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Withdrawal not found'; END IF;
  IF v_withdrawal.status = 'completed' THEN RETURN jsonb_build_object('success', true, 'message', 'Already completed'); END IF;
  UPDATE public.withdrawals SET status = 'completed', processed_at = NOW(), updated_at = NOW() WHERE id = p_withdrawal_id;
  v_remaining := v_withdrawal.amount;
  FOR rec IN SELECT id, net_amount, amount_withdrawn FROM public.revenues WHERE influencer_id = v_withdrawal.influencer_id AND amount_withdrawn < net_amount ORDER BY created_at ASC FOR UPDATE LOOP
    EXIT WHEN v_remaining <= 0;
    v_take := LEAST(v_remaining, rec.net_amount - rec.amount_withdrawn);
    UPDATE public.revenues SET amount_withdrawn = amount_withdrawn + v_take, status = CASE WHEN amount_withdrawn + v_take >= net_amount THEN 'withdrawn' ELSE status END, withdrawn_at = NOW(), updated_at = NOW() WHERE id = rec.id;
    v_remaining := v_remaining - v_take;
  END LOOP;
  IF v_remaining > 0.01 THEN INSERT INTO public.system_logs (event_type, message, details) VALUES ('error', 'Withdrawal completed but insufficient revenues found to burn', jsonb_build_object('withdrawal_id', p_withdrawal_id, 'missing', v_remaining)); END IF;
  RETURN jsonb_build_object('success', true);
END;
$$;

-- V21: confirm_withdrawal_failure (NEW Atomic)
CREATE OR REPLACE FUNCTION public.confirm_withdrawal_failure(p_withdrawal_id UUID, p_reason TEXT) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_service_role() THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  UPDATE public.withdrawals SET status = 'failed', failure_reason = p_reason, updated_at = NOW() WHERE id = p_withdrawal_id;
  RETURN jsonb_build_object('success', true);
END;
$$;

-- V21: safe_update_order_status (Updated)
CREATE OR REPLACE FUNCTION public.safe_update_order_status(p_order_id UUID, p_new_status TEXT, p_reason TEXT DEFAULT NULL) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_order public.orders%ROWTYPE; v_actor UUID := auth.uid(); v_role TEXT;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF public.is_admin() THEN v_role := 'admin'; ELSIF v_actor = v_order.merchant_id THEN v_role := 'merchant'; ELSIF v_actor = v_order.influencer_id THEN v_role := 'influencer'; ELSE RAISE EXCEPTION 'Access denied'; END IF;
  UPDATE public.orders SET status = p_new_status, updated_at = NOW(), completed_at = CASE WHEN p_new_status = 'completed' THEN NOW() ELSE completed_at END, cancelled_at = CASE WHEN p_new_status = 'cancelled' THEN NOW() ELSE cancelled_at END WHERE id = p_order_id;
  IF p_new_status = 'completed' AND v_order.status NOT IN ('completed','finished') THEN
    INSERT INTO public.revenues (influencer_id, order_id, amount, net_amount, commission, status, available_at, amount_withdrawn) VALUES (v_order.influencer_id, p_order_id, v_order.total_amount, v_order.net_amount, v_order.total_amount - v_order.net_amount, 'available', NOW(), 0) ON CONFLICT (order_id) DO NOTHING;
    UPDATE public.profiles SET completed_orders_count = completed_orders_count + 1 WHERE id = v_order.influencer_id;
  END IF;
  IF (p_new_status = 'cancelled' OR p_new_status = 'disputed') AND v_order.status IN ('completed','finished') THEN
    PERFORM 1 FROM public.revenues WHERE order_id = p_order_id AND amount_withdrawn > 0;
    IF FOUND THEN INSERT INTO public.system_logs (event_type, message, details) VALUES ('error', 'CRITICAL: Cannot revert revenue - Money withdrawn', jsonb_build_object('order_id', p_order_id)); ELSE DELETE FROM public.revenues WHERE order_id = p_order_id; END IF;
  END IF;
  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_delivery(p_order_id UUID, p_url TEXT) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_order public.orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF v_order.influencer_id != auth.uid() THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  IF v_order.status != 'in_progress' THEN RAISE EXCEPTION 'Order not in progress'; END IF;
  UPDATE public.orders SET status = 'submitted', delivery_url = p_url, submitted_at = NOW(), merchant_confirm_deadline = NOW() + INTERVAL '72 hours', updated_at = NOW() WHERE id = p_order_id;
  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.handle_cron_deadlines() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.orders SET status = 'cancelled', cancelled_at = NOW(), updated_at = NOW() WHERE status = 'payment_authorized' AND acceptance_deadline < NOW();
  UPDATE public.orders SET status = 'completed', completed_at = NOW(), updated_at = NOW() WHERE status IN ('submitted', 'review_pending') AND merchant_confirm_deadline < NOW();
  INSERT INTO public.revenues (influencer_id, order_id, amount, net_amount, commission, status, available_at, amount_withdrawn)
  SELECT o.influencer_id, o.id, o.total_amount, o.net_amount, o.total_amount - o.net_amount, 'available', NOW(), 0
  FROM public.orders o WHERE o.status = 'completed' AND o.completed_at >= NOW() - INTERVAL '1 minute' AND NOT EXISTS (SELECT 1 FROM public.revenues r WHERE r.order_id = o.id);
END;
$$;

CREATE OR REPLACE FUNCTION public.create_review(p_order_id UUID, p_rating INT, p_comment TEXT) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_order public.orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF v_order.merchant_id != auth.uid() THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  IF v_order.status NOT IN ('completed', 'finished') THEN RAISE EXCEPTION 'Order not completed'; END IF;
  INSERT INTO public.reviews (order_id, merchant_id, influencer_id, rating, comment) VALUES (p_order_id, v_order.merchant_id, v_order.influencer_id, p_rating, p_comment);
  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.respond_to_review(p_review_id UUID, p_response TEXT) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_review public.reviews%ROWTYPE;
BEGIN
  SELECT * INTO v_review FROM public.reviews WHERE id = p_review_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Review not found'; END IF;
  IF v_review.influencer_id != auth.uid() THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  UPDATE public.reviews SET response = p_response, response_at = NOW(), updated_at = NOW() WHERE id = p_review_id;
  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.create_contestation(p_order_id UUID, p_reason TEXT, p_evidence_url TEXT DEFAULT NULL, p_evidence_desc TEXT DEFAULT NULL) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_order public.orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF auth.uid() NOT IN (v_order.merchant_id, v_order.influencer_id) THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  IF v_order.status IN ('cancelled', 'finished') THEN RAISE EXCEPTION 'Order already final'; END IF;
  UPDATE public.orders SET status = 'disputed', dispute_reason = p_reason, dispute_opened_at = NOW(), updated_at = NOW() WHERE id = p_order_id;
  INSERT INTO public.contestations (order_id, influencer_id, merchant_id, reason, evidence_url, evidence_description) VALUES (p_order_id, v_order.influencer_id, v_order.merchant_id, p_reason, p_evidence_url, p_evidence_desc);
  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_resolve_contestation(p_contestation_id UUID, p_resolution TEXT, p_notes TEXT) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cont public.contestations%ROWTYPE;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT * INTO v_cont FROM public.contestations WHERE id = p_contestation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Contestation not found'; END IF;
  UPDATE public.contestations SET status = 'resolved', admin_notes = p_notes, decided_by = auth.uid(), decided_at = NOW(), updated_at = NOW() WHERE id = p_contestation_id;
  IF p_resolution = 'refund_merchant' THEN PERFORM public.safe_update_order_status(v_cont.order_id, 'cancelled', 'Admin resolved: Refund Merchant');
  ELSIF p_resolution = 'pay_influencer' THEN PERFORM public.safe_update_order_status(v_cont.order_id, 'completed', 'Admin resolved: Pay Influencer');
  END IF;
  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_all_notifications_read() RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE public.notifications SET is_read = TRUE, read_at = NOW() WHERE user_id = auth.uid() AND is_read = FALSE;
$$;

CREATE OR REPLACE FUNCTION public.increment_profile_view(p_profile_id UUID) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN UPDATE public.profiles SET profile_views = profile_views + 1 WHERE id = p_profile_id; END;
$$;

CREATE OR REPLACE FUNCTION public.increment_profile_share(p_profile_id UUID) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN UPDATE public.profiles SET profile_share_count = profile_share_count + 1 WHERE id = p_profile_id; END;
$$;

CREATE OR REPLACE FUNCTION public.cleanup_old_logs() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN DELETE FROM public.system_logs WHERE created_at < NOW() - INTERVAL '30 days'; DELETE FROM public.payment_logs WHERE created_at < NOW() - INTERVAL '30 days'; END;
$$;
-- ============================================================================
-- PARTIE 3 : SECURITE & DONNEES (TRIGGERS, RLS, DATA)
-- ============================================================================

-- 6. TRIGGERS
CREATE TRIGGER trg_check_message_rate_limit BEFORE INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.check_message_rate_limit();
CREATE TRIGGER trg_protect_sensitive_profile_fields BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.protect_sensitive_profile_fields();
CREATE TRIGGER trg_validate_order_status_transition BEFORE UPDATE OF status ON public.orders FOR EACH ROW EXECUTE FUNCTION public.validate_order_status_transition();
CREATE TRIGGER trg_calculate_order_amounts BEFORE INSERT OR UPDATE OF total_amount, commission_rate ON public.orders FOR EACH ROW EXECUTE FUNCTION public.calculate_order_amounts();
CREATE TRIGGER trg_enforce_order_creation_rules BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION public.enforce_order_creation_rules();
CREATE TRIGGER trg_snapshot_offer_on_order_create BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION public.snapshot_offer_on_order_create();
CREATE TRIGGER trg_sync_stripe_status_to_order BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.sync_stripe_status_to_order();
CREATE TRIGGER trg_audit_order_status_change AFTER UPDATE OF status ON public.orders FOR EACH ROW EXECUTE FUNCTION public.audit_order_status_change();
CREATE TRIGGER trg_auto_notify_order_status AFTER UPDATE OF status ON public.orders FOR EACH ROW EXECUTE FUNCTION public.auto_notify_order_status();
CREATE TRIGGER trg_update_influencer_stats_on_review AFTER INSERT OR UPDATE ON public.reviews FOR EACH ROW EXECUTE FUNCTION public.update_influencer_stats_on_review();
CREATE TRIGGER trg_canonicalize_conversation BEFORE INSERT ON public.conversations FOR EACH ROW EXECUTE FUNCTION public.canonicalize_conversation();
CREATE TRIGGER trg_check_message_integrity BEFORE INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.check_message_integrity();
CREATE TRIGGER trg_update_conversation_timestamp AFTER INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.update_conversation_timestamp();
CREATE TRIGGER trg_ensure_single_default_bank_account BEFORE INSERT OR UPDATE OF is_default ON public.bank_accounts FOR EACH ROW WHEN (NEW.is_default = TRUE) EXECUTE FUNCTION public.ensure_single_default_bank_account();

-- Updated_at triggers
CREATE TRIGGER trg_updated_at_profiles BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trg_updated_at_social_links BEFORE UPDATE ON public.social_links FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trg_updated_at_offers BEFORE UPDATE ON public.offers FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trg_updated_at_orders BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trg_updated_at_revenues BEFORE UPDATE ON public.revenues FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trg_updated_at_withdrawals BEFORE UPDATE ON public.withdrawals FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trg_updated_at_notifications BEFORE UPDATE ON public.notifications FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trg_updated_at_reviews BEFORE UPDATE ON public.reviews FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trg_updated_at_bank_accounts BEFORE UPDATE ON public.bank_accounts FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trg_updated_at_portfolio_items BEFORE UPDATE ON public.portfolio_items FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trg_updated_at_contestations BEFORE UPDATE ON public.contestations FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 7. VUES
CREATE OR REPLACE VIEW public.public_profiles AS SELECT id, role, first_name, last_name, city, bio, avatar_url, is_verified, average_rating, total_reviews, profile_views, profile_share_count, created_at FROM public.profiles;
GRANT SELECT ON public.public_profiles TO anon, authenticated;

-- 8. RLS POLICIES
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
CREATE POLICY "profiles_read_public" ON public.profiles FOR SELECT USING (true);
CREATE POLICY "profiles_update_own" ON public.profiles FOR UPDATE USING (id = auth.uid());
CREATE POLICY "profiles_insert_own" ON public.profiles FOR INSERT WITH CHECK (id = auth.uid());

-- Admins
CREATE POLICY "admins_read_own" ON public.admins FOR SELECT USING (user_id = auth.uid());

-- Categories (Public read, Admin write)
CREATE POLICY "categories_read_public" ON public.categories FOR SELECT USING (true);
CREATE POLICY "categories_write_admin" ON public.categories FOR ALL USING (public.is_admin());

-- Social Links
CREATE POLICY "social_read_public" ON public.social_links FOR SELECT USING (true);
CREATE POLICY "social_write_own" ON public.social_links FOR ALL USING (user_id = auth.uid());

-- Offers
CREATE POLICY "offers_read_public" ON public.offers FOR SELECT USING (is_active = true);
CREATE POLICY "offers_write_own" ON public.offers FOR ALL USING (influencer_id = auth.uid());

-- Orders
CREATE POLICY "orders_read_participants" ON public.orders FOR SELECT USING (auth.uid() IN (merchant_id, influencer_id) OR public.is_admin());
CREATE POLICY "orders_insert_merchant" ON public.orders FOR INSERT WITH CHECK (auth.uid() = merchant_id);
CREATE POLICY "orders_update_participants" ON public.orders FOR UPDATE USING (auth.uid() IN (merchant_id, influencer_id) OR public.is_admin());

-- Conversations & Messages
CREATE POLICY "conversations_read_participants" ON public.conversations FOR SELECT USING (auth.uid() IN (participant_1_id, participant_2_id));
CREATE POLICY "conversations_insert_participants" ON public.conversations FOR INSERT WITH CHECK (auth.uid() IN (participant_1_id, participant_2_id));
CREATE POLICY "messages_read_participants" ON public.messages FOR SELECT USING (EXISTS (SELECT 1 FROM public.conversations c WHERE c.id = conversation_id AND auth.uid() IN (c.participant_1_id, c.participant_2_id)));
CREATE POLICY "messages_insert_participants" ON public.messages FOR INSERT WITH CHECK (auth.uid() = sender_id);

-- Revenues & Withdrawals
CREATE POLICY "revenues_read_own" ON public.revenues FOR SELECT USING (influencer_id = auth.uid() OR public.is_admin());
CREATE POLICY "withdrawals_read_own" ON public.withdrawals FOR SELECT USING (influencer_id = auth.uid() OR public.is_admin());
CREATE POLICY "withdrawals_insert_own" ON public.withdrawals FOR INSERT WITH CHECK (influencer_id = auth.uid());

-- Notifications
CREATE POLICY "notifications_read_own" ON public.notifications FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "notifications_update_own" ON public.notifications FOR UPDATE USING (user_id = auth.uid());

-- Reviews
CREATE POLICY "reviews_read_public" ON public.reviews FOR SELECT USING (is_visible = true);
CREATE POLICY "reviews_write_own" ON public.reviews FOR INSERT WITH CHECK (merchant_id = auth.uid());
CREATE POLICY "reviews_update_own" ON public.reviews FOR UPDATE USING (influencer_id = auth.uid()); -- For response

-- Bank Accounts
CREATE POLICY "bank_read_own" ON public.bank_accounts FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "bank_write_own" ON public.bank_accounts FOR ALL USING (user_id = auth.uid());

-- Portfolio
CREATE POLICY "portfolio_read_public" ON public.portfolio_items FOR SELECT USING (true);
CREATE POLICY "portfolio_write_own" ON public.portfolio_items FOR ALL USING (influencer_id = auth.uid());

-- Contestations
CREATE POLICY "contestations_read_participants" ON public.contestations FOR SELECT USING (auth.uid() IN (merchant_id, influencer_id) OR public.is_admin());
CREATE POLICY "contestations_insert_participants" ON public.contestations FOR INSERT WITH CHECK (auth.uid() IN (merchant_id, influencer_id));

-- 9. INITIAL DATA
INSERT INTO public.categories (name, slug, icon_name, sort_order) VALUES
('Mode & BeautÃ©', 'mode-beaute', 'fashion', 10),
('Tech & Gaming', 'tech-gaming', 'gamepad', 20),
('Voyage & Lifestyle', 'voyage-lifestyle', 'plane', 30),
('Food & Nutrition', 'food-nutrition', 'utensils', 40),
('Sport & Fitness', 'sport-fitness', 'dumbbell', 50),
('Business & Finance', 'business-finance', 'briefcase', 60),
('Famille & Enfants', 'famille-enfants', 'baby', 70),
('Animaux', 'animaux', 'paw', 80),
('Art & Design', 'art-design', 'palette', 90),
('Autre', 'autre', 'dots-horizontal', 100)
ON CONFLICT (slug) DO NOTHING;

-- 10. GRANTS
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO postgres, service_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon, authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated;

COMMIT;
