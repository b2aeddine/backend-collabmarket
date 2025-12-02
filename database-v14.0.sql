-- ==============================================================================
-- ========== SCRIPT SQL FINAL V15 ==========
-- Description: Installation complète sur projet vierge (BUGS CORRIGÉS)
-- Features: Stripe Connect, Identity, Escrow 5%, Payouts, Logs, Automations
-- ==============================================================================

-- 1. EXTENSIONS
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

BEGIN;

-- ======================================================
-- 2) FONCTIONS UTILITAIRES & CRYPTOGRAPHIE
-- ======================================================

-- 2.1 Clé de Chiffrement
-- ⚠️ IMPORTANT: Remplacer par une vraie clé générée avec: SELECT encode(gen_random_bytes(32), 'hex');
CREATE OR REPLACE FUNCTION public.get_encryption_key()
RETURNS text LANGUAGE sql IMMUTABLE SECURITY DEFINER AS $$
  SELECT current_setting('app.encryption_key', true);
$$;

REVOKE EXECUTE ON FUNCTION public.get_encryption_key() FROM PUBLIC, authenticated, anon;

-- 2.2 Trigger updated_at
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- 2.3 Masquage Email
CREATE OR REPLACE FUNCTION public.mask_email(p_encrypted_email bytea, p_owner_id uuid)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE v_clear_email text;
BEGIN
  IF p_encrypted_email IS NULL THEN RETURN NULL; END IF;
  IF auth.uid() != p_owner_id AND NOT public.is_admin() THEN RETURN '***@***.***'; END IF;
  BEGIN
    v_clear_email := pgp_sym_decrypt(p_encrypted_email, public.get_encryption_key());
  EXCEPTION WHEN OTHERS THEN RETURN NULL; END;
  RETURN v_clear_email;
END;
$$;

-- 2.4 Masquage Téléphone
CREATE OR REPLACE FUNCTION public.mask_phone(p_encrypted_phone bytea, p_owner_id uuid)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE v_clear_phone text;
BEGIN
  IF p_encrypted_phone IS NULL THEN RETURN NULL; END IF;
  IF auth.uid() != p_owner_id AND NOT public.is_admin() THEN RETURN '***-***-**'; END IF;
  BEGIN
    v_clear_phone := pgp_sym_decrypt(p_encrypted_phone, public.get_encryption_key());
  EXCEPTION WHEN OTHERS THEN RETURN NULL; END;
  RETURN v_clear_phone;
END;
$$;

-- ======================================================
-- 3) STRUCTURE DES TABLES
-- ======================================================

-- 3.1 PROFILES
CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('influenceur', 'commercant', 'admin')),
  first_name TEXT CHECK (LENGTH(first_name) <= 100),
  last_name TEXT CHECK (LENGTH(last_name) <= 100),
  email_encrypted BYTEA, 
  phone_encrypted BYTEA,
  city TEXT CHECK (LENGTH(city) <= 100),
  bio TEXT CHECK (LENGTH(bio) <= 2000),
  avatar_url TEXT,
  is_verified BOOLEAN DEFAULT false,
  profile_views INTEGER DEFAULT 0,
  stripe_account_id TEXT, 
  stripe_customer_id TEXT,
  stripe_identity_session_id TEXT,
  stripe_identity_last_status TEXT,
  stripe_identity_last_update TIMESTAMPTZ,
  identity_trust_score INTEGER DEFAULT 0,
  identity_verification_confidence CHAR(1),
  identity_document_country TEXT,
  identity_verified_at TIMESTAMPTZ,
  connect_kyc_status TEXT DEFAULT 'none',
  connect_kyc_last_sync TIMESTAMPTZ,
  connect_kyc_source TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3.2 ADMINS
CREATE TABLE public.admins (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION public.is_admin() 
RETURNS boolean LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid());
$$;

-- 3.3 LOGS & LIMITS
CREATE TABLE public.api_rate_limits (
  user_id UUID NOT NULL, 
  endpoint TEXT NOT NULL, 
  last_call TIMESTAMPTZ DEFAULT NOW(), 
  call_count INTEGER DEFAULT 1, 
  PRIMARY KEY (user_id, endpoint)
);

CREATE TABLE public.system_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), 
  event_type TEXT NOT NULL CHECK (event_type IN ('cron', 'error', 'warning', 'info', 'security', 'identity_init')), 
  message TEXT, 
  details JSONB, 
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3.4 AUDIT & MESSAGES
CREATE TABLE public.payment_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stripe_session_id TEXT,
  stripe_payment_intent_id TEXT,  -- FIX: Ajout de cette colonne
  event_type TEXT NOT NULL,
  event_data JSONB,
  order_id UUID, 
  processed BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.contact_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  email TEXT NOT NULL,
  subject TEXT,
  message TEXT NOT NULL,
  ip_address TEXT,
  status TEXT DEFAULT 'new' CHECK (status IN ('new', 'read', 'replied', 'archived')),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3.5 BUSINESS TABLES
