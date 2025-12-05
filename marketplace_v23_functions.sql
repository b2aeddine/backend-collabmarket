-- ============================================================================
-- MARKETPLACE V23 - FONCTIONS & RPC (FREELANCE)
-- ============================================================================

BEGIN;

-- 1. RPC: CREATE COMPLETE GIG (Atomic)
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

  -- 4. Insert Affiliate Config (if provided)
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

-- 2. RPC: DISTRIBUTE COMMISSIONS (The Core Financial Logic)
CREATE OR REPLACE FUNCTION public.distribute_commissions(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_order RECORD;
  v_affiliate_conv RECORD;
  v_listing RECORD;
  
  -- Variables calculées
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
  
  -- Vérifier si déjà traité (via ledger ou affiliate_conversions)
  PERFORM 1 FROM public.ledger WHERE order_id = p_order_id LIMIT 1;
  IF FOUND THEN RETURN jsonb_build_object('success', true, 'message', 'Already processed'); END IF;

  v_base_price := v_order.net_amount; -- On suppose que net_amount stocke le prix de base du package ici, ou total_amount. 
  -- ATTENTION: Dans le schéma V21, total_amount est le payé par le client. 
  -- Pour un gig, total_amount = base - discount + fee.
  -- Il faut retrouver le base_price. 
  -- Si c'est un gig, on regarde le package.
  IF v_order.gig_package_id IS NOT NULL THEN
    SELECT price INTO v_base_price FROM public.gig_packages WHERE id = v_order.gig_package_id;
  ELSE
    v_base_price := v_order.total_amount; -- Fallback (ex: custom offer)
  END IF;

  -- 2. Gestion Affiliation
  IF v_order.affiliate_link_id IS NOT NULL THEN
    -- Récupérer la config affiliation au moment de la commande (snapshot idéalement, mais ici on prend le listing)
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
      
      -- CALCULS (Formules du prompt)
      v_client_discount := ROUND((v_client_discount_rate / 100.0) * v_base_price, 2);
      
      -- Platform Fee (payé par client)
      -- Formule prompt: platform_fee = (platform_fee_rate * (base_price - client_discount))
      v_platform_fee := ROUND((v_platform_fee_rate / 100.0) * (v_base_price - v_client_discount), 2);
      
      -- Agent Commission
      -- Formule prompt: agent_commission = agent_commission_rate * (base_price - client_discount)
      v_agent_commission := ROUND((v_agent_commission_rate / 100.0) * (v_base_price - v_client_discount), 2);
      
      -- Platform Cut on Agent
      v_platform_cut_on_agent := ROUND((v_platform_cut_on_agent_rate / 100.0) * v_agent_commission, 2);
      
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
    -- Pas d'affiliation : Calcul standard (Freelance + Platform Fee simple si applicable)
    -- Ici on simplifie : Freelance touche tout sauf frais plateforme standard s'il y en a.
    -- Supposons frais standard 5%
    v_platform_fee := ROUND(0.05 * v_base_price, 2);
    v_freelancer_net := v_base_price; -- Ou v_base_price - fee si le freelance paie les frais. 
    -- Dans le modèle Fiverr, le client paie les frais. Donc Freelance touche base_price.
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

COMMIT;
