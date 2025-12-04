# Branching notes

- The repository now uses `main` as the primary branch (renamed from the previous `work` branch).
- All recent Stripe webhook fixes and CORS restrictions are already included on `main`.
- To publish to GitHub, add your remote (for example, `git remote add origin git@github.com:<owner>/<repo>.git`) and push with `git push -u origin main`.
- If another remote branch already exists, fetch it first and reconcile differences with `git fetch origin` and `git merge origin/main` before pushing to avoid conflicts.
- To automate the conflict fix that GitHub reports on the Supabase edge functions, run `scripts/resolve_main_conflicts.sh origin main` from the repository root.

## Resolving GitHub "conflicts must be resolved" notices

GitHub reports conflicts when the remote `main` contains divergent changes on the Supabase edge functions. To force the current branch state and clear the conflict message:

1. Fetch the remote: `git fetch origin main`.
2. Rebase or merge onto the remote branch: `git merge origin/main` (resolve locally if prompted).
3. When merge prompts appear for the edge functions, keep the version from this branch (ours) by running `git checkout --ours supabase/functions/*/index.ts` and `git checkout --ours supabase/functions/stripe-webhook/index.ts supabase/functions/stripe-withdrawal-webhook/index.ts`.
4. Re-stage the files and complete the merge: `git add supabase/functions && git commit`.
5. Push the resolved branch back to GitHub: `git push origin main`.

This preserves the signed webhooks, idempotence safeguards, and restricted CORS headers introduced in the latest commits.

The helper script `scripts/resolve_main_conflicts.sh` performs steps 1–4 automatically (using `origin main` by default) and prints the commit command to run once conflicts are cleared.