CREATE TABLE public.categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), 
  name TEXT NOT NULL UNIQUE, 
  slug TEXT NOT NULL UNIQUE, 
  description TEXT, 
  icon_name TEXT, 
  is_active BOOLEAN DEFAULT true, 
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.social_links (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), 
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE, 
  platform TEXT NOT NULL, 
  username TEXT NOT NULL, 
  profile_url TEXT NOT NULL, 
  followers INTEGER DEFAULT 0, 
  engagement_rate DECIMAL(5,2) DEFAULT 0, 
  is_active BOOLEAN DEFAULT true, 
  created_at TIMESTAMPTZ DEFAULT NOW(), 
  UNIQUE(user_id, platform)
);

CREATE TABLE public.offers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), 
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE, 
  category_id UUID REFERENCES public.categories(id) ON DELETE SET NULL, 
  title TEXT NOT NULL, 
  description TEXT, 
  price DECIMAL(10,2) NOT NULL, 
  delivery_time TEXT, 
  is_popular BOOLEAN DEFAULT false, 
  is_active BOOLEAN DEFAULT true, 
  created_at TIMESTAMPTZ DEFAULT NOW(), 
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), 
  participant_1_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE, 
  participant_2_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE, 
  last_message_at TIMESTAMPTZ DEFAULT NOW(), 
  created_at TIMESTAMPTZ DEFAULT NOW(), 
  CHECK (participant_1_id != participant_2_id)
);
CREATE UNIQUE INDEX ux_conversations_participants_canonical ON public.conversations ((LEAST(participant_1_id, participant_2_id)), (GREATEST(participant_1_id, participant_2_id)));

-- 3.6 ORDERS (5% COMMISSION)
CREATE TABLE public.orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  offer_id UUID REFERENCES public.offers(id) ON DELETE SET NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','payment_authorized','accepted','in_progress','submitted','review_pending','completed','finished','cancelled','disputed')),
  total_amount DECIMAL(10,2) NOT NULL CHECK (total_amount >= 0),
  net_amount DECIMAL(10,2) NOT NULL CHECK (net_amount <= total_amount),
  commission_rate DECIMAL(5,2) DEFAULT 5.0,
  requirements TEXT,
  stripe_payment_intent_id TEXT,
  stripe_checkout_session_id TEXT,  -- FIX: Ajout colonne manquante
  stripe_payment_status TEXT DEFAULT 'unpaid'
    CHECK (stripe_payment_status IN ('unpaid', 'requires_payment_method', 'requires_confirmation', 'requires_capture', 'processing', 'requires_action', 'canceled', 'succeeded', 'authorized', 'captured', 'refunded')),
  payment_authorized_at TIMESTAMPTZ, 
  captured_at TIMESTAMPTZ, 
  acceptance_deadline TIMESTAMPTZ, 
  merchant_confirm_deadline TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(), 
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT check_acceptance_deadline CHECK (acceptance_deadline IS NULL OR acceptance_deadline > created_at),
  CONSTRAINT check_merchant_confirm_deadline CHECK (merchant_confirm_deadline IS NULL OR merchant_confirm_deadline > created_at)
);

-- 3.7 MESSAGES
CREATE TABLE public.messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), 
  conversation_id UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE, 
  sender_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE, 
  receiver_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE, 
  content TEXT NOT NULL CHECK (LENGTH(content) > 0 AND LENGTH(content) <= 5000), 
  is_read BOOLEAN DEFAULT false, 
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3.8 REVENUES
CREATE TABLE public.revenues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), 
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT, 
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT, 
  amount DECIMAL(10,2) NOT NULL, 
  net_amount DECIMAL(10,2) NOT NULL, 
  commission DECIMAL(10,2) NOT NULL, 
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','available','withdrawn')), 
  created_at TIMESTAMPTZ DEFAULT NOW(), 
  updated_at TIMESTAMPTZ DEFAULT NOW(), 
  CONSTRAINT uq_revenues_order UNIQUE(order_id)
);

