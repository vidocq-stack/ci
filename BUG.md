# BUG — Vidocq CI

Tracking reproducible bugs in the shared CI actions and workflows.
Vidocq workspace convention: short id, date, symptom, minimal repro, cause hypothesis, status.

---

## BUG-20261024-01 — merge-bot waits for checks the branch does not require, and gives up on a green pull request

- **Date**: 2026-10-24
- **Status**: FIXED on `fix/merge-bot-required-checks` (Vidocq/ci#47, found while merging Vidocq/vidocq#340)
- **Symptom**: `/merge` on Vidocq/vidocq#340 failed with `required status checks on 78a6c356 did not succeed within
  30 minutes (last state: pending)`. The two checks `main` requires were green at 16:13:32; the SonarQube analysis,
  which `main` does not require, ended at 16:45:31; the bot gave up at 16:43:56. A second `/merge` merged at once.
- **Minimal repro**: a pull request whose required checks are green while a check outside
  `status_check_contexts` of the base branch stays pending for more than 30 minutes: `/merge` fails.
- **Cause**: `merge-bot/merge.sh` waited for the `state` of `GET /repos/{repo}/commits/{sha}/status`. That combined
  state covers every status of the commit, the SonarQube analysis in report mode included. A failed check the
  branch does not require made the bot refuse a pull request the forge would merge, too.
- **Fix**: the bot reads the required contexts from `GET /repos/{repo}/branches/{base}` (readable with the bot
  token) and waits for those only, matched as glob patterns as the forge does; with no context listed, every
  status counts, as on the forge. `merge-bot/required-checks.py`, tests `merge-bot/required-checks-test.sh`.
