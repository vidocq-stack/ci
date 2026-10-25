# BENCH — Vidocq CI

Performance numbers of the shared CI actions. Vidocq workspace convention: date, hardware/JVM, exact command,
raw results, delta against the previous run.

---

## 2026-10-25 — targeted consumer tests with intermediate upstreams from central-snapshots (Vidocq/vidocq#285)

- **Hardware/JVM**: Apple M5 Max (18 cores, 128 GB), Temurin 25, Maven 3.9.16, `CI=true`.
- **Setup**: the real `build-one-consumer/build-consumer.sh` of this branch, with:
  - `CONSUMER=Vidocq/vidocq` (cloned from Codefloe main) and `PRODUCER_SLUG=Vidocq/champollion`;
  - champollion `56babcc` already installed at `0.4.0-PR0.tgi` by `rebuild-producer.sh`;
  - `UPSTREAMS="Vidocq/cassini Vidocq/cervantes Vidocq/cyrano Vidocq/dirac"` and no companion branch
    (`HEAD_REF` empty);
  - `GRAPH_PRUNING=false` and the default `maven-args`;
  - an isolated, warm Maven repository.

  The same script ran with `TESTS=targeted`, then with `TESTS=full`.
- **Network**: central-snapshots resolution was slow during the session (see the entries below).

| Mode | Job (clone + pin + versions:set + analysis + install) | Install | Tests run | Non-pom modules keeping their tests |
|---|---:|---:|---:|---:|
| full | 644 s | 10:37 min | 3 320 | 77 / 77 |
| targeted | 148 s (−77 %) | 2:08 min | 272 | 21 / 77 |

- **The analysis**: 48 external artifacts resolved on the synthetic project, with the intermediates' artifacts
  among them.
- **Through an intermediate.** `vidocq-runtime-cervantes-jwt-extension` is affected only through intermediates:
  "io.vidocq.champollion:champollion-api via dependency io.vidocq.cervantes:cervantes-cdi-vauban". The match is by
  groupId:artifactId; the intermediate's pom declares the SNAPSHOT version.
- **Re-run after the review fix 62-I1** (`io.vidocq` coordinates written in sources are suspects too): 159 s job,
  2:19 min install, 272 tests, 21 / 77 modules, 48 externals. No source-text doubt was raised, and the gain holds
  (−75 %).
- **Before this change**, the job fell back to full ("the consumer has impacted intermediate upstreams").
---

## 2026-10-25 — targeted-producer-tests on vidocq's own pull requests (Vidocq/vidocq#285)

