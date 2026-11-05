# BUG — Vidocq CI

Tracking reproducible bugs in the shared CI actions and workflows.
Vidocq workspace convention: short id, date, symptom, minimal repro, cause hypothesis, status.

---

## BUG-20261105-01 — setup-maven reads Maven from a host that drops old versions, and never checks the archive

- **Date**: 2026-11-05
- **Status**: FIXED on `fix/maven-download` (found while reading Vidocq/vidocq's `crac.yml` run 3034, which failed on
  a different download: Azul's, see Vidocq/vidocq BUG.md)
- **Symptom**: `maven-version: 3.9.9`, the README's own example, fails today: `dlcdn.apache.org` answers 404, since
  it serves the current releases only (3.9.16 and 3.10.0 on 2026-11-05). The default 3.9.16 goes the same way when
  3.9.17 comes out, and every job using `setup-maven` or `release-maven` fails at once, in every repository. The
  archive is extracted with no check either: a download cut short shows only as a tar error.
- **Minimal repro**: `curl -sI https://dlcdn.apache.org/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.tar.gz`
  answers 404; `setup-maven` with `maven-version: 3.9.9` fails in its Install Maven step.
- **Cause**: `setup-maven` and `release-maven` each ran `wget -q <dlcdn url>` then `tar -xzf`, from a host that drops
  old versions, with no retry and no integrity check.
- **Fix**: `setup-maven/install-maven.sh <version> <dest-dir>`, used by both actions: Maven Central (every version
  stays there), the archive extracted only once it matches the SHA-512 published next to it, four attempts with a
  growing pause, a malformed version refused before any download. Tests `setup-maven/install-maven-test.sh`
  (offline: `file://` repository and a curl that cuts the first downloads short).

---

## BUG-20261024-02 — merge-bot gives up after 30 minutes, before Vauban's pr-validate ends

- **Date**: 2026-10-24
- **Status**: FIXED on `fix/merge-bot-checks-timeout` (Vidocq/ci#49, found while merging Vidocq/vauban#215)
- **Symptom**: on Vidocq/vauban, `/merge` fails with `required status checks on <sha> did not succeed within
  30 minutes (last state: pending: …)`, though `pr-validate` ends green about 48 minutes in; the pull request merges
  only on a second `/merge`, once the checks are done.
- **Minimal repro**: a pull request whose required `pr-validate` runs longer than 30 minutes: `/merge` fails.
- **Cause**: `merge-bot/merge.sh` polled 360 times with a 5 s sleep, a fixed budget of about 30 minutes for every
  repository, and the job of `merge-bot-reusable.yml` stopped at 45 minutes anyway. Vauban's `pr-validate`
  rebuilds its consumers.
- **Fix**: the budget is on the clock, 60 minutes by default, and configurable from 1 to 80 minutes through the
  `checks-timeout-minutes` input of the action and of the reusable workflow; a bad value is refused before the
  rebase. The job stops at 90 minutes. Tests `merge-bot/checks-timeout-test.sh`.

---

## BUG-20261024-01 — merge-bot waits for checks the branch does not require, and gives up on a green pull request

- **Date**: 2026-10-24
- **Status**: FIXED (Vidocq/ci#47, merged with Vidocq/ci#48; found while merging Vidocq/vidocq#340)
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
