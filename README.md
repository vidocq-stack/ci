# Vidocq CI — shared composite actions

Forgejo (Codefloe) composite actions factoring out the repeated CI steps of the Vidocq
sub-projects. **This repo is not a Maven project**: it is never built or published.
It only provides reusable actions consumed via `uses: https://codefloe.com/Vidocq/ci/<action>@<ref>`.
The tests of the actions' scripts (`<action>/*-test.sh`) run on each pull request (`action-tests`).

> ⚠️ On Forgejo (Codefloe), reference these actions by **absolute URL**
> (`https://codefloe.com/Vidocq/ci/<action>@main`). A relative `Vidocq/ci/...@main` is resolved
> against the default actions registry (code.forgejo.org), not codefloe.com → 404.

> Repo is **public** on purpose: it holds no secrets, and a public repo means runners do not
> need to authenticate to clone the action from private repos.

## Actions

| Action | Purpose | Notable inputs (all overridable) |
|--------|---------|----------------------------------|
| `setup-maven` | Install Temurin + Maven, put them on the PATH. **Temporarily** also gives Maven, through `MAVEN_OPTS`, a trust store without the roots that the compromised eMudhra intermediate CAs chain to (keys leaked on 2026-10-20, [Vidocq/vidocq#292](https://codefloe.com/Vidocq/vidocq/issues/292)), until Temurin ships a JDK that refuses them. The JDK itself stays untouched: jlink refuses a modified JDK that has no jmods. `setup-maven/block-emudhra-intermediates.sh <java-home> <trust-store>` builds the same trust store on a maintainer machine. The Maven cache is `actions/cache` on `~/.m2/repository`, with the key `m2-<os>-<repository>-<hash of every pom.xml>`, falling back to the newest cache of the same repository, then of any repository; an exact hit is not saved again. It replaces setup-java's own cache, which saved the whole repository again after every job (its restore and save keys differ in case). Artifacts installed at a pull-request version (`io/vidocq/**/<version>-PR<n>.<sha>`) are left out of the saved cache through GNU tar's `TAR_OPTIONS` on that step: `actions/cache` ignores a `!` pattern under a directory it archives whole. | `java-version` (25), `maven-version` (3.9.16), `distribution` (temurin), `cache` (maven: the cache above; another value such as gradle goes to setup-java's cache; empty: no cache) |
| `run-tck` | Run a Maven TCK, or a custom shell script | `command` (custom shell, wins), `module` (-pl), `profile` (tck), `pre-install` (true), `maven-args` (-B -ntp) |
| `notify-slack` | `[ViBot]` Slack notification | `webhook-url` (required), `status` (success/failure/pr-open/pr-merged/pr-validated/release-success/release-failure), plus repo/ref/run-url and commit/PR/release fields. `dry-run: true` renders a big "🧪 DRY RUN 🧪" Block Kit header so the channel sees at a glance that nothing real happened. |
| `deploy-maven` | settings.xml + GPG import + Central deploy (SNAPSHOT/RELEASE by version) | `central-username`, `central-password`, `gpg-private-key`, `gpg-passphrase`, `snapshot-profile`, `release-profile` |
| `cla-check` | PR-gate: verify the PR author signed the Vidocq CLA (identity-based, one of the 3 checks split out of `governance-checks`) | `pr-author` (required), `slack-webhook` |
| `gpg-check` | PR-gate: verify every PR commit is GPG-signed by a registered contributor key (signature-based — re-evaluate after any merge-bot re-sign) | none (reads `BASE_REF..HEAD` from the checked-out repo) |
| `dco-check` | PR-gate: verify every PR commit carries a `Signed-off-by` trailer (trailer-based, survives a merge-bot re-sign) | none |
| `governance-checks` | ⚠️ Deprecated — bundles `cla-check` + `gpg-check` + `dco-check` into a single job/status-check. Kept for repos not yet migrated to the 3 split actions above. | `pr-author` (required), `slack-webhook` |
| `build-impacted` | PR-only: rebuild the transitive downstream consumers (topological order) against the producer's local PR artifacts — no staging registry. A consumer that has a branch named like the PR's head branch (a *companion branch*, for a change spanning several repos) is rebuilt on it instead of on its default branch; only for a PR from a branch of the producer repo, never from a fork. The log names the branch of each consumer, and a notice lists the consumers rebuilt on a companion branch. Workflow: `vidocq-workspace/docs/changes-across-repositories.md`. Before resolving the consumers, it checks that the graph (`graph/inverted.json`, its `generated_at`) is not older than the producer's data file (its `updated_at`): a stale graph may not know every consumer, so the rebuild would check too few repositories without saying so. With `require-fresh-graph: true` a stale graph fails the job, otherwise it is a warning (`build-impacted/graph-freshness.py`). In each consumer, the versions of the upstreams already rebuilt are pinned in one pass without starting Maven (`build-impacted/pin-upstreams.py`): the same edits as one `versions:set-property` per upstream, in the poms of the default reactor only (profiles evaluated as Maven does), and only the project property itself. When the script cannot tell exactly what Maven would do (a profile activated by the JDK, the OS or a file, a pinned property defined in a profile...), it changes nothing and the job falls back to `versions:set-property`, with a warning. The consumer builds rerun a failing test once (surefire and failsafe, through the default `maven-args`; never the producer's own build): a test that then passes does not fail the pull request, and the next step turns each "Flakes:" entry of the consumer logs into a `::warning::` and a row of the job summary naming the consumer, the module and the test, so that it gets a `BUG.md` entry in that repository (`build-impacted/flakes.py`). | `producer-slug` (required), `producer-version` (required), `version-suffix` (required), `bot-token` (required), `graph-ref` (main), `maven-args` (-B -ntp -Dsurefire.rerunFailingTestsCount=1 -Dfailsafe.rerunFailingTestsCount=1; a value given replaces the whole default), `companion-branches` (true), `require-fresh-graph` (true; the dependency graph is rebuilt with every data update since Vidocq/dep-graph#3) |
| `update-dep-graph` | Extract `io.vidocq.*` deps and push them into GestionProjet/data | `bot-token` (required), `repo` (required), `base-url`, `graph-repo`, `branch` |
| `trigger-docs-rebuild` | POST a `workflow_dispatch` to `vidocq-docs/build.yml` so the Antora site is rebuilt & redeployed. Use after a push on `main` that touched `docs/**`. | `bot-token` (required), `source-repo` (required), `base-url`, `docs-repo`, `workflow`, `ref` |
| `sonar-analysis` | SonarQube analysis of the Maven build on `sonar.vidocq.dev` (community branch plugin): `main` on push, a pull request with its own quality gate. Report mode by default: never fails the job, and keeps one comment on the pull request up to date with the gate. Skipped when the token is empty (pull requests from forks). The project is created on the server when missing, so the same workflow works unchanged in every repository. The build also writes a CycloneDX SBOM; between the build and the analysis, OSV-Scanner checks that SBOM for known vulnerabilities in the dependencies the build ships, OpenGrep looks for security patterns (community rules at a pinned commit) and Trivy for leaked secrets and Dockerfile misconfigurations, offline. None of them sends a request to Maven Central. Their SARIF reports become external issues in SonarQube, minus the findings of modules SonarQube does not analyse. Each tool is a pinned release checked by SHA-256 (`sonar-analysis/security-scans.sh`), and a scan that fails never stops the analysis. When `maven-args` runs a repository's Error Prone profile, in report mode, the warnings Error Prone writes in the build log become external issues too, as reliability issues through SonarQube's generic format, since a SARIF import counts every result as a vulnerability (`sonar-analysis/errorprone-sarif.py`, `sonar-analysis/sarif-to-generic.py`). A module whose build runs japicmp gets its API compatibility with the last release summarised in the log and in one more pull-request comment (`sonar-analysis/api-compat-comment.py`), report mode. With `infer: true`, Infer's RacerD looks for data races in the main sources, captured with javac module by module (Infer's Maven integration recompiles with `-source 11`), and its findings become reliability issues the same way (`sonar-analysis/infer.sh`). | `sonar-token` (required, `secrets.SONAR_TOKEN`), `host-url` (required, `vars.SONAR_HOST_URL`), `project-key` (`vidocq-<repository>`), `bot-token` (PR comment, `secrets.VIDOCQ_BOT_TOKEN`), `maven-args` (-B -ntp -Pquality -Dmaven.test.failure.ignore=true install: a failing test does not stop the analysis, the pull request validation is the test gate; install puts the modules in the job's local repository for the separate analysis run; add `errorprone` to the profiles for Error Prone's findings), `analysis-args` (-B -ntp -Pquality), `cyclonedx-version`, `scanner-version`, `blocking` (false), `security-scans` (true), `infer` (false: it downloads Infer, 276 MB) |
| `merge-bot` | Rebase a PR's head branch onto its base, re-sign every replayed commit with the dedicated CI bot key, force-push, then fast-forward merge. The only way to merge without producing an unsigned commit once `require_signed_commits` is enforced (server-side merge/squash/rebase always strips the original signature — true of Forgejo, GitHub and GitLab alike). | `pr-number` (required), `repo` (required), `bot-token` (required), `git-signing-private-key`/`git-signing-passphrase`/`git-signing-key-id` (required, `secrets.CI_BOT_GPG_*`), `base-url` |
| `bench-report` | Pilot, not an action yet: scripts that turn raw benchmark output into a `results.json` and into the generated sections of a Performance page, with Vega-Lite charts drawn by Kroki at docs build time (workspace ADR 0001). See `bench-report/README.md`. | — |
| `bench-window` | Opens and closes the benchmark window of macuntu through the Portainer API: stops the CI runners once their jobs end, sets the CPU governor and turbo, and puts everything back (workspace ADR 0001). A script, run by the bench workflow | `PORTAINER_URL`, `PORTAINER_TOKEN`, `BENCH_RUNNERS`, `BENCH_GRACE` |

## Examples

```yaml
# Maven 3.9 for a TCK that requires it:
- uses: https://codefloe.com/Vidocq/ci/setup-maven@main
  with: { maven-version: 3.9.9 }
- uses: https://codefloe.com/Vidocq/ci/run-tck@main
  with: { module: my-tck-module }

# SonarQube analysis in report mode (needs fetch-depth: 0 on the checkout, for the
# new-code detection), in a workflow triggered on push to main and on pull_request:
- uses: actions/checkout@v4
  with: { fetch-depth: 0 }
- uses: https://codefloe.com/Vidocq/ci/setup-maven@main
- uses: https://codefloe.com/Vidocq/ci/sonar-analysis@main
  with:
    sonar-token: ${{ secrets.SONAR_TOKEN }}
    host-url: ${{ vars.SONAR_HOST_URL }}
    bot-token: ${{ secrets.VIDOCQ_BOT_TOKEN }}

# Out-of-reactor TCK via a script:
- uses: https://codefloe.com/Vidocq/ci/run-tck@main
  with: { command: "./run-official-tck-restful-4.0.sh all", pre-install: "false" }

# PR validation (single job): build the producer locally at a release-style PR
# version, then rebuild every impacted downstream consumer against it:
- uses: https://codefloe.com/Vidocq/ci/setup-maven@main
- run: mvn -B -ntp install            # producer at <base>-PR<n>.<sha8>, into ~/.m2
- uses: https://codefloe.com/Vidocq/ci/build-impacted@main
  with:
    producer-slug: ${{ github.repository }}
    producer-version: 0.1.0-PR42.abc1234
    version-suffix: PR42.abc1234
    bot-token: ${{ secrets.VIDOCQ_BOT_TOKEN }}

# Trigger vidocq-docs rebuild from a dedicated workflow filtered on docs/**:
# (see notify-docs.yml below — wired into every sub-project)
- uses: https://codefloe.com/Vidocq/ci/trigger-docs-rebuild@main
  with:
    bot-token: ${{ secrets.VIDOCQ_BOT_TOKEN }}
    source-repo: ${{ github.repository }}
```

### Per-repo wiring — `pr.yml` governance gate (split checks)

3 independent status checks, replacing the single `governance-checks` job.
Migrating a repo means updating this job list AND its branch-protection
`status_check_contexts` (`pr-validate / cla-check (pull_request)`, `pr-validate
/ gpg-check (pull_request)`, `pr-validate / dco-check (pull_request)` instead
of `pr-validate / governance-checks (pull_request)`).

```yaml
name: pr-validate
on:
  pull_request:
    branches: [main]

jobs:
  cla-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: https://codefloe.com/Vidocq/ci/cla-check@main
        with:
          pr-author: ${{ github.event.pull_request.user.login }}
          slack-webhook: ${{ secrets.SLACK_WEBHOOK_URL }}

  gpg-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: https://codefloe.com/Vidocq/ci/gpg-check@main

  dco-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: https://codefloe.com/Vidocq/ci/dco-check@main
```

### Per-repo wiring — `notify-docs.yml`

Add this workflow once per sub-project. It fires only when a `main` push touches
`docs/**` and dispatches `vidocq-docs/build.yml` — no other CI overhead.

```yaml
name: Notify docs

on:
  push:
    branches: [main]
    paths:
      - 'docs/**'

jobs:
  notify-docs:
    runs-on: ubuntu-latest
    steps:
      - uses: https://codefloe.com/Vidocq/ci/trigger-docs-rebuild@main
        with:
          bot-token: ${{ secrets.VIDOCQ_BOT_TOKEN }}
          source-repo: ${{ github.repository }}
```

### Per-repo wiring — `merge-bot.yml`

Add this workflow once per sub-project to enable a `/merge` PR comment command.
Requires `require_signed_commits` (org default) and the `CI_BOT_GPG_*` org
secrets (key registered in `Vidocq/governance/.forgejo/keys/vidocq-ci-bot.asc`).
Only commenters with `write`/`admin` access trigger a merge; anyone else's
comment is ignored by the permission check.

```yaml
name: merge-bot

on:
  issue_comment:
    types: [created]

jobs:
  merge:
    if: >-
      github.event.issue.pull_request != null &&
      contains(github.event.comment.body, '/merge')
    runs-on: ubuntu-latest
    steps:
      - name: Require write access
        env:
          BOT_TOKEN: ${{ secrets.VIDOCQ_BOT_TOKEN }}
          ACTOR: ${{ github.event.comment.user.login }}
        run: |
          set -euo pipefail
          level=$(curl -fsS -H "Authorization: token $BOT_TOKEN" \
            "https://codefloe.com/api/v1/repos/${{ github.repository }}/collaborators/${ACTOR}/permission" \
            | python3 -c 'import sys,json; print(json.load(sys.stdin).get("permission",""))')
          [[ "$level" == "admin" || "$level" == "write" ]] \
            || { echo "::error::@${ACTOR} lacks write access — refusing /merge"; exit 1; }

      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: ${{ secrets.VIDOCQ_BOT_TOKEN }}

      - uses: https://codefloe.com/Vidocq/ci/merge-bot@main
        with:
          pr-number: ${{ github.event.issue.number }}
          repo: ${{ github.repository }}
          bot-token: ${{ secrets.VIDOCQ_BOT_TOKEN }}
          git-signing-private-key: ${{ secrets.CI_BOT_GPG_PRIVATE_KEY }}
          git-signing-passphrase: ${{ secrets.CI_BOT_GPG_PASSPHRASE }}
          git-signing-key-id: ${{ secrets.CI_BOT_GPG_KEY_ID }}

      - name: Comment on failure
        if: failure()
        env:
          BOT_TOKEN: ${{ secrets.VIDOCQ_BOT_TOKEN }}
        run: |
          curl -fsS -X POST -H "Authorization: token $BOT_TOKEN" -H "Content-Type: application/json" \
            -d '{"body":"❌ merge-bot failed — see the Actions run log for details."}' \
            "https://codefloe.com/api/v1/repos/${{ github.repository }}/issues/${{ github.event.issue.number }}/comments"
```

## Secrets

A composite action **does not inherit** `secrets.*`: they must be passed explicitly via
`with:` (mapped to `inputs`, then re-exported as `env:` inside the steps). Secrets stay
managed at the Codefloe **organisation** level.

## Versioning

- Consumers reference these actions via **`@main`** — the head of the only branch.
- No mobile `@v1` / `@v2` tags. The retag dance was the source of repeated
  desync incidents (silent `git push +refs/tags/v1` failures, a parasite
  `v1` branch shadowing the tag) without ever buying a real freeze: every
  commit on `main` to date has been a bug fix, not a breaking change.
- A consumer that needs to **freeze** at a specific revision pins the SHA
  directly: `uses: https://codefloe.com/Vidocq/ci/<action>@<sha>`.
- If a genuinely incompatible change ever lands, we'll create a one-off
  immutable `vX.Y.Z` semver tag **before** the breaking commit, migrate
  consumers explicitly, and delete the tag once everyone is on the new
  shape. No mobile aliases.
