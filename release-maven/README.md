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
6. After a real release, opens one pull request per direct consumer of the dependency graph that
   moves `<this brick>.version` to the new dev SNAPSHOT (see "Aligning the consumers" below).

## Caller responsibilities

The workflow that uses this action must:

- `actions/checkout@v4` **with `fetch-depth: 0` and `token: secrets.VIDOCQ_BOT_TOKEN`**
  (needed to push the release tag + lock + bump commits back to `main`).
- Be triggered on `workflow_dispatch` and pass the inputs documented below.
- Run on a clean `main` branch (the action refuses to proceed otherwise).

## Blocking the release of a project

A project that must not be released yet commits a `.forgejo/release-blocked` file on `main`.
Its content is free text: say why, and link the issue that tracks the decision.

- A real run stops in the pre-checks, before any branch, tag, push or upload, and prints the
  content of the file.
- A dry run (`dry-run: true`) goes on, since it publishes nothing: the project can still rehearse
  its release.

The guard lives in the action, not in the caller's `release.yml`: `bootstrap-workflows.sh` and the
`refresh-release-yml` workflow rewrite that file, and would drop a guard written in it. To allow
the release again, delete the file in the pull request that prepares the release.

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
| `git-signing-private-key` | ❌ | `''` | `secrets.CI_BOT_GPG_PRIVATE_KEY` — dedicated key (separate from `gpg-private-key`) used to GPG-sign the release/bump commits themselves. Unset → those commits are pushed unsigned, which fails branch protection on repos with `require_signed_commits`. |
| `git-signing-passphrase` | ❌ | `''` | `secrets.CI_BOT_GPG_PASSPHRASE` |
| `git-signing-key-id` | ❌ | `''` | `secrets.CI_BOT_GPG_KEY_ID` (long key id) |
| `release-profile` | ❌ | `release` | Profile activated during `release:perform` |
| `wait-timeout-seconds` | ❌ | `3600` | Max seconds to wait for Central propagation |
| `wait-interval-seconds` | ❌ | `60` | Polling interval |
| `java-setup` | ❌ | `true` | `false` skips the Temurin install and uses the JDK of the runner image (its `JAVA_HOME`). For a release that needs a JDK Temurin does not ship: `vidocq` runs on the `crac` runner (Azul Zulu CRaC, `jdk.crac`) with `release-profile: release,crac`, so the CRaC extension is built and published with the rest. |

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
      - uses: https://codefloe.com/Vidocq/ci/release-maven@v1
        with:
          release-version:  ${{ inputs.release_version }}
          next-dev-version: ${{ inputs.next_dev_version }}
          central-username: ${{ secrets.CENTRAL_USERNAME }}
          central-password: ${{ secrets.CENTRAL_PASSWORD }}
          gpg-private-key:  ${{ secrets.GPG_PRIVATE_KEY }}
          gpg-passphrase:   ${{ secrets.GPG_PASSPHRASE }}
          gpg-key-id:       ${{ secrets.GPG_KEY_ID }}
          git-signing-private-key: ${{ secrets.CI_BOT_GPG_PRIVATE_KEY }}
          git-signing-passphrase:  ${{ secrets.CI_BOT_GPG_PASSPHRASE }}
          git-signing-key-id:      ${{ secrets.CI_BOT_GPG_KEY_ID }}
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
      - uses: https://codefloe.com/Vidocq/ci/release-maven@v1
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
          git-signing-private-key: ${{ secrets.CI_BOT_GPG_PRIVATE_KEY }}
          git-signing-passphrase:  ${{ secrets.CI_BOT_GPG_PASSPHRASE }}
          git-signing-key-id:      ${{ secrets.CI_BOT_GPG_KEY_ID }}
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

## Aligning the consumers after a release