-- 3.9 WITHDRAWALS
CREATE TABLE public.withdrawals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), 
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT, 
  amount DECIMAL(10,2) NOT NULL CHECK (amount > 0), 
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','processing','completed','failed')), 
  iban_last4 TEXT, 
  stripe_transfer_id TEXT, 
  stripe_payout_id TEXT, 
  failure_reason TEXT, 
  processed_at TIMESTAMPTZ, 
  created_at TIMESTAMPTZ DEFAULT NOW(), 
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3.10 MISC
CREATE TABLE public.favorites (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), 
  merchant_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE, 
  influencer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE, 
  created_at TIMESTAMPTZ DEFAULT NOW(), 
  UNIQUE(merchant_id, influencer_id)
);

CREATE TABLE public.notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), 
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE, 
  type TEXT NOT NULL, 
  title TEXT NOT NULL, 
  content TEXT NOT NULL, 
  is_read BOOLEAN DEFAULT false, 
  related_id UUID, 
  created_at TIMESTAMPTZ DEFAULT NOW(), 
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.audit_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), 
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE, 
  old_status TEXT, 
  new_status TEXT, 
  changed_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL, 
  changed_at TIMESTAMPTZ DEFAULT NOW(), 
  notes TEXT
);

-- ======================================================
-- 4) INDEXES
-- ======================================================
CREATE INDEX idx_messages_inbox ON public.messages (receiver_id, is_read, created_at DESC);
CREATE INDEX idx_messages_conv_created ON public.messages (conversation_id, created_at DESC);
CREATE INDEX idx_messages_archiving ON public.messages (created_at);
CREATE INDEX idx_messages_content_search ON public.messages USING GIN (content gin_trgm_ops);

CREATE INDEX idx_orders_merchant_status ON public.orders (merchant_id, status);
CREATE INDEX idx_orders_influencer_status ON public.orders (influencer_id, status);
CREATE INDEX idx_orders_status ON public.orders (status);
CREATE INDEX idx_orders_stripe_intent ON public.orders (stripe_payment_intent_id);
CREATE INDEX idx_orders_stripe_session ON public.orders (stripe_checkout_session_id);  -- FIX: Index ajouté
CREATE INDEX idx_orders_updated_at ON public.orders (updated_at DESC);
CREATE INDEX idx_orders_cron_acceptance ON public.orders (status, acceptance_deadline) WHERE status = 'payment_authorized';
CREATE INDEX idx_orders_cron_confirm ON public.orders (status, merchant_confirm_deadline) WHERE status IN ('submitted', 'review_pending');

CREATE INDEX idx_offers_cat_active ON public.offers (category_id) WHERE is_active = true;
CREATE INDEX idx_withdrawals_stripe_payout ON public.withdrawals(stripe_payout_id);
CREATE INDEX idx_withdrawals_updated_at ON public.withdrawals (updated_at DESC);
CREATE INDEX idx_withdrawals_status_created ON public.withdrawals(status, created_at);
CREATE INDEX idx_revenues_updated_at ON public.revenues (updated_at DESC);
CREATE INDEX idx_revenues_influencer_status ON public.revenues(influencer_id, status);

CREATE INDEX idx_audit_orders_changed_by ON public.audit_orders(changed_by);
CREATE INDEX idx_audit_orders_archiving ON public.audit_orders(changed_at);
CREATE INDEX idx_system_logs_details ON public.system_logs USING GIN (details);

CREATE INDEX idx_contact_ip_created ON public.contact_messages(ip_address, created_at);
CREATE INDEX idx_payment_logs_session ON public.payment_logs(stripe_session_id);
CREATE INDEX idx_payment_logs_intent ON public.payment_logs(stripe_payment_intent_id);  -- FIX: Index ajouté
CREATE INDEX idx_profiles_search ON public.profiles USING GIN ( (first_name || ' ' || last_name || ' ' || COALESCE(bio, '') || ' ' || COALESCE(city, '')) gin_trgm_ops );
CREATE INDEX idx_profiles_risk_score ON public.profiles(identity_verification_confidence);
CREATE INDEX idx_profiles_doc_country ON public.profiles(identity_document_country);
CREATE INDEX idx_profiles_connect_kyc ON public.profiles(connect_kyc_status);
CREATE INDEX idx_profiles_stripe_combo ON public.profiles(stripe_account_id, connect_kyc_status, identity_verification_confidence);

-- ======================================================
-- 5) TRIGGERS & LOGIQUE MÉTIER
-- ======================================================

