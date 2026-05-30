# `release-maven` — Maven Central release orchestrator

Composite action that drives a full Maven Central release for a Vidocq sub-project
end-to-end, with **no human intervention during the job**:

1. Locks every `io.vidocq.*` SNAPSHOT (parent + inter-project deps) to the
   release versions supplied via the `overrides` input.
2. Fails fast (with a clear list) if any `io.vidocq.*` SNAPSHOT remains
   unresolved.
3. Commits the lock back to `main`.
4. Runs `mvn release:prepare release:perform` with `releaseProfiles=release`,
   which uploads a signed bundle through `central-publishing-maven-plugin`.
5. Blocks until every deployable module's `.pom` is visible on
   `repo1.maven.org` (poll, default timeout 60 min). The bundle must therefore
   use `<autoPublish>true</autoPublish>` (configured in `vidocq-parent`).

## Caller responsibilities

The workflow that uses this action must:

- `actions/checkout@v4` **with `fetch-depth: 0` and `token: secrets.VIDOCQ_BOT_TOKEN`**
  (needed to push the release tag + lock + bump commits back to `main`).
- Be triggered on `workflow_dispatch` and pass the inputs documented below.
- Run on a clean `main` branch (the action refuses to proceed otherwise).

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `release-version` | ✅ | — | e.g. `1.0.0`, `0.1.0`. Must not end with `-SNAPSHOT`. |
| `next-dev-version` | ✅ | — | e.g. `0.2.0`. The script auto-appends `-SNAPSHOT` (a value already ending with `-SNAPSHOT` is kept as-is for backward compatibility). |
| `overrides` | ❌ | `''` | Multiline. Each line is either `groupId=version` (the whole upstream "family" — recommended) or `groupId:artifactId=version` (narrow override). The script auto-patches `<version>` elements and properties (`${X.version}`) alike. Empty for `vidocq-parent`. |
| `central-username` | ✅ | — | `secrets.CENTRAL_USERNAME` |
| `central-password` | ✅ | — | `secrets.CENTRAL_PASSWORD` |
| `gpg-private-key` | ✅ | — | `secrets.GPG_PRIVATE_KEY` (base64 or ASCII-armored) |
| `gpg-passphrase` | ✅ | — | `secrets.GPG_PASSPHRASE` |
| `gpg-key-id` | ✅ | — | `secrets.GPG_KEY_ID` (long key id) |
| `bot-name` | ❌ | `Vidocq CI Bot` | Git author for lock + bump commits |
| `bot-email` | ❌ | `ci@vidocq.dev` | Git author email |
| `release-profile` | ❌ | `release` | Profile activated during `release:perform` |
| `wait-timeout-seconds` | ❌ | `3600` | Max seconds to wait for Central propagation |
| `wait-interval-seconds` | ❌ | `60` | Polling interval |

## Example — `vidocq-parent` (no inter-project deps)

```yaml
# vidocq-parent/.forgejo/workflows/release.yml
name: release
on:
  workflow_dispatch:
    inputs:
      release_version:    { description: "e.g. 1.0.0",            required: true }
      next_dev_version:   { description: "e.g. 1.1.0-SNAPSHOT",   required: true }

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: ${{ secrets.VIDOCQ_BOT_TOKEN }}
      - uses: https://codeberg.org/Vidocq/ci/release-maven@v1
        with:
          release-version:  ${{ inputs.release_version }}
          next-dev-version: ${{ inputs.next_dev_version }}
          central-username: ${{ secrets.CENTRAL_USERNAME }}
          central-password: ${{ secrets.CENTRAL_PASSWORD }}
          gpg-private-key:  ${{ secrets.GPG_PRIVATE_KEY }}
          gpg-passphrase:   ${{ secrets.GPG_PASSPHRASE }}
          gpg-key-id:       ${{ secrets.GPG_KEY_ID }}
```

## Example — `vauban` (depends on `vidocq-parent`)

```yaml
# vauban/.forgejo/workflows/release.yml
name: release
on:
  workflow_dispatch:
    inputs:
      release_version:  { description: "e.g. 0.1.0",          required: true }
      next_dev_version: { description: "Next dev version WITHOUT -SNAPSHOT (e.g. 0.2.0)", required: true }
      parent_release:   { description: "io.vidocq:vidocq-parent stable version (must be on Central)", required: true }

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: ${{ secrets.VIDOCQ_BOT_TOKEN }}
      - uses: https://codeberg.org/Vidocq/ci/release-maven@v1
        with:
          release-version:  ${{ inputs.release_version }}
          next-dev-version: ${{ inputs.next_dev_version }}
          overrides: |
            io.vidocq=${{ inputs.parent_release }}
          central-username: ${{ secrets.CENTRAL_USERNAME }}
          central-password: ${{ secrets.CENTRAL_PASSWORD }}
          gpg-private-key:  ${{ secrets.GPG_PRIVATE_KEY }}
          gpg-passphrase:   ${{ secrets.GPG_PASSPHRASE }}
          gpg-key-id:       ${{ secrets.GPG_KEY_ID }}
```

## Topological release order

The action will fail-fast if an upstream isn't released yet. Suggested order:

| Wave | Projects | `overrides` you must pass |
|---|---|---|
| 0 | `vidocq-parent` | (none) |
| 1 | `chappe`, `vauban`, `champollion`, `ravel` | `io.vidocq=…` |
| 2a | `knock`, `heisenberg` | `io.vidocq.vauban=…`, `io.vidocq.ravel=…` |
| 2b | `foy`, `cassini`, `cervantes`, `dirac`, `humboldt`, `grimm` | their level-1 deps |
| 3 | `cyrano`, `mansart` | their level-1 + level-2 deps |
| 4 | `vidocq` | everything below |

Wait for each wave's wait-for-Central step to succeed before triggering the
next — the action does this implicitly per job, so you only need to start the
next workflow when the previous green-passed.

## Required `vidocq-parent` configuration

For the bundle to actually publish without a human clicking, `vidocq-parent`
must declare `<autoPublish>true</autoPublish>` on the
`central-publishing-maven-plugin`. With `false`, the `release:perform` succeeds
but the bundle stays in state `VALIDATED` on `central.sonatype.com/publishing`
and the wait-for-Central step polls until timeout.

## Gotchas

- **Working tree must be clean on `main`.** Stash/commit local changes first.
- **`gpg-key-id` is the long key id** (the 40-hex fingerprint or the last 16
  hex of it). Used as `-Dgpg.keyname=` so Maven picks the right key when the
  keyring has several.
- **The `overrides` are applied across every `pom.xml` recursively** (including
  `dependencyManagement`), via a namespace-aware Python parser. Sub-modules
  inheriting the version via property still need the property bump — supply
  the override anyway, the scanner will surface the leak otherwise.
- **`release.sh` self-references**: when a module's own `<version>` is
  `X-SNAPSHOT`, it is *not* an override target; `maven-release-plugin` handles
  the project version bump itself.
- **Slack notifications** are not emitted by this action. Wire them in the
  caller workflow with `Vidocq/ci/notify-slack@v1` on `if: success()`/`failure()`
  if you want them on release runs too.
