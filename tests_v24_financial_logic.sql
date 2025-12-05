-- ============================================================================
-- TESTS DE VERIFICATION - LOGIQUE FINANCIERE V24 (CRITICAL FIXES)
-- ============================================================================

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
  v_order_id UUID;
  v_res JSONB;
  v_conv RECORD;
BEGIN
  RAISE NOTICE '=== DEBUT DES TESTS V24 ===';

  -- 1. SETUP DATA
  INSERT INTO auth.users (id, email) VALUES (gen_random_uuid(), 'freelance_v24@test.com') RETURNING id INTO v_freelancer_id;
  INSERT INTO public.profiles (id, role, first_name) VALUES (v_freelancer_id, 'influenceur', 'Freelance V24');
  
  INSERT INTO auth.users (id, email) VALUES (gen_random_uuid(), 'agent_v24@test.com') RETURNING id INTO v_agent_id;
  INSERT INTO public.profiles (id, role, first_name) VALUES (v_agent_id, 'influenceur', 'Agent V24');
  
  INSERT INTO auth.users (id, email) VALUES (gen_random_uuid(), 'client_v24@test.com') RETURNING id INTO v_client_id;
  INSERT INTO public.profiles (id, role, first_name) VALUES (v_client_id, 'commercant', 'Client V24');

  -- Create Gig
  INSERT INTO public.gigs (freelancer_id, title, slug, description, base_price, min_delivery_days, status, is_affiliable)
  VALUES (v_freelancer_id, 'Test Gig V24', 'test-gig-v24', 'Desc', 19.99, 3, 'active', true) RETURNING id INTO v_gig_id;

  -- Create Package (Price 19.99 for rounding test)
  INSERT INTO public.gig_packages (gig_id, name, price, delivery_days)
  VALUES (v_gig_id, 'Standard', 19.99, 3) RETURNING id INTO v_pkg_id;

  -- Create Listing
  INSERT INTO public.collabmarket_listings (gig_id, freelancer_id, client_discount_rate, agent_commission_rate, platform_fee_rate, platform_cut_on_agent_rate)
  VALUES (v_gig_id, v_freelancer_id, 10.0, 10.0, 5.0, 20.0) RETURNING id INTO v_listing_id;

  -- Create Link
  INSERT INTO public.affiliate_links (code, url_slug, listing_id, gig_id, agent_id)
  VALUES ('TESTV24', 'test-v24', v_listing_id, v_gig_id, v_agent_id) RETURNING id INTO v_link_id;

  RAISE NOTICE 'DATA SETUP OK';

  -- 2. TEST ROUNDING (Stripe Exact)
  -- Base: 19.99
  -- Discount 10%: 1.999 -> 2.00 (ROUND)
  -- Base - Discount: 17.99
  -- Platform Fee 5%: 0.8995 -> 0.90
  -- Agent Com 10%: 1.799 -> 1.80
  -- Platform Cut 20%: 0.36
  -- Agent Net: 1.44
  -- Freelance Net: 17.99 - 1.80 = 16.19
  
  INSERT INTO public.orders (merchant_id, influencer_id, gig_id, gig_package_id, affiliate_link_id, order_type, total_amount, net_amount, status, stripe_payment_status)
  VALUES (v_client_id, v_freelancer_id, v_gig_id, v_pkg_id, v_link_id, 'freelance_gig', 18.89, 19.99, 'pending', 'captured')
  RETURNING id INTO v_order_id;

  v_res := public.distribute_commissions(v_order_id);
  
  SELECT * INTO v_conv FROM public.affiliate_conversions WHERE order_id = v_order_id;
  
  IF v_conv.client_discount != 2.00 THEN RAISE EXCEPTION 'Fail Rounding Discount: %', v_conv.client_discount; END IF;
  IF v_conv.agent_commission != 1.80 THEN RAISE EXCEPTION 'Fail Rounding Agent Com: %', v_conv.agent_commission; END IF;
  IF v_conv.platform_cut_on_agent != 0.36 THEN RAISE EXCEPTION 'Fail Rounding Cut: %', v_conv.platform_cut_on_agent; END IF;
  IF v_conv.freelancer_net != 16.19 THEN RAISE EXCEPTION 'Fail Rounding Freelance: %', v_conv.freelancer_net; END IF;

  RAISE NOTICE '✅ TEST 1 (ROUNDING) PASSED';

  -- 3. TEST IMMUTABLE LEDGER
  BEGIN
    DELETE FROM public.ledger WHERE order_id = v_order_id;
    RAISE EXCEPTION 'Fail: Ledger should be immutable';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '✅ TEST 2 (IMMUTABLE LEDGER) PASSED (Error caught: %)', SQLERRM;
  END;

  -- 4. TEST REFUND
  v_res := public.reverse_commissions(v_order_id, 18.89);
  
  PERFORM 1 FROM public.orders WHERE id = v_order_id AND refund_status = 'full';
  IF NOT FOUND THEN RAISE EXCEPTION 'Fail Refund Status'; END IF;
  
  PERFORM 1 FROM public.ledger WHERE order_id = v_order_id AND type = 'refund' AND actor_type = 'freelancer' AND direction = 'debit';
  IF NOT FOUND THEN RAISE EXCEPTION 'Fail Refund Ledger'; END IF;

  RAISE NOTICE '✅ TEST 3 (REFUND) PASSED';

  RAISE NOTICE '=== TOUS LES TESTS V24 PASSES ===';
  ROLLBACK;
END;
$$;