- **Hardware/JVM**: Apple M5 Max, Temurin 25, Maven 3.9.16, `CI=true`.
- **Source**: vidocq `ee782c0` (origin/main).
- **Setup** (after the review fixes of Vidocq/ci#59), for each case:
  1. one pull-request commit changing the file, on a `pr` branch;
  2. the PR version set as in `pr.yml` (`versions:set 0.4.0-PR0.prod` plus the plugin.xml sync);
  3. `producer-tests.sh` with `MODE=targeted` (changed paths from git, against `main`; `-Ptck` model read,
     since vidocq declares `ci.tck.modules`);
  4. `mvn -B -ntp install` through `verify-mvn.sh` (isolated repository, warm);
  5. `MODE=restore`, then `MODE=guard`. Every pom was checked byte for byte against its state before step 3.
- **Network**: the same slow central-snapshots resolution as in the entries below. The full install took 609 s.

| Change | Non-pom modules keeping their tests | Analysis | Install | Full install | Tests run (targeted / full) | Restore / guard |
|---|---:|---:|---:|---:|---:|---|
| knock-health-extension (main source) | 67 / 77 | 4 s | 611 s (≈ full) | 609 s | 2 985 / 3 246 | ok / ok, poms identical |
| vidocq-runtime-core (main source) | 69 / 77 | 5 s | 621 s (≈ full) | 609 s | 3 092 / 3 246 | ok / ok, poms identical |
| petstore example (main source) | 1 / 77 | 5 s | 86 s (−86 %) | 609 s | 1 / 3 246 | ok / ok, poms identical |

- **Why knock-extension no longer gains (it gave −78 % before the fixes).**
  - `vidocq-runtime-tooling`'s `META-INF/vidocq/extension-catalog.properties` (a main resource) names every
    extension artifact.
  - Since the review, a mention in main sources or resources propagates. So tooling is a seed, then
    `vidocq-runtime-maven-plugin` (which depends on tooling), then every example and extension.
  - Any extension change on vidocq therefore keeps nearly every test.

---|---:|---:|---:|---:|---:|
| knock-health-extension (main source) | 7 / 77 | 3 s | 124 s (−78 %) | 579 s | 852 / 3 246 |
| vidocq-runtime-core (main source) | 71 / 77 | 3 s | 571 s (≈ full) | 579 s | 3 116 / 3 246 |
| petstore example (main source) | 1 / 77 | 3 s | 87 s (−85 %) | 579 s | 1 / 3 246 |

- **knock-extension: 7 modules keep their tests.** These are the extension, its `-dev` module and the example
  (reactor dependents), plus four modules whose `src/` names it:
  - `vidocq-runtime-tooling` (the extension catalog);
  - `vidocq-runtime-maven-plugin` (a test);
  - the dirac and heisenberg extensions (`module-info.java`).
- **vidocq-runtime-core: not every module.** The 6 modules that do not depend on core still skip their tests:
  codegen-commons, core-codegen, devconsole-spi, devservices-spi, devservice-keycloak and devservice-postgres.

---

## 2026-10-25 (middle producers) — `tests: targeted` for chappe, champollion, cassini, foy, ravel, mansart (Vidocq/vidocq#285)

- **Hardware/JVM**: Apple M5 Max (18 cores, 128 GB), Temurin 25, Maven 3.9.16, `CI=true`.
- **Code**: this branch, with external parent and BOM chains followed, and test-source-only mentions not
  propagating. Whole-producer changed set, `graph-pruning` off.
- **Sources**: origin/main of 2026-10-25. Producers: chappe `c6cff89`, champollion `56babcc`, cassini `9232f7d`,
  foy `9fe2487`, ravel `4bf7006`, mansart `bbc1367`. Consumers: vidocq `425fca1`, foy `9fe2487`, knock `f244c25`,
  cyrano `41c3af3`.
- **Setup**: each producer was rebuilt by `rebuild-producer.sh` (`TESTS=targeted`, 0.4.0-PR0.tgi). The consumer was
  pinned and versioned the CI way. The analysis ran through `targeted-tests.sh`; the install ran through
  `verify-mvn.sh` (isolated repository, warm) with the default `maven-args`.
- **Network.** vidocq's three invoker-driven IT modules (Application layer, Brick codegen, Continuous testing)
  resolve SNAPSHOTs from central-snapshots in nested builds. During this session they took 4–6 min instead of
  about 50 s. vidocq's full install measured **222 s** at 03:17 and **592 s / 582 s** during these runs.
  Compare the vidocq rows with the 592 s baseline measured in the same conditions.

| Producer → consumer | Non-pom modules affected | Analysis | Targeted install | Full install (same session) | Tests run (targeted / full) | Fallback |
|---|---:|---:|---:|---:|---:|---|
| chappe → vidocq | 33 / 77 | 13 s | 492 s | 592 s | 1 124 / 3 233 | none |
| champollion → vidocq | 22 / 77 | 13 s | 104 s | 592 s | 269 / 3 233 | none |
| cassini → vidocq | 65 / 77 | 9 s | 570 s | 592 s | 2 206 / 3 233 | none |
| foy → vidocq | 12 / 77 | 15 s | 412 s | 592 s | 716 / 3 233 | none |
| ravel → vidocq | 12 / 77 | 14 s | 103 s | 592 s | 27 / 3 233 | none |
| mansart → vidocq | 69 / 77 | 9 s | 617 s | 592 s | 2 487 / 3 233 | none |
| chappe → foy | 8 / 11 | 4 s | 45 s | 46 s | 1 397 / 1 432 | none |
| cassini → knock | 3 / 7 | 9 s | 14 s | 17 s | 16 / 68 | none |
| champollion → knock | 5 / 7 | 4 s | 19 s | 17 s | 61 / 68 | none |
| ravel → cyrano | 5 / 7 | 4 s | 21 s | 21 s | 159 / 172 | none |

Notes:
- **What sets the time on vidocq.** It is whether the Application layer and Brick codegen ITs are affected (185 s
  and 101 s in these conditions):
  - foy reaches them through foy-servlet-extension and ibarra-pages-extension;
  - chappe, cassini and mansart reach them too;
  - champollion and ravel do not.
- **cassini and mansart** select nearly everything. Main sources name their artifacts:
  - `vidocq-runtime-maven-plugin`'s `VidocqJlinkMojo` names `cassini-maven-plugin`;
  - `vidocq-runtime-devconsole-spi` names `mansart-pool`.

  Both modules are depended on almost everywhere.
- **foy → vidocq** selected 73 / 77 before test-source-only mentions stopped propagating:
  `vidocq-runtime-maven-plugin`'s tests name `foy-core`.
- **One module in every row.** `vidocq-runtime-knock-health-example` is affected for every producer: its
  `<includeArtifact>io.vidocq.knock:knock-jaxrs</includeArtifact>` has no version, so its closure is unknown
  (doubt).
- **The small consumers (foy, knock, cyrano)** finish in 14–45 s in either mode, so the targeted mode changes
  little there.

---

## 2026-10-25 (review fixes) — `tests: targeted` with the default `graph-pruning: false` (Vidocq/vidocq#285)

- **Hardware/JVM, sources, setup and build command**: as in the entry below. One change: the analysis now has
  no dependency graph (`GRAPH_URL` empty, the new default). It also has the review's extra rules: coordinates
  written as text, nested coordinates, producer artifactIds named in `src/`. The synthetic resolution runs with
  `-T 1C`.
- **Full baselines**: measured again in the same session.

| Producer → consumer | Full install | Targeted: producer list + analysis + install | Delta | Tests run (full → targeted) | Modules with tests skipped |
|---|---:|---:|---:|---:|---:|
| knock → vidocq | 222 s | 2 s + 13 s (66 externals resolved) + 92 s = 107 s | −52 % | 3 233 → 38 | 71 (6 affected) |
| vauban → foy | 44 s | 1 s + 5 s (2 externals) + 13 s = 19 s | −57 % | 1 432 → 62 | 7 (4 affected) |

- **Synthetic resolution of the 66 vidocq externals**: 64 s serial, 9 s with `-T 1C`, with identical
  `deps.txt` files. The work is remote metadata checks (`updatePolicy` `always` on central-snapshots).
- **Affected modules for knock → vidocq: 6 instead of 3.**
  - `vidocq-runtime-grimm-openapi-extension` is now affected: its Javadoc names `knock-cdi-vauban` (the new
    `src/` text rule).
  - Through it, `vidocq-runtime-it-grimm-openapi` and `vidocq-runtime-mansart-h2-example` are affected too.
- **Ground truth**: `dependency:list` of every module, all scopes, after the targeted builds. No producer
  artifact in any of the 71 (vidocq) and 7 (foy) modules whose tests were skipped.
- **Delta vs the entry below** (graph pruning on, fewer rules): knock → vidocq 93 s → 107 s (+14 s: about +11 s
  of analysis, plus 15 more tests). vauban → foy 15 s → 19 s.

---

## 2026-10-25 — build-one-consumer, `tests: targeted` against `tests: full` (Vidocq/vidocq#285)

- **Hardware/JVM**: Apple M5 Max (18 cores, 128 GB), Temurin 25 (25+36), Maven 3.9.16, `CI=true`.
- **Sources**: origin/main of 2026-10-25: knock `f244c25`, vauban `80d1679`, vidocq `425fca1`, foy `9fe2487`.
- **Setup, the CI way (flat mode)**: the producer rebuilt with `build-one-consumer/rebuild-producer.sh`
  (`PRODUCER_VERSION=0.4.0-PR0.tgi`, `TESTS=targeted`), the consumer pinned with
  `build-impacted/pin-upstreams.py`, `versions:set` + `sync-plugin-descriptors.py`, then
  `build-one-consumer/targeted/targeted-tests.sh` (dependency graph read from
  `Vidocq/dep-graph` main). Isolated Maven repository, warm (copied from an earlier run), never `~/.m2`.
- **Build command** (both modes, the default `maven-args`):
  `mvn -B -ntp -Dsurefire.rerunFailingTestsCount=1 -Dfailsafe.rerunFailingTestsCount=1 install`.

| Producer → consumer | Full install | Targeted: analysis + install | Delta | Tests run (full → targeted) | Modules with tests skipped |
|---|---:|---:|---:|---:|---:|
| knock → vidocq | 219 s | 1 s (producer list) + 2 s + 90 s = 93 s | −58 % | 3 233 → 23 | 74 of 77 non-pom modules (3 affected) |
| vauban → foy | 43 s | 2 s + 2 s + 11 s = 15 s | −65 % | 1 432 → 62 | 7 of 11 non-pom modules (4 affected) |

- Analysis without the dependency graph (knock → vidocq): 68 external artifacts resolved on the synthetic project,
  63 s, same selection: the pruning is what keeps the analysis at 2 s.
- Every build green, 0 failures. Ground truth after the targeted builds: `dependency:list` of every module (all
  scopes) shows no producer artifact in any of the 74 (vidocq) and 7 (foy) modules whose tests were skipped.
- Previous run: the prototype of 2026-10-24 (vidocq `993dac72`, foy `317ffda4`), same machine: vidocq full 220 s,
  knock targeted 87 s + 4 s; foy full 43 s, vauban targeted 12 s + 2 s. Delta within noise.
