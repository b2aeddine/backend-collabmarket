#!/bin/bash
# ==============================================================================
# SMOKE TEST SCRIPT - CollabMarket Backend
# Tests critical paths and verifies system health
# ==============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SUPABASE_URL="${SUPABASE_URL:-}"
SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-}"
SUPABASE_SERVICE_ROLE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
CRON_SECRET="${CRON_SECRET:-}"

# Track results
PASSED=0
FAILED=0
WARNINGS=0

# Helper functions
log_pass() {
  echo -e "${GREEN}[PASS]${NC} $1"
  ((PASSED++))
}

log_fail() {
  echo -e "${RED}[FAIL]${NC} $1"
  ((FAILED++))
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
  ((WARNINGS++))
}

log_info() {
  echo -e "[INFO] $1"
}

check_required_env() {
  if [ -z "$SUPABASE_URL" ]; then
    log_fail "SUPABASE_URL is not set"
    exit 1
  fi
  if [ -z "$SUPABASE_ANON_KEY" ]; then
    log_fail "SUPABASE_ANON_KEY is not set"
    exit 1
  fi
  log_pass "Required environment variables are set"
}

# ==============================================================================
# TEST: Database Connectivity
# ==============================================================================
test_database_health() {
  log_info "Testing database connectivity..."

  response=$(curl -s -w "\n%{http_code}" \
    -H "apikey: $SUPABASE_ANON_KEY" \
    -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
    "$SUPABASE_URL/rest/v1/")

  http_code=$(echo "$response" | tail -n1)

  if [ "$http_code" = "200" ]; then
    log_pass "Database connection successful (HTTP $http_code)"
  else
    log_fail "Database connection failed (HTTP $http_code)"
  fi
}

# ==============================================================================
# TEST: Public Tables Accessible
# ==============================================================================
test_public_tables() {
  log_info "Testing public table access..."

  # Test services table (should be publicly readable)
  response=$(curl -s -w "\n%{http_code}" \
    -H "apikey: $SUPABASE_ANON_KEY" \
    -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
    "$SUPABASE_URL/rest/v1/services?select=id&limit=1")

  http_code=$(echo "$response" | tail -n1)

  if [ "$http_code" = "200" ]; then
    log_pass "Public services table accessible"
  else
    log_fail "Cannot access services table (HTTP $http_code)"
  fi

  # Test categories table
  response=$(curl -s -w "\n%{http_code}" \
    -H "apikey: $SUPABASE_ANON_KEY" \
    -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
    "$SUPABASE_URL/rest/v1/categories?select=id&limit=1")

  http_code=$(echo "$response" | tail -n1)

  if [ "$http_code" = "200" ]; then
    log_pass "Public categories table accessible"
  else
    log_fail "Cannot access categories table (HTTP $http_code)"
  fi
}

# ==============================================================================
# TEST: RLS Enforcement
# ==============================================================================
test_rls_enforcement() {
  log_info "Testing RLS enforcement..."

  # Try to access orders without auth (should fail or return empty)
  response=$(curl -s \
    -H "apikey: $SUPABASE_ANON_KEY" \
    -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
    "$SUPABASE_URL/rest/v1/orders?select=id&limit=1")

  # Should return empty array, not error
  if [ "$response" = "[]" ]; then
    log_pass "RLS blocks unauthenticated access to orders"
  else
    log_warn "Orders table returned data without auth: $response"
  fi

  # Try to access withdrawals (should be blocked)
  response=$(curl -s \
    -H "apikey: $SUPABASE_ANON_KEY" \
    -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
    "$SUPABASE_URL/rest/v1/withdrawals?select=id&limit=1")

  if [ "$response" = "[]" ]; then
    log_pass "RLS blocks unauthenticated access to withdrawals"
  else
    log_warn "Withdrawals table returned data without auth"
  fi
}

# ==============================================================================
# TEST: Edge Functions Available
# ==============================================================================
test_edge_functions() {
  log_info "Testing Edge Functions availability..."

  functions=(
    "create-payment"
    "create-order"
    "stripe-webhook"
    "job-worker"
    "cron-process-withdrawals"
  )

  for func in "${functions[@]}"; do
    # OPTIONS request to check if function exists
    response=$(curl -s -w "\n%{http_code}" -X OPTIONS \
      "$SUPABASE_URL/functions/v1/$func")

    http_code=$(echo "$response" | tail -n1)

    if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
      log_pass "Edge Function '$func' is deployed"
    else
      log_fail "Edge Function '$func' not available (HTTP $http_code)"
    fi
  done
}