-- 5.1 Sync Auth
CREATE OR REPLACE FUNCTION public.handle_new_user() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_role text; v_phone text;
BEGIN
  v_role := COALESCE(NEW.raw_user_meta_data->>'role', 'influenceur'); 
  v_phone := NEW.raw_user_meta_data->>'phone';
  INSERT INTO public.profiles (id, email_encrypted, phone_encrypted, role, first_name, last_name, created_at)
  VALUES (
    NEW.id, 
    pgp_sym_encrypt(NEW.email, public.get_encryption_key()), 
    CASE WHEN v_phone IS NOT NULL THEN pgp_sym_encrypt(v_phone, public.get_encryption_key()) ELSE NULL END, 
    v_role, 
    SUBSTRING(COALESCE(NEW.raw_user_meta_data->>'first_name',''),1,100), 
    SUBSTRING(COALESCE(NEW.raw_user_meta_data->>'last_name',''),1,100), 
    NOW()
  ) ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END; $$;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();

CREATE OR REPLACE FUNCTION public.handle_user_update() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_phone text;
BEGIN
  v_phone := NEW.raw_user_meta_data->>'phone';
  IF (OLD.email IS DISTINCT FROM NEW.email) OR (OLD.raw_user_meta_data IS DISTINCT FROM NEW.raw_user_meta_data) THEN
    UPDATE public.profiles SET 
      email_encrypted = pgp_sym_encrypt(NEW.email, public.get_encryption_key()), 
      phone_encrypted = CASE WHEN v_phone IS NOT NULL THEN pgp_sym_encrypt(v_phone, public.get_encryption_key()) ELSE NULL END, 
      first_name = COALESCE(NEW.raw_user_meta_data->>'first_name', first_name), 
      last_name = COALESCE(NEW.raw_user_meta_data->>'last_name', last_name), 
      updated_at = NOW() 
    WHERE id = NEW.id;
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER on_auth_user_updated AFTER UPDATE ON auth.users FOR EACH ROW EXECUTE PROCEDURE public.handle_user_update();

-- 5.2 Updated_at Triggers
CREATE TRIGGER trg_updated_at_profiles BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE PROCEDURE public.update_updated_at_column();
CREATE TRIGGER trg_updated_at_offers BEFORE UPDATE ON public.offers FOR EACH ROW EXECUTE PROCEDURE public.update_updated_at_column();
CREATE TRIGGER trg_updated_at_orders BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE PROCEDURE public.update_updated_at_column();
CREATE TRIGGER trg_updated_at_revenues BEFORE UPDATE ON public.revenues FOR EACH ROW EXECUTE PROCEDURE public.update_updated_at_column();
CREATE TRIGGER trg_updated_at_withdrawals BEFORE UPDATE ON public.withdrawals FOR EACH ROW EXECUTE PROCEDURE public.update_updated_at_column();
CREATE TRIGGER trg_updated_at_notifications BEFORE UPDATE ON public.notifications FOR EACH ROW EXECUTE PROCEDURE public.update_updated_at_column();

-- 5.3 Anti-Spam
CREATE OR REPLACE FUNCTION public.apply_rate_limit(p_key text, p_limit int DEFAULT 30) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_user_id uuid := auth.uid(); v_new_count int;
BEGIN
  IF v_user_id IS NULL THEN RETURN; END IF;
  IF p_key = 'messages' THEN p_limit := 60; END IF;
  IF p_key = 'social_links' THEN p_limit := 10; END IF;
  IF p_key = 'safe_update_order_status' THEN p_limit := 20; END IF;
  INSERT INTO public.api_rate_limits (user_id, endpoint, last_call, call_count) VALUES (v_user_id, p_key, NOW(), 1)
  ON CONFLICT (user_id, endpoint) DO UPDATE SET 
    call_count = CASE WHEN public.api_rate_limits.last_call > NOW() - INTERVAL '1 minute' THEN public.api_rate_limits.call_count + 1 ELSE 1 END, 
    last_call = NOW() 
  RETURNING call_count INTO v_new_count;
  IF v_new_count > p_limit THEN RAISE EXCEPTION 'Rate limit exceeded'; END IF;
END; $$;

CREATE OR REPLACE FUNCTION public.trg_check_rate_limit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN PERFORM public.apply_rate_limit(TG_TABLE_NAME); RETURN NEW; END; $$;

CREATE TRIGGER trg_rate_limit_messages BEFORE INSERT ON public.messages FOR EACH ROW EXECUTE PROCEDURE public.trg_check_rate_limit();
CREATE TRIGGER trg_rate_limit_social BEFORE INSERT ON public.social_links FOR EACH ROW EXECUTE PROCEDURE public.trg_check_rate_limit();
CREATE TRIGGER trg_rate_limit_favorites BEFORE INSERT ON public.favorites FOR EACH ROW EXECUTE PROCEDURE public.trg_check_rate_limit();
CREATE TRIGGER trg_rate_limit_notif BEFORE INSERT ON public.notifications FOR EACH ROW EXECUTE PROCEDURE public.trg_check_rate_limit();

