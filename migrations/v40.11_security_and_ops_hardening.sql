-- ============================================================================
-- COLLABMARKET V40.11 - SECURITY & OPS HARDENING
-- ============================================================================
-- Cette migration ajoute:
-- 1. Audit de sécurité RLS et SECURITY DEFINER
-- 2. Invariants comptables (sum debits = sum credits)
-- 3. Index P1 pour performance
-- 4. Infrastructure monitoring/alerting
-- 5. Préparation partitionnement affiliate_clicks
-- 6. Procédures ops (replay, reprocess)
-- 7. Contraintes supplémentaires
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. AUDIT SÉCURITÉ RLS - Fonction de vérification
-- ============================================================================

-- Fonction pour auditer les tables sans RLS
CREATE OR REPLACE FUNCTION public.audit_rls_coverage()
RETURNS TABLE (
  table_name TEXT,
  has_rls BOOLEAN,
  policy_count INTEGER,
  issue TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN QUERY
  SELECT
    t.tablename::TEXT,
    t.rowsecurity AS has_rls,
    COALESCE(p.policy_count, 0)::INTEGER,
    CASE
      WHEN NOT t.rowsecurity THEN 'CRITICAL: RLS not enabled'
      WHEN COALESCE(p.policy_count, 0) = 0 THEN 'WARNING: RLS enabled but no policies'
      ELSE 'OK'
    END AS issue
  FROM pg_tables t
  LEFT JOIN (
    SELECT schemaname, tablename, COUNT(*) AS policy_count
    FROM pg_policies
    GROUP BY schemaname, tablename
  ) p ON t.schemaname = p.schemaname AND t.tablename = p.tablename
  WHERE t.schemaname = 'public'
    AND t.tablename NOT LIKE 'pg_%'
    AND t.tablename NOT LIKE '_prisma%'
  ORDER BY
    CASE
      WHEN NOT t.rowsecurity THEN 1
      WHEN COALESCE(p.policy_count, 0) = 0 THEN 2
      ELSE 3
    END,
    t.tablename;
END;
$$;

-- Fonction pour auditer les fonctions SECURITY DEFINER
CREATE OR REPLACE FUNCTION public.audit_security_definer_functions()
RETURNS TABLE (
  function_name TEXT,
  has_search_path BOOLEAN,
  search_path_value TEXT,
  is_safe BOOLEAN,
  issue TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN QUERY
  SELECT
    p.proname::TEXT AS function_name,
    (p.proconfig IS NOT NULL AND array_to_string(p.proconfig, ',') LIKE '%search_path%') AS has_search_path,
    COALESCE(
      (SELECT regexp_replace(cfg, 'search_path=', '')
       FROM unnest(p.proconfig) cfg
       WHERE cfg LIKE 'search_path=%' LIMIT 1),
      'NOT SET'
    )::TEXT AS search_path_value,
    (p.proconfig IS NOT NULL
     AND array_to_string(p.proconfig, ',') LIKE '%search_path%'
     AND array_to_string(p.proconfig, ',') LIKE '%pg_temp%') AS is_safe,
    CASE
      WHEN p.proconfig IS NULL OR NOT array_to_string(p.proconfig, ',') LIKE '%search_path%'
        THEN 'CRITICAL: No search_path set - vulnerable to temp schema injection'
      WHEN NOT array_to_string(p.proconfig, ',') LIKE '%pg_temp%'
        THEN 'WARNING: search_path missing pg_temp'
      ELSE 'OK'
    END AS issue
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE n.nspname = 'public'
    AND p.prosecdef = TRUE  -- SECURITY DEFINER
  ORDER BY
    CASE
      WHEN p.proconfig IS NULL OR NOT array_to_string(p.proconfig, ',') LIKE '%search_path%' THEN 1
      WHEN NOT array_to_string(p.proconfig, ',') LIKE '%pg_temp%' THEN 2
      ELSE 3
    END,
    p.proname;
END;
$$;

-- Fonction pour vérifier les policies trop permissives
CREATE OR REPLACE FUNCTION public.audit_permissive_policies()
RETURNS TABLE (
  table_name TEXT,
  policy_name TEXT,
  policy_type TEXT,
  roles TEXT[],
  using_expr TEXT,
  check_expr TEXT,
  issue TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN QUERY
  SELECT
    pol.tablename::TEXT,
    pol.policyname::TEXT,
    pol.cmd::TEXT AS policy_type,
    pol.roles::TEXT[],
    pol.qual::TEXT AS using_expr,
    pol.with_check::TEXT AS check_expr,
    CASE
      WHEN pol.qual = 'true' OR pol.qual IS NULL THEN 'CRITICAL: USING clause allows all rows'
      WHEN pol.with_check = 'true' THEN 'WARNING: WITH CHECK allows all mutations'
      WHEN 'public' = ANY(pol.roles) THEN 'WARNING: Policy applies to PUBLIC role'
      ELSE 'OK'
    END AS issue
  FROM pg_policies pol
  WHERE pol.schemaname = 'public'
    AND (pol.qual = 'true' OR pol.qual IS NULL OR pol.with_check = 'true' OR 'public' = ANY(pol.roles))
  ORDER BY
    CASE
      WHEN pol.qual = 'true' OR pol.qual IS NULL THEN 1
      WHEN pol.with_check = 'true' THEN 2
      ELSE 3
    END,
    pol.tablename;
END;
$$;

GRANT EXECUTE ON FUNCTION public.audit_rls_coverage() TO service_role;
GRANT EXECUTE ON FUNCTION public.audit_security_definer_functions() TO service_role;
GRANT EXECUTE ON FUNCTION public.audit_permissive_policies() TO service_role;

-- ============================================================================
-- 2. INVARIANTS COMPTABLES
-- ============================================================================

-- Table pour tracker les invariants comptables par transaction group
CREATE TABLE IF NOT EXISTS public.ledger_balance_checks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_group_id UUID NOT NULL,
  total_debits DECIMAL(12,2) NOT NULL,
  total_credits DECIMAL(12,2) NOT NULL,
  is_balanced BOOLEAN NOT NULL,
  variance DECIMAL(12,2),
  checked_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_ledger_balance_checks_group ON public.ledger_balance_checks(transaction_group_id);
CREATE INDEX idx_ledger_balance_checks_unbalanced ON public.ledger_balance_checks(is_balanced) WHERE is_balanced = FALSE;

ALTER TABLE public.ledger_balance_checks ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ledger_balance_checks_admin" ON public.ledger_balance_checks FOR ALL USING (public.is_admin() OR public.is_service_role());

-- Fonction pour vérifier l'équilibre d'un transaction group
CREATE OR REPLACE FUNCTION public.verify_ledger_balance(p_transaction_group_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_debits DECIMAL(12,2);
  v_credits DECIMAL(12,2);
  v_is_balanced BOOLEAN;
BEGIN
  SELECT
    COALESCE(SUM(CASE WHEN entry_type = 'debit' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN entry_type = 'credit' THEN amount ELSE 0 END), 0)
  INTO v_debits, v_credits
  FROM public.ledger_entries
  WHERE transaction_group_id = p_transaction_group_id;

  -- Tolérance de 0.01€ pour arrondis
  v_is_balanced := ABS(v_debits - v_credits) < 0.01;

  -- Enregistrer le check
  INSERT INTO public.ledger_balance_checks (transaction_group_id, total_debits, total_credits, is_balanced, variance)
  VALUES (p_transaction_group_id, v_debits, v_credits, v_is_balanced, v_debits - v_credits);

  RETURN v_is_balanced;
END;
$$;

-- Fonction pour auditer tous les transaction groups non équilibrés
CREATE OR REPLACE FUNCTION public.audit_unbalanced_ledger_entries()
RETURNS TABLE (
  transaction_group_id UUID,
  total_debits DECIMAL,
  total_credits DECIMAL,
  variance DECIMAL,
  entry_count INTEGER,
  order_ids UUID[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN QUERY
  SELECT
    le.transaction_group_id,
    SUM(CASE WHEN le.entry_type = 'debit' THEN le.amount ELSE 0 END) AS total_debits,
    SUM(CASE WHEN le.entry_type = 'credit' THEN le.amount ELSE 0 END) AS total_credits,
    SUM(CASE WHEN le.entry_type = 'debit' THEN le.amount ELSE 0 END) -
    SUM(CASE WHEN le.entry_type = 'credit' THEN le.amount ELSE 0 END) AS variance,
    COUNT(*)::INTEGER AS entry_count,
    ARRAY_AGG(DISTINCT le.order_id) FILTER (WHERE le.order_id IS NOT NULL) AS order_ids
  FROM public.ledger_entries le
  GROUP BY le.transaction_group_id
  HAVING ABS(SUM(CASE WHEN le.entry_type = 'debit' THEN le.amount ELSE 0 END) -
             SUM(CASE WHEN le.entry_type = 'credit' THEN le.amount ELSE 0 END)) >= 0.01
  ORDER BY variance DESC;
END;
$$;

-- Fonction d'arrondi standardisée (HALF_UP, 2 décimales)
CREATE OR REPLACE FUNCTION public.round_money(p_amount DECIMAL)
RETURNS DECIMAL
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT ROUND(p_amount, 2);
$$;

-- Fonction de calcul commission avec arrondis explicites
CREATE OR REPLACE FUNCTION public.calculate_commission_amounts(
  p_total_amount DECIMAL,
  p_platform_fee_rate DECIMAL,
  p_agent_commission_rate DECIMAL,
  p_platform_cut_on_agent_rate DECIMAL
)
RETURNS TABLE (
  platform_fee DECIMAL,
  agent_gross DECIMAL,
  platform_from_agent DECIMAL,
  agent_net DECIMAL,
  seller_amount DECIMAL,
  total_platform DECIMAL,
  check_sum DECIMAL
)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_platform_fee DECIMAL;
  v_agent_gross DECIMAL;
  v_platform_from_agent DECIMAL;
  v_agent_net DECIMAL;
  v_seller_amount DECIMAL;
  v_total_platform DECIMAL;
BEGIN
  -- Tous les calculs avec arrondi explicite
  v_platform_fee := public.round_money(p_total_amount * p_platform_fee_rate / 100);
  v_agent_gross := public.round_money(p_total_amount * p_agent_commission_rate / 100);
  v_platform_from_agent := public.round_money(v_agent_gross * p_platform_cut_on_agent_rate / 100);
  v_agent_net := public.round_money(v_agent_gross - v_platform_from_agent);
  v_seller_amount := public.round_money(p_total_amount - v_agent_gross - v_platform_fee);
  v_total_platform := public.round_money(v_platform_fee + v_platform_from_agent);

  -- Le seller absorbe les micro-différences d'arrondi
  IF v_seller_amount + v_agent_net + v_total_platform != p_total_amount THEN
    v_seller_amount := p_total_amount - v_agent_net - v_total_platform;
  END IF;

  RETURN QUERY SELECT
    v_platform_fee,
    v_agent_gross,
    v_platform_from_agent,
    v_agent_net,
    v_seller_amount,
    v_total_platform,
    v_seller_amount + v_agent_net + v_total_platform AS check_sum;
END;
$$;

GRANT EXECUTE ON FUNCTION public.verify_ledger_balance(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.audit_unbalanced_ledger_entries() TO service_role;
GRANT EXECUTE ON FUNCTION public.round_money(DECIMAL) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.calculate_commission_amounts(DECIMAL, DECIMAL, DECIMAL, DECIMAL) TO service_role;

-- ============================================================================
-- 3. INDEX P1 POUR PERFORMANCE
-- ============================================================================

-- Index partiel sur orders par statuts "actifs" (dashboard)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_active_status
ON public.orders(status, seller_id, created_at DESC)
WHERE status IN ('pending', 'payment_authorized', 'accepted', 'in_progress', 'delivered', 'revision_requested');

-- Index partiel sur orders "en attente paiement"
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_pending_payment
ON public.orders(created_at)
WHERE status = 'pending' AND stripe_payment_intent_id IS NOT NULL;

-- Index sur job_queue pour monitoring
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_job_queue_failed
ON public.job_queue(job_type, completed_at DESC)
WHERE status = 'failed';

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_job_queue_stuck
ON public.job_queue(started_at)
WHERE status = 'processing' AND started_at < NOW() - INTERVAL '30 minutes';

-- Index GIN sur orders.requirements_responses (recherche JSONB)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_requirements_jsonb
ON public.orders USING GIN (requirements_responses jsonb_path_ops);

-- Index sur commission_runs non complétées
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_commission_runs_pending
ON public.commission_runs(started_at)
WHERE completed = FALSE;

-- Index sur withdrawals par statut
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_withdrawals_processing
ON public.withdrawals(created_at)
WHERE status IN ('pending', 'processing');

-- ============================================================================
-- 4. INFRASTRUCTURE MONITORING & ALERTING
-- ============================================================================

-- Table pour les alertes système
CREATE TABLE IF NOT EXISTS public.system_alerts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  alert_type TEXT NOT NULL CHECK (alert_type IN (
    'webhook_failure', 'job_failed', 'job_stuck', 'balance_mismatch',
    'transfer_failed', 'commission_drift', 'rls_violation', 'rate_limit_exceeded',
    'withdrawal_failed', 'stripe_error', 'security_audit'
  )),
  severity TEXT NOT NULL DEFAULT 'warning' CHECK (severity IN ('info', 'warning', 'error', 'critical')),
  title TEXT NOT NULL,
  message TEXT,
  context JSONB DEFAULT '{}'::jsonb,
  acknowledged BOOLEAN DEFAULT FALSE,
  acknowledged_by UUID REFERENCES public.profiles(id),
  acknowledged_at TIMESTAMPTZ,
  resolved BOOLEAN DEFAULT FALSE,
  resolved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_system_alerts_unresolved ON public.system_alerts(severity, created_at DESC) WHERE resolved = FALSE;
CREATE INDEX idx_system_alerts_type ON public.system_alerts(alert_type, created_at DESC);

ALTER TABLE public.system_alerts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "alerts_admin_manage" ON public.system_alerts FOR ALL USING (public.is_admin() OR public.is_service_role());

-- Fonction pour créer une alerte
CREATE OR REPLACE FUNCTION public.create_alert(
  p_alert_type TEXT,
  p_severity TEXT,
  p_title TEXT,
  p_message TEXT DEFAULT NULL,
  p_context JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_alert_id UUID;
BEGIN
  INSERT INTO public.system_alerts (alert_type, severity, title, message, context)
  VALUES (p_alert_type, p_severity, p_title, p_message, p_context)
  RETURNING id INTO v_alert_id;

  -- Log pour external monitoring (Datadog, etc.)
  INSERT INTO public.system_logs (level, event_type, message, details)
  VALUES (
    CASE p_severity WHEN 'critical' THEN 'fatal' WHEN 'error' THEN 'error' ELSE 'warn' END,
    'alert_created',
    p_title,
    jsonb_build_object('alert_id', v_alert_id, 'type', p_alert_type, 'context', p_context)
  );

  RETURN v_alert_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_alert(TEXT, TEXT, TEXT, TEXT, JSONB) TO service_role;

-- Fonction de monitoring: jobs bloqués
CREATE OR REPLACE FUNCTION public.monitor_stuck_jobs()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_stuck_count INTEGER;
  v_job RECORD;
BEGIN
  SELECT COUNT(*) INTO v_stuck_count
  FROM public.job_queue
  WHERE status = 'processing'
    AND started_at < NOW() - INTERVAL '30 minutes';

  IF v_stuck_count > 0 THEN
    FOR v_job IN
      SELECT id, job_type, payload, started_at
      FROM public.job_queue
      WHERE status = 'processing'
        AND started_at < NOW() - INTERVAL '30 minutes'
    LOOP
      PERFORM public.create_alert(
        'job_stuck',
        'error',
        'Job stuck in processing: ' || v_job.job_type,
        'Job started at ' || v_job.started_at::TEXT || ' has been processing for over 30 minutes',
        jsonb_build_object('job_id', v_job.id, 'job_type', v_job.job_type, 'payload', v_job.payload)
      );
    END LOOP;
  END IF;

  RETURN v_stuck_count;
END;
$$;

-- Fonction de monitoring: jobs échoués récents
CREATE OR REPLACE FUNCTION public.monitor_failed_jobs()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_failed_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_failed_count
  FROM public.job_queue
  WHERE status = 'failed'
    AND completed_at > NOW() - INTERVAL '1 hour';

  IF v_failed_count >= 5 THEN
    PERFORM public.create_alert(
      'job_failed',
      'warning',
      v_failed_count || ' jobs failed in the last hour',
      'Multiple job failures detected, investigate job_queue for details',
      (SELECT jsonb_agg(jsonb_build_object('id', id, 'type', job_type, 'error', last_error))
       FROM public.job_queue
       WHERE status = 'failed' AND completed_at > NOW() - INTERVAL '1 hour')
    );
  END IF;

  RETURN v_failed_count;
END;
$$;

-- Fonction de monitoring: drift financier
CREATE OR REPLACE FUNCTION public.monitor_financial_drift()
RETURNS TABLE (
  issue_type TEXT,
  details JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_unbalanced_count INTEGER;
  v_missing_revenues INTEGER;
  v_orphan_allocations INTEGER;
BEGIN
  -- Check unbalanced ledger entries
  SELECT COUNT(*) INTO v_unbalanced_count
  FROM (SELECT * FROM public.audit_unbalanced_ledger_entries()) sub;

  IF v_unbalanced_count > 0 THEN
    PERFORM public.create_alert(
      'balance_mismatch',
      'critical',
      v_unbalanced_count || ' transaction groups with unbalanced ledger entries',
      'Critical: Double-entry accounting invariant violated',
      (SELECT jsonb_agg(row_to_json(sub)) FROM public.audit_unbalanced_ledger_entries() sub)
    );
    RETURN QUERY SELECT 'unbalanced_ledger'::TEXT,
      (SELECT jsonb_agg(row_to_json(sub)) FROM public.audit_unbalanced_ledger_entries() sub);
  END IF;

  -- Check orders completed without revenues
  SELECT COUNT(*) INTO v_missing_revenues
  FROM public.orders o
  WHERE o.status = 'completed'
    AND o.completed_at < NOW() - INTERVAL '1 hour'
    AND NOT EXISTS (SELECT 1 FROM public.seller_revenues sr WHERE sr.order_id = o.id);

  IF v_missing_revenues > 0 THEN
    PERFORM public.create_alert(
      'commission_drift',
      'error',
      v_missing_revenues || ' completed orders without seller_revenues',
      'Commission distribution may have failed',
      (SELECT jsonb_agg(o.id)
       FROM public.orders o
       WHERE o.status = 'completed'
         AND o.completed_at < NOW() - INTERVAL '1 hour'
         AND NOT EXISTS (SELECT 1 FROM public.seller_revenues sr WHERE sr.order_id = o.id))
    );
    RETURN QUERY SELECT 'missing_revenues'::TEXT,
      jsonb_build_object('count', v_missing_revenues);
  END IF;

  -- Check orphan withdrawal allocations
  SELECT COUNT(*) INTO v_orphan_allocations
  FROM public.withdrawal_allocations wa
  LEFT JOIN public.withdrawals w ON w.id = wa.withdrawal_id
  WHERE w.id IS NULL;

  IF v_orphan_allocations > 0 THEN
    RETURN QUERY SELECT 'orphan_allocations'::TEXT,
      jsonb_build_object('count', v_orphan_allocations);
  END IF;

  RETURN;
END;
$$;

GRANT EXECUTE ON FUNCTION public.monitor_stuck_jobs() TO service_role;
GRANT EXECUTE ON FUNCTION public.monitor_failed_jobs() TO service_role;
GRANT EXECUTE ON FUNCTION public.monitor_financial_drift() TO service_role;

-- Fonction cron de monitoring global (à appeler toutes les 5 min)
CREATE OR REPLACE FUNCTION public.run_monitoring_checks()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_result JSONB := '{}'::jsonb;
BEGIN
  v_result := v_result || jsonb_build_object('stuck_jobs', public.monitor_stuck_jobs());
  v_result := v_result || jsonb_build_object('failed_jobs', public.monitor_failed_jobs());
  v_result := v_result || jsonb_build_object('financial_drift',
    (SELECT COALESCE(jsonb_agg(row_to_json(sub)), '[]'::jsonb) FROM public.monitor_financial_drift() sub));
  v_result := v_result || jsonb_build_object('checked_at', NOW());

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.run_monitoring_checks() TO service_role;

-- ============================================================================
-- 5. PROCÉDURES OPS (REPLAY, REPROCESS)
-- ============================================================================

-- Fonction pour rejouer un webhook manuellement
CREATE OR REPLACE FUNCTION public.replay_webhook(
  p_event_id TEXT,
  p_force BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_webhook public.processed_webhooks%ROWTYPE;
BEGIN
  -- Vérifier que l'utilisateur est admin
  IF NOT public.is_admin() AND NOT public.is_service_role() THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED');
  END IF;

  -- Récupérer le webhook
  SELECT * INTO v_webhook FROM public.processed_webhooks WHERE event_id = p_event_id;

  IF v_webhook.event_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'WEBHOOK_NOT_FOUND');
  END IF;

  IF p_force THEN
    -- Supprimer de processed_webhooks pour permettre le replay
    DELETE FROM public.processed_webhooks WHERE event_id = p_event_id;

    -- Logger
    INSERT INTO public.audit_logs (event_name, table_name, record_id, new_values)
    VALUES ('webhook_replay_forced', 'processed_webhooks', NULL,
      jsonb_build_object('event_id', p_event_id, 'event_type', v_webhook.event_type));

    RETURN jsonb_build_object(
      'success', true,
      'message', 'Webhook removed from processed_webhooks, can be replayed',
      'event_type', v_webhook.event_type
    );
  ELSE
    RETURN jsonb_build_object(
      'success', false,
      'error', 'WEBHOOK_ALREADY_PROCESSED',
      'event_type', v_webhook.event_type,
      'processed_at', v_webhook.processed_at,
      'hint', 'Use p_force=TRUE to force replay'
    );
  END IF;
END;
$$;

-- Fonction pour relancer une distribution de commissions
CREATE OR REPLACE FUNCTION public.reprocess_commission_distribution(
  p_order_id UUID,
  p_force BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_run public.commission_runs%ROWTYPE;
BEGIN
  -- Vérifier admin
  IF NOT public.is_admin() AND NOT public.is_service_role() THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED');
  END IF;

  -- Récupérer la commande
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF v_order.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
  END IF;

  -- Vérifier l'état
  IF v_order.status != 'completed' THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_COMPLETED', 'status', v_order.status);
  END IF;

  -- Vérifier commission_runs
  SELECT * INTO v_run FROM public.commission_runs WHERE order_id = p_order_id;

  IF v_run.completed AND NOT p_force THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'COMMISSION_ALREADY_DISTRIBUTED',
      'completed_at', v_run.completed_at,
      'result', v_run.result,
      'hint', 'Use p_force=TRUE to force reprocess (will create duplicate entries!)'
    );
  END IF;

  IF p_force AND v_run.completed THEN
    -- Supprimer le run existant pour permettre un reprocess
    -- ATTENTION: cela peut créer des doublons si les revenus existent déjà
    DELETE FROM public.commission_runs WHERE order_id = p_order_id;

    -- Logger
    INSERT INTO public.audit_logs (event_name, table_name, record_id, old_values, new_values)
    VALUES ('commission_reprocess_forced', 'commission_runs', p_order_id,
      row_to_json(v_run)::jsonb,
      jsonb_build_object('forced_by', auth.uid(), 'forced_at', NOW()));
  END IF;

  -- Enqueue le job de distribution
  PERFORM public.enqueue_job('distribute_commissions', jsonb_build_object('order_id', p_order_id), 10);

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Commission distribution job enqueued',
    'order_id', p_order_id,
    'was_forced', p_force AND v_run.completed
  );
END;
$$;

-- Fonction pour corriger un retrait échoué
CREATE OR REPLACE FUNCTION public.fix_failed_withdrawal(
  p_withdrawal_id UUID,
  p_action TEXT  -- 'retry' ou 'cancel'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_withdrawal public.withdrawals%ROWTYPE;
BEGIN
  -- Vérifier admin
  IF NOT public.is_admin() AND NOT public.is_service_role() THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED');
  END IF;

  SELECT * INTO v_withdrawal FROM public.withdrawals WHERE id = p_withdrawal_id;
  IF v_withdrawal.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'WITHDRAWAL_NOT_FOUND');
  END IF;

  IF v_withdrawal.status NOT IN ('failed', 'processing') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_withdrawal.status);
  END IF;

  IF p_action = 'retry' THEN
    -- Remettre en pending pour retry
    UPDATE public.withdrawals SET status = 'pending', failure_reason = NULL, updated_at = NOW()
    WHERE id = p_withdrawal_id;

    RETURN jsonb_build_object('success', true, 'message', 'Withdrawal reset to pending for retry');

  ELSIF p_action = 'cancel' THEN
    -- Annuler et libérer les revenus
    PERFORM public.confirm_withdrawal_failure(p_withdrawal_id, 'Manually cancelled by admin');

    RETURN jsonb_build_object('success', true, 'message', 'Withdrawal cancelled and revenues released');
  ELSE
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_ACTION', 'valid_actions', ARRAY['retry', 'cancel']);
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.replay_webhook(TEXT, BOOLEAN) TO service_role;
GRANT EXECUTE ON FUNCTION public.reprocess_commission_distribution(UUID, BOOLEAN) TO service_role;
GRANT EXECUTE ON FUNCTION public.fix_failed_withdrawal(UUID, TEXT) TO service_role;

-- ============================================================================
-- 6. WEBHOOK OUT-OF-ORDER HANDLING
-- ============================================================================

-- Table pour tracker les événements Stripe reçus (ordre et dépendances)
CREATE TABLE IF NOT EXISTS public.stripe_event_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id TEXT NOT NULL UNIQUE,
  event_type TEXT NOT NULL,
  resource_type TEXT,  -- 'payment_intent', 'payout', 'transfer', etc.
  resource_id TEXT,    -- ID Stripe de la ressource
  event_created BIGINT,  -- timestamp Stripe
  received_at TIMESTAMPTZ DEFAULT NOW(),
  processed BOOLEAN DEFAULT FALSE,
  processed_at TIMESTAMPTZ,
  depends_on_event TEXT,  -- event_id d'un événement dont celui-ci dépend
  error TEXT,
  retry_count INTEGER DEFAULT 0
);
CREATE INDEX idx_stripe_event_log_resource ON public.stripe_event_log(resource_type, resource_id);
CREATE INDEX idx_stripe_event_log_pending ON public.stripe_event_log(processed, received_at) WHERE processed = FALSE;
CREATE INDEX idx_stripe_event_log_depends ON public.stripe_event_log(depends_on_event) WHERE depends_on_event IS NOT NULL;

ALTER TABLE public.stripe_event_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY "stripe_event_log_service" ON public.stripe_event_log FOR ALL USING (public.is_service_role());

-- Fonction pour vérifier si un événement peut être traité (dépendances résolues)
CREATE OR REPLACE FUNCTION public.can_process_stripe_event(p_event_id TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_event public.stripe_event_log%ROWTYPE;
  v_depends_processed BOOLEAN;
BEGIN
  SELECT * INTO v_event FROM public.stripe_event_log WHERE event_id = p_event_id;

  IF v_event.id IS NULL THEN
    RETURN FALSE;  -- Event not logged
  END IF;

  IF v_event.processed THEN
    RETURN FALSE;  -- Already processed
  END IF;

  IF v_event.depends_on_event IS NULL THEN
    RETURN TRUE;  -- No dependency
  END IF;

  -- Check if dependency is processed
  SELECT processed INTO v_depends_processed
  FROM public.stripe_event_log
  WHERE event_id = v_event.depends_on_event;

  RETURN COALESCE(v_depends_processed, FALSE);
END;
$$;

GRANT EXECUTE ON FUNCTION public.can_process_stripe_event(TEXT) TO service_role;

-- ============================================================================
-- 7. GO-LIVE CHECKLIST TABLE
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.go_live_checklist (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  category TEXT NOT NULL CHECK (category IN (
    'security', 'stripe', 'backups', 'monitoring', 'rgpd', 'performance', 'ci_cd'
  )),
  item TEXT NOT NULL,
  description TEXT,
  is_critical BOOLEAN DEFAULT FALSE,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'in_progress', 'done', 'blocked', 'na')),
  verified_by UUID REFERENCES public.profiles(id),
  verified_at TIMESTAMPTZ,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.go_live_checklist ENABLE ROW LEVEL SECURITY;
CREATE POLICY "checklist_admin_manage" ON public.go_live_checklist FOR ALL USING (public.is_admin() OR public.is_service_role());

-- Seed initial checklist
INSERT INTO public.go_live_checklist (category, item, description, is_critical) VALUES
-- Security
('security', 'RLS audit passed', 'Run audit_rls_coverage() and fix all issues', TRUE),
('security', 'SECURITY DEFINER audit passed', 'Run audit_security_definer_functions() and fix all issues', TRUE),
('security', 'No service_role on client', 'Verify no Edge Functions expose service_role key to client', TRUE),
('security', 'Rate limiting active', 'All public endpoints have rate limiting', TRUE),
('security', 'Secrets in env only', 'STRIPE_SECRET_KEY, CRON_SECRET only in Supabase secrets', TRUE),

-- Stripe
('stripe', 'Webhook signature verified', 'All webhook endpoints verify Stripe signature', TRUE),
('stripe', 'Idempotency tested', 'Send duplicate webhooks and verify no double-processing', TRUE),
('stripe', 'Out-of-order events handled', 'Test events arriving in wrong order', FALSE),
('stripe', 'Test mode simulations done', 'Simulate all payment flows in test mode', TRUE),
('stripe', 'Live mode credentials ready', 'Stripe live keys generated and stored', TRUE),

-- Backups
('backups', 'Daily backups configured', 'Supabase PITR or custom backup solution', TRUE),
('backups', 'Restore tested', 'Successfully restored from backup at least once', TRUE),
('backups', 'Retention policy defined', '30 days minimum for PITR', FALSE),

-- Monitoring
('monitoring', 'Alerts configured', 'system_alerts table monitored by external service', TRUE),
('monitoring', 'Job queue monitored', 'Failed/stuck jobs trigger alerts', TRUE),
('monitoring', 'Financial drift monitored', 'Daily check for unbalanced ledger', TRUE),
('monitoring', 'Error logging active', 'system_logs sent to external service (Datadog/etc)', FALSE),

-- RGPD
('rgpd', 'Export data works', 'export_user_data() tested and returns complete data', TRUE),
('rgpd', 'Deletion works', 'request_account_deletion() and actual deletion tested', TRUE),
('rgpd', 'IP addresses hashed', 'No raw IP stored, only ip_hash', TRUE),
('rgpd', 'Consent tracking', 'data_retention_consent and marketing_consent tracked', FALSE),

-- Performance
('performance', 'P1 indexes created', 'All P1 indexes from v40.11 migration applied', TRUE),
('performance', 'Key queries analyzed', 'EXPLAIN ANALYZE on dashboard queries', FALSE),
('performance', 'Partitioning plan ready', 'affiliate_clicks and messages partitioning documented', FALSE),

-- CI/CD
('ci_cd', 'Migrations versioned', 'All SQL migrations in git with proper versioning', TRUE),
('ci_cd', 'Staging environment', 'Staging with same RLS/triggers as prod', TRUE),
('ci_cd', 'Rollback plan documented', 'Steps to rollback migration documented', TRUE)
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 8. CONTRAINTE FK POLYMORPHE (withdrawal_allocations)
-- ============================================================================

-- Note: PostgreSQL ne supporte pas nativement les FK polymorphes
-- On ajoute un trigger de validation à la place

CREATE OR REPLACE FUNCTION public.validate_withdrawal_allocation_revenue()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.revenue_type = 'seller' THEN
    IF NOT EXISTS (SELECT 1 FROM public.seller_revenues WHERE id = NEW.revenue_id) THEN
      RAISE EXCEPTION 'Invalid revenue_id: seller_revenues record not found'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
  ELSIF NEW.revenue_type = 'agent' THEN
    IF NOT EXISTS (SELECT 1 FROM public.agent_revenues WHERE id = NEW.revenue_id) THEN
      RAISE EXCEPTION 'Invalid revenue_id: agent_revenues record not found'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_withdrawal_allocation ON public.withdrawal_allocations;
CREATE TRIGGER trg_validate_withdrawal_allocation
BEFORE INSERT OR UPDATE ON public.withdrawal_allocations
FOR EACH ROW
EXECUTE FUNCTION public.validate_withdrawal_allocation_revenue();

-- ============================================================================
-- 9. PARTITIONNEMENT AFFILIATE_CLICKS (PRÉPARATION)
-- ============================================================================

-- Note: Le partitionnement natif PostgreSQL nécessite de recréer la table
-- Pour une table existante avec données, la stratégie est:
-- 1. Créer une nouvelle table partitionnée
-- 2. Migrer les données
-- 3. Swapper les tables
--
-- Pour l'instant, on ajoute une vue et une fonction de cleanup agressif

-- Fonction de cleanup pour affiliate_clicks (garder 90 jours max online)
CREATE OR REPLACE FUNCTION public.archive_old_affiliate_clicks()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_deleted INTEGER;
BEGIN
  -- Archiver vers table cold storage (à créer si besoin)
  -- Pour l'instant, on supprime simplement après 90 jours
  DELETE FROM public.affiliate_clicks
  WHERE clicked_at < NOW() - INTERVAL '90 days';

  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  IF v_deleted > 0 THEN
    INSERT INTO public.system_logs (level, event_type, message, details)
    VALUES ('info', 'affiliate_clicks_cleanup',
      v_deleted || ' old affiliate clicks archived/deleted',
      jsonb_build_object('deleted_count', v_deleted, 'threshold', '90 days'));
  END IF;

  RETURN v_deleted;
END;
$$;

GRANT EXECUTE ON FUNCTION public.archive_old_affiliate_clicks() TO service_role;

-- ============================================================================
-- COMMIT
-- ============================================================================

COMMIT;

-- ============================================================================
-- POST-COMMIT CHECKS (run manually after migration)
-- ============================================================================
-- SELECT * FROM public.audit_rls_coverage() WHERE issue != 'OK';
-- SELECT * FROM public.audit_security_definer_functions() WHERE issue != 'OK';
-- SELECT * FROM public.audit_permissive_policies();
-- SELECT * FROM public.audit_unbalanced_ledger_entries();
-- SELECT * FROM public.run_monitoring_checks();
