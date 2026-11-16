# BUG — Vidocq CI

Tracking reproducible bugs in the shared CI actions and workflows.
Vidocq workspace convention: short id, date, symptom, minimal repro, cause hypothesis, status.

---

## BUG-20261116-02 — Infer gives no result on three runners out of five, and the pull request's SonarQube comment does not say so

- **Date**: 2026-11-16
- **Status**: FIXED on `fix/infer-without-result` (Vidocq/ci#120; found while checking what BUG-20261116-01 left as
  is). The runners themselves are not changed: see "Left as is".
- **Symptom**: Chappe and Foy ask for Infer (`infer: 'true'`). Vidocq/chappe pull request run 729 (runner `ababeffb`,
  job image `node:20-bookworm`, `linux/amd64`) logs `::warning::Infer does not run here: [...] version
  `GLIBC_2.38' not found`, ends green, and its comment has no word of Infer. The push analysis of the same commit (run
  733, runner `6c935f1a`, job image `node:24.22.1-trixie`) logs `Infer: 7 module(s), 0 finding(s), 0 kept`.
- **Minimal repro**: `bash sonar-analysis/infer.sh` where the release cannot start (a glibc older than 2.38, or an
  arm64 machine): one warning, exit status 0. Offline: `bash sonar-analysis/infer-test.sh` on the script before the
  fix (22 checks fail).
- **Cause**: `infer.sh` ended with status 0 on every path where Infer gave no result, so the action had nothing to
  tell the quality-gate step. And Infer cannot run on three of the five runners seen on 2026-11-16: `ababeffb` and
  `9d388c1b` run their jobs in `node:20-bookworm` (glibc 2.36; observed on the first, same image on the second), and
  `f924a289` is arm64, for which Infer 1.3.0, its latest release, has no Linux asset (`infer-linux-x86_64` and
  `infer-osx-arm64` only; not observed in a log, no sonar job of Chappe or Foy was found on that runner).
- **Fix**: `infer.sh` ends with status 3 when Infer gave no result and writes `SONAR_INFER_NOT_RUN=true` for the
  quality-gate step: the pull-request comment says "Infer without a result", the log holds one warning, and that
  analysis is not recorded for reuse. The architecture is asked before the download: nothing is downloaded (276 MB)
  where no release exists. A reactor without a main source is still status 0. Tests `sonar-analysis/infer-test.sh`
  (offline: `uname`, `curl`, `sha256sum`, `mvn` and Infer are stubs).
- **Left as is**: the runners. Until they run their jobs in one image, a pull request of Chappe or Foy gets an Infer
  result from two runners out of five, and the comment asks for a re-run on the others (Vidocq/ci#121). The push
  analysis of `main` has no comment: only the warning of its log says that Infer did not run. Whether SonarQube closes
  Infer's issues of `main` after such an analysis, and opens them again after the next one, was not checked.

---

## BUG-20261116-01 — No security scan runs on the arm64 runner, and the pull request's SonarQube comment stays green

- **Date**: 2026-11-16
- **Status**: FIXED on `fix/security-scans-arm64` (Vidocq/ci#118; found while reading why `main` of Vidocq/vidocq
  turned red right after a pull request with a green SonarQube comment)
- **Symptom**: Vidocq/vidocq#625 got "✅ passed, New issues: 0" (sonar run 4771) and was merged; the push analyses of
  `main` that followed (runs 4783 and 4814) have a quality gate in error, on two OpenGrep findings in the code that
  pull request added. The log of run 4771 says, for each of the three tools, `security-scans.sh: line 78:
  /tmp/vidocq-security/bin/osv-scanner: cannot execute binary file: Exec format error` then `::warning::OSV-Scanner
  failed (exit 126)`, and ends on `Reports handed to SonarQube: none`. The same lines are in Vidocq/vidocq run 4832 and
  Vidocq/vauban run 2204. The job container of those three runs is `platform=linux/arm64`; runs 4783, 4814 and 4825, on
  `platform=linux/amd64`, scan (`opengrep: 21 finding(s)`).
- **Minimal repro**: `bash sonar-analysis/security-scans.sh` on an arm64 Linux machine: the three tools end with exit
  126 and the script hands no report over. Offline: `bash sonar-analysis/security-scans-test.sh` on the script before
  the fix asks for the amd64 assets under `uname -m` = `aarch64`.
- **Cause**: `security-scans.sh` downloaded the amd64 asset of each tool on every runner (`osv-scanner_linux_amd64`,
  `opengrep_manylinux_x86`, `trivy_<version>_Linux-64bit.tar.gz`), and one shared runner is arm64. A scan that fails is
  reported in the log and skipped, by design, so the analysis went on; nothing of it reached the quality-gate step,
  whose comment read the same as when the scans ran and found nothing.
- **Fix**: the asset and its SHA-256 by the machine's architecture (`uname -m`: amd64 or arm64; any other runs no scan
  and says so). The arm64 checksums are those GitHub computes for the release assets, equal to the ones OSV-Scanner
  and Trivy publish (`osv-scanner_SHA256SUMS`, `trivy_0.75.0_checksums.txt`); OpenGrep publishes signatures only. The
  script hands the scans without a result to the quality-gate step (`SONAR_SCANS_NOT_RUN`): the pull-request comment
  names them, the log holds one warning, and that analysis is not recorded for reuse, so the next run of the same code
  scans again. Tests `sonar-analysis/security-scans-test.sh` (offline: `uname`, `curl` and `sha256sum` are stubs).
- **Left as is**: `sonar-analysis/infer.sh` pinned `infer-linux-x86_64` too and only said "Infer does not run here"
  in the log: BUG-20261116-02 since. An analysis recorded before the fix by a run whose scans did not execute can
  still be reused by a later push of the same code tree; a re-run of the job always analyses again.

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
