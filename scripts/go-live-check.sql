-- ==============================================================================
-- GO-LIVE VERIFICATION SCRIPT
-- Run this before going live to verify all critical checks pass
-- ==============================================================================

\echo '=========================================='
\echo 'COLLABMARKET GO-LIVE VERIFICATION'
\echo '=========================================='
\echo ''

-- 1. RLS COVERAGE
\echo '1. RLS COVERAGE CHECK'
\echo '--------------------'
SELECT
  CASE
    WHEN COUNT(*) = 0 THEN '✅ PASS: All tables have RLS enabled'
    ELSE '❌ FAIL: ' || COUNT(*) || ' tables missing RLS'
  END AS rls_status
FROM public.audit_rls_coverage()
WHERE issue LIKE 'CRITICAL%';

SELECT table_name, issue FROM public.audit_rls_coverage() WHERE issue != 'OK';

\echo ''

-- 2. SECURITY DEFINER FUNCTIONS
\echo '2. SECURITY DEFINER AUDIT'
\echo '-------------------------'
SELECT
  CASE
    WHEN COUNT(*) = 0 THEN '✅ PASS: All SECURITY DEFINER functions are safe'
    ELSE '❌ FAIL: ' || COUNT(*) || ' functions have security issues'
  END AS definer_status
FROM public.audit_security_definer_functions()
WHERE issue LIKE 'CRITICAL%';

SELECT function_name, issue FROM public.audit_security_definer_functions() WHERE issue != 'OK';

\echo ''

-- 3. PERMISSIVE POLICIES
\echo '3. PERMISSIVE POLICIES CHECK'
\echo '----------------------------'
SELECT
  CASE
    WHEN COUNT(*) = 0 THEN '✅ PASS: No overly permissive policies found'
    ELSE '⚠️ WARNING: ' || COUNT(*) || ' potentially permissive policies (review manually)'
  END AS policy_status
FROM public.audit_permissive_policies()
WHERE issue LIKE 'CRITICAL%';

SELECT table_name, policy_name, issue FROM public.audit_permissive_policies();

\echo ''

-- 4. LEDGER BALANCE
\echo '4. LEDGER BALANCE CHECK'
\echo '-----------------------'
SELECT
  CASE
    WHEN COUNT(*) = 0 THEN '✅ PASS: All ledger entries are balanced'
    ELSE '❌ FAIL: ' || COUNT(*) || ' unbalanced transaction groups'
  END AS ledger_status
FROM public.audit_unbalanced_ledger_entries();

SELECT * FROM public.audit_unbalanced_ledger_entries() LIMIT 5;

\echo ''

-- 5. STUCK JOBS
\echo '5. STUCK JOBS CHECK'
\echo '-------------------'
SELECT
  CASE
    WHEN COUNT(*) = 0 THEN '✅ PASS: No stuck jobs'
    ELSE '⚠️ WARNING: ' || COUNT(*) || ' jobs stuck in processing'
  END AS jobs_status
FROM public.job_queue
WHERE status = 'processing'
  AND started_at < NOW() - INTERVAL '30 minutes';

\echo ''

-- 6. FAILED JOBS (last 24h)
\echo '6. FAILED JOBS (LAST 24H)'
\echo '-------------------------'
SELECT
  CASE
    WHEN COUNT(*) = 0 THEN '✅ PASS: No failed jobs in last 24h'
    ELSE '⚠️ WARNING: ' || COUNT(*) || ' failed jobs in last 24h'
  END AS failed_jobs_status
FROM public.job_queue
WHERE status = 'failed'
  AND completed_at > NOW() - INTERVAL '24 hours';

\echo ''

-- 7. PENDING WITHDRAWALS
\echo '7. PENDING WITHDRAWALS CHECK'
\echo '----------------------------'
SELECT
  COUNT(*) AS pending_withdrawals,
  COALESCE(SUM(amount), 0) AS total_amount
FROM public.withdrawals
WHERE status IN ('pending', 'processing');

\echo ''

-- 8. ORPHAN ORDERS (completed without revenues)
\echo '8. ORPHAN ORDERS CHECK'
\echo '----------------------'
SELECT
  CASE
    WHEN COUNT(*) = 0 THEN '✅ PASS: No orphan completed orders'
    ELSE '⚠️ WARNING: ' || COUNT(*) || ' completed orders without revenues'
  END AS orphan_status
FROM public.orders o
WHERE o.status = 'completed'
  AND o.completed_at < NOW() - INTERVAL '1 hour'
  AND NOT EXISTS (SELECT 1 FROM public.seller_revenues sr WHERE sr.order_id = o.id);

\echo ''

-- 9. GO-LIVE CHECKLIST STATUS
\echo '9. GO-LIVE CHECKLIST STATUS'
\echo '---------------------------'
SELECT
  category,
  COUNT(*) FILTER (WHERE status = 'done') AS done,
  COUNT(*) FILTER (WHERE status = 'pending') AS pending,
  COUNT(*) FILTER (WHERE is_critical AND status != 'done') AS critical_pending
FROM public.go_live_checklist
GROUP BY category
ORDER BY critical_pending DESC, category;

\echo ''
\echo '=========================================='
\echo 'SUMMARY'
\echo '=========================================='

SELECT
  CASE
    WHEN (
      (SELECT COUNT(*) FROM public.audit_rls_coverage() WHERE issue LIKE 'CRITICAL%') = 0
      AND (SELECT COUNT(*) FROM public.audit_security_definer_functions() WHERE issue LIKE 'CRITICAL%') = 0
      AND (SELECT COUNT(*) FROM public.audit_unbalanced_ledger_entries()) = 0
    ) THEN '✅ READY FOR PRODUCTION'
    ELSE '❌ NOT READY - FIX ISSUES ABOVE'
  END AS overall_status;

\echo ''
\echo 'Run this script again after fixing any issues.'
\echo '=========================================='
