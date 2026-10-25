# BENCH — Vidocq CI

Performance numbers of the shared CI actions. Vidocq workspace convention: date, hardware/JVM, exact command,
raw results, delta against the previous run.

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
