#!/usr/bin/env bash
# Resolve GitHub conflict warnings by merging remote main while keeping local Supabase function implementations.
set -euo pipefail

remote="${1:-origin}"
branch="${2:-main}"

# Ensure we are in a git repo
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "This script must be run inside a git repository." >&2
  exit 1
fi

# Fetch the latest remote refs
git fetch "$remote" "$branch"

# Merge without auto-commit to allow conflict resolution
if git merge --no-commit --no-ff "$remote/$branch"; then
  echo "Merge completed without conflicts; nothing to resolve." >&2
  exit 0
fi

# Prefer local versions for Supabase edge functions when conflicts occur
if ls supabase/functions/*/index.ts >/dev/null 2>&1; then
  git checkout --ours supabase/functions/*/index.ts || true
fi

# Always prefer local webhook implementations
if [ -f supabase/functions/stripe-webhook/index.ts ]; then
  git checkout --ours supabase/functions/stripe-webhook/index.ts || true
fi
if [ -f supabase/functions/stripe-withdrawal-webhook/index.ts ]; then
  git checkout --ours supabase/functions/stripe-withdrawal-webhook/index.ts || true
fi

# Stage resolved files and finish the merge
if git diff --name-only --diff-filter=U | grep -q "supabase/functions"; then
  git add supabase/functions
fi

git status --short

echo "Conflicts resolved with local Supabase function implementations."
echo "Complete the merge with: git commit -m 'Merge $remote/$branch keeping local Supabase functions'"
