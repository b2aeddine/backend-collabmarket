-- ============================================================================
-- MARKETPLACE V24 - PATCH DISTRIBUTE COMMISSIONS (STRIPE ROUNDING)
-- ============================================================================

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
    v_base_price := v_order.total_amount; 
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
      
      -- Platform Fee
      v_platform_fee := ROUND((v_base_price - v_client_discount) * (v_platform_fee_rate / 100.0) * 100) / 100.0;
      
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
    v_platform_fee := ROUND(v_base_price * 0.05 * 100) / 100.0;
    v_freelancer_net := v_base_price;
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
