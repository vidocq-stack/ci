# Vidocq CI — shared composite actions

Forgejo/Codeberg composite actions factoring out the repeated CI steps of the Vidocq
sub-projects. **This repo is not a Maven project**: it is never built, tested or published.
It only provides reusable actions consumed via `uses: https://codeberg.org/Vidocq/ci/<action>@<ref>`.

> ⚠️ On Codeberg/Forgejo, reference these actions by **absolute URL**
> (`https://codeberg.org/Vidocq/ci/<action>@main`). A relative `Vidocq/ci/...@main` is resolved
> against the default actions registry (code.forgejo.org), not codeberg.org → 404.

> Repo is **public** on purpose: it holds no secrets, and a public repo means runners do not
> need to authenticate to clone the action from private repos.

## Actions

| Action | Purpose | Notable inputs (all overridable) |
|--------|---------|----------------------------------|
| `setup-maven` | Install Temurin + Maven, put them on the PATH | `java-version` (25), `maven-version` (3.9.16), `distribution` (temurin), `cache` (maven) |
| `run-tck` | Run a Maven TCK, or a custom shell script | `command` (custom shell, wins), `module` (-pl), `profile` (tck), `pre-install` (true), `maven-args` (-B -ntp) |
| `notify-slack` | `[ViBot]` Slack notification | `webhook-url` (required), `status` (success/failure/pr-open/pr-merged/pr-validated/release-success/release-failure), plus repo/ref/run-url and commit/PR/release fields. `dry-run: true` renders a big "🧪 DRY RUN 🧪" Block Kit header so the channel sees at a glance that nothing real happened. |
| `deploy-maven` | settings.xml + GPG import + Central deploy (SNAPSHOT/RELEASE by version) | `central-username`, `central-password`, `gpg-private-key`, `gpg-passphrase`, `snapshot-profile`, `release-profile` |
| `cla-check` | PR-gate: verify the PR author signed the Vidocq CLA (identity-based, one of the 3 checks split out of `governance-checks`) | `pr-author` (required), `slack-webhook` |
| `gpg-check` | PR-gate: verify every PR commit is GPG-signed by a registered contributor key (signature-based — re-evaluate after any merge-bot re-sign) | none (reads `BASE_REF..HEAD` from the checked-out repo) |
| `dco-check` | PR-gate: verify every PR commit carries a `Signed-off-by` trailer (trailer-based, survives a merge-bot re-sign) | none |
| `governance-checks` | ⚠️ Deprecated — bundles `cla-check` + `gpg-check` + `dco-check` into a single job/status-check. Kept for repos not yet migrated to the 3 split actions above. | `pr-author` (required), `slack-webhook` |
| `build-impacted` | PR-only: rebuild the transitive downstream consumers (topological order) against the producer's local PR artifacts — no staging registry | `producer-slug` (required), `producer-version` (required), `version-suffix` (required), `bot-token` (required), `graph-ref` (main), `maven-args` (-B -ntp) |
| `update-dep-graph` | Extract `io.vidocq.*` deps and push them into GestionProjet/data | `bot-token` (required), `repo` (required), `base-url`, `graph-repo`, `branch` |
| `trigger-docs-rebuild` | POST a `workflow_dispatch` to `vidocq-docs/build.yml` so the Antora site is rebuilt & redeployed. Use after a push on `main` that touched `docs/**`. | `bot-token` (required), `source-repo` (required), `base-url`, `docs-repo`, `workflow`, `ref` |
| `merge-bot` | Rebase a PR's head branch onto its base, re-sign every replayed commit with the dedicated CI bot key, force-push, then fast-forward merge. The only way to merge without producing an unsigned commit once `require_signed_commits` is enforced (server-side merge/squash/rebase always strips the original signature — true of Forgejo, GitHub and GitLab alike). | `pr-number` (required), `repo` (required), `bot-token` (required), `git-signing-private-key`/`git-signing-passphrase`/`git-signing-key-id` (required, `secrets.CI_BOT_GPG_*`), `base-url` |

## Examples

```yaml
# Maven 3.9 for a TCK that requires it:
- uses: https://codeberg.org/Vidocq/ci/setup-maven@main
  with: { maven-version: 3.9.9 }
- uses: https://codeberg.org/Vidocq/ci/run-tck@main
  with: { module: my-tck-module }

# Out-of-reactor TCK via a script:
- uses: https://codeberg.org/Vidocq/ci/run-tck@main
  with: { command: "./run-official-tck-restful-4.0.sh all", pre-install: "false" }

# PR validation (single job): build the producer locally at a release-style PR
# version, then rebuild every impacted downstream consumer against it:
- uses: https://codeberg.org/Vidocq/ci/setup-maven@main
- run: mvn -B -ntp install            # producer at <base>-PR<n>.<sha8>, into ~/.m2
- uses: https://codeberg.org/Vidocq/ci/build-impacted@main
  with:
    producer-slug: ${{ github.repository }}
    producer-version: 0.1.0-PR42.abc1234
    version-suffix: PR42.abc1234
    bot-token: ${{ secrets.VIDOCQ_BOT_TOKEN }}

# Trigger vidocq-docs rebuild from a dedicated workflow filtered on docs/**:
# (see notify-docs.yml below — wired into every sub-project)
- uses: https://codeberg.org/Vidocq/ci/trigger-docs-rebuild@main
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
      - uses: https://codeberg.org/Vidocq/ci/trigger-docs-rebuild@main
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
managed at the Codeberg **organisation** level.

## Versioning

- Consumers reference these actions via **`@main`** — the head of the only branch.
- No mobile `@v1` / `@v2` tags. The retag dance was the source of repeated
  desync incidents (silent `git push +refs/tags/v1` failures, a parasite
  `v1` branch shadowing the tag) without ever buying a real freeze: every
  commit on `main` to date has been a bug fix, not a breaking change.
- A consumer that needs to **freeze** at a specific revision pins the SHA
  directly: `uses: https://codeberg.org/Vidocq/ci/<action>@<sha>`.
- If a genuinely incompatible change ever lands, we'll create a one-off
  immutable `vX.Y.Z` semver tag **before** the breaking commit, migrate
  consumers explicitly, and delete the tag once everyone is on the new
  shape. No mobile aliases.
