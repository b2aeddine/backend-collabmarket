// ==============================================================================
// CRON-MONITORING - V2.0 (SCHEMA V40 ALIGNED)
// Runs periodic monitoring checks, auto-complete/cancel orders, and sends alerts
// Protected by CRON_SECRET
// FEATURES:
// - Health monitoring via run_monitoring_checks()
// - Security audits (optional)
// - Auto-complete delivered orders (72h timeout)
// - Auto-cancel expired orders (acceptance deadline)
// - Retry stuck/failed jobs
// - Cleanup old data
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

// SECURITY: Verify CRON_SECRET
function verifyCronSecret(req: Request): string | null {
  const authHeader = req.headers.get("Authorization");
  const cronSecret = Deno.env.get("CRON_SECRET");

  if (!cronSecret) {
    return "CRON_SECRET not configured";
  }

  if (!authHeader || authHeader !== `Bearer ${cronSecret}`) {
    return "Invalid or missing CRON_SECRET";
  }

  return null;
}

serve(async (req) => {
  // 1. VERIFY AUTHORIZATION
  // -------------------------------------------------------------------------
  const authError = verifyCronSecret(req);
  if (authError) {
    console.error("[Monitoring] Auth error:", authError);
    return new Response(JSON.stringify({ error: authError }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  console.log("[Monitoring] Starting periodic checks...");

  try {
    // 2. RUN ALL MONITORING CHECKS
    // -----------------------------------------------------------------------
    const { data: monitoringResult, error: monitoringError } = await supabase.rpc(
      "run_monitoring_checks"
    );

    if (monitoringError) {
      console.error("[Monitoring] Error running checks:", monitoringError);
      return new Response(
        JSON.stringify({
          success: false,
          error: monitoringError.message,
        }),
        {
          status: 500,
          headers: { "Content-Type": "application/json" },
        }
      );
    }

    console.log("[Monitoring] Checks completed:", JSON.stringify(monitoringResult));

    // 3. RUN SECURITY AUDITS (less frequently - check flag)
    // -----------------------------------------------------------------------
    const runSecurityAudit = req.headers.get("X-Run-Security-Audit") === "true";

    let securityResult = null;
    if (runSecurityAudit) {
      console.log("[Monitoring] Running security audit...");

      // Check RLS coverage
      const { data: rlsIssues } = await supabase.rpc("audit_rls_coverage");
      const rlsProblems = rlsIssues?.filter(
        (r: { issue: string }) => r.issue !== "OK"
      );

      // Check SECURITY DEFINER functions
      const { data: definerIssues } = await supabase.rpc(
        "audit_security_definer_functions"
      );
      const definerProblems = definerIssues?.filter(
        (r: { issue: string }) => r.issue !== "OK"
      );

      // Check permissive policies
      const { data: policyIssues } = await supabase.rpc(
        "audit_permissive_policies"
      );

      securityResult = {
        rls_issues: rlsProblems?.length || 0,
        definer_issues: definerProblems?.length || 0,
        policy_issues: policyIssues?.length || 0,
      };

      // Alert on critical security issues
      if (rlsProblems && rlsProblems.length > 0) {
        const criticalRls = rlsProblems.filter((r: { issue: string }) =>
          r.issue.startsWith("CRITICAL")
        );
        if (criticalRls.length > 0) {
          await supabase.rpc("create_alert", {
            p_alert_type: "security_audit",
            p_severity: "critical",
            p_title: `${criticalRls.length} tables without RLS enabled`,
            p_message: "Critical security issue: tables without Row Level Security",
            p_context: { tables: criticalRls.map((r: { table_name: string }) => r.table_name) },
          });
        }
      }

      if (definerProblems && definerProblems.length > 0) {
        const criticalDefiner = definerProblems.filter((r: { issue: string }) =>
          r.issue.startsWith("CRITICAL")
        );
        if (criticalDefiner.length > 0) {
          await supabase.rpc("create_alert", {
            p_alert_type: "security_audit",
            p_severity: "critical",
            p_title: `${criticalDefiner.length} SECURITY DEFINER functions without search_path`,
            p_message: "Critical security issue: functions vulnerable to temp schema injection",
            p_context: {
              functions: criticalDefiner.map((r: { function_name: string }) => r.function_name),
            },
          });
        }
      }

      console.log("[Monitoring] Security audit completed:", securityResult);
    }

    // 4. AUTO-COMPLETE DELIVERED ORDERS (72h timeout)
    // -----------------------------------------------------------------------
    console.log("[Monitoring] Running auto_complete_orders...");
    const { error: autoCompleteError } = await supabase.rpc("auto_complete_orders");
    if (autoCompleteError) {
      console.warn("[Monitoring] auto_complete_orders error:", autoCompleteError);
    } else {
      console.log("[Monitoring] auto_complete_orders completed");
    }

    // 5. AUTO-CANCEL EXPIRED ORDERS (acceptance deadline)
    // -----------------------------------------------------------------------
    console.log("[Monitoring] Running auto_cancel_expired_orders...");
    const { error: autoCancelError } = await supabase.rpc("auto_cancel_expired_orders");
    if (autoCancelError) {
      console.warn("[Monitoring] auto_cancel_expired_orders error:", autoCancelError);
    } else {
      console.log("[Monitoring] auto_cancel_expired_orders completed");
    }

    // 6. RETRY STUCK JOBS (processing for > 30 min)
    // -----------------------------------------------------------------------
    console.log("[Monitoring] Checking for stuck jobs...");
    const thirtyMinutesAgo = new Date(Date.now() - 30 * 60 * 1000).toISOString();

    const { data: stuckJobs, error: stuckError } = await supabase
      .from("job_queue")
      .update({
        status: "pending",
        started_at: null,
        last_error: "Reset from stuck state by monitoring cron"
      })
      .eq("status", "processing")
      .lt("started_at", thirtyMinutesAgo)
      .select("id");

    if (stuckError) {
      console.warn("[Monitoring] Stuck jobs reset error:", stuckError);
    } else if (stuckJobs && stuckJobs.length > 0) {
      console.log(`[Monitoring] Reset ${stuckJobs.length} stuck jobs`);

      // Alert if we have stuck jobs
      await supabase.rpc("create_alert", {
        p_alert_type: "job_stuck",
        p_severity: "warning",
        p_title: `${stuckJobs.length} stuck jobs reset`,
        p_message: "Jobs were stuck in processing state for > 30 minutes",
        p_context: { job_ids: stuckJobs.map((j: { id: string }) => j.id) },
      });
    }

    // 7. CLEANUP OLD DATA
    // -----------------------------------------------------------------------
    const { error: cleanupError } = await supabase.rpc("cleanup_old_data");
    if (cleanupError) {
      console.warn("[Monitoring] Cleanup error:", cleanupError);
    }

    // 8. ARCHIVE OLD AFFILIATE CLICKS
    // -----------------------------------------------------------------------
    const { data: archivedCount, error: archiveError } = await supabase.rpc(
      "archive_old_affiliate_clicks"
    );
    if (archiveError) {
      console.warn("[Monitoring] Archive error:", archiveError);
    } else if (archivedCount > 0) {
      console.log(`[Monitoring] Archived ${archivedCount} old affiliate clicks`);
    }

    // 9. RELEASE PENDING REVENUES (if available_at reached)
    // -----------------------------------------------------------------------
    const { error: releaseError } = await supabase.rpc("release_pending_revenues");
    if (releaseError) {
      console.warn("[Monitoring] release_pending_revenues error:", releaseError);
    }

    // 10. SUCCESS RESPONSE
    // -----------------------------------------------------------------------
    return new Response(
      JSON.stringify({
        success: true,
        monitoring: monitoringResult,
        security: securityResult,
        stuck_jobs_reset: stuckJobs?.length || 0,
        archived_clicks: archivedCount || 0,
        auto_complete: !autoCompleteError,
        auto_cancel: !autoCancelError,
        timestamp: new Date().toISOString(),
      }),
      {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }
    );
  } catch (err: unknown) {
    const error = err as Error;
    console.error("[Monitoring] Unexpected error:", error);

    return new Response(
      JSON.stringify({
        success: false,
        error: error.message,
      }),
      {
        status: 500,
        headers: { "Content-Type": "application/json" },
      }
    );
  }
});
