-- ============================================================================
-- TESTS DE VERIFICATION - LOGIQUE FINANCIERE V23
-- ============================================================================
-- Ce script crée des données de test temporaires, exécute les calculs et vérifie les résultats.
-- Il utilise une transaction ROLLBACK à la fin pour ne pas polluer la base.

BEGIN;

DO $$
DECLARE
  v_freelancer_id UUID;
  v_agent_id UUID;
  v_client_id UUID;
  v_gig_id UUID;
  v_pkg_id UUID;
  v_listing_id UUID;
  v_link_id UUID;
  v_order_affiliate_id UUID;
  v_order_direct_id UUID;
  v_res JSONB;
  v_conv RECORD;
  v_ledger_count INT;
BEGIN
  RAISE NOTICE '=== DEBUT DES TESTS V23 ===';

  -- 1. SETUP DATA
  INSERT INTO auth.users (id, email) VALUES (gen_random_uuid(), 'freelance@test.com') RETURNING id INTO v_freelancer_id;
  INSERT INTO public.profiles (id, role, first_name) VALUES (v_freelancer_id, 'influenceur', 'Freelance Test');
  
  INSERT INTO auth.users (id, email) VALUES (gen_random_uuid(), 'agent@test.com') RETURNING id INTO v_agent_id;
  INSERT INTO public.profiles (id, role, first_name) VALUES (v_agent_id, 'influenceur', 'Agent Test');
  
  INSERT INTO auth.users (id, email) VALUES (gen_random_uuid(), 'client@test.com') RETURNING id INTO v_client_id;
  INSERT INTO public.profiles (id, role, first_name) VALUES (v_client_id, 'commercant', 'Client Test');

  -- Create Gig
  INSERT INTO public.gigs (freelancer_id, title, slug, description, base_price, min_delivery_days, status, is_affiliable)
  VALUES (v_freelancer_id, 'Test Gig', 'test-gig', 'Desc', 100.00, 3, 'active', true) RETURNING id INTO v_gig_id;

  -- Create Package (Price 100)
  INSERT INTO public.gig_packages (gig_id, name, price, delivery_days)
  VALUES (v_gig_id, 'Standard', 100.00, 3) RETURNING id INTO v_pkg_id;

  -- Create Listing (Affiliable)
  -- Config: Discount 5%, Agent 10%, Platform Fee 5%, Platform Cut 20%
  INSERT INTO public.collabmarket_listings (gig_id, freelancer_id, client_discount_rate, agent_commission_rate, platform_fee_rate, platform_cut_on_agent_rate)
  VALUES (v_gig_id, v_freelancer_id, 5.0, 10.0, 5.0, 20.0) RETURNING id INTO v_listing_id;

  -- Create Affiliate Link
  INSERT INTO public.affiliate_links (code, url_slug, listing_id, gig_id, agent_id)
  VALUES ('TEST1234', 'test-slug', v_listing_id, v_gig_id, v_agent_id) RETURNING id INTO v_link_id;

  RAISE NOTICE 'DATA SETUP OK';

  -- 2. TEST CAS 1 : COMMANDE AFFILIEE
  -- Calcul théorique :
  -- Base: 100
  -- Discount: 5% -> 5.00
  -- Platform Fee: 5% de (100-5) = 4.75
  -- Client Pay: 95 + 4.75 = 99.75
  -- Agent Com Base: 95
  -- Agent Com: 10% de 95 = 9.50
  -- Platform Cut: 20% de 9.50 = 1.90
  -- Agent Net: 9.50 - 1.90 = 7.60
  -- Freelance Net: 100 - 5 - 9.50 = 85.50
  -- Platform Revenue: 4.75 + 1.90 = 6.65

  INSERT INTO public.orders (merchant_id, influencer_id, gig_id, gig_package_id, affiliate_link_id, order_type, total_amount, net_amount, status, stripe_payment_status)
  VALUES (v_client_id, v_freelancer_id, v_gig_id, v_pkg_id, v_link_id, 'freelance', 99.75, 100.00, 'pending', 'captured') -- net_amount store base price here for logic
  RETURNING id INTO v_order_affiliate_id;

  -- Execute Distribution
  v_res := public.distribute_commissions(v_order_affiliate_id);
  RAISE NOTICE 'Distribute Affiliate Result: %', v_res;

  -- Verify Conversion
  SELECT * INTO v_conv FROM public.affiliate_conversions WHERE order_id = v_order_affiliate_id;
  
  IF v_conv.base_price != 100.00 THEN RAISE EXCEPTION 'Fail: Base Price %', v_conv.base_price; END IF;
  IF v_conv.client_discount != 5.00 THEN RAISE EXCEPTION 'Fail: Discount %', v_conv.client_discount; END IF;
  IF v_conv.platform_fee != 4.75 THEN RAISE EXCEPTION 'Fail: Platform Fee %', v_conv.platform_fee; END IF;
  IF v_conv.agent_commission != 9.50 THEN RAISE EXCEPTION 'Fail: Agent Com %', v_conv.agent_commission; END IF;
  IF v_conv.platform_cut_on_agent != 1.90 THEN RAISE EXCEPTION 'Fail: Platform Cut %', v_conv.platform_cut_on_agent; END IF;
  IF v_conv.agent_net != 7.60 THEN RAISE EXCEPTION 'Fail: Agent Net %', v_conv.agent_net; END IF;
  IF v_conv.freelancer_net != 85.50 THEN RAISE EXCEPTION 'Fail: Freelancer Net %', v_conv.freelancer_net; END IF;
  IF v_conv.platform_revenue != 6.65 THEN RAISE EXCEPTION 'Fail: Platform Rev %', v_conv.platform_revenue; END IF;

  RAISE NOTICE '✅ TEST 1 (AFFILIATE) PASSED';

  -- 3. TEST CAS 2 : COMMANDE DIRECTE (SANS AGENT)
  -- Calcul théorique :
  -- Base: 100
  -- Fee: 5% = 5.00 (Standard fallback)
  -- Freelance Net: 100
  -- Platform Rev: 5.00

  INSERT INTO public.orders (merchant_id, influencer_id, gig_id, gig_package_id, affiliate_link_id, order_type, total_amount, net_amount, status, stripe_payment_status)
  VALUES (v_client_id, v_freelancer_id, v_gig_id, v_pkg_id, NULL, 'freelance', 105.00, 100.00, 'pending', 'captured')
  RETURNING id INTO v_order_direct_id;

  v_res := public.distribute_commissions(v_order_direct_id);
  RAISE NOTICE 'Distribute Direct Result: %', v_res;

  -- Verify Ledger
  PERFORM 1 FROM public.ledger WHERE order_id = v_order_direct_id AND actor_type = 'freelancer' AND amount = 100.00;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fail Direct: Freelancer Ledger missing'; END IF;
  
  PERFORM 1 FROM public.ledger WHERE order_id = v_order_direct_id AND actor_type = 'platform' AND amount = 5.00;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fail Direct: Platform Ledger missing'; END IF;

  RAISE NOTICE '✅ TEST 2 (DIRECT) PASSED';

  -- 4. TEST IDEMPOTENCE
  -- Rerun distribute on affiliate order
  v_res := public.distribute_commissions(v_order_affiliate_id);
  IF (v_res->>'message') != 'Already processed' THEN RAISE EXCEPTION 'Fail Idempotency'; END IF;
  
  SELECT COUNT(*) INTO v_ledger_count FROM public.ledger WHERE order_id = v_order_affiliate_id;
  -- Should be 3 entries (Freelancer, Agent, Platform)
  IF v_ledger_count != 3 THEN RAISE EXCEPTION 'Fail Idempotency: Ledger count %', v_ledger_count; END IF;

  RAISE NOTICE '✅ TEST 3 (IDEMPOTENCY) PASSED';

  -- 5. TEST EDGE CASE: 0% RATES
  -- Update listing to 0%
  UPDATE public.collabmarket_listings SET client_discount_rate = 0, agent_commission_rate = 0, platform_fee_rate = 0, platform_cut_on_agent_rate = 0 WHERE id = v_listing_id;
  
  -- Create new order
  INSERT INTO public.orders (merchant_id, influencer_id, gig_id, gig_package_id, affiliate_link_id, order_type, total_amount, net_amount, status, stripe_payment_status)
  VALUES (v_client_id, v_freelancer_id, v_gig_id, v_pkg_id, v_link_id, 'freelance', 100.00, 100.00, 'pending', 'captured')
  RETURNING id INTO v_order_affiliate_id; -- Reuse variable
  
  v_res := public.distribute_commissions(v_order_affiliate_id);
  
  SELECT * INTO v_conv FROM public.affiliate_conversions WHERE order_id = v_order_affiliate_id;
  IF v_conv.freelancer_net != 100.00 THEN RAISE EXCEPTION 'Fail 0%%: Freelancer Net %', v_conv.freelancer_net; END IF;
  IF v_conv.agent_net != 0.00 THEN RAISE EXCEPTION 'Fail 0%%: Agent Net %', v_conv.agent_net; END IF;
  IF v_conv.platform_revenue != 0.00 THEN RAISE EXCEPTION 'Fail 0%%: Platform Rev %', v_conv.platform_revenue; END IF;

  RAISE NOTICE '✅ TEST 4 (0% RATES) PASSED';

  RAISE NOTICE '=== TOUS LES TESTS PASSES AVEC SUCCES ===';
  
  -- ROLLBACK POUR NE RIEN GARDER
  ROLLBACK;
END;
$$;
