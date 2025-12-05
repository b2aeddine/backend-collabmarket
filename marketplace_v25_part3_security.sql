-- ============================================================================
-- MARKETPLACE V25 FULL - PART 3: SECURITY (RLS)
-- ============================================================================

BEGIN;

-- 1. ENABLE RLS ON ALL TABLES
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.freelancer_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gigs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_packages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_media ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_faqs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_requirements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.collabmarket_listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_clicks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_conversions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.freelancer_revenues ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_revenues ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_revenues ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.withdrawals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gig_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- 2. POLICIES

-- PROFILES
CREATE POLICY "Public profiles are viewable by everyone" ON public.profiles FOR SELECT USING (true);
CREATE POLICY "Users can insert their own profile" ON public.profiles FOR INSERT WITH CHECK (auth.uid() = id);
CREATE POLICY "Users can update own profile" ON public.profiles FOR UPDATE USING (auth.uid() = id);

-- ADMINS
CREATE POLICY "Admins viewable by admins" ON public.admins FOR SELECT USING (public.is_admin());

-- FREELANCER DETAILS
CREATE POLICY "Public freelancer details" ON public.freelancer_details FOR SELECT USING (true);
CREATE POLICY "Freelancers update own details" ON public.freelancer_details FOR ALL USING (auth.uid() = id);

-- GIGS
CREATE POLICY "Public active gigs" ON public.gigs FOR SELECT USING (status = 'active' OR auth.uid() = freelancer_id);
CREATE POLICY "Freelancers manage own gigs" ON public.gigs FOR ALL USING (auth.uid() = freelancer_id);

-- GIG PACKAGES/MEDIA/FAQS/REQS/TAGS
CREATE POLICY "Public gig components" ON public.gig_packages FOR SELECT USING (true);
CREATE POLICY "Freelancers manage packages" ON public.gig_packages FOR ALL USING (EXISTS (SELECT 1 FROM public.gigs WHERE id = gig_id AND freelancer_id = auth.uid()));

CREATE POLICY "Public gig media" ON public.gig_media FOR SELECT USING (true);
CREATE POLICY "Freelancers manage media" ON public.gig_media FOR ALL USING (EXISTS (SELECT 1 FROM public.gigs WHERE id = gig_id AND freelancer_id = auth.uid()));

CREATE POLICY "Public gig faqs" ON public.gig_faqs FOR SELECT USING (true);
CREATE POLICY "Freelancers manage faqs" ON public.gig_faqs FOR ALL USING (EXISTS (SELECT 1 FROM public.gigs WHERE id = gig_id AND freelancer_id = auth.uid()));

CREATE POLICY "Public gig reqs" ON public.gig_requirements FOR SELECT USING (true);
CREATE POLICY "Freelancers manage reqs" ON public.gig_requirements FOR ALL USING (EXISTS (SELECT 1 FROM public.gigs WHERE id = gig_id AND freelancer_id = auth.uid()));

CREATE POLICY "Public gig tags" ON public.gig_tags FOR SELECT USING (true);
CREATE POLICY "Freelancers manage tags" ON public.gig_tags FOR ALL USING (EXISTS (SELECT 1 FROM public.gigs WHERE id = gig_id AND freelancer_id = auth.uid()));

-- COLLABMARKET LISTINGS
CREATE POLICY "Public active listings" ON public.collabmarket_listings FOR SELECT USING (is_active = true OR auth.uid() = freelancer_id);
CREATE POLICY "Freelancers manage listings" ON public.collabmarket_listings FOR ALL USING (auth.uid() = freelancer_id);

-- AFFILIATE LINKS
CREATE POLICY "Public affiliate links" ON public.affiliate_links FOR SELECT USING (true);
CREATE POLICY "Agents manage own links" ON public.affiliate_links FOR ALL USING (auth.uid() = agent_id);

-- AFFILIATE CLICKS (Public Insert for tracking)
CREATE POLICY "Public insert clicks" ON public.affiliate_clicks FOR INSERT WITH CHECK (true);
CREATE POLICY "Agents view own clicks" ON public.affiliate_clicks FOR SELECT USING (EXISTS (SELECT 1 FROM public.affiliate_links WHERE id = affiliate_link_id AND agent_id = auth.uid()));

-- ORDERS
CREATE POLICY "Users view own orders" ON public.orders FOR SELECT USING (auth.uid() = merchant_id OR auth.uid() = influencer_id);
CREATE POLICY "Users create orders" ON public.orders FOR INSERT WITH CHECK (auth.uid() = merchant_id);
-- Update restricted to status transitions via RPC usually, but allow basic updates if needed (e.g. requirements)
CREATE POLICY "Users update own orders" ON public.orders FOR UPDATE USING (auth.uid() = merchant_id OR auth.uid() = influencer_id);

-- LEDGER (Strict)
CREATE POLICY "Admins view ledger" ON public.ledger FOR SELECT USING (public.is_admin());
-- No Insert/Update policy for users. Only RPC (Security Definer) can write.

-- REVENUES
CREATE POLICY "Freelancers view own revenues" ON public.freelancer_revenues FOR SELECT USING (auth.uid() = freelancer_id);
CREATE POLICY "Agents view own revenues" ON public.agent_revenues FOR SELECT USING (auth.uid() = agent_id);
CREATE POLICY "Admins view platform revenues" ON public.platform_revenues FOR SELECT USING (public.is_admin());

-- WITHDRAWALS
CREATE POLICY "Users view own withdrawals" ON public.withdrawals FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users create withdrawals" ON public.withdrawals FOR INSERT WITH CHECK (auth.uid() = user_id);

-- REVIEWS
CREATE POLICY "Public reviews" ON public.gig_reviews FOR SELECT USING (is_visible = true);
CREATE POLICY "Users create reviews" ON public.gig_reviews FOR INSERT WITH CHECK (auth.uid() = reviewer_id);

-- 3. GRANTS
GRANT USAGE ON SCHEMA public TO postgres, anon, authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA public TO postgres, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO postgres, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;

-- 4. INITIAL DATA (Categories)
INSERT INTO public.gig_categories (name, slug, description) VALUES
('Graphisme & Design', 'graphisme-design', 'Logos, Web Design, Illustration'),
('Marketing Digital', 'marketing-digital', 'SEO, Social Media, Ads'),
('Rédaction & Traduction', 'redaction-traduction', 'Articles, Traduction, Correction'),
('Vidéo & Animation', 'video-animation', 'Montage, Motion Design'),
('Programmation & Tech', 'programmation-tech', 'Web Dev, Mobile Apps, Scripts')
ON CONFLICT (slug) DO NOTHING;

COMMIT;