# ==============================================================================
# TEST: Cron Endpoint Authentication
# ==============================================================================
test_cron_auth() {
  log_info "Testing cron endpoint authentication..."

  if [ -z "$CRON_SECRET" ]; then
    log_warn "CRON_SECRET not set, skipping cron auth tests"
    return
  fi

  # Test without auth (should fail)
  response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    "$SUPABASE_URL/functions/v1/job-worker")

  http_code=$(echo "$response" | tail -n1)

  if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
    log_pass "Cron endpoint rejects unauthenticated requests"
  else
    log_warn "Cron endpoint may not be properly protected (HTTP $http_code)"
  fi

  # Test with auth (should succeed)
  response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: Bearer $CRON_SECRET" \
    -H "Content-Type: application/json" \
    -d '{"max_jobs": 0}' \
    "$SUPABASE_URL/functions/v1/job-worker")

  http_code=$(echo "$response" | tail -n1)

  if [ "$http_code" = "200" ]; then
    log_pass "Cron endpoint accepts authenticated requests"
  else
    log_fail "Cron endpoint rejected authenticated request (HTTP $http_code)"
  fi
}

# ==============================================================================
# TEST: Database Functions (via service role)
# ==============================================================================
test_database_functions() {
  log_info "Testing database functions..."

  if [ -z "$SUPABASE_SERVICE_ROLE_KEY" ]; then
    log_warn "SUPABASE_SERVICE_ROLE_KEY not set, skipping DB function tests"
    return
  fi

  # Test monitoring checks function
  response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Content-Type: application/json" \
    "$SUPABASE_URL/rest/v1/rpc/run_monitoring_checks")

  http_code=$(echo "$response" | tail -n1)

  if [ "$http_code" = "200" ]; then
    log_pass "run_monitoring_checks() function works"
  else
    log_fail "run_monitoring_checks() failed (HTTP $http_code)"
  fi

  # Test RLS audit function
  response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Content-Type: application/json" \
    "$SUPABASE_URL/rest/v1/rpc/audit_rls_coverage")

  http_code=$(echo "$response" | tail -n1)

  if [ "$http_code" = "200" ]; then
    log_pass "audit_rls_coverage() function works"
  else
    log_fail "audit_rls_coverage() failed (HTTP $http_code)"
  fi
}

# ==============================================================================
# TEST: Stripe Webhook Endpoint
# ==============================================================================
test_stripe_webhook() {
  log_info "Testing Stripe webhook endpoint..."

  # Send a test event (should be rejected due to invalid signature)
  response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -H "Stripe-Signature: invalid" \
    -d '{"type": "test.event"}' \
    "$SUPABASE_URL/functions/v1/stripe-webhook")

  http_code=$(echo "$response" | tail -n1)

  # Should return 400 or 401 for invalid signature
  if [ "$http_code" = "400" ] || [ "$http_code" = "401" ]; then
    log_pass "Stripe webhook rejects invalid signatures"
  else
    log_warn "Stripe webhook response unexpected (HTTP $http_code)"
  fi
}

# ==============================================================================
# TEST: Job Queue Health
# ==============================================================================
test_job_queue() {
  log_info "Testing job queue health..."

  if [ -z "$SUPABASE_SERVICE_ROLE_KEY" ]; then
    log_warn "SUPABASE_SERVICE_ROLE_KEY not set, skipping job queue tests"
    return
  fi

  # Check for stuck jobs
  response=$(curl -s \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    "$SUPABASE_URL/rest/v1/job_queue?status=eq.processing&started_at=lt.$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)&select=id")

  if [ "$response" = "[]" ]; then
    log_pass "No stuck jobs in queue"
  else
    job_count=$(echo "$response" | jq 'length')
    log_warn "$job_count stuck jobs detected in queue"
  fi

  # Check failed jobs
  response=$(curl -s \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    "$SUPABASE_URL/rest/v1/job_queue?status=eq.failed&select=id")

  if [ "$response" = "[]" ]; then
    log_pass "No failed jobs in queue"
  else
    job_count=$(echo "$response" | jq 'length')
    log_warn "$job_count failed jobs in queue"
  fi
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
  echo "=============================================="
  echo "  CollabMarket Backend Smoke Tests"
  echo "=============================================="
  echo ""

  check_required_env

  echo ""
  echo "--- Database Tests ---"
  test_database_health
  test_public_tables
  test_rls_enforcement

  echo ""
  echo "--- Edge Function Tests ---"
  test_edge_functions
  test_cron_auth
  test_stripe_webhook

  echo ""
  echo "--- Database Function Tests ---"
  test_database_functions

  echo ""
  echo "--- Job Queue Tests ---"
  test_job_queue

  echo ""
  echo "=============================================="
  echo "  RESULTS"
  echo "=============================================="
  echo -e "  ${GREEN}Passed:${NC}   $PASSED"
  echo -e "  ${RED}Failed:${NC}   $FAILED"
  echo -e "  ${YELLOW}Warnings:${NC} $WARNINGS"
  echo "=============================================="

  if [ $FAILED -gt 0 ]; then
    echo -e "\n${RED}Some tests failed!${NC}"
    exit 1
  elif [ $WARNINGS -gt 0 ]; then
    echo -e "\n${YELLOW}Tests passed with warnings.${NC}"
    exit 0
  else
    echo -e "\n${GREEN}All tests passed!${NC}"
    exit 0
  fi
}

main "$@"
