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
# analysis error, a closure that cannot be established...), no pom is edited and the build
# runs every test, with the reason in the log and the job summary. This script never fails
# the build itself.
#
# Env:
#   PRODUCER_ARTIFACTS  producer artifacts, one groupId:artifactId per line, written by
#                       rebuild-producer.sh ($RUNNER_TEMP/targeted/producer-artifacts.txt)
#   PRODUCER_SLUG       forge slug of the producer (for the dependency graph)
#   CONSUMER            forge slug of the consumer (for the summary)
#   MVN_ARGS            Maven args of the consumer build, word-split as given
#   GRAPH_URL           optional URL of the dependency graph (graph/inverted.json): it prunes
#                       the synthetic resolution; unreadable: no pruning, same result, slower
#   BOT_TOKEN           optional token for GRAPH_URL (rate limits)
#   TARGETED_DIR        work directory ($RUNNER_TEMP/targeted/consumer)
#   TESTS_MODE_OUT      file receiving the one-line test mode (TARGETED_DIR/mode.txt)
#   GITHUB_STEP_SUMMARY job summary, when set
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MVN_ARGS="${MVN_ARGS--B -ntp}"
DIR="${TARGETED_DIR:-${RUNNER_TEMP:-/tmp}/targeted/consumer}"
PRODUCER_ARTIFACTS="${PRODUCER_ARTIFACTS:-${RUNNER_TEMP:-/tmp}/targeted/producer-artifacts.txt}"
MODE_OUT="${TESTS_MODE_OUT:-$DIR/mode.txt}"
HELP_PLUGIN=org.apache.maven.plugins:maven-help-plugin:3.5.2
DEPENDENCY_PLUGIN=org.apache.maven.plugins:maven-dependency-plugin:3.8.1
REPO="$PWD"
rm -rf "$DIR"
mkdir -p "$DIR"

finish() { # finish <mode line> [with details]
  printf '%s\n' "$1" > "$MODE_OUT"
  echo "Tests: $1"
  local details=""
  if [ "${2:-}" = details ]; then
    details=$(python3 - "$DIR/report.json" "$DIR/skipped.json" <<'PY'
import json, os, sys
r = json.load(open(sys.argv[1]))
s = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else {'skipped': [], 'own': {}}
p = r.get('pruning', '')
if p.startswith('dependency graph'):
    print(f"Synthetic resolution of {r.get('synthetic', 0)} external artifact(s), pruned by the {p}.")
else:
    print(f"Synthetic resolution of {r.get('synthetic', 0)} external artifact(s), not pruned: {p}.")
print()
print('| Affected module | Reason |')
print('|---|---|')
for m, why in r.get('affected', {}).items():
    print(f"| `{m}` | {why.replace('|', '/')} |")
print()
if s['skipped']:
    print('Tests skipped (still compiled): ' + ', '.join(f'`{m}`' for m in s['skipped']))
for m, why in s['own'].items():
    print(f'`{m}` {why}')
PY
) || details=""
    printf '%s\n' "$details"
  fi
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "#### Tests of ${CONSUMER:-the consumer}"
      echo
      echo "Tests: $1"
      echo
      if [ -n "$details" ]; then printf '%s\n\n' "$details"; fi
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}
fallback() { # fallback <reason>: no pom edited, every test runs
  finish "full (fallback: $1)"
  exit 0
}
show_log() { echo "--- last lines of $1"; tail -n 30 "$1" 2>/dev/null || true; }
field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$DIR/report.json" "$1"; }

if [ ! -s "$PRODUCER_ARTIFACTS" ]; then
  fallback "the producer artifact list is missing or empty (see the producer rebuild step)"
fi

graph_args=()
if [ -n "${GRAPH_URL:-}" ]; then
  if python3 - "$GRAPH_URL" "$DIR/inverted.json" <<'PY'
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
    graph_args=(--graph "$DIR/inverted.json" --producer-slug "${PRODUCER_SLUG:-}")
  fi
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

analyse() {
  python3 "$HERE/affected-modules.py" --effective-pom "$DIR/effective-pom.xml" --repo "$REPO" \
    --producer-artifacts "$PRODUCER_ARTIFACTS" --synthetic "$DIR/synthetic" \
    --report "$DIR/report.json" ${graph_args[@]+"${graph_args[@]}"} "$@"
}
rc=0
analyse || rc=$?
[ "$rc" -eq 0 ] || fallback "the analysis failed (exit $rc)"

if [ "$(field decision)" = resolve ]; then
  n=$(field synthetic)
  echo "Resolving the closures of $n external artifact(s) (synthetic project)"
  # shellcheck disable=SC2086
  if ! (cd "$DIR/synthetic" && mvn $MVN_ARGS -f "$DIR/synthetic/pom.xml" "$DEPENDENCY_PLUGIN:list" \
          -DoutputFile=deps.txt </dev/null > "$DIR/synthetic.log" 2>&1); then
    show_log "$DIR/synthetic.log"
    fallback "Maven error in the synthetic resolution of $n external artifact(s)"
  fi
  analyse --closures || rc=$?
  [ "$rc" -eq 0 ] || fallback "the analysis failed (exit $rc)"
fi

case "$(field decision)" in
  full) fallback "$(field reason | tr '\n' ' ')" ;;
  all) finish "full: every module is affected" details ;;
  targeted)
    python3 "$HERE/skip-tests.py" --repo "$REPO" --report "$DIR/report.json" --out "$DIR/skipped.json" \
      || fallback "the pom edits failed"
    n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["skipped"]))' "$DIR/skipped.json")
    finish "targeted: tests skipped in $n module(s) (still compiled)" details
    ;;
  *) fallback "unexpected analysis decision '$(field decision)'" ;;
esac
