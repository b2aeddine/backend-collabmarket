# Cron Jobs Setup Guide

This document describes how to configure scheduled tasks (cron jobs) for the CollabMarket backend.

## Overview

The system uses several cron-triggered Edge Functions for background processing:

| Function | Purpose | Recommended Schedule |
|----------|---------|---------------------|
| `job-worker` | Process background jobs from job_queue | Every minute |
| `cron-process-withdrawals` | Process pending withdrawal payouts | Every 5 minutes |
| `cron-monitoring` | Health checks, auto-complete/cancel orders, stuck job recovery | Every 15 minutes |
| `cleanup-orphan-orders` | Clean up stale orders | Daily at 3:00 AM |

### cron-monitoring Features (V2.0)

The `cron-monitoring` Edge Function now handles multiple tasks:

1. **Health Monitoring** - Runs `run_monitoring_checks()` for system health
2. **Security Audit** - Optional deep security scan (pass `X-Run-Security-Audit: true` header)
3. **Auto-Complete Orders** - Completes delivered orders after 72h buyer inactivity
4. **Auto-Cancel Orders** - Cancels unaccepted orders past `acceptance_deadline`
5. **Stuck Job Recovery** - Resets jobs stuck in `processing` state > 30 minutes
6. **Revenue Release** - Releases pending revenues when `available_at` is reached
7. **Data Cleanup** - Archives old affiliate clicks, cleans expired data

## Authentication

All cron endpoints require a `CRON_SECRET` header for authentication:

```bash
curl -X POST \
  -H "Authorization: Bearer CRON_SECRET_VALUE" \
  -H "Content-Type: application/json" \
  https://YOUR_PROJECT.supabase.co/functions/v1/job-worker
```

## Environment Variables

Set these in your Supabase project settings:

```env
CRON_SECRET=your-secure-random-string-min-32-chars
```

Generate a secure secret:
```bash
openssl rand -base64 32
```

## Supabase Cron Setup (pg_cron)

### 1. Enable pg_cron Extension

In your Supabase dashboard, go to Database > Extensions and enable `pg_cron`.

### 2. Create Cron Jobs

Execute these SQL statements to set up scheduled jobs:

```sql
-- Job Worker: Process background jobs every minute
SELECT cron.schedule(
  'job-worker',
  '* * * * *',  -- Every minute
  $$
  SELECT net.http_post(
    url := current_setting('app.settings.supabase_url') || '/functions/v1/job-worker',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || current_setting('app.settings.cron_secret'),
      'Content-Type', 'application/json'
    ),
    body := '{"max_jobs": 20}'::jsonb
  );
  $$
);

-- Process Withdrawals: Every 5 minutes
SELECT cron.schedule(
  'process-withdrawals',
  '*/5 * * * *',  -- Every 5 minutes
  $$
  SELECT net.http_post(
    url := current_setting('app.settings.supabase_url') || '/functions/v1/cron-process-withdrawals',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || current_setting('app.settings.cron_secret'),
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);

-- Monitoring: Every 15 minutes
SELECT cron.schedule(
  'monitoring',
  '*/15 * * * *',  -- Every 15 minutes
  $$
  SELECT net.http_post(
    url := current_setting('app.settings.supabase_url') || '/functions/v1/cron-monitoring',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || current_setting('app.settings.cron_secret'),
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);

-- Cleanup Orphan Orders: Daily at 3:00 AM UTC
SELECT cron.schedule(
  'cleanup-orphan-orders',
  '0 3 * * *',  -- 3:00 AM UTC daily
  $$
  SELECT net.http_post(
    url := current_setting('app.settings.supabase_url') || '/functions/v1/cleanup-orphan-orders',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || current_setting('app.settings.cron_secret'),
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);

-- Daily Analytics Aggregation: 1:00 AM UTC
SELECT cron.schedule(
  'aggregate-analytics',
  '0 1 * * *',  -- 1:00 AM UTC daily
  $$
  SELECT public.aggregate_daily_stats(CURRENT_DATE - INTERVAL '1 day');
  $$
);

-- Auto-complete Orders (after delivery timeout): Every hour
SELECT cron.schedule(
  'auto-complete-orders',
  '0 * * * *',  -- Every hour
  $$
  SELECT public.auto_complete_orders();
  $$
);

-- Auto-cancel Expired Orders: Every 30 minutes
SELECT cron.schedule(
  'auto-cancel-expired',
  '*/30 * * * *',  -- Every 30 minutes
  $$
  SELECT public.auto_cancel_expired_orders();
  $$
);

-- Cleanup Old Data: Weekly on Sunday at 4:00 AM UTC
SELECT cron.schedule(
  'cleanup-old-data',
  '0 4 * * 0',  -- Sunday 4:00 AM UTC
  $$
  SELECT public.cleanup_old_data();
  $$
);
```

### 3. Set App Settings

