-- ============================================================================
-- MIGRATION V40.12: CRON SCHEDULING & STATE MACHINE HARDENING
-- ============================================================================
-- This migration:
-- 1. Enables pg_cron extension and schedules all periodic jobs
-- 2. Adds trigger to enforce order state machine transitions
-- 3. Adds index optimizations for job_queue
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. PG_CRON EXTENSION & SCHEDULING
-- Note: pg_cron requires superuser. If not available, use external schedulers.
-- ============================================================================

-- Enable pg_cron if available (requires Supabase Pro or superuser access)
-- If this fails, use external cron services as documented in CRON_SETUP.md
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;
  END IF;
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'pg_cron extension requires superuser. Use external cron services instead.';
  WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron extension not available: %', SQLERRM;
END;
$$;

-- Only schedule jobs if pg_cron is available
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    -- Job Worker: Process background jobs every minute
    PERFORM cron.schedule(
      'job-worker',
      '* * * * *',
      $job$
      SELECT net.http_post(
        url := current_setting('app.settings.supabase_url', true) || '/functions/v1/job-worker',
        headers := jsonb_build_object(
          'Authorization', 'Bearer ' || current_setting('app.settings.cron_secret', true),
          'Content-Type', 'application/json'
        ),
        body := '{"max_jobs": 20}'::jsonb
      );
      $job$
    );

    -- Process Withdrawals: Every 5 minutes
    PERFORM cron.schedule(
      'process-withdrawals',
      '*/5 * * * *',
      $job$
      SELECT net.http_post(
        url := current_setting('app.settings.supabase_url', true) || '/functions/v1/cron-process-withdrawals',
        headers := jsonb_build_object(
          'Authorization', 'Bearer ' || current_setting('app.settings.cron_secret', true),
          'Content-Type', 'application/json'
        ),
        body := '{}'::jsonb
      );
      $job$
    );

    -- Monitoring: Every 15 minutes
    PERFORM cron.schedule(
      'monitoring',
      '*/15 * * * *',
      $job$
      SELECT net.http_post(
        url := current_setting('app.settings.supabase_url', true) || '/functions/v1/cron-monitoring',
        headers := jsonb_build_object(
          'Authorization', 'Bearer ' || current_setting('app.settings.cron_secret', true),
          'Content-Type', 'application/json'
        ),
        body := '{}'::jsonb
      );
      $job$
    );

    -- Cleanup Orphan Orders: Daily at 3:00 AM UTC
    PERFORM cron.schedule(
      'cleanup-orphan-orders',
      '0 3 * * *',
      $job$
      SELECT net.http_post(
        url := current_setting('app.settings.supabase_url', true) || '/functions/v1/cleanup-orphan-orders',
        headers := jsonb_build_object(
          'Authorization', 'Bearer ' || current_setting('app.settings.cron_secret', true),
          'Content-Type', 'application/json'
        ),
        body := '{}'::jsonb
      );
      $job$
    );

    -- Daily Analytics Aggregation: 1:00 AM UTC (direct SQL call)
    PERFORM cron.schedule(
      'aggregate-analytics',
      '0 1 * * *',
      $job$ SELECT public.aggregate_daily_stats(CURRENT_DATE - INTERVAL '1 day'); $job$
    );

    -- Auto-complete Orders: Every hour (backup, also in cron-monitoring)
    PERFORM cron.schedule(
      'auto-complete-orders',
      '0 * * * *',
      $job$ SELECT public.auto_complete_orders(); $job$
    );

    -- Auto-cancel Expired Orders: Every 30 minutes
    PERFORM cron.schedule(
      'auto-cancel-expired',
      '*/30 * * * *',
      $job$ SELECT public.auto_cancel_expired_orders(); $job$
    );

    -- Cleanup Old Data: Weekly on Sunday at 4:00 AM UTC
    PERFORM cron.schedule(
      'cleanup-old-data',
      '0 4 * * 0',
      $job$ SELECT public.cleanup_old_data(); $job$
    );

    -- Release Pending Revenues: Hourly
    PERFORM cron.schedule(
      'release-revenues',
      '30 * * * *',
      $job$ SELECT public.release_pending_revenues(); $job$
    );

    RAISE NOTICE 'pg_cron jobs scheduled successfully';
  ELSE
    RAISE NOTICE 'pg_cron not available. Please use external cron services (see CRON_SETUP.md)';
  END IF;
