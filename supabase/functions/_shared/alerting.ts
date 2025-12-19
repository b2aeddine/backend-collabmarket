// ==============================================================================
// ALERTING UTILITIES - Send alerts to monitoring systems
// ==============================================================================

import { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

export type AlertSeverity = "info" | "warning" | "error" | "critical";

export type AlertType =
  | "webhook_failure"
  | "job_failed"
  | "job_stuck"
  | "balance_mismatch"
  | "transfer_failed"
  | "commission_drift"
  | "rls_violation"
  | "rate_limit_exceeded"
  | "withdrawal_failed"
  | "stripe_error"
  | "security_audit";

export interface AlertContext {
  [key: string]: unknown;
}

/**
 * Create an alert via Supabase RPC
 */
export async function createAlert(
  supabase: SupabaseClient,
  alertType: AlertType,
  severity: AlertSeverity,
  title: string,
  message?: string,
  context?: AlertContext
): Promise<{ alertId: string | null; error: string | null }> {
  const { data, error } = await supabase.rpc("create_alert", {
    p_alert_type: alertType,
    p_severity: severity,
    p_title: title,
    p_message: message || null,
    p_context: context || {},
  });

  if (error) {
    console.error("[Alert] Failed to create alert:", error);
    return { alertId: null, error: error.message };
  }

  return { alertId: data, error: null };
}

/**
 * Log and alert on webhook failure
 */
export async function alertWebhookFailure(
  supabase: SupabaseClient,
  eventId: string,
  eventType: string,
  error: string,
  context?: AlertContext
): Promise<void> {
  await createAlert(
    supabase,
    "webhook_failure",
    "error",
    `Webhook processing failed: ${eventType}`,
    error,
    {
      event_id: eventId,
      event_type: eventType,
      ...context,
    }
  );
}

/**
 * Log and alert on Stripe error
 */
export async function alertStripeError(
  supabase: SupabaseClient,
  operation: string,
  error: string,
  context?: AlertContext
): Promise<void> {
  await createAlert(
    supabase,
    "stripe_error",
    "error",
    `Stripe operation failed: ${operation}`,
    error,
    context
  );
}

/**
 * Log and alert on transfer failure
 */
export async function alertTransferFailure(
  supabase: SupabaseClient,
  withdrawalId: string,
  userId: string,
  amount: number,
  error: string
): Promise<void> {
  await createAlert(
    supabase,
    "transfer_failed",
    "critical",
    `Withdrawal transfer failed: ${amount}EUR`,
    error,
    {
      withdrawal_id: withdrawalId,
      user_id: userId,
      amount,
    }
  );
}

/**
 * Log and alert on withdrawal failure
 */
export async function alertWithdrawalFailure(
  supabase: SupabaseClient,
  withdrawalId: string,
  reason: string,
  context?: AlertContext
): Promise<void> {
  await createAlert(
    supabase,
    "withdrawal_failed",
    "error",
    `Withdrawal failed: ${withdrawalId}`,
    reason,
    {
      withdrawal_id: withdrawalId,
      ...context,
    }
  );
}

/**
 * Send external notification (webhook to Slack/Discord/etc.)
 * Configure via ALERT_WEBHOOK_URL env variable
 */
export async function sendExternalAlert(
  severity: AlertSeverity,
  title: string,
  message?: string,
  context?: AlertContext
): Promise<void> {
  const webhookUrl = Deno.env.get("ALERT_WEBHOOK_URL");

  if (!webhookUrl) {
    // No external webhook configured, skip
    return;
  }

  const severityEmoji: Record<AlertSeverity, string> = {
    info: "ℹ️",
    warning: "⚠️",
    error: "❌",
    critical: "🚨",
  };

  // Slack-compatible format (also works with Discord webhooks)
  const payload = {
    text: `${severityEmoji[severity]} *${title}*`,
    blocks: [
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: `${severityEmoji[severity]} *${title}*${message ? `\n${message}` : ""}`,
        },
      },
      ...(context
        ? [
            {
              type: "context",
              elements: [
                {
                  type: "mrkdwn",
                  text: `\`\`\`${JSON.stringify(context, null, 2)}\`\`\``,
                },
              ],
            },
          ]
        : []),
    ],
  };

  try {
    await fetch(webhookUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
  } catch (err) {
    console.error("[External Alert] Failed to send:", err);
  }
}

/**
 * Combined alert: DB + external
 */
export async function alert(
  supabase: SupabaseClient,
  alertType: AlertType,
  severity: AlertSeverity,
  title: string,
  message?: string,
  context?: AlertContext
): Promise<void> {
  // Store in DB
  await createAlert(supabase, alertType, severity, title, message, context);

  // Send external notification for error/critical
  if (severity === "error" || severity === "critical") {
    await sendExternalAlert(severity, title, message, context);
  }
}
