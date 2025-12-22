-- ============================================================================
-- Migration v40.13: Performance Indexes & Webhook Idempotency Fix
-- ============================================================================
-- CHANGES:
-- 1. Add missing FK indexes for child tables (query performance)
-- 2. Add date indexes for time-range queries
-- 3. Add composite indexes for common query patterns
-- 4. Add GIN index for search_tags full-text search
-- 5. Fix check_webhook_replay race condition with ON CONFLICT pattern
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. MISSING FK INDEXES (Critical for JOIN performance)
-- ============================================================================
-- Without these, queries joining on FK columns cause full table scans

CREATE INDEX IF NOT EXISTS idx_service_faqs_service
  ON public.service_faqs(service_id);

CREATE INDEX IF NOT EXISTS idx_service_requirements_service
  ON public.service_requirements(service_id);

CREATE INDEX IF NOT EXISTS idx_service_extras_service
  ON public.service_extras(service_id);

-- ============================================================================
-- 2. DATE INDEXES FOR TIME-RANGE QUERIES
-- ============================================================================
-- These columns are frequently filtered by date ranges in analytics/reports

CREATE INDEX IF NOT EXISTS idx_affiliate_conversions_created
  ON public.affiliate_conversions(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ledger_entries_created
  ON public.ledger_entries(created_at DESC);

-- ============================================================================
-- 3. COMPOSITE INDEXES FOR COMMON QUERY PATTERNS
-- ============================================================================

-- Portfolio items: commonly filtered by is_active + sorted by is_featured
CREATE INDEX IF NOT EXISTS idx_portfolio_active_featured
  ON public.portfolio_items(user_id, is_active, is_featured DESC)
  WHERE is_active = TRUE;

-- Contact messages: admin dashboard filters by status, orders by created_at
CREATE INDEX IF NOT EXISTS idx_contact_messages_status_created
  ON public.contact_messages(status, created_at DESC);

-- ============================================================================
-- 4. GIN INDEX FOR SEARCH_TAGS (Text Array Search)
-- ============================================================================
-- Enables fast array containment queries: WHERE 'tag' = ANY(search_tags)

CREATE INDEX IF NOT EXISTS idx_services_search_tags
  ON public.services USING GIN (search_tags);

-- ============================================================================
-- 5. FIX check_webhook_replay RACE CONDITION
-- ============================================================================
-- PROBLEM: Original implementation has TOCTOU race condition:
--   IF EXISTS (SELECT 1 ...) THEN RETURN FALSE; END IF;
--   INSERT INTO ...
-- Two concurrent calls can both pass the EXISTS check before either INSERTs.
--
-- SOLUTION: Use INSERT ... ON CONFLICT DO NOTHING RETURNING to atomically
-- check and insert in a single statement. Returns event_id if inserted (new),
-- or NULL if conflict (duplicate).

CREATE OR REPLACE FUNCTION public.check_webhook_replay(
  p_event_id TEXT,
  p_event_type TEXT,
  p_payload_hash TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_inserted_id TEXT;
BEGIN
  -- Atomic insert-if-not-exists using ON CONFLICT
  -- Returns the event_id if inserted (first time), NULL if already exists
  INSERT INTO public.processed_webhooks (event_id, event_type, payload_hash)
  VALUES (p_event_id, p_event_type, p_payload_hash)
  ON CONFLICT (event_id) DO NOTHING
  RETURNING event_id INTO v_inserted_id;

  -- If we got a value back, this is the first processing (not a replay)
  RETURN v_inserted_id IS NOT NULL;
END;
$$;

-- Ensure proper grants maintained
GRANT EXECUTE ON FUNCTION public.check_webhook_replay(TEXT, TEXT, TEXT) TO service_role;

COMMIT;
