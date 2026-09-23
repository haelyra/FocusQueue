# Git delivery safety

Use one canonical integration checkout for Focus Queue. It is the configured
project repository whose `origin/main` supplies the install provenance. Treat
all agent worktrees as isolated development lanes, not alternate application
sources. New Focus Queue worktrees live under the ignored
`<repository>/.worktrees/` directory. Recorded legacy worktrees keep their exact
paths until their assignments are safely completed and reconciled.

## Integrate without losing fixes

1. Start each change from a freshly fetched integration commit and make it on an
   owned feature branch.
2. Review the complete branch diff and run the affected workflow plus automated
   checks before committing or requesting a push.
3. Integrate with a pull request or an explicit reviewed merge. Update the
   canonical checkout with a fast-forward-only operation. Never copy one
   worktree over another checkout and never force-push the integration branch.
4. Build and install the shared app only from a clean canonical checkout at the
   exact current `origin/main` revision. Feature worktrees may build for
   verification but must not replace the shared installation.
5. Keep the bundle provenance and installer preflight enabled. A rejected build
   is evidence to correct the source checkout, not a reason to bypass the gate.

Protect `main` on the Git host with pull requests, required Swift and Python
checks, required up-to-date branches, conversation resolution, force-push
blocking, and branch-deletion blocking. Restrict bypass to an emergency owner
and keep the audit log. Local `review-push` and signed provenance are additional
guards, not substitutes for server-side protection.

## Recovery check

When a fix appears missing, compare commit ancestry and patch identity before
editing. Inspect the remote push chain, local reflogs, all linked worktree refs,
task logs, the installed bundle's source provenance, and hashes of shipped
helpers. Recover only changes that are not already patch-equivalent or
superseded, then add a regression test that fails on the current integration
revision. Preserve dirty worktrees and unknown history for review.
