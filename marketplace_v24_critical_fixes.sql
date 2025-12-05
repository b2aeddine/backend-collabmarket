-- ============================================================================
-- MARKETPLACE V24 - CRITICAL FIXES & HARDENING
-- ============================================================================
-- Dépendances : marketplace_v23_freelance_schema.sql et marketplace_v23_functions.sql

BEGIN;

-- ============================================================================
-- 1. MISSING TABLES (Fiverr-like)
-- ============================================================================

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

CREATE INDEX IF NOT EXISTS idx_gig_tags_tag ON public.gig_tags(tag);

-- RLS for new tables
ALTER TABLE public.gig_faqs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_requirements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_tags ENABLE ROW LEVEL SECURITY;

CREATE POLICY "gig_faqs_read_public" ON public.gig_faqs FOR SELECT USING (true);
CREATE POLICY "gig_faqs_write_own" ON public.gig_faqs FOR ALL USING (EXISTS (SELECT 1 FROM public.gigs WHERE id = gig_id AND freelancer_id = auth.uid()));

CREATE POLICY "gig_reqs_read_public" ON public.gig_requirements FOR SELECT USING (true);
CREATE POLICY "gig_reqs_write_own" ON public.gig_requirements FOR ALL USING (EXISTS (SELECT 1 FROM public.gigs WHERE id = gig_id AND freelancer_id = auth.uid()));

CREATE POLICY "gig_tags_read_public" ON public.gig_tags FOR SELECT USING (true);
CREATE POLICY "gig_tags_write_own" ON public.gig_tags FOR ALL USING (EXISTS (SELECT 1 FROM public.gigs WHERE id = gig_id AND freelancer_id = auth.uid()));

-- ============================================================================
-- 2. SCHEMA HARDENING & CONSTRAINTS
-- ============================================================================

-- 2.1 Order Type Constraint
ALTER TABLE public.orders DROP CONSTRAINT IF EXISTS orders_order_type_check;
ALTER TABLE public.orders ADD CONSTRAINT orders_order_type_check CHECK (order_type IN ('influencer_offer', 'freelance_gig'));

-- 2.2 Collabmarket Listings Business Constraints
ALTER TABLE public.collabmarket_listings DROP CONSTRAINT IF EXISTS collabmarket_listings_agent_commission_rate_check;
ALTER TABLE public.collabmarket_listings ADD CONSTRAINT collabmarket_listings_agent_commission_rate_check CHECK (agent_commission_rate BETWEEN 0 AND 30);

ALTER TABLE public.collabmarket_listings DROP CONSTRAINT IF EXISTS collabmarket_listings_platform_fee_rate_check;
ALTER TABLE public.collabmarket_listings ADD CONSTRAINT collabmarket_listings_platform_fee_rate_check CHECK (platform_fee_rate BETWEEN 0 AND 15);

ALTER TABLE public.collabmarket_listings DROP CONSTRAINT IF EXISTS collabmarket_listings_platform_cut_on_agent_rate_check;
ALTER TABLE public.collabmarket_listings ADD CONSTRAINT collabmarket_listings_platform_cut_on_agent_rate_check CHECK (platform_cut_on_agent_rate BETWEEN 0 AND 50);

-- 2.3 Immutable Revenues
ALTER TABLE public.freelancer_revenues ADD COLUMN IF NOT EXISTS locked BOOLEAN DEFAULT FALSE;
ALTER TABLE public.agent_revenues ADD COLUMN IF NOT EXISTS locked BOOLEAN DEFAULT FALSE;
ALTER TABLE public.platform_revenues ADD COLUMN IF NOT EXISTS locked BOOLEAN DEFAULT FALSE;

CREATE OR REPLACE FUNCTION public.prevent_revenue_modification() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.locked = TRUE THEN RAISE EXCEPTION 'Cannot modify locked revenue entry'; END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_lock_freelancer_revenues BEFORE UPDATE OR DELETE ON public.freelancer_revenues FOR EACH ROW EXECUTE FUNCTION public.prevent_revenue_modification();
CREATE TRIGGER trg_lock_agent_revenues BEFORE UPDATE OR DELETE ON public.agent_revenues FOR EACH ROW EXECUTE FUNCTION public.prevent_revenue_modification();
CREATE TRIGGER trg_lock_platform_revenues BEFORE UPDATE OR DELETE ON public.platform_revenues FOR EACH ROW EXECUTE FUNCTION public.prevent_revenue_modification();

-- 2.4 Ledger Append-Only Policies
DROP POLICY IF EXISTS "ledger_read_admin" ON public.ledger;
CREATE POLICY "ledger_read_admin" ON public.ledger FOR SELECT USING (public.is_admin());
-- No UPDATE/DELETE policies created means default deny for everyone (including admin if not explicit, but we want NO ONE).
-- To be safe, we can add a trigger to prevent UPDATE/DELETE even for superusers/service_role if possible, but RLS is good for app users.
-- Let's add a trigger for extra safety.
CREATE OR REPLACE FUNCTION public.prevent_ledger_modification() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Ledger is immutable'; END;
$$;
CREATE TRIGGER trg_ledger_immutable BEFORE UPDATE OR DELETE ON public.ledger FOR EACH ROW EXECUTE FUNCTION public.prevent_ledger_modification();

-- ============================================================================
-- 3. FINANCIAL LOGIC & REFUNDS
-- ============================================================================

