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
| `setup-maven` | Install Temurin + Maven, put them on the PATH. **Temporarily** also gives Maven, through `MAVEN_OPTS`, a trust store without the roots that the compromised eMudhra intermediate CAs chain to (keys leaked on 2026-10-20, [Vidocq/vidocq#292](https://codefloe.com/Vidocq/vidocq/issues/292)), until Temurin ships a JDK that refuses them. The JDK itself stays untouched: jlink refuses a modified JDK that has no jmods. `setup-maven/block-emudhra-intermediates.sh <java-home> <trust-store>` builds the same trust store on a maintainer machine. The Maven cache is `actions/cache` on `~/.m2/repository`, with the key `m2-<os>-<repository>-<hash of every pom.xml>`, falling back to the newest cache of the same repository, then of any repository; an exact hit is not saved again. It replaces setup-java's own cache, which saved the whole repository again after every job (its restore and save keys differ in case). Artifacts installed at a pull-request version (`io/vidocq/**/<version>-PR<n>.<sha>`) or at a nightly version (`io/vidocq/**/<version>-NIGHTLY.<sha>`, the `downstream-nightly.yml` chain) are left out of the saved cache through GNU tar's `TAR_OPTIONS` on that step: `actions/cache` ignores a `!` pattern under a directory it archives whole. | `java-version` (25), `maven-version` (3.9.16), `distribution` (temurin), `cache` (maven: the cache above; another value such as gradle goes to setup-java's cache; empty: no cache) |
| `run-tck` | Run a Maven TCK, or a custom shell script | `command` (custom shell, wins), `module` (-pl), `profile` (tck), `pre-install` (true), `maven-args` (-B -ntp) |
| `notify-slack` | `[ViBot]` Slack notification | `webhook-url` (required), `status` (success/failure/pr-open/pr-merged/pr-validated/release-success/release-failure), plus repo/ref/run-url and commit/PR/release fields. `dry-run: true` renders a big "🧪 DRY RUN 🧪" Block Kit header so the channel sees at a glance that nothing real happened. |
| `deploy-maven` | settings.xml + GPG import + Central deploy (SNAPSHOT/RELEASE by version) | `central-username`, `central-password`, `gpg-private-key`, `gpg-passphrase`, `snapshot-profile`, `release-profile`, `maven-args` (-B -ntp), `skip-tests` (true: deploy with -DskipTests after the caller's build step; false: one pass that runs the tests, only with deployAtEnd=true in every pom of the reactor, or a failing test leaves the modules built before it published) |
| `cla-check` | PR-gate: verify the PR author signed the Vidocq CLA (identity-based, one of the 3 checks split out of `governance-checks`) | `pr-author` (required), `slack-webhook` |
| `gpg-check` | PR-gate: verify every PR commit is GPG-signed by a registered contributor key (signature-based — re-evaluate after any merge-bot re-sign) | none (reads `BASE_REF..HEAD` from the checked-out repo) |
| `dco-check` | PR-gate: verify every PR commit carries a `Signed-off-by` trailer (trailer-based, survives a merge-bot re-sign) | none |
| `governance-checks` | ⚠️ Deprecated — bundles `cla-check` + `gpg-check` + `dco-check` into a single job/status-check. Kept for repos not yet migrated to the 3 split actions above. | `pr-author` (required), `slack-webhook` |
| `build-impacted` | PR-only: rebuild the transitive downstream consumers (topological order) against the producer's local PR artifacts — no staging registry. A consumer that has a branch named like the PR's head branch (a *companion branch*, for a change spanning several repos) is rebuilt on it instead of on its default branch; only for a PR from a branch of the producer repo, never from a fork. The log names the branch of each consumer, and a notice lists the consumers rebuilt on a companion branch. Workflow: `vidocq-workspace/docs/changes-across-repositories.md`. Before resolving the consumers, it checks that the graph (`graph/inverted.json`, its `generated_at`) is not older than the producer's data file (its `updated_at`): a stale graph may not know every consumer, so the rebuild would check too few repositories without saying so. With `require-fresh-graph: true` a stale graph fails the job, otherwise it is a warning (`build-impacted/graph-freshness.py`). In each consumer, the versions of the upstreams already rebuilt are pinned in one pass without starting Maven (`build-impacted/pin-upstreams.py`): the same edits as one `versions:set-property` per upstream, in the poms of the default reactor only (profiles evaluated as Maven does), and only the project property itself. When the script cannot tell exactly what Maven would do (a profile activated by the JDK, the OS or a file, a pinned property defined in a profile...), it changes nothing and the job falls back to `versions:set-property`, with a warning. The consumer builds rerun a failing test once (surefire and failsafe, through the default `maven-args`; never the producer's own build): a test that then passes does not fail the pull request, and the next step turns each "Flakes:" entry of the consumer logs into a `::warning::` and a row of the job summary naming the consumer, the module and the test, so that it gets a `BUG.md` entry in that repository (`build-impacted/flakes.py`). The graph resolution and the per-consumer steps are scripts shared with `resolve-impacted` and `build-one-consumer` (`build-impacted/resolve-consumers.sh`, `build-impacted/rebuild-consumer.sh`). | `producer-slug` (required), `producer-version` (required), `version-suffix` (required), `bot-token` (required), `graph-ref` (main), `maven-args` (-B -ntp -Dsurefire.rerunFailingTestsCount=1 -Dfailsafe.rerunFailingTestsCount=1; a value given replaces the whole default), `companion-branches` (true), `require-fresh-graph` (true; the dependency graph is rebuilt with every data update since Vidocq/dep-graph#3) |
| `resolve-impacted` | PR-only, for the flat parallel downstream check (study step 2, [Vidocq/vidocq#285](https://codefloe.com/Vidocq/vidocq/issues/285)): the graph part of `build-impacted`, on its own, with the same scripts (`build-impacted/resolve-consumers.sh`: graph download, freshness check, forge filter). Outputs the impacted consumers as a job matrix, in topological order, for one `build-one-consumer` job per consumer, and for each consumer the other impacted consumers it depends on, directly or not (`resolve-impacted/impacted-matrix.py`). Needs no checkout, no Java, no Maven. | `producer-slug` (required), `bot-token`, `graph-repo` (Vidocq/dep-graph), `graph-ref` (main), `require-fresh-graph` (true). Outputs: `matrix` (`{"include":[{"repo":"Vidocq/foy"},…]}` for `strategy.matrix: ${{ fromJSON(...) }}`), `count` (`0`: nothing to rebuild; the matrix then holds one placeholder entry, `{"repo":"none"}`, because Forgejo creates no job for an empty matrix and the jobs that need it stay blocked: the downstream job must skip on `count == 0`), `upstreams` (JSON object, consumer → space-separated upstreams) |
| `select-tck` | PR-only, for a repository that declares several TCK runner modules in `ci.tck.modules`: keeps the runners a changed module reaches, that is the module owning a changed path or any reactor module depending on it in the `-Ptck` reactor (dependencies of every scope, annotation processor paths, plugin configurations, nested builds: the model of `build-one-consumer/targeted/pommodel.py`), or whose `src/` names a changed artifactId (`select-tck/select-tck.py`). Every doubt replays all the runners: a change in the root module or outside every module (root pom, scripts, CI configuration), an unknown runner, a failed effective POM, any error; the step never fails. Documentation outside `src/` is ignored. Writes a table to the job summary and a notice. The nightly TCK job still replays every runner. | `changed-files` (required: the PR's changed paths, one per line), `maven-args` (-B -ntp -q), `working-directory` (.). Outputs: `mode` (`selected` or `all`), `modules` (comma-separated runner paths to replay in mode `selected`, may be empty) |
| `targeted-producer-tests` | PR-only, opt-in, for a repository's own pull request (Vidocq/vidocq#285). **Policy: only for a repository whose `main` publishes after a full test run** (`deploy-maven` with `skip-tests: false`, whose single pass uses `deployAtEnd`, or a separate full build-and-test before the deploy): a pull request may then turn `main` red, never publish an untested artifact. The repository's declared TCK runners are selected separately, by `select-tck`. Three steps around the build's `mvn install`, in the same job: **`mode: targeted`** after the PR version is set and right before the install: the changed paths come from git (`git diff --name-only --no-renames` against the merge base with the base branch; a shallow checkout is deepened, then unshallowed; no merge base means full; the optional `changed-files` list from the forge is only a cross-check, any path git does not report means full). The modules owning them (documentation outside every module is ignored, inside a module it belongs to it), every reactor module depending on them by any reference, every non-pom module whose main sources or resources name one of them (with its dependents) and every module whose test sources name one (with the modules using its test classes: test-jar, classifier, `dependenciesToScan`) keep their tests; when the root pom declares `ci.tck.modules`, the analysis combines the default and `-Ptck` models, so what the TCK profile uses counts, and the declared TCK runners are never skipped. A repository can list, in the root-pom property `ci.targeted.mention-local` (comma-separated repository-relative paths or fnmatch globs), files whose mentions keep the tests of their own module only, not of its dependents (a generated catalog of names, such as vidocq's `extension-catalog.properties`); a listed file that is itself changed propagates as any changed path. The property is the repository's own assertion that nothing resolves the listed names at run time: a test that resolves a listed entry from a Maven repository (ShrinkWrap, a CLI fixture, the local repository) makes that entry unsafe, and the file must leave the property. Every other non-pom module of the build's own reactor gets `skipTests`, `skipITs` and `invoker.skip` in its pom, so the same install still compiles, packages and installs everything (`targeted-producer-tests/changed-modules.py`; pom editing shared with `build-one-consumer`, `build-one-consumer/targeted/skip-lib.sh`). **`mode: restore`** right after the install with `if: always()`: every edited pom is put back byte for byte, or the step fails. **`mode: guard`** (also `targeted-producer-tests/guard.sh`, which `run-tck` calls) fails while edits are in place; the composite exports `TARGETED_PRODUCER_EDITS` (the marker file) for any other later Maven step. Falls back to every test on any doubt, with the reason in a `::notice` and the job summary: no merge base, a forge path missing from git, a changed path in the root module or outside every module (root pom, `.mvn/`, `.forgejo/`, scripts), documentation only, an effective-POM failure, any error; the poms are copied first and put back byte for byte on a fallback, and the step fails if that cannot be done. `mode: full` (the default) does nothing. Known limits: a file of one module read by a sibling through a relative path (a shared fixture) counts for its owner only; runtime resolution outside Maven is caught only through the `src/` text search. | `mode` (full), `changed-files` (optional cross-check), `base-ref` (github.base_ref), `maven-args` (-B -ntp), `working-directory` (.). Outputs: `mode` (`targeted` or `full`), `skipped` (count) |
| `producer-artifacts` | PR-only (Vidocq/vidocq#285): build the producer once, share it with the downstream jobs. `mode: publish` in the producer job, right after its install: packs the producer reactor's artifacts at the PR version from the job's local repository (every file of each module's PR-version directory except sources and javadoc jars, which no build uses: poms, jars, wars, plugin jars, test jars (classifier `tests`, as the rebuild installs them), `_remote.repositories`) with a manifest (version, modules, the modules that skip install, sha256 of every file) and uploads them as the run's artifact `producer-artifacts-<run id>` (`actions/upload-artifact@v3`: v4 is refused by Forgejo 16, "not supported on GHES"; one-day retention: the forge's default is 30 days). Fails closed: a module that does not skip install by design (maven-install-plugin `skip`, or the `maven.install.skip` property, true in its effective POM, as for the vauban examples and TCK runners: the rebuild installs nothing for them either) and kept another version than the PR version, or installed nothing, means nothing is packed and the consumers rebuild. No `maven-metadata*` file is shipped: a consumer resolves the producer at its exact PR version only (what the pin writes), never through a version range, `LATEST`/`RELEASE` or a SNAPSHOT. Measured: vauban 1.46 MB, chappe 0.66 MB, knock 0.15 MB. `build-one-consumer` with `producer-artifacts: <name>` then downloads them through the Forgejo API with the job token, checks the manifest (exactly one artifact of that name in the run, the PR version, exactly the producer's modules and the same modules that skip install as its checkout describes them, every path directly in `<group>/<artifactId>/<PR version>/` of a module that installs and at least one file for each such module, every archive member listed with its sha256, every listed file present) and installs them into the local repository instead of running `rebuild-producer.sh`; any problem (download, several artifacts of that name, checksum, version, module list, install skips, a path outside the modules' PR-version directories, a module without files, a member outside the manifest) rebuilds the producer as before, with a notice. `mode: delete` in the verdict job (`if: always()`, after downstream) deletes the run's artifact (`DELETE /api/v1/repos/<repo>/actions/artifacts/<id>`, accepted with the job token on Forgejo 16); never fails. Publish whenever the producer build runs (not for a docs-only or test-only change set, nor a reused validated tree), without waiting for the impacted matrix (a second runner wait on a busy forge): the verdict job deletes the artifact, and the one-day retention is the backstop. | `mode` (publish), `producer-version`, `maven-args` (-B -ntp), `name` (producer-artifacts-<run id>), `retention-days` (1), `token` (job token). Outputs: `name`, `packed` |
| `build-one-consumer` | PR-only, one job per consumer of the `resolve-impacted` matrix ("flat" mode). Rebuilds the producer under pull request in the job, at its PR version, without its tests (same version setting as the producers' `pr.yml`), then builds ONE consumer against it, with its tests: only the producer's version is pinned in the consumer (`build-impacted/pin-upstreams.py`, one entry), every other `io.vidocq` upstream comes from `central-snapshots` as published, which is what Central holds right after the producer is merged. The consumer gets its own PR version, and its build reruns a failing test once, with the same flaky-test report as `build-impacted`. Companion branches follow the same rules as `build-impacted` (a PR from a branch of the producer repo only): the consumer is built on its companion branch when it has one, and each intermediate upstream that has the companion branch is rebuilt first, in the same job, without its tests, and pinned in the consumer (a mini-chain). An intermediate upstream without a companion branch is never rebuilt. A warning names a consumer whose poms declare no `<producer>.version`: that build does not check the change under test. The job summary gives the consumer, the branch, the PR versions, the upstreams that could not be pinned, the result and the build time. The per-consumer steps are shared with `build-impacted` (`build-impacted/rebuild-consumer.sh`). **Targeted tests** (`tests: targeted`, opt-in; the default `full` runs exactly the same commands as before): the consumer still compiles, test-compiles, runs its codegen, packages and installs every module in the same single `install`, but test execution is turned off (`skipTests`, `skipITs`, `invoker.skip` written into the `<properties>` of the module's pom, never `-DskipTests` on the command line, never in a pom-packaged module) in the modules whose build cannot see any artifact of the producer. The producer artifacts are every module of the producer reactor, listed after its rebuild. The analysis reads the consumer's effective POM (same Maven args and environment as the build, so the same profiles): dependencies of every scope, plugins, plugin dependencies, build extensions, artifacts named in plugin configurations (annotationProcessorPaths, including reactor codegen modules and their dependents), `g:a[:v]` coordinates written as text in plugin configurations, parents, BOM imports (raw poms), the poms of nested builds under the module (invoker ITs, test projects, fixtures), producer artifactIds named in the module's `src/` files (tests that resolve artifacts at run time), and the reactor edges; the external `io.vidocq` artifacts that may carry the producer get their closure from one Maven run on a synthetic project. With `graph-pruning: true` (default `false`), the dependency graph (`graph-repo`, `graph-ref`) skips the externals of repositories that do not consume the producer: about 60 s less on vidocq, but the graph is trusted without any freshness or version check. A doubt about one module (a coordinate that cannot be resolved, a nested pom that does not parse) makes that module affected. The consumer's root-pom property `ci.targeted.mention-local` (comma-separated repository-relative paths or globs) lists files whose mentions keep the tests of their own module only, as for the producer side. It falls back to `full` on any doubt, with the reason in the job summary: an intermediate upstream rebuilt from its companion branch (mini-chain; intermediate upstreams that come from `central-snapshots` as published are analysed as external `io.vidocq` artifacts, their closure matched by groupId:artifactId; an `io.vidocq` coordinate of the producer or of an intermediate upstream (groupId `io.vidocq.<repository>` by convention) written in a module's sources, as a test may resolve it at run time, gets its closure too, or makes the module affected when it has no version; coordinates of other repositories cannot carry the producer and are ignored), a companion branch of the consumer, an empty producer artifact list, a Maven error in the effective POM or the synthetic resolution, a pom that does not parse, a closure that cannot be established, any analysis or script error (`build-one-consumer/targeted/`). Every pom it edits is copied first: on a fallback after the edits started, each one is put back and checked byte for byte, and when that fails the job fails rather than run with tests skipped. A `::notice` gives the mode or the fallback reason. Known limits: intermediate upstreams are SNAPSHOTs read from `central-snapshots` twice, by the analysis and minutes later by the install, so a publish in between could change a closure; only `io.vidocq` artifacts (and the producer's groups) are treated as possible carriers of the producer, not a third-party artifact that wraps or shades one; external parent chains and BOM import chains that leave the reactor through an `io.vidocq` artifact are followed through the local repository's poms (a producer pom anywhere in them makes the module affected, an unreadable pom or unresolved import version is a doubt); runtime resolution outside Maven is caught only through the `src/` text search. The summary lists the affected modules with the reason for each and the number of modules whose tests were skipped. **Baseline on failure** (`baseline-on-failure: true`, opt-in, default `false`): when the consumer build fails, the same consumer commit is rebuilt against the producer's current `main` SNAPSHOT (no PR pin, same intermediates from `central-snapshots`, same skip set in targeted mode); a green baseline fails the job at once; otherwise the pull-request build runs again, and both run with `-fae -Dmaven.test.failure.ignore=true` (the flaky reruns of `maven-args` kept), so every module is built and tested. The job passes, with a `::warning` and a job-summary section "Pre-existing failures, not caused by this PR" (which also records the producer SNAPSHOT build the baseline resolved), only when every failure of the pull-request builds, the first build (its reports saved before the rerun) and the rerun alike, also fails on the baseline: a test case keyed by module, report kind (surefire, failsafe) and class#method, an invoker build, a build error by module, goal and normalised message and by each `file:[line,col] message` line; and only when the rerun skipped no module. A failure of the first build that passes in the rerun (flaky with the PR), a failure only the pull request has, a module whose log test summaries count more failures than its reports name (killed fork, reports elsewhere), a test-plugin error that its module's reports do not explain (an execution that failed, a crashed fork), a module the rerun skipped, or no failure at all fails as before. Known limit: a test that is flaky on `main` and fails on the baseline can absorb the same test made to fail deterministically by the PR (`build-one-consumer/baseline/`). Never on a companion-branch run, where the consumer or an intermediate differs from Central too. Cost: one more consumer build when the failure is the pull request's, two when it is pre-existing, none when the build passes. | `consumer` (required, `${{ matrix.repo }}`), `upstreams` (`fromJSON(needs.<job>.outputs.upstreams)[matrix.repo]`), `producer-slug` (required), `producer-version` (required), `version-suffix` (required), `producer-dir` (.), `producer-maven-args` (-B -ntp), `maven-args` (same default as `build-impacted`), `companion-branches` (true), `baseline-on-failure` (false), `producer-artifacts` (empty: rebuild the producer), `tests` (full; or targeted), `graph-pruning` (false), `graph-repo` (Vidocq/dep-graph), `graph-ref` (main), `bot-token` |
| `validated-tree` | PR-only ([Vidocq/ci#57](https://codefloe.com/Vidocq/ci/issues/57)): keys a validation on the **code-tree id** of HEAD, a SHA-256 of its tree without the documentation files (`*.md`, `*.adoc`, `docs/`, `LICENSE*`, `NOTICE*`, never under a `src/`), instead of the commit (`validated-tree/validated_tree.py`). Mode `check` says whether a run of the same scope already validated that id; mode `record`, at the end of a green run, records it as a ref of the repository, `refs/validated/<scope>/<id>[-<key-suffix>]`, pointing at a parentless commit of the empty tree whose message holds the validated commit, the run and a note; it needs the bot token to push. The actions cache is per runner (five runners on three sites), a ref is seen by all of them. So a docs-only commit, a rebase on a `main` that moved by documentation only, or the merge-bot's re-signing of an unchanged rebase reuse the earlier result instead of building again. Never reused: an event other than `pull_request`, a re-run (attempt > 1: a re-run is how one asks for a real build), a companion branch (another repository of the organisation has a branch named like the head branch; any forge error counts as one). | `mode` (required: `check` or `record`), `scope` (required: `pr-validate`, `sonar-pr<n>`...), `tree-id` (record: the id the check output), `key-suffix` (what else must match, in both modes: `sonar-analysis` passes the date of the pull request's last analysis), `note` (record: one line read back as `recorded-note`), `bot-token` (required to record). Outputs: `tree-id`, `reused`, `reason`, `recorded-commit`, `recorded-note` |
| `pr-validate-gate` | PR-only, for the producers' `pr.yml` ([Vidocq/vidocq#285](https://codefloe.com/Vidocq/vidocq/issues/285)): every decision of the pull-request validation, resolved from `@main` so that a change of policy needs no change in the producer repositories (`pr-validate-gate/gate.py`). **`mode: state`**, in a first job (`pr-state`, no checkout): reads the pull request as it is now, through the API (the event payload only when the API does not answer: a re-run replays an old payload), and says which jobs run. A **train member** (label `train-member`, a line `Train-top: #N` in the description) builds nothing. A **WIP or blocked** pull request (the maintainer's rule: `wip` anywhere in the title as a word, any case; a `Draft:` or `[draft]` prefix; the forge's draft flag; a label whose name contains `wip`, or `blocked`) builds and tests the producer but not its consumers. Any other activity than `opened`, `reopened`, `synchronize` (an edit, a label change) on a commit that a completed run already judged, in the same mode (ready, WIP or train), with no other run of the workflow unfinished on that commit, reproduces that run's verdict and builds nothing: the latest completed run of the same workflow on the same head commit (the one whose status stands), read through the actions API, with the mode it judged and its verdict taken from the record its aggregator's first step prints (`PR-VALIDATE-RECORD {...}`: the first such line, at the start of a line, naming that run and that job; logs are public): a run may be judged after the pull request changed, so the event it was triggered with is not enough. Each new run overwrites the commit statuses of the previous one, so a description edit must neither turn a red `pr-validate` green nor a green one red. It validates in full when that verdict cannot be established: no completed run, a cancelled one, no record (a run older than the gate, or one that judged nothing: failed governance checks, a pull request changed during the run), an API or a log that does not answer, a mode that changed (WIP or the train label removed), a base branch changed (`edited` with `changes.base`), another run unfinished on the commit, a re-run (attempt > 1: re-running all the jobs forces a full validation). **`mode: verdict`**, in the aggregator `pr-validate` (required check), decides from `toJSON(needs)`: it fails a train member ("validated through the train's top PR #N"), a WIP pull request ("WIP: downstream not run; remove WIP to validate"), an undetermined state, and any expected work that did not succeed; a skipped downstream passes only for a docs-only or test-only change set, a code tree already validated (`validated-tree`), or no impacted consumer. A reproduced verdict is checked again at the end: its run must still be the latest completed one, with nothing unfinished, else the newer run's verdict in the same mode, else a failure. It reads the pull request again at the end, and fails when it cannot: one that became WIP or a train member during the run fails, and one that stopped being WIP takes the verdict of the newer run if it already ended, else fails and leaves the final word to that run. Public repositories are read anonymously, so fork pull requests work without a token. Its only write, with the token: mode `state` cancels a merge the merge-bot scheduled when the pull request is not ready, or on a push the merge-bot did not announce (its comment `<!-- merge-bot-scheduled-head: <sha> -->`, by the token's own account): Forgejo's scheduled merge does not pin the head. `classify --pr-json` gives the same classification to the merge-bot and the train script. | `mode` (required: `state` or `verdict`), `needs` (verdict: `toJSON(needs)`; the aggregator must need `governance-checks`, the state job, `producer`, `impacted`, `downstream`), `token` (`secrets.VIDOCQ_BOT_TOKEN`, rate limits only), `wip-labels` (wip: substrings of a label name), `blocked-labels` (blocked), `train-label` (train-member), `state-job` (pr-state), `aggregator-job` (pr-validate). Outputs: `state` (JSON, for the aggregator), `mode`, `run-producer`, `run-downstream`, `reproduce`; `verdict`, `notify` (`true` for a fresh green validation: the Slack message), `reason` |
| `update-dep-graph` | Extract `io.vidocq.*` deps and push them into GestionProjet/data | `bot-token` (required), `repo` (required), `base-url`, `graph-repo`, `branch` |
| `trigger-docs-rebuild` | POST a `workflow_dispatch` to `vidocq-docs/build.yml` so the Antora site is rebuilt & redeployed. Use after a push on `main` that touched `docs/**`. | `bot-token` (required), `source-repo` (required), `base-url`, `docs-repo`, `workflow`, `ref` |
| `sonar-analysis` | SonarQube analysis of the Maven build on `sonar.vidocq.dev` (community branch plugin): `main` on push, a pull request with its own quality gate. Report mode by default: never fails the job, and keeps one comment on the pull request up to date with the gate. Skipped when the token is empty (pull requests from forks). The project is created on the server when missing, so the same workflow works unchanged in every repository. A pull request whose code tree was already analysed, by the analysis that is still its last one, gets that quality gate read again with no build and no analysis (`validated-tree`, scope `sonar-pr<n>`); one that changes no code a pull request builds, documentation or workflows it cannot run (its code tree is that of its merge base with the base branch), is not built nor analysed, and the comment says so; a server that does not answer is said in the pull-request comment instead of a silent green job. The build also writes a CycloneDX SBOM; between the build and the analysis, OSV-Scanner checks that SBOM for known vulnerabilities in the dependencies the build ships, OpenGrep looks for security patterns (community rules at a pinned commit) and Trivy for leaked secrets and Dockerfile misconfigurations, offline. None of them sends a request to Maven Central. Their SARIF reports become external issues in SonarQube, minus the findings of modules SonarQube does not analyse. Each tool is a pinned release checked by SHA-256 (`sonar-analysis/security-scans.sh`), and a scan that fails never stops the analysis. When `maven-args` runs a repository's Error Prone profile, in report mode, the warnings Error Prone writes in the build log become external issues too, as reliability issues through SonarQube's generic format, since a SARIF import counts every result as a vulnerability (`sonar-analysis/errorprone-sarif.py`, `sonar-analysis/sarif-to-generic.py`). A module whose build runs japicmp gets its API compatibility with the last release summarised in the log and in one more pull-request comment (`sonar-analysis/api-compat-comment.py`), report mode. With `infer: true`, Infer's RacerD looks for data races in the main sources, captured with javac module by module (Infer's Maven integration recompiles with `-source 11`), and its findings become reliability issues the same way (`sonar-analysis/infer.sh`). With `targeted-tests: true` (pull requests only; a push to `main` always runs every test), the build runs only the tests of the modules the pull request reaches (`targeted-producer-tests`, changed paths from git) and restores the poms right after it, before the scans and the analysis (`sonar-analysis/targeted-build.sh`): the coverage of new code is unchanged, since only modules that can execute the changed classes hold tests that cover them (checked on vidocq for three changes, identical per-line coverage of the changed modules; full build 918 s, targeted 94–126 s). The claim covers coverage, issues and duplications, not test-count metrics (tests run, test failures and errors): a quality gate condition on those could differ. The effective POM of the analysis takes the profiles and properties of `maven-args`, so it sees what the build sees. | `sonar-token` (required, `secrets.SONAR_TOKEN`), `host-url` (required, `vars.SONAR_HOST_URL`), `project-key` (`vidocq-<repository>`), `bot-token` (PR comment, `secrets.VIDOCQ_BOT_TOKEN`), `maven-args` (-B -ntp -Pquality -Dmaven.test.failure.ignore=true install: a failing test does not stop the analysis, the pull request validation is the test gate; install puts the modules in the job's local repository for the separate analysis run; add `errorprone` to the profiles for Error Prone's findings), `analysis-args` (-B -ntp -Pquality), `cyclonedx-version`, `scanner-version`, `blocking` (false), `security-scans` (true), `infer` (false: it downloads Infer, 276 MB), `targeted-tests` (false) |
| `merge-bot` | Rebase a PR's head branch onto its base, re-sign every replayed commit with the dedicated CI bot key, force-push, then fast-forward merge. The only way to merge without producing an unsigned commit once `require_signed_commits` is enforced (server-side merge/squash/rebase always strips the original signature — true of Forgejo, GitHub and GitLab alike). **It never waits for the checks in its job** (seventeen waiting /merge runs once held 14 of the 20 runner slots and starved the checks they waited for): after the push it reads the checks the base branch requires, and only those (`merge-bot/required-checks.py`, Vidocq/ci#47). Green already, or none required: it fast-forwards the exact head at once. Red: it refuses. Pending: **only where the base branch's `.forgejo/workflows/pr.yml` runs `pr-validate-gate` with `mode: state`** (the job that cancels a stale schedule), it schedules Forgejo's merge when checks succeed (`merge_when_checks_succeed`) and exits (`merge-bot/schedule.py`); elsewhere (ci, GestionProjet, a producer before the template rollout) it refuses with "checks still running; re-run /merge when pr-validate is green", and a later `/merge` fast-forwards the green head. Right after scheduling it re-reads the head and cancels on any mismatch. Before the push, a comment announces the head (`<!-- merge-bot-scheduled-head: <sha> -->`). Forgejo's schedule does not pin the head, so the pr-validate gate cancels it on a push the bot did not announce and when the pull request becomes WIP, blocked or a train member; the bot cancels any earlier schedule itself before rebasing and whenever it refuses. If `main` moves after scheduling, the fast-forward cannot happen: comment `/merge` again, the bot rebases and schedules anew. A cancellation that `pr-state` needs and cannot do fails that job, so `pr-validate` fails and the forge cannot merge. Measured on Forgejo 16: a schedule also fires right after a push (2 s, no status event), so a push of a head whose own checks are already green (a force-push back to an older validated commit) is merged before `pr-state` can cancel; `main` still receives only a commit whose own `pr-validate` is green, but not necessarily the announced head: do not push after `/merge`. `checks-timeout-minutes` is no longer used. `/merge` refuses a WIP or blocked pull request (the same rule as `pr-validate-gate`) and a train member, before the rebase and again right before the merge (`merge-bot/refusal.sh`, the classification of `pr-validate-gate`, Vidocq/vidocq#285); `/rebase` still works on them. The failure comment quotes the reason (`MERGE_BOT_REASON_FILE`). | `pr-number` (required), `repo` (required), `bot-token` (required), `git-signing-private-key`/`git-signing-passphrase`/`git-signing-key-id` (required, `secrets.CI_BOT_GPG_*`), `base-url`, `checks-timeout-minutes` (default `60`) |
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

# Flat parallel downstream (one job per consumer, each against the PR producer plus the
# SNAPSHOTs on central-snapshots); see vauban's pr-downstream-matrix.yml:
jobs:
  impacted:
    runs-on: vidocq-runner
    outputs:
      matrix: ${{ steps.r.outputs.matrix }}
      count: ${{ steps.r.outputs.count }}
      upstreams: ${{ steps.r.outputs.upstreams }}
    steps:
      - id: r
        uses: https://codefloe.com/Vidocq/ci/resolve-impacted@main
        with: { producer-slug: '${{ github.repository }}' }
  downstream:
    needs: impacted
    if: needs.impacted.outputs.count != '0'
    runs-on: vidocq-runner
    strategy:
      fail-fast: false
      max-parallel: 6
      matrix: ${{ fromJSON(needs.impacted.outputs.matrix) }}
    steps:
      - uses: actions/checkout@v4
      - uses: https://codefloe.com/Vidocq/ci/setup-maven@main
      - uses: https://codefloe.com/Vidocq/ci/build-one-consumer@main
        with:
          consumer: ${{ matrix.repo }}
          upstreams: ${{ fromJSON(needs.impacted.outputs.upstreams)[matrix.repo] }}
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

### PR trains — `scripts/train-merge.py`

A train is a chain of pull requests on one repository, each one's head a descendant of the previous one's
(Vidocq/vidocq#285, CI study option L). Only the top runs the full validation; the members' `pr-validate`
fails on purpose, so none of them can be merged alone, by hand or by `/merge`. From a clone of `Vidocq/ci`,
with `CODEFLOE_BOT_TOKEN` in the environment (members listed bottom first, the top first of all):

```bash
python3 scripts/train-merge.py mark  Vidocq/vauban 213 210 211 212   # label train-member + "Train-top: #213"
# ... wait for #213's pr-validate to go green (the members fail in seconds) ...
python3 scripts/train-merge.py check Vidocq/vauban 213 210 211 212   # every verification, nothing written
python3 scripts/train-merge.py merge Vidocq/vauban 213 210 211 212 --yes
python3 scripts/train-merge.py unmark Vidocq/vauban 211              # back to a standalone pull request
```

`merge` refuses on any doubt: every pull request open, from the repository itself, on the same base; the top
ready (not WIP, not blocked, not a member) with its required checks and its `pr-validate` green on its exact
head; every member labelled for this top, neither WIP nor blocked; and, with git (`--remote`, default the
repository on the forge, read anonymously), the heads the API reports are the heads fetched, the base branch
is an ancestor of the top, each member's head is an ancestor of the next one and of the top, no member is in
the base already. Without `--yes` it is a dry run. With it, the base branch is fast-forwarded to the top's
exact head through the API (the top's checks are green: no rebase, no re-signing, the members' commits are
already signed), the script checks that the branch moved there, then each member is found merged by the
forge's autodetection, or marked "manually merged" by its own head, or commented and closed when the
repository does not allow that mark. The organisation needs a `train-member` label. **Rollout:** a member whose head still has the old `pr.yml` (no `pr-state` job) keeps a green `pr-validate`:
only `/merge` and this script refuse it, not the forge's merge button, so roll the new `pr.yml` out to every
producer at once. In a repository without
a `pr-validate` check (`ci`, `GestionProjet`), pass `--context ''` to rely on the branch's required checks alone.

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
