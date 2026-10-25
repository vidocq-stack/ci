#!/usr/bin/env bash
# Targeted test mode of build-one-consumer: run in the consumer checkout, after the producer is
# pinned and the consumer has its PR version, just before its one `mvn $MVN_ARGS install`.
# Turns off test EXECUTION in the modules whose build cannot see any artifact of the producer;
# every module still compiles, test-compiles, runs its codegen, packages and installs.
#
#   1. effective POM of the consumer, with the build's Maven args and environment (profiles);
#   2. affected-modules.py (phase 1); when external artifacts may carry the producer, one Maven
#      run resolves their closures on a synthetic project, then affected-modules.py (phase 2);
#   3. skip-tests.py writes skipTests/skipITs/invoker.skip=true into the poms of the unaffected
#      non-pom modules. The install that follows is the same command as in full mode.
#
# Fallback on any doubt: whatever goes wrong (missing or empty producer artifact list, Maven
# error in the effective POM or in the synthetic resolution, a pom that does not parse, an
# analysis error, a closure that cannot be established, any error of this script...), the build
# runs every test, with the reason in the log, a notice and the job summary. Every pom this
# script may edit is copied first; on a fallback after the edits started, each one is put back
# and compared byte for byte with its copy. When that cannot be done, the script fails the
# step: a run with tests skipped is never reported as a full one.
#
# Env:
#   PRODUCER_ARTIFACTS  producer artifacts, one groupId:artifactId per line, written by
#                       rebuild-producer.sh ($RUNNER_TEMP/targeted/producer-artifacts.txt)
#   PRODUCER_SLUG       forge slug of the producer (for the dependency graph)
#   CONSUMER            forge slug of the consumer (for the summary)
#   MVN_ARGS            Maven args of the consumer build, word-split as given
#   GRAPH_URL           optional (graph-pruning: true only): URL of the dependency graph
#                       (graph/inverted.json), which prunes the synthetic resolution; empty or
#                       unreadable: every suspect external gets its closure resolved
#   BOT_TOKEN           optional token for GRAPH_URL (rate limits)
#   TARGETED_DIR        work directory ($RUNNER_TEMP/targeted/consumer)
#   TESTS_MODE_OUT      file receiving the one-line test mode (TARGETED_DIR/mode.txt)
#   SKIP_TESTS_PY       the pom editor (skip-tests.py next to this script; tests replace it)
#   GITHUB_STEP_SUMMARY job summary, when set
set -euo pipefail
set -E

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MVN_ARGS="${MVN_ARGS--B -ntp}"
DIR="${TARGETED_DIR:-${RUNNER_TEMP:-/tmp}/targeted/consumer}"
PRODUCER_ARTIFACTS="${PRODUCER_ARTIFACTS:-${RUNNER_TEMP:-/tmp}/targeted/producer-artifacts.txt}"
MODE_OUT="${TESTS_MODE_OUT:-$DIR/mode.txt}"
SKIP_TESTS_PY="${SKIP_TESTS_PY:-$HERE/skip-tests.py}"
HELP_PLUGIN=org.apache.maven.plugins:maven-help-plugin:3.5.2
DEPENDENCY_PLUGIN=org.apache.maven.plugins:maven-dependency-plugin:3.8.1
REPO="$PWD"
SUBJECT="${CONSUMER:-the consumer}"
NOTICE_TITLE="Targeted tests"
# fallback, finish, decide and the ERR trap, shared with the producer side.
# shellcheck source=skip-lib.sh
. "$HERE/skip-lib.sh"

rm -rf "$DIR"
mkdir -p "$DIR"

if [ ! -s "$PRODUCER_ARTIFACTS" ]; then
  fallback "the producer artifact list is missing or empty (see the producer rebuild step)"
fi

graph_args=()
if [ -z "${GRAPH_URL:-}" ]; then
  echo "Dependency-graph pruning: off (every suspect external artifact gets its closure resolved)"
elif python3 - "$GRAPH_URL" "$DIR/inverted.json" <<'PY'
import os, sys, time, urllib.request
url, out = sys.argv[1:]
headers = {}
if os.environ.get('BOT_TOKEN') and url.startswith('http'):
    headers['Authorization'] = 'token ' + os.environ['BOT_TOKEN']
err = None
for attempt in range(3 if url.startswith('http') else 1):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
            data = r.read()
        with open(out, 'wb') as f:
            f.write(data)
        sys.exit(0)
    except Exception as e:  # any failure: no pruning
        err = e
        time.sleep(3 * attempt)
