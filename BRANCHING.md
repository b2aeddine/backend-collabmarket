# Branching notes

- The repository now uses `main` as the primary branch (renamed from the previous `work` branch).
- All recent Stripe webhook fixes and CORS restrictions are already included on `main`.
- To publish to GitHub, add your remote (for example, `git remote add origin git@github.com:<owner>/<repo>.git`) and push with `git push -u origin main`.
- If another remote branch already exists, fetch it first and reconcile differences with `git fetch origin` and `git merge origin/main` before pushing to avoid conflicts.