The post-release commit moves the brick's own version to `<next-dev-version>-SNAPSHOT`, but nothing
used to move the `<brick>.version` properties of its consumers: they kept the SNAPSHOT of the line
just released (`0.3.0-SNAPSHOT` after 0.3.0), which the brick no longer publishes. A merge on the
brick then never reached a consumer's local build, and the skew cost a hand-bump of 14 repositories
after 0.3.0 ([Vidocq/ci#19](https://codefloe.com/Vidocq/ci/issues/19)).

A step of the action, `bump-consumers.sh`, runs after the release is visible on Central and
the `refresh-downstream-release-yml` cascade, **on a real run only**:

1. reads `graph/inverted.json` (`Vidocq/dep-graph`) and takes the **direct** consumers of every
   artifact the brick publishes (a consumer declares `<brick>.version` only for what it uses itself);
2. in each, rewrites `<brick>.version` to `<next-dev-version>-SNAPSHOT` with
   `build-impacted/pin-upstreams.py` (the reactor's poms only, the property only, every other byte
   untouched; `versions:set-property` when it cannot decide, as `build-impacted` does);
3. commits `chore(deps): bump <brick>.version to <next-dev>-SNAPSHOT` (GPG-signed with the bot key,
   `Signed-off-by`), pushes `chore/bump-<brick>-<next-dev>` and opens a pull request through the
   forge API. The merge is a human one, as for any pull request: pr-validate builds the consumer
   against it.

Properties of the step: **a dry run touches nothing** (the step is skipped, and the script refuses
`DRY_RUN=true` too); **idempotent** (a consumer that already has the branch, or whose property is
absent or already at the target, is skipped); **never fails the job** (the release is published by
then: a consumer that cannot be bumped is a `::warning`, and the guard below reports the skew).

Why a pull request and not a direct push to `main` (as `refresh-release-yml` does): a bump changes
what the consumer compiles against, so it deserves the consumer's own validation. Why in the release
step and not a scheduled sweep: the release is the only moment the next dev version is created, the
step already holds the bot token and signing key, and a sweep would need a second place that knows
what "the dev line" is.

A consumer pull request is opened right after the producer's post-release commit: the
`<next-dev>-SNAPSHOT` must have been published to `central-snapshots` by the producer's `main` build
before pr-validate can resolve it. If that job fails on resolution, re-run it a few minutes later.
`vidocq-parent` has no `<dependency>` consumers in the graph (a `<parent>` is not tracked): it gets
no bump pull requests.

### The guard: `check-brick-versions`

`check-brick-versions/` (run by `pr-validate-gate` in its `state` mode, so every producer's
pr-validate gets it from `@main` without touching its `pr.yml`) is the safety net for what the
step above misses (a failed consumer, a pull request left open, a hand-edit). **Report mode**: it
prints `::warning` annotations and never changes the verdict. For the repository under pull request
it warns when:

- a `<brick>.version` is neither the **latest release of that brick on Maven Central**
  (`maven-metadata.xml`) nor the brick's **current development version** (root `<version>` of its
  `main`); a SNAPSHOT superseded by a release is named as such;
- its **own** SNAPSHOT version is superseded by its own latest release (a brick left on
  `0.3.0-SNAPSHOT` after 0.3.0, as foy, heisenberg, humboldt and mansart were) or lags the highest
  development version of the bricks.

It reads the poms through the forge archive API (no checkout) and skips quietly when the graph, the
forge or Central cannot be read. Blocking (`--strict`, the `strict` input of the action) is
available but off: between the release of a brick and the merge of its consumers' bump pull
requests, every consumer legitimately sits on the superseded line for a while, and a mid-release
state must not turn a pull request red.


## The Forgejo release (Publications tab)

The pipeline pushes the tag `v<release-version>` and the branch `release/<release-version>`, which
is all the forge showed: no entry in the Publications tab. The last step of the action,
`create-forgejo-release.sh`, creates it **on a real run only**: a release named
`<brick> <release-version>` on that tag, flagged as a pre-release when the version has a suffix
(`0.4.0-RC2`), with a body that points at Maven Central. It is idempotent (a tag that already has a
release is left alone) and never fails the job: a forge error is a `::warning`, and the release can
be created by hand. Test: `bash release-maven/create-forgejo-release-test.sh`.

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