-- 5.4 Integrity & Logic
CREATE OR REPLACE FUNCTION public.prevent_offer_deletion() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN 
  IF EXISTS (SELECT 1 FROM public.orders WHERE offer_id = OLD.id AND status IN ('pending','payment_authorized','accepted','in_progress')) THEN 
    RAISE EXCEPTION 'Offre utilisée par commande en cours'; 
  END IF; 
  RETURN OLD; 
END; $$;
CREATE TRIGGER trg_check_offer_deletion BEFORE DELETE ON public.offers FOR EACH ROW EXECUTE PROCEDURE public.prevent_offer_deletion();

CREATE OR REPLACE FUNCTION public.canonicalize_conversation_participants() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE tmp uuid; 
BEGIN 
  IF NEW.participant_1_id > NEW.participant_2_id THEN 
    tmp := NEW.participant_1_id; 
    NEW.participant_1_id := NEW.participant_2_id; 
    NEW.participant_2_id := tmp; 
  END IF; 
  RETURN NEW; 
END; $$;
CREATE TRIGGER trg_canonical_conv BEFORE INSERT ON public.conversations FOR EACH ROW EXECUTE PROCEDURE public.canonicalize_conversation_participants();

CREATE OR REPLACE FUNCTION public.chk_message_integrity() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE p1 uuid; p2 uuid;
BEGIN
  IF NEW.sender_id = NEW.receiver_id THEN RAISE EXCEPTION 'Self-msg interdit'; END IF;
  SELECT participant_1_id, participant_2_id INTO p1, p2 FROM public.conversations WHERE id = NEW.conversation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Conversation introuvable'; END IF;
  IF NEW.sender_id NOT IN (p1, p2) THEN RAISE EXCEPTION 'Expéditeur intrus'; END IF;
  IF NEW.receiver_id NOT IN (p1, p2) THEN RAISE EXCEPTION 'Destinataire invalide'; END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_chk_msg BEFORE INSERT ON public.messages FOR EACH ROW EXECUTE PROCEDURE public.chk_message_integrity();

CREATE OR REPLACE FUNCTION public.update_conversation_timestamp() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN UPDATE public.conversations SET last_message_at = NOW() WHERE id = NEW.conversation_id; RETURN NEW; END; $$;
CREATE TRIGGER trg_upd_conv_ts AFTER INSERT ON public.messages FOR EACH ROW EXECUTE PROCEDURE public.update_conversation_timestamp();

-- 5.5 Financials (5%)
CREATE OR REPLACE FUNCTION public.enforce_financial_consistency() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.total_amount := ROUND(NEW.total_amount, 2);
  IF NEW.net_amount IS NULL OR NEW.net_amount = 0 THEN 
    NEW.net_amount := ROUND((NEW.total_amount * (1 - (COALESCE(NEW.commission_rate, 5.0) / 100.0))), 2); 
  ELSE 
    NEW.net_amount := ROUND(NEW.net_amount, 2); 
  END IF;
  IF NEW.total_amount < NEW.net_amount THEN RAISE EXCEPTION 'Total < Net'; END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_financial_math BEFORE INSERT OR UPDATE ON public.orders FOR EACH ROW EXECUTE PROCEDURE public.enforce_financial_consistency();

-- 5.6 Stripe Sync
CREATE OR REPLACE FUNCTION public.sync_stripe_status_to_order() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NEW.stripe_payment_status IS DISTINCT FROM OLD.stripe_payment_status THEN
    BEGIN 
      IF COALESCE(current_setting('request.jwt.claims', true)::json->>'role', '') != 'service_role' THEN 
        NEW.stripe_payment_status := OLD.stripe_payment_status; 
        RETURN NEW; 
      END IF; 
    EXCEPTION WHEN OTHERS THEN 
      NEW.stripe_payment_status := OLD.stripe_payment_status; 
      RETURN NEW; 
    END;
  END IF;
  
  IF NEW.stripe_payment_status = 'authorized' AND OLD.stripe_payment_status != 'authorized' THEN 
    IF NEW.status = 'pending' THEN 
      NEW.status := 'payment_authorized'; 
      NEW.payment_authorized_at := NOW(); 
      NEW.acceptance_deadline := NOW() + INTERVAL '48 hours'; 
    END IF;
  ELSIF NEW.stripe_payment_status = 'captured' THEN 
    NEW.captured_at := NOW();
  ELSIF NEW.stripe_payment_status = 'refunded' THEN 
    IF NEW.status NOT IN ('cancelled','disputed') THEN 
      NEW.status := 'cancelled'; 
    END IF; 
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_sync_stripe BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE PROCEDURE public.sync_stripe_status_to_order();