print(f'dependency graph not read from {url}: {err}', file=sys.stderr)
sys.exit(1)
PY
then
  echo "Dependency-graph pruning: on (graph from $GRAPH_URL)"
  graph_args=(--graph "$DIR/inverted.json" --producer-slug "${PRODUCER_SLUG:-}")
else
  echo "Dependency-graph pruning: off (graph not read from $GRAPH_URL)"
fi

echo "Effective POM of the consumer"
# shellcheck disable=SC2086
if ! mvn $MVN_ARGS "$HELP_PLUGIN:effective-pom" -Doutput="$DIR/effective-pom.xml" \
     </dev/null > "$DIR/effective-pom.log" 2>&1; then
  show_log "$DIR/effective-pom.log"
  fallback "Maven error in the effective POM of the consumer"
fi
if [ ! -s "$DIR/effective-pom.xml" ]; then
  show_log "$DIR/effective-pom.log"
  fallback "Maven wrote no effective POM of the consumer"
fi

# The local repository holds the poms of the external parent and BOM import chains that the
# effective POM went through; without it, an external io.vidocq chain is a doubt.
chain_args=()
# shellcheck disable=SC2086
if local_repo=$(mvn $MVN_ARGS -N -q "$HELP_PLUGIN:evaluate" -Dexpression=settings.localRepository \
     -DforceStdout </dev/null 2>/dev/null) && [ -n "$local_repo" ] && [ -d "$local_repo" ]; then
  echo "Local repository: $local_repo"
  chain_args=(--local-repo "$local_repo")
else
  echo "Local repository unknown: external io.vidocq parent and BOM chains count as doubts"
fi

# The groupIds of the impacted intermediate upstreams (io.vidocq.<repository>, by convention):
# coordinates written in sources are suspects for them and for the producer only.
upstream_groups=""
for up in ${UPSTREAMS:-}; do
  short="${up##*/}"
  upstream_groups="${upstream_groups:+$upstream_groups,}io.vidocq.$(printf '%s' "$short" | tr '[:upper:]' '[:lower:]')"
done

# Files whose mentions keep their module's tests only (the consumer's ci.targeted.mention-local).
mention_local=$(python3 - <<'PY' 2>/dev/null || true
import xml.etree.ElementTree as ET
for el in ET.parse("pom.xml").getroot():
    if el.tag.split('}')[-1] == 'properties':
        for p in el:
            if p.tag.split('}')[-1] == 'ci.targeted.mention-local':
                print(' '.join((p.text or '').split()))
PY
)
[ -z "$mention_local" ] || echo "Mentions kept local (ci.targeted.mention-local): $mention_local"

analyse() {
  python3 "$HERE/affected-modules.py" --effective-pom "$DIR/effective-pom.xml" --repo "$REPO" \
    --upstream-groups "$upstream_groups" --mention-local "$mention_local" \
    --producer-artifacts "$PRODUCER_ARTIFACTS" --synthetic "$DIR/synthetic" \
    --report "$DIR/report.json" ${graph_args[@]+"${graph_args[@]}"} ${chain_args[@]+"${chain_args[@]}"} "$@"
}
rc=0
analyse || rc=$?
[ "$rc" -eq 0 ] || fallback "the analysis failed (exit $rc)"

if [ "$(field decision)" = resolve ]; then
  n=$(field synthetic)
  echo "Resolving the closures of $n external artifact(s) (synthetic project)"
  # The synthetic modules are independent and the run is mostly remote metadata checks: one
  # thread per core (64 s -> 9 s for vidocq), unless the build's own args choose a -T.
  parallel="-T 1C"
  case " $MVN_ARGS " in *" -T "*|*" -T"[0-9]*|*" --threads"*) parallel="" ;; esac
  # shellcheck disable=SC2086
  if ! (cd "$DIR/synthetic" && mvn $MVN_ARGS $parallel -f "$DIR/synthetic/pom.xml" "$DEPENDENCY_PLUGIN:list" \
          -DoutputFile=deps.txt </dev/null > "$DIR/synthetic.log" 2>&1); then
    show_log "$DIR/synthetic.log"
    fallback "Maven error in the synthetic resolution of $n external artifact(s)"
  fi
  analyse --closures || rc=$?
  [ "$rc" -eq 0 ] || fallback "the analysis failed (exit $rc)"
fi

decide