END;
$$;

-- ============================================================================
-- 2. ORDER STATE MACHINE ENFORCEMENT
-- Validates that order status transitions follow the allowed state machine
-- ============================================================================

-- Define the allowed state transitions
CREATE OR REPLACE FUNCTION public.validate_order_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_allowed_transitions JSONB;
BEGIN
  -- Only validate if status is actually changing
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- Define the state machine: from_status -> [allowed_to_statuses]
  v_allowed_transitions := '{
    "pending": ["payment_authorized", "cancelled"],
    "payment_authorized": ["accepted", "cancelled"],
    "accepted": ["in_progress", "cancelled"],
    "in_progress": ["delivered", "cancelled"],
    "delivered": ["revision_requested", "completed", "disputed"],
    "revision_requested": ["delivered", "disputed", "cancelled"],
    "completed": ["disputed", "refunded"],
    "disputed": ["completed", "refunded", "cancelled"],
    "cancelled": [],
    "refunded": []
  }'::JSONB;

  -- Check if the transition is allowed
  IF NOT (v_allowed_transitions->OLD.status) ? NEW.status THEN
    -- Log the attempted invalid transition
    INSERT INTO public.system_logs (event_type, message, details)
    VALUES (
      'security',
      'Invalid order status transition attempted',
      jsonb_build_object(
        'order_id', NEW.id,
        'from_status', OLD.status,
        'to_status', NEW.status,
        'attempted_at', NOW()
      )
    );

    RAISE EXCEPTION 'Invalid order status transition: % -> % is not allowed',
      OLD.status, NEW.status
      USING HINT = 'Valid transitions from ' || OLD.status || ': ' ||
        COALESCE((v_allowed_transitions->OLD.status)::TEXT, '[]');
  END IF;

  -- Record the transition in history
  INSERT INTO public.order_status_history (order_id, old_status, new_status, changed_by, reason)
  VALUES (
    NEW.id,
    OLD.status,
    NEW.status,
    COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::UUID),
    'State transition validated by trigger'
  );

  RETURN NEW;
END;
$$;

-- Create the trigger (drop if exists to allow re-running)
DROP TRIGGER IF EXISTS trg_validate_order_transition ON public.orders;

CREATE TRIGGER trg_validate_order_transition
  BEFORE UPDATE OF status ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.validate_order_transition();

-- ============================================================================
-- 3. ADDITIONAL INDEX OPTIMIZATIONS
-- ============================================================================

-- Index for finding orders by payment intent (webhook lookups)
CREATE INDEX IF NOT EXISTS idx_orders_stripe_pi
  ON public.orders(stripe_payment_intent_id)
  WHERE stripe_payment_intent_id IS NOT NULL;

-- Index for finding pending withdrawals efficiently
CREATE INDEX IF NOT EXISTS idx_withdrawals_pending
  ON public.withdrawals(status, created_at)
  WHERE status = 'pending';

-- Index for finding processing withdrawals (timeout detection)
CREATE INDEX IF NOT EXISTS idx_withdrawals_processing
  ON public.withdrawals(status, updated_at)
  WHERE status = 'processing';

-- Index for job queue priority processing
CREATE INDEX IF NOT EXISTS idx_job_queue_priority
  ON public.job_queue(priority DESC, scheduled_at ASC)
  WHERE status = 'pending';

-- ============================================================================
-- 4. GRANT PERMISSIONS
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.validate_order_transition() TO service_role;

COMMIT;

-- ============================================================================
-- POST-MIGRATION: Configure app settings for cron jobs
-- Run these commands separately as superuser:
-- ============================================================================
-- ALTER DATABASE postgres SET app.settings.supabase_url = 'https://YOUR_PROJECT.supabase.co';
-- ALTER DATABASE postgres SET app.settings.cron_secret = 'your-cron-secret-here';