-- 5.7 Notification Trigger - FIX: Utilise une fonction pour récupérer les secrets
CREATE OR REPLACE FUNCTION public.trigger_notify_order_change() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_supabase_url TEXT;
  v_service_key TEXT;
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    -- Récupérer les valeurs depuis les settings
    v_supabase_url := current_setting('app.supabase_url', true);
    v_service_key := current_setting('app.service_role_key', true);
    
    IF v_supabase_url IS NOT NULL AND v_service_key IS NOT NULL THEN
      PERFORM net.http_post(
        url := v_supabase_url || '/functions/v1/notify-order-events',
        headers := jsonb_build_object(
          'Content-Type', 'application/json', 
          'Authorization', 'Bearer ' || v_service_key
        ),
        body := jsonb_build_object('orderId', NEW.id, 'event', NEW.status)
      );
    END IF;
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_notify_order_change AFTER UPDATE ON public.orders FOR EACH ROW EXECUTE PROCEDURE public.trigger_notify_order_change();

-- ======================================================
-- 6) VUES
-- ======================================================
CREATE OR REPLACE VIEW public.public_profiles AS
SELECT 
  id, role, first_name, last_name, city, bio, avatar_url, is_verified, profile_views, created_at, 
  public.mask_email(email_encrypted, id) AS email, 
  public.mask_phone(phone_encrypted, id) AS phone 
FROM public.profiles;

CREATE OR REPLACE VIEW public.dashboard_stats AS
SELECT 
  (SELECT COUNT(*) FROM public.profiles WHERE role='influenceur') as total_influencers, 
  (SELECT COUNT(*) FROM public.orders WHERE status IN ('completed', 'finished')) as completed_orders, 
  (SELECT COALESCE(SUM(amount), 0) FROM public.revenues) as total_volume_eur;

-- ======================================================
-- 7) RPC (LOGIQUE MÉTIER)
-- ======================================================

-- FIX: Fonction corrigée avec bon retour JSON
CREATE OR REPLACE FUNCTION public.handle_cron_deadlines() RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE 
  rec RECORD; 
  cancelled_count int := 0;
  completed_count int := 0;
BEGIN
  IF current_user != 'postgres' AND COALESCE(current_setting('request.jwt.claims', true)::json->>'role', '') != 'service_role' THEN 
    RAISE EXCEPTION 'Unauthorized'; 
  END IF;
  
  -- Annuler les commandes non acceptées après 48h
  FOR rec IN SELECT id FROM public.orders WHERE status = 'payment_authorized' AND acceptance_deadline < NOW() LIMIT 500 LOOP
    UPDATE public.orders SET status = 'cancelled', updated_at = NOW() WHERE id = rec.id;
    cancelled_count := cancelled_count + 1;
  END LOOP;
  
  -- Auto-compléter les commandes non confirmées par le merchant après 48h
  FOR rec IN SELECT id FROM public.orders WHERE status IN ('submitted', 'review_pending') AND merchant_confirm_deadline < NOW() LIMIT 500 LOOP
    UPDATE public.orders SET status = 'completed', updated_at = NOW() WHERE id = rec.id;
    completed_count := completed_count + 1;
  END LOOP;
  
  RETURN json_build_object(
    'success', true, 
    'cancelled', cancelled_count, 
    'completed', completed_count,
    'total_processed', cancelled_count + completed_count
  );
END; $$;

