# CollabMarket Database Migrations

## Migration Naming Convention

```
v{major}.{minor}_{description}.sql
```

Examples:
- `v40.10_initial_schema.sql`
- `v40.11_security_and_ops_hardening.sql`
- `v40.12_performance_indexes.sql`

## Migration History

| Version | Date | Description |
|---------|------|-------------|
| v40.10 | 2024-XX | Initial v40 schema with multi-role support |
| v40.11 | 2024-XX | Security audit, monitoring, accounting invariants |

## How to Apply Migrations

### Development (Local)
```bash
# Using Supabase CLI
supabase db push

# Or directly via psql
psql $DATABASE_URL -f migrations/v40.11_security_and_ops_hardening.sql
```

### Staging
```bash
# Via Supabase CLI
supabase db push --db-url $STAGING_DATABASE_URL
```

### Production
```bash
# 1. Create backup first
supabase db dump -f backup_$(date +%Y%m%d_%H%M%S).sql

# 2. Apply migration
supabase db push --db-url $PROD_DATABASE_URL

# 3. Run post-migration checks
psql $PROD_DATABASE_URL -c "SELECT * FROM public.audit_rls_coverage() WHERE issue != 'OK';"
psql $PROD_DATABASE_URL -c "SELECT * FROM public.audit_security_definer_functions() WHERE issue != 'OK';"
```

## Rollback Procedures

### General Rollback Steps
1. Stop the application (put in maintenance mode)
2. Restore from backup
3. Deploy previous Edge Functions version
4. Remove maintenance mode

### Creating Rollback Scripts
For each migration, create a corresponding rollback script:
```
v40.11_security_and_ops_hardening_rollback.sql
```

## Post-Migration Checks

After each migration, run these checks:

```sql
-- 1. RLS Coverage
SELECT * FROM public.audit_rls_coverage() WHERE issue != 'OK';

-- 2. SECURITY DEFINER Audit
SELECT * FROM public.audit_security_definer_functions() WHERE issue != 'OK';

-- 3. Permissive Policies
SELECT * FROM public.audit_permissive_policies();

-- 4. Ledger Balance
SELECT * FROM public.audit_unbalanced_ledger_entries();

-- 5. Monitoring
SELECT * FROM public.run_monitoring_checks();
```

## Environment Variables Required

### Edge Functions
```env
SUPABASE_URL=https://xxx.supabase.co
SUPABASE_ANON_KEY=eyJ...
SUPABASE_SERVICE_ROLE_KEY=eyJ...
STRIPE_SECRET_KEY=sk_live_...
STRIPE_WEBHOOK_SECRET=whsec_...
CRON_SECRET=your-secure-random-string
ALLOWED_ORIGIN=https://collabmarket.fr
ALERT_WEBHOOK_URL=https://hooks.slack.com/services/... (optional)
```

### Database
```env
DATABASE_URL=postgresql://...
```

## CI/CD Integration

### GitHub Actions Example
```yaml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Supabase CLI
        uses: supabase/setup-cli@v1

      - name: Run Migrations
        run: |
          supabase db push --db-url ${{ secrets.DATABASE_URL }}

      - name: Deploy Edge Functions
        run: |
          supabase functions deploy --project-ref ${{ secrets.SUPABASE_PROJECT_REF }}

      - name: Post-Migration Checks
        run: |
          psql ${{ secrets.DATABASE_URL }} -c "SELECT COUNT(*) FROM public.audit_rls_coverage() WHERE issue != 'OK';" | grep -q "0" || exit 1
```

## Security Checklist

Before deploying to production:

- [ ] All RLS policies reviewed
- [ ] No `service_role` key exposed to client
- [ ] All SECURITY DEFINER functions have `SET search_path`
- [ ] Webhook signatures verified
- [ ] Rate limiting enabled
- [ ] Secrets stored in environment variables only
- [ ] Backup strategy tested