-- 3.1 Refund Columns
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS refund_status TEXT DEFAULT 'none' CHECK (refund_status IN ('none','partial','full'));
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS refund_amount DECIMAL(10,2) DEFAULT 0;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS refunded_at TIMESTAMPTZ;

-- 3.2 Reverse Commissions RPC
CREATE OR REPLACE FUNCTION public.reverse_commissions(p_order_id UUID, p_refund_amount DECIMAL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_conv public.affiliate_conversions%ROWTYPE;
  v_ratio DECIMAL;
BEGIN
  IF NOT public.is_service_role() AND NOT public.is_admin() THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  
  SELECT * INTO v_conv FROM public.affiliate_conversions WHERE order_id = p_order_id;
  
  -- Calculate ratio if partial refund (simple pro-rata)
  -- Note: This is complex. For full refund, we reverse everything.
  -- For partial, we might only reverse freelancer part, or everything pro-rata.
  -- Assumption: Full Refund for now or pro-rata on all parts.
  
  -- Ledger: Debit Freelancer
  INSERT INTO public.ledger (type, actor_type, actor_id, order_id, gig_id, amount, direction, metadata)
  VALUES ('refund', 'freelancer', v_conv.freelancer_id, p_order_id, v_conv.gig_id, v_conv.freelancer_net, 'debit', jsonb_build_object('reason', 'refund'));
  
  -- Update Revenue Status to Cancelled (if full refund)
  UPDATE public.freelancer_revenues SET status = 'cancelled', locked = TRUE WHERE order_id = p_order_id;
  
  IF v_conv.agent_id IS NOT NULL THEN
     INSERT INTO public.ledger (type, actor_type, actor_id, order_id, gig_id, amount, direction, metadata)
     VALUES ('refund', 'agent', v_conv.agent_id, p_order_id, v_conv.gig_id, v_conv.agent_net, 'debit', jsonb_build_object('reason', 'refund'));
     UPDATE public.agent_revenues SET status = 'cancelled', locked = TRUE WHERE order_id = p_order_id;
  END IF;
  
  UPDATE public.orders SET refund_status = 'full', refund_amount = p_refund_amount, refunded_at = NOW(), status = 'cancelled' WHERE id = p_order_id;
  
  RETURN jsonb_build_object('success', true);
END;
$$;

-- ============================================================================
-- 4. WORKFLOW CORRECTIONS
-- ============================================================================

-- 4.1 Fix Stripe Trigger (Payment Authorized NOT Accepted)
CREATE OR REPLACE FUNCTION public.sync_stripe_status_to_order() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  -- Authorization: requires_capture
  IF NEW.stripe_payment_status = 'requires_capture' AND OLD.stripe_payment_status != 'requires_capture' AND NEW.status = 'pending' THEN
    NEW.status := 'payment_authorized';
    NEW.payment_authorized_at := NOW();
    NEW.acceptance_deadline := NOW() + INTERVAL '48 hours';
  
  -- Capture: captured or succeeded -> PAYMENT_AUTHORIZED (Freelancer must accept)
  ELSIF NEW.stripe_payment_status IN ('captured', 'succeeded') AND OLD.stripe_payment_status NOT IN ('captured', 'succeeded') THEN
    -- DO NOT auto-accept. Just ensure status is at least payment_authorized.
    IF NEW.status = 'pending' THEN
       NEW.status := 'payment_authorized';
       NEW.payment_authorized_at := NOW();
    END IF;
    -- If already accepted/in_progress, do nothing (just update stripe status).
  END IF;
  RETURN NEW;
END;
$$;

-- 4.2 Prevent Financial Field Update
CREATE OR REPLACE FUNCTION public.prevent_financial_field_update() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF (OLD.agent_commission_rate != NEW.agent_commission_rate OR OLD.client_discount_rate != NEW.client_discount_rate) THEN
    -- Check if sales exist
    IF EXISTS (SELECT 1 FROM public.affiliate_conversions WHERE gig_id = OLD.gig_id) THEN
       RAISE EXCEPTION 'Cannot modify commission rates after sales have occurred. Create a new listing/gig.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_prevent_financial_update BEFORE UPDATE ON public.collabmarket_listings FOR EACH ROW EXECUTE FUNCTION public.prevent_financial_field_update();

-- 4.3 Validate Order Integrity
CREATE OR REPLACE FUNCTION public.validate_freelance_order_integrity() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_gig_status TEXT;
  v_listing_active BOOLEAN;
BEGIN
  IF NEW.order_type = 'freelance_gig' THEN
    -- Check Gig Status
    SELECT status INTO v_gig_status FROM public.gigs WHERE id = NEW.gig_id;
    IF v_gig_status != 'active' THEN RAISE EXCEPTION 'Gig is not active'; END IF;
    
    -- Check Affiliate Integrity
    IF NEW.affiliate_link_id IS NOT NULL THEN
       SELECT is_active INTO v_listing_active FROM public.collabmarket_listings 
       WHERE id = (SELECT listing_id FROM public.affiliate_links WHERE id = NEW.affiliate_link_id);
       
       IF v_listing_active IS NOT TRUE THEN RAISE EXCEPTION 'Affiliate listing is not active'; END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_order_integrity BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION public.validate_freelance_order_integrity();

COMMIT;