CREATE OR REPLACE FUNCTION public.safe_update_order_status(p_order_id uuid, p_new_status text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE 
  v_merchant_id uuid; 
  v_influencer_id uuid; 
  v_current_status text; 
  v_stripe_status text; 
  v_total numeric; 
  v_net numeric; 
  v_actor uuid;
BEGIN
  v_actor := auth.uid();
  PERFORM public.apply_rate_limit('safe_update_order_status'); 
  
  SELECT merchant_id, influencer_id, status, total_amount, net_amount, stripe_payment_status 
  INTO v_merchant_id, v_influencer_id, v_current_status, v_total, v_net, v_stripe_status 
  FROM public.orders WHERE id = p_order_id FOR UPDATE;
  
  IF NOT FOUND THEN RAISE EXCEPTION 'Commande introuvable'; END IF;
  IF v_actor != v_merchant_id AND v_actor != v_influencer_id AND NOT public.is_admin() THEN RAISE EXCEPTION 'Accès refusé'; END IF;
  
  IF public.is_admin() THEN 
    IF (p_new_status = 'completed' OR p_new_status = 'finished') AND v_stripe_status != 'captured' THEN 
      RAISE EXCEPTION 'Admin Safety: Capture requise'; 
    END IF; 
  END IF;
  
  UPDATE public.orders SET 
    status = p_new_status, 
    updated_at = NOW(), 
    merchant_confirm_deadline = CASE WHEN p_new_status IN ('submitted', 'review_pending') THEN NOW() + INTERVAL '48 hours' ELSE merchant_confirm_deadline END 
  WHERE id = p_order_id;
  
  INSERT INTO public.audit_orders (order_id, old_status, new_status, changed_by) VALUES (p_order_id, v_current_status, p_new_status, v_actor);
  
  IF (p_new_status = 'completed' OR p_new_status = 'finished') AND v_current_status NOT IN ('completed', 'finished') THEN 
    INSERT INTO public.revenues (influencer_id, order_id, amount, net_amount, commission, status) 
    VALUES (v_influencer_id, p_order_id, v_total, v_net, (v_total - v_net), 'available') 
    ON CONFLICT (order_id) DO NOTHING; 
  END IF;
END; $$;

CREATE OR REPLACE FUNCTION public.request_withdrawal(p_amount decimal) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_avail decimal; v_id uuid;
BEGIN
  SELECT COALESCE(SUM(net_amount), 0) INTO v_avail FROM public.revenues WHERE influencer_id = auth.uid() AND status = 'available';
  v_avail := v_avail - (SELECT COALESCE(SUM(amount), 0) FROM public.withdrawals WHERE influencer_id = auth.uid() AND status IN ('pending', 'processing'));
  IF p_amount > v_avail THEN RAISE EXCEPTION 'Solde insuffisant'; END IF;
  INSERT INTO public.withdrawals (influencer_id, amount, status) VALUES (auth.uid(), p_amount, 'pending') RETURNING id INTO v_id;
  RETURN v_id;
END; $$;

-- RPC FIFO
CREATE OR REPLACE FUNCTION public.finalize_revenue_withdrawal(p_influencer_id uuid, p_amount decimal) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r RECORD; rem decimal := p_amount;
BEGIN
  FOR r IN SELECT id, net_amount FROM public.revenues WHERE influencer_id = p_influencer_id AND status = 'available' ORDER BY created_at ASC LOOP
    IF rem <= 0 THEN EXIT; END IF;
    IF r.net_amount <= rem THEN 
      UPDATE public.revenues SET status = 'withdrawn', updated_at = NOW() WHERE id = r.id; 
      rem := rem - r.net_amount; 
    END IF;
  END LOOP;
  IF rem > 0.01 THEN 
    INSERT INTO public.system_logs (event_type, message, details) 
    VALUES ('error', 'Revenue Consistency Error', json_build_object('inf', p_influencer_id, 'miss', rem)); 
  END IF;
END; $$;

-- RPC REVERT
CREATE OR REPLACE FUNCTION public.revert_revenue_withdrawal(p_influencer_id uuid, p_amount decimal) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r RECORD; rem decimal := p_amount;
BEGIN
  FOR r IN SELECT id, net_amount FROM public.revenues WHERE influencer_id = p_influencer_id AND status = 'withdrawn' ORDER BY updated_at DESC LOOP
    IF rem <= 0 THEN EXIT; END IF;
    IF r.net_amount <= rem THEN 
      UPDATE public.revenues SET status = 'available', updated_at = NOW() WHERE id = r.id; 
      rem := rem - r.net_amount; 
    END IF;
  END LOOP;
END; $$;

CREATE OR REPLACE FUNCTION public.increment_profile_view(p_profile_id uuid) RETURNS int LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_new int; 
BEGIN 
  UPDATE public.profiles SET profile_views = profile_views + 1 WHERE id = p_profile_id RETURNING profile_views INTO v_new; 
  RETURN v_new; 
END; $$;

CREATE OR REPLACE FUNCTION public.cleanup_old_logs() RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN DELETE FROM public.system_logs WHERE created_at < NOW() - INTERVAL '30 days'; END; $$;

-- ======================================================
-- 8) RLS
-- ======================================================
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
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
ALTER TABLE public.system_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contact_messages ENABLE ROW LEVEL SECURITY;

REVOKE SELECT ON public.profiles FROM authenticated, anon; 
GRANT SELECT ON public.public_profiles TO authenticated, anon;
GRANT SELECT ON public.profiles TO authenticated; 
CREATE POLICY "Users view own profile" ON public.profiles FOR SELECT USING (auth.uid() = id OR public.is_admin());
CREATE POLICY "Users update own profile" ON public.profiles FOR UPDATE USING (auth.uid() = id OR public.is_admin());

