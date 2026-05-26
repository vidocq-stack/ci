# Vidocq CI — shared composite actions

Forgejo/Codeberg composite actions factoring out the repeated CI steps of the Vidocq
sub-projects. **This repo is not a Maven project**: it is never built, tested or published.
It only provides reusable actions consumed via `uses: https://codeberg.org/Vidocq/ci/<action>@<ref>`.

> ⚠️ On Codeberg/Forgejo, reference these actions by **absolute URL**
> (`https://codeberg.org/Vidocq/ci/<action>@v1`). A relative `Vidocq/ci/...@v1` is resolved
> against the default actions registry (code.forgejo.org), not codeberg.org → 404.

> Repo is **public** on purpose: it holds no secrets, and a public repo means runners do not
> need to authenticate to clone the action from private repos.

## Actions

| Action | Purpose | Notable inputs (all overridable) |
|--------|---------|----------------------------------|
| `setup-maven` | Install Temurin + Maven, put them on the PATH | `java-version` (25), `maven-version` (4.0.0-rc-5), `distribution` (temurin), `cache` (maven) |
| `run-tck` | Run a Maven TCK, or a custom shell script | `command` (custom shell, wins), `module` (-pl), `profile` (tck), `pre-install` (true), `maven-args` (-B -ntp) |
| `notify-slack` | `[ViBot]` Slack notification | `webhook-url` (required), `status` (success/failure/pr-open/pr-merged/pr-validated), plus repo/ref/run-url and commit/PR fields |
| `deploy-maven` | settings.xml + GPG import + Central deploy (SNAPSHOT/RELEASE by version) | `central-username`, `central-password`, `gpg-private-key`, `gpg-passphrase`, `snapshot-profile`, `release-profile` |
| `build-impacted` | PR-only: rebuild the transitive downstream consumers (topological order) against the producer's local PR artifacts — no staging registry | `producer-slug` (required), `producer-version` (required), `version-suffix` (required), `bot-token` (required), `graph-ref` (main), `maven-args` (-B -ntp) |
| `update-dep-graph` | Extract `io.vidocq.*` deps and push them into GestionProjet/data | `bot-token` (required), `repo` (required), `base-url`, `graph-repo`, `branch` |

## Examples

```yaml
# Maven 3.9 for a TCK that requires it:
- uses: https://codeberg.org/Vidocq/ci/setup-maven@v1
  with: { maven-version: 3.9.9 }
- uses: https://codeberg.org/Vidocq/ci/run-tck@v1
  with: { module: my-tck-module }

# Out-of-reactor TCK via a script:
- uses: https://codeberg.org/Vidocq/ci/run-tck@v1
  with: { command: "./run-official-tck-restful-4.0.sh all", pre-install: "false" }

# PR validation (single job): build the producer locally at a release-style PR
# version, then rebuild every impacted downstream consumer against it:
- uses: https://codeberg.org/Vidocq/ci/setup-maven@v1
- run: mvn -B -ntp install            # producer at <base>-PR<n>.<sha8>, into ~/.m2
- uses: https://codeberg.org/Vidocq/ci/build-impacted@v1
  with:
    producer-slug: ${{ github.repository }}
    producer-version: 0.1.0-PR42.abc1234
    version-suffix: PR42.abc1234
    bot-token: ${{ secrets.VIDOCQ_BOT_TOKEN }}
```

## Secrets

A composite action **does not inherit** `secrets.*`: they must be passed explicitly via
`with:` (mapped to `inputs`, then re-exported as `env:` inside the steps). Secrets stay
managed at the Codeberg **organisation** level.

## Versioning

- Reference a **mobile tag `@v1`** (re-pointed on each backward-compatible change).
- Pin `@vX.Y.Z` for a repo that wants to freeze.
- Breaking change → `v2`, migrate repo by repo.
- `@main` is reserved for validation phases (pilot).