Configure the app settings for cron jobs:

```sql
-- Set these in a migration or manually
ALTER DATABASE postgres SET app.settings.supabase_url = 'https://YOUR_PROJECT.supabase.co';
ALTER DATABASE postgres SET app.settings.cron_secret = 'your-cron-secret-here';
```

## Alternative: External Cron Services

If you prefer external cron services, here are some options:

### GitHub Actions

```yaml
# .github/workflows/cron-jobs.yml
name: Cron Jobs

on:
  schedule:
    - cron: '* * * * *'  # Every minute

jobs:
  job-worker:
    runs-on: ubuntu-latest
    steps:
      - name: Trigger Job Worker
        run: |
          curl -X POST \
            -H "Authorization: Bearer ${{ secrets.CRON_SECRET }}" \
            -H "Content-Type: application/json" \
            -d '{"max_jobs": 20}' \
            ${{ secrets.SUPABASE_URL }}/functions/v1/job-worker
```

### cron-job.org

1. Create account at https://cron-job.org
2. Add new job for each endpoint
3. Set headers: `Authorization: Bearer YOUR_CRON_SECRET`
4. Set schedule as needed

### Cloudflare Workers

```javascript
// Cloudflare Worker scheduled trigger
export default {
  async scheduled(event, env, ctx) {
    const response = await fetch(`${env.SUPABASE_URL}/functions/v1/job-worker`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${env.CRON_SECRET}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ max_jobs: 20 }),
    });
    console.log('Job worker response:', await response.json());
  },
};
```

## Monitoring Cron Jobs

### View Scheduled Jobs

```sql
SELECT * FROM cron.job ORDER BY jobname;
```

### View Job Run History

```sql
SELECT
  jobid,
  jobname,
  status,
  start_time,
  end_time,
  return_message
FROM cron.job_run_details
ORDER BY start_time DESC
LIMIT 50;
```

### Disable a Job

```sql
SELECT cron.unschedule('job-worker');
```

### Update Job Schedule

```sql
-- First unschedule, then reschedule with new timing
SELECT cron.unschedule('job-worker');
SELECT cron.schedule('job-worker', '*/2 * * * *', $$ ... $$);
```

## Job Queue Monitoring

Monitor the job_queue table for issues:

```sql
-- Pending jobs
SELECT job_type, COUNT(*), MIN(scheduled_at) as oldest
FROM job_queue
WHERE status = 'pending'
GROUP BY job_type;

-- Failed jobs
SELECT id, job_type, attempts, last_error, created_at
FROM job_queue
WHERE status = 'failed'
ORDER BY created_at DESC
LIMIT 20;

-- Stuck jobs (processing for too long)
SELECT *
FROM job_queue
WHERE status = 'processing'
  AND started_at < NOW() - INTERVAL '10 minutes';
```

### Reset Stuck Jobs

```sql
-- Reset stuck jobs to pending for retry
UPDATE job_queue
SET status = 'pending', started_at = NULL
WHERE status = 'processing'
  AND started_at < NOW() - INTERVAL '30 minutes';
```

## Troubleshooting

### Job Worker Not Processing

1. Check `CRON_SECRET` matches in cron config and Edge Function
2. Verify Edge Function is deployed: `supabase functions list`
3. Check Edge Function logs: `supabase functions logs job-worker`
4. Verify jobs exist in queue: `SELECT * FROM job_queue WHERE status = 'pending' LIMIT 5;`

### Withdrawals Not Processing

1. Check Stripe credentials are valid
2. Verify users have `stripe_account_id` in profiles
3. Check withdrawal status: `SELECT status, COUNT(*) FROM withdrawals GROUP BY status;`

### High Job Queue Backlog

If jobs are accumulating faster than processing:

1. Increase job-worker frequency (every 30 seconds)
2. Increase `max_jobs` parameter to 50
3. Deploy multiple job-worker instances with different job types:

```sql
-- Worker 1: High priority (commissions)
SELECT cron.schedule('job-worker-commissions', '* * * * *', $$
  SELECT net.http_post(
    url := '...',
    body := '{"max_jobs": 20, "job_types": ["distribute_commissions", "reverse_commissions"]}'::jsonb
  );
$$);

-- Worker 2: Low priority (cleanup, notifications)
SELECT cron.schedule('job-worker-low-priority', '*/5 * * * *', $$
  SELECT net.http_post(
    url := '...',
    body := '{"max_jobs": 50, "job_types": ["cleanup_data", "send_notification", "sync_analytics"]}'::jsonb
  );
$$);
```

## Security Considerations

1. **Never expose CRON_SECRET** in client-side code or public repositories
2. **Rotate CRON_SECRET** periodically (update both Edge Function env and cron config)
3. **Use HTTPS only** for all cron endpoint calls
4. **Monitor for unauthorized attempts** via system_logs table
5. **Set rate limits** on cron endpoints to prevent abuse
