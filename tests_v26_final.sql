-- ============================================================================
-- TESTS DE VERIFICATION - MARKETPLACE V26 FINAL
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
  RAISE NOTICE '=== DEBUT TESTS V26 ===';

  -- 1. SETUP USERS
  INSERT INTO auth.users (id, email) VALUES (gen_random_uuid(), 'freelance_v26@test.com') RETURNING id INTO v_freelancer_id;
  INSERT INTO public.profiles (id, role, first_name) VALUES (v_freelancer_id, 'influenceur', 'Freelance V26');
  
  INSERT INTO auth.users (id, email) VALUES (gen_random_uuid(), 'agent_v26@test.com') RETURNING id INTO v_agent_id;
  INSERT INTO public.profiles (id, role, first_name) VALUES (v_agent_id, 'influenceur', 'Agent V26');
  
  INSERT INTO auth.users (id, email) VALUES (gen_random_uuid(), 'client_v26@test.com') RETURNING id INTO v_client_id;
  INSERT INTO public.profiles (id, role, first_name) VALUES (v_client_id, 'commercant', 'Client V26');

  -- 2. SETUP GIG & AFFILIATION
  INSERT INTO public.gigs (freelancer_id, title, slug, description, base_price, min_delivery_days, status, is_affiliable)
  VALUES (v_freelancer_id, 'Gig V26', 'gig-v26', 'Desc', 100.00, 3, 'active', true) RETURNING id INTO v_gig_id;

  INSERT INTO public.gig_packages (gig_id, name, price, delivery_days)
  VALUES (v_gig_id, 'Standard', 100.00, 3) RETURNING id INTO v_pkg_id;

  -- Config: Discount 5%, Agent 10%, Platform Fee 5%, Platform Cut 20%
  INSERT INTO public.collabmarket_listings (gig_id, freelancer_id, client_discount_rate, agent_commission_rate, platform_fee_rate, platform_cut_on_agent_rate)
  VALUES (v_gig_id, v_freelancer_id, 5.0, 10.0, 5.0, 20.0) RETURNING id INTO v_listing_id;

  INSERT INTO public.affiliate_links (code, url_slug, listing_id, gig_id, agent_id)
  VALUES ('V26TEST', 'v26-test', v_listing_id, v_gig_id, v_agent_id) RETURNING id INTO v_link_id;

  -- 3. CREATE ORDER (Simulate Stripe Capture)
  -- Base: 100
  -- Discount 5%: 5.00 -> Client Price Before Fee: 95.00
  -- Fee 5% (of 95): 4.75
  -- Total Client Pay: 99.75
  
  INSERT INTO public.orders (merchant_id, influencer_id, gig_id, gig_package_id, affiliate_link_id, order_type, total_amount, net_amount, status, stripe_payment_status)
  VALUES (v_client_id, v_freelancer_id, v_gig_id, v_pkg_id, v_link_id, 'freelance_gig', 99.75, 100.00, 'pending', 'captured')
  RETURNING id INTO v_order_id;

  -- 4. EXECUTE DISTRIBUTION
  v_res := public.distribute_commissions(v_order_id);
  RAISE NOTICE 'Distribution Result: %', v_res;

  -- 5. VERIFY LEDGER (V26 Strict Formula)
  -- Agent Gross: 10% of 100 (Base) = 10.00
  -- Platform Cut: 20% of 10.00 = 2.00
  -- Agent Net: 8.00
  -- Freelancer Net: 100 - 5 (Discount) - 10 (Agent Gross) = 85.00
  -- Platform Rev: 4.75 (Client Fee) + 2.00 (Cut) = 6.75
  
  SELECT * INTO v_conv FROM public.affiliate_conversions WHERE order_id = v_order_id;
  
  IF v_conv.agent_net != 8.00 THEN RAISE EXCEPTION 'Fail Agent Net: %', v_conv.agent_net; END IF;
  IF v_conv.freelancer_net != 85.00 THEN RAISE EXCEPTION 'Fail Freelancer Net: %', v_conv.freelancer_net; END IF;
  IF v_conv.platform_revenue != 6.75 THEN RAISE EXCEPTION 'Fail Platform Rev: %', v_conv.platform_revenue; END IF;

  RAISE NOTICE '✅ V26 TESTS PASSED';
  ROLLBACK;
END;
$$;
