-- ============================================================================
-- TESTS DE VERIFICATION - MARKETPLACE V25 FULL
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
  RAISE NOTICE '=== DEBUT TESTS V25 ===';

  -- 1. SETUP USERS
  INSERT INTO auth.users (id, email) VALUES (gen_random_uuid(), 'freelance_v25@test.com') RETURNING id INTO v_freelancer_id;
  INSERT INTO public.profiles (id, role, first_name) VALUES (v_freelancer_id, 'influenceur', 'Freelance V25');
  
  INSERT INTO auth.users (id, email) VALUES (gen_random_uuid(), 'agent_v25@test.com') RETURNING id INTO v_agent_id;
  INSERT INTO public.profiles (id, role, first_name) VALUES (v_agent_id, 'influenceur', 'Agent V25');
  
  INSERT INTO auth.users (id, email) VALUES (gen_random_uuid(), 'client_v25@test.com') RETURNING id INTO v_client_id;
  INSERT INTO public.profiles (id, role, first_name) VALUES (v_client_id, 'commercant', 'Client V25');

  -- 2. SETUP GIG & AFFILIATION
  INSERT INTO public.gigs (freelancer_id, title, slug, description, base_price, min_delivery_days, status, is_affiliable)
  VALUES (v_freelancer_id, 'Gig V25', 'gig-v25', 'Desc', 100.00, 3, 'active', true) RETURNING id INTO v_gig_id;

  INSERT INTO public.gig_packages (gig_id, name, price, delivery_days)
  VALUES (v_gig_id, 'Standard', 100.00, 3) RETURNING id INTO v_pkg_id;

  -- Config: Discount 5%, Agent 10%, Platform Fee 5%, Platform Cut 20%
  INSERT INTO public.collabmarket_listings (gig_id, freelancer_id, client_discount_rate, agent_commission_rate, platform_fee_rate, platform_cut_on_agent_rate)
  VALUES (v_gig_id, v_freelancer_id, 5.0, 10.0, 5.0, 20.0) RETURNING id INTO v_listing_id;

  INSERT INTO public.affiliate_links (code, url_slug, listing_id, gig_id, agent_id)
  VALUES ('V25TEST', 'v25-test', v_listing_id, v_gig_id, v_agent_id) RETURNING id INTO v_link_id;

  -- 3. CREATE ORDER (Simulate Stripe Capture)
  -- Base: 100
  -- Discount 5%: 5.00 -> Client Pays 95 + Fee
  -- Fee 5% (of 100): 5.00
  -- Total Client Pay: 100.00 (95 + 5)
  
  INSERT INTO public.orders (merchant_id, influencer_id, gig_id, gig_package_id, affiliate_link_id, order_type, total_amount, net_amount, status, stripe_payment_status)
  VALUES (v_client_id, v_freelancer_id, v_gig_id, v_pkg_id, v_link_id, 'freelance_gig', 100.00, 100.00, 'pending', 'captured')
  RETURNING id INTO v_order_id;

  -- 4. EXECUTE DISTRIBUTION
  v_res := public.distribute_commissions(v_order_id);
  RAISE NOTICE 'Distribution Result: %', v_res;

  -- 5. VERIFY LEDGER
  -- Agent Com: 10% of (100-5=95) = 9.50
  -- Platform Cut: 20% of 9.50 = 1.90
  -- Agent Net: 7.60
  -- Freelancer Net: 100 - 5 - 9.50 = 85.50
  -- Platform Rev: 5.00 + 1.90 = 6.90
  
  SELECT * INTO v_conv FROM public.affiliate_conversions WHERE order_id = v_order_id;
  
  IF v_conv.agent_net != 7.60 THEN RAISE EXCEPTION 'Fail Agent Net: %', v_conv.agent_net; END IF;
  IF v_conv.freelancer_net != 85.50 THEN RAISE EXCEPTION 'Fail Freelancer Net: %', v_conv.freelancer_net; END IF;
  IF v_conv.platform_revenue != 6.90 THEN RAISE EXCEPTION 'Fail Platform Rev: %', v_conv.platform_revenue; END IF;

  RAISE NOTICE '✅ V25 TESTS PASSED';
  ROLLBACK;
END;
$$;
