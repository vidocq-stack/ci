#!/usr/bin/env bash
# Baseline on failure (build-one-consumer, opt-in): the consumer build failed against the producer
# under pull request. Are those failures caused by the pull request, or already there on the
# producer's main?
#
#   1. The baseline: the same consumer commit, the same intermediates (central-snapshots), the
#      producer NOT pinned (so its current main SNAPSHOT), the same skip set in targeted mode,
#      built with `mvn $MVN_ARGS -fae -Dmaven.test.failure.ignore=true install`: every module is
#      built and tested, a test failure stops nothing.
#   2. A green baseline (Maven succeeds, no failing test): the failures are the pull request's;
#      fail at once.
#   3. Otherwise the pull-request build again, in its own checkout (pin, PR version and skip set
#      unchanged), with the same flags, for the complete list of its failures (the first build
#      stopped at the first failing module).
#   4. compare.py: exit 0 only when every failure of the pull-request build (test case, invoker
#      build, build error by module and goal) also fails on the baseline, and the pull-request
#      build skipped no module the baseline built.
#
# The flaky-test reruns of MVN_ARGS (rerunFailingTestsCount) apply to both builds.
#
# Env:
#   CONSUMER            forge slug of the consumer
#   PR_DIR              the pull-request build's checkout (left in place by build-consumer.sh)
#   PR_LOG              the pull-request build's log
#   MVN_ARGS            Maven args of the consumer builds
#   VERSION_SUFFIX      suffix of the PR versions; the baseline gets <base>-BASELINE.<suffix>
#   TARGETED_REPORT     the targeted analysis report when the pull-request build skipped tests
#   SHARED              directory of the shared scripts (../../build-impacted)
#   BASELINE_DIR        where to put the baseline checkout (<PR_DIR>-baseline)
#   GITHUB_STEP_SUMMARY job summary, when set
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED="${SHARED:-$HERE/../../build-impacted}"
: "${CONSUMER:?CONSUMER}" "${PR_DIR:?PR_DIR}" "${PR_LOG:?PR_LOG}" "${VERSION_SUFFIX:?VERSION_SUFFIX}"
MVN_ARGS="${MVN_ARGS--B -ntp}"
BASE="${BASELINE_DIR:-${PR_DIR}-baseline}"
FLAGS=(-fae -Dmaven.test.failure.ignore=true)
WORKDIR="$(dirname "$PR_DIR")"

if [ ! -s "$PR_LOG" ] || ! grep -q 'BUILD FAILURE' "$PR_LOG"; then
  echo "Baseline: the failure did not come from the consumer's Maven build (clone, pin, version...): not compared."
  exit 1
fi

echo "::group::Baseline: $CONSUMER at the same commit, against the producer's current main SNAPSHOT"
rm -rf "$BASE"
git clone -q --no-hardlinks "$PR_DIR" "$BASE"
git -C "$BASE" checkout -q "$(git -C "$PR_DIR" rev-parse HEAD)"
cd "$BASE"
base_version=$(python3 "$SHARED/pom-version.py" pom.xml)
# shellcheck disable=SC2086
mvn $MVN_ARGS versions:set -DnewVersion="${base_version}-BASELINE.${VERSION_SUFFIX}" \
  -DprocessAllModules=true -DgenerateBackupPoms=false </dev/null
python3 "$SHARED/sync-plugin-descriptors.py" .
if [ -n "${TARGETED_REPORT:-}" ] && [ -s "$TARGETED_REPORT" ] \
   && python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("decision") == "targeted" else 1)' "$TARGETED_REPORT"; then
  echo "Baseline: the same skip set as the pull-request build (its skipped modules ran no test there)"
  python3 "$HERE/../targeted/skip-tests.py" --repo "$BASE" --report "$TARGETED_REPORT" --out "$WORKDIR/baseline-skipped.json"
fi
rc=0
# shellcheck disable=SC2086
mvn $MVN_ARGS "${FLAGS[@]}" install </dev/null > "$WORKDIR/baseline.log" 2>&1 || rc=$?
tail -n 20 "$WORKDIR/baseline.log"
echo "::endgroup::"

has_failures() { # has_failures <dir>: any failing test case in its reports
  python3 - "$1" <<'PY'
import os, sys, xml.etree.ElementTree as ET
for d, _, files in os.walk(sys.argv[1]):
    if os.path.basename(d) in ('surefire-reports', 'failsafe-reports', 'invoker-reports'):
        for n in files:
            if n.endswith('.xml') and (n.startswith('TEST-') or n.startswith('BUILD-')):
                try:
                    root = ET.parse(os.path.join(d, n)).getroot()
                except ET.ParseError:
                    sys.exit(0)
                if root.get('result') not in (None, 'success', 'skipped'):
                    sys.exit(0)
                for c in root.iter():
                    if c.tag.split('}')[-1] in ('failure', 'error'):
                        sys.exit(0)
sys.exit(1)
PY
}

summary_out="${GITHUB_STEP_SUMMARY:-/dev/null}"
if [ "$rc" -eq 0 ] && ! has_failures "$BASE"; then
  echo "Baseline: green against the producer's current main: the failures are caused by this pull request."
  python3 "$HERE/compare.py" --pr "$PR_DIR" --pr-log "$PR_LOG" --baseline "$BASE" --baseline-log "$WORKDIR/baseline.log" \
    --summary "$summary_out" || true
  exit 1
fi

echo "::group::Pull-request build again, for the complete list of its failures"
cd "$PR_DIR"
# shellcheck disable=SC2086
mvn $MVN_ARGS "${FLAGS[@]}" install </dev/null > "$WORKDIR/pr-rerun.log" 2>&1 || true
tail -n 20 "$WORKDIR/pr-rerun.log"
echo "::endgroup::"

if python3 "$HERE/compare.py" --pr "$PR_DIR" --pr-log "$WORKDIR/pr-rerun.log" --baseline "$BASE" \
     --baseline-log "$WORKDIR/baseline.log" --json "$WORKDIR/baseline-decision.json" --summary "$summary_out"; then
  n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["pre_existing"]))' "$WORKDIR/baseline-decision.json")
  echo "::warning title=Pre-existing failures in ${CONSUMER}::${n} failure(s) of ${CONSUMER} also fail against the producer's current main: not caused by this PR (see the job summary). Fix them in ${CONSUMER}."
  exit 0
fi
exit 1