CREATE POLICY "Public view categories" ON public.categories FOR SELECT USING (is_active = true);
CREATE POLICY "Public view active offers" ON public.offers FOR SELECT USING (is_active = true OR influencer_id = auth.uid() OR public.is_admin());
CREATE POLICY "Public view social" ON public.social_links FOR SELECT USING (is_active = true);

CREATE POLICY "User manage social select" ON public.social_links FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "User manage social insert" ON public.social_links FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "User manage social update" ON public.social_links FOR UPDATE USING (user_id = auth.uid());
CREATE POLICY "User manage social delete" ON public.social_links FOR DELETE USING (user_id = auth.uid());

CREATE POLICY "Influencer manage offers" ON public.offers FOR ALL USING (influencer_id = auth.uid());

CREATE POLICY "Participants view conversations" ON public.conversations FOR SELECT USING (auth.uid() = participant_1_id OR auth.uid() = participant_2_id);
CREATE POLICY "Participants create conversations" ON public.conversations FOR INSERT WITH CHECK (auth.uid() = participant_1_id OR auth.uid() = participant_2_id);
CREATE POLICY "Participants view messages" ON public.messages FOR SELECT USING (sender_id = auth.uid() OR receiver_id = auth.uid());
CREATE POLICY "Participants send messages" ON public.messages FOR INSERT WITH CHECK (sender_id = auth.uid());

CREATE POLICY "View own orders" ON public.orders FOR SELECT USING (merchant_id = auth.uid() OR influencer_id = auth.uid() OR public.is_admin());
CREATE POLICY "Merchant create order" ON public.orders FOR INSERT WITH CHECK (merchant_id = auth.uid());

CREATE POLICY "View own revenues" ON public.revenues FOR SELECT USING (influencer_id = auth.uid() OR public.is_admin());
CREATE POLICY "View own withdrawals" ON public.withdrawals FOR SELECT USING (influencer_id = auth.uid() OR public.is_admin());
CREATE POLICY "RPC Only Withdrawals" ON public.withdrawals FOR INSERT WITH CHECK (false); 

CREATE POLICY "Admins view logs" ON public.system_logs FOR SELECT USING (public.is_admin());
CREATE POLICY "Admins view payment logs" ON public.payment_logs FOR ALL USING (public.is_admin());

CREATE POLICY "Anon insert contact" ON public.contact_messages FOR INSERT WITH CHECK (true);
CREATE POLICY "Admin read contact" ON public.contact_messages FOR SELECT USING (public.is_admin());
CREATE POLICY "Admin update contact" ON public.contact_messages FOR UPDATE USING (public.is_admin());

CREATE POLICY "Manage favorites" ON public.favorites FOR ALL USING (merchant_id = auth.uid());
CREATE POLICY "View notifications" ON public.notifications FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "Update notifications" ON public.notifications FOR UPDATE USING (user_id = auth.uid());

-- ======================================================
-- 9) DATA INIT
-- ======================================================
INSERT INTO public.categories (name, slug, icon_name) VALUES
('Story Instagram', 'story-instagram', 'instagram'),
('Post Instagram', 'post-instagram', 'image'),
('Vidéo TikTok', 'video-tiktok', 'video'),
('UGC Vidéo', 'ugc-video', 'camera')
ON CONFLICT (slug) DO NOTHING;

GRANT SELECT ON public.dashboard_stats TO authenticated;
GRANT EXECUTE ON FUNCTION public.increment_profile_view(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.request_withdrawal(numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.safe_update_order_status(uuid, text) TO authenticated;

COMMIT;

-- ==============================================================================
-- 10) CONFIGURATION DES SECRETS (À EXÉCUTER APRÈS LE DÉPLOIEMENT)
-- ==============================================================================
-- Exécuter ces commandes dans psql avec les vraies valeurs :
--
-- ALTER DATABASE postgres SET app.encryption_key = 'votre-cle-32-bytes-en-hex';
-- ALTER DATABASE postgres SET app.supabase_url = 'https://votre-projet.supabase.co';
-- ALTER DATABASE postgres SET app.service_role_key = 'votre-service-role-key';
--
-- Puis redémarrer la connexion ou utiliser: SELECT pg_reload_conf();

-- ==============================================================================
-- 11) ACTIVATION DES CRON JOBS (À EXÉCUTER APRÈS CONFIGURATION DES SECRETS)
-- ==============================================================================
-- SELECT cron.schedule('auto-handle-deadlines', '0 * * * *', 'SELECT public.handle_cron_deadlines();');
-- SELECT cron.schedule('cleanup-logs-weekly', '0 4 * * 0', 'SELECT public.cleanup_old_logs();');
