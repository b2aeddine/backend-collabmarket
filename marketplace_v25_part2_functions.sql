-- ============================================================================
-- MARKETPLACE V25 FULL - PART 2: FUNCTIONS & TRIGGERS
-- ============================================================================

BEGIN;

-- 1. UTILS
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.profiles (id, role, first_name, email_encrypted)
  VALUES (NEW.id, 'influenceur', 'New User', NULL);
  RETURN NEW;
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
  -- 1. Insert Gig
  INSERT INTO public.gigs (
    freelancer_id, category_id, title, slug, description, base_price, min_delivery_days, status, is_affiliable
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

  -- 2. Insert Packages
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

  -- 3. Insert Media
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

  -- 4. Insert Affiliate Config
  IF p_affiliate_config IS NOT NULL AND (p_gig->>'is_affiliable')::BOOLEAN THEN
    INSERT INTO public.collabmarket_listings (
      gig_id, freelancer_id, client_discount_rate, agent_commission_rate, platform_fee_rate, platform_cut_on_agent_rate
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

-- 3. FINANCIAL LOGIC (CENTRAL RPC)
CREATE OR REPLACE FUNCTION public.distribute_commissions(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_order RECORD;
  v_listing RECORD;
  
  -- Variables calculées (Stripe Rounding Logic)
  v_base_price DECIMAL;
  v_client_discount DECIMAL := 0;
  v_platform_fee DECIMAL := 0;
  v_agent_commission DECIMAL := 0;
  v_platform_cut_on_agent DECIMAL := 0;
  v_freelancer_net DECIMAL;
  v_agent_net DECIMAL := 0;
  v_platform_revenue DECIMAL := 0;
  
  -- Configuration
  v_client_discount_rate DECIMAL := 0;
  v_agent_commission_rate DECIMAL := 0;
  v_platform_fee_rate DECIMAL := 5.0;
  v_platform_cut_on_agent_rate DECIMAL := 20.0;
  
BEGIN
  -- 1. Récupérer la commande
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;
  
  -- Vérifier si déjà traité
  PERFORM 1 FROM public.ledger WHERE order_id = p_order_id LIMIT 1;
  IF FOUND THEN RETURN jsonb_build_object('success', true, 'message', 'Already processed'); END IF;

  -- Base Price Logic
  IF v_order.gig_package_id IS NOT NULL THEN
    SELECT price INTO v_base_price FROM public.gig_packages WHERE id = v_order.gig_package_id;
  ELSE
    v_base_price := v_order.total_amount; -- Fallback
  END IF;

  -- 2. Gestion Affiliation
  IF v_order.affiliate_link_id IS NOT NULL THEN
    SELECT l.*, a.agent_id 
    INTO v_listing 
    FROM public.affiliate_links a
    JOIN public.collabmarket_listings l ON a.listing_id = l.id
    WHERE a.id = v_order.affiliate_link_id;
    
    IF FOUND THEN
      v_client_discount_rate := v_listing.client_discount_rate;
      v_agent_commission_rate := v_listing.agent_commission_rate;
      v_platform_fee_rate := v_listing.platform_fee_rate;
      v_platform_cut_on_agent_rate := v_listing.platform_cut_on_agent_rate;
      
      -- STRIPE EXACT ROUNDING: ROUND(amount * 100) / 100
      -- Discount
      v_client_discount := ROUND(v_base_price * (v_client_discount_rate / 100.0) * 100) / 100.0;
      
      -- Platform Fee (Client Fee)
      v_platform_fee := ROUND(v_base_price * (v_platform_fee_rate / 100.0) * 100) / 100.0;
      
      -- Agent Commission
      v_agent_commission := ROUND((v_base_price - v_client_discount) * (v_agent_commission_rate / 100.0) * 100) / 100.0;
      
      -- Platform Cut on Agent
      v_platform_cut_on_agent := ROUND(v_agent_commission * (v_platform_cut_on_agent_rate / 100.0) * 100) / 100.0;
      
      v_agent_net := v_agent_commission - v_platform_cut_on_agent;
      v_freelancer_net := v_base_price - v_client_discount - v_agent_commission;
      v_platform_revenue := v_platform_fee + v_platform_cut_on_agent;
      
      -- Enregistrement Conversion
      INSERT INTO public.affiliate_conversions (
        affiliate_link_id, order_id, gig_id, agent_id, freelancer_id, client_id,
        base_price, client_discount, platform_fee, agent_commission, platform_cut_on_agent,
        freelancer_net, agent_net, platform_revenue
      ) VALUES (
        v_order.affiliate_link_id, p_order_id, v_order.gig_id, v_listing.agent_id, v_order.influencer_id, v_order.merchant_id,
        v_base_price, v_client_discount, v_platform_fee, v_agent_commission, v_platform_cut_on_agent,
        v_freelancer_net, v_agent_net, v_platform_revenue
      );
      
      -- Ledger: Credit Agent
      INSERT INTO public.ledger (type, actor_type, actor_id, order_id, gig_id, amount, direction, metadata)
      VALUES ('affiliate_commission', 'agent', v_listing.agent_id, p_order_id, v_order.gig_id, v_agent_net, 'credit', jsonb_build_object('rate', v_agent_commission_rate));
      
      -- Agent Revenue
      INSERT INTO public.agent_revenues (agent_id, order_id, affiliate_link_id, amount, status)
      VALUES (v_listing.agent_id, p_order_id, v_order.affiliate_link_id, v_agent_net, 'pending');
      
    END IF;
  ELSE
    -- Pas d'affiliation
    v_platform_fee := ROUND(v_base_price * 0.05 * 100) / 100.0; -- 5% Standard
    v_freelancer_net := v_base_price; -- Freelancer gets full base price (Client pays fee on top usually, but here fee is separate revenue stream)
    v_platform_revenue := v_platform_fee;
  END IF;

  -- Ledger: Credit Freelancer
  INSERT INTO public.ledger (type, actor_type, actor_id, order_id, gig_id, amount, direction, metadata)
  VALUES ('order_payment', 'freelancer', v_order.influencer_id, p_order_id, v_order.gig_id, v_freelancer_net, 'credit', NULL);

  -- Ledger: Credit Platform
  INSERT INTO public.ledger (type, actor_type, actor_id, order_id, gig_id, amount, direction, metadata)
  VALUES ('platform_fee', 'platform', NULL, p_order_id, v_order.gig_id, v_platform_revenue, 'credit', NULL);

  -- Freelancer Revenue
  INSERT INTO public.freelancer_revenues (freelancer_id, order_id, source_type, amount, status)
  VALUES (v_order.influencer_id, p_order_id, 'gig', v_freelancer_net, 'pending');

  -- Platform Revenue
  INSERT INTO public.platform_revenues (order_id, amount, source)
  VALUES (p_order_id, v_platform_revenue, 'fee_and_commission');

  RETURN jsonb_build_object('success', true);
END;
$$;

-- 4. REFUND RPC
CREATE OR REPLACE FUNCTION public.reverse_commissions(p_order_id UUID, p_refund_amount DECIMAL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_conv public.affiliate_conversions%ROWTYPE;
BEGIN
  IF NOT public.is_service_role() AND NOT public.is_admin() THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  
  SELECT * INTO v_conv FROM public.affiliate_conversions WHERE order_id = p_order_id;
  
  -- Ledger: Debit Freelancer
  INSERT INTO public.ledger (type, actor_type, actor_id, order_id, gig_id, amount, direction, metadata)
  VALUES ('refund', 'freelancer', v_conv.freelancer_id, p_order_id, v_conv.gig_id, v_conv.freelancer_net, 'debit', jsonb_build_object('reason', 'refund'));
  
  -- Update Revenue Status
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

-- 5. TRIGGERS
-- 5.1 Sync Stripe Status
CREATE OR REPLACE FUNCTION public.sync_stripe_status_to_order() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  -- Authorization
  IF NEW.stripe_payment_status = 'requires_capture' AND OLD.stripe_payment_status != 'requires_capture' AND NEW.status = 'pending' THEN
    NEW.status := 'payment_authorized';
    NEW.payment_authorized_at := NOW();
  -- Capture
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

-- 5.2 Validate Integrity
CREATE OR REPLACE FUNCTION public.validate_freelance_order_integrity() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_gig_status TEXT;
  v_listing_active BOOLEAN;
BEGIN
  IF NEW.order_type = 'freelance_gig' THEN
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

CREATE TRIGGER trg_validate_order_integrity BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION public.validate_freelance_order_integrity();

-- 5.3 Immutable Ledger
CREATE OR REPLACE FUNCTION public.prevent_ledger_modification() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Ledger is immutable'; END;
$$;
CREATE TRIGGER trg_ledger_immutable BEFORE UPDATE OR DELETE ON public.ledger FOR EACH ROW EXECUTE FUNCTION public.prevent_ledger_modification();

-- 5.4 Locked Revenues
CREATE OR REPLACE FUNCTION public.prevent_revenue_modification() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.locked = TRUE THEN RAISE EXCEPTION 'Cannot modify locked revenue entry'; END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_lock_freelancer_revenues BEFORE UPDATE OR DELETE ON public.freelancer_revenues FOR EACH ROW EXECUTE FUNCTION public.prevent_revenue_modification();
CREATE TRIGGER trg_lock_agent_revenues BEFORE UPDATE OR DELETE ON public.agent_revenues FOR EACH ROW EXECUTE FUNCTION public.prevent_revenue_modification();

COMMIT;
