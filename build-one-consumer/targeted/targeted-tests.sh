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
BACKUP="$DIR/backup"
edits_started=false

summary_section() { # summary_section <mode line> [details]
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "#### Tests of ${CONSUMER:-the consumer}"
      echo
      echo "Tests: $1"
      echo
      if [ -n "${2:-}" ]; then printf '%s\n\n' "$2"; fi
    } >> "$GITHUB_STEP_SUMMARY" || true
  fi
}

# Put back every pom copied before the edits and check each one byte for byte.
restore_poms() {
  [ -f "$BACKUP/list" ] || return 1
  local rel ok=0
  while IFS= read -r rel; do
    cp "$BACKUP/$rel/pom.xml" "$REPO/$rel/pom.xml" 2>/dev/null || ok=1
    cmp -s "$BACKUP/$rel/pom.xml" "$REPO/$rel/pom.xml" || ok=1
  done < "$BACKUP/list"
  return "$ok"
}

fallback() { # fallback <reason>: every test runs; never with a pom left edited
  # In a subshell (command substitution), only report the failure to the main shell.
  if [ "${BASHPID:-$$}" != "$$" ]; then exit 1; fi
  trap - ERR
  set +e
  local mode="full (fallback: $1)"
  if [ "$edits_started" = true ] && ! restore_poms; then
    mode="failed: the poms edited for the targeted tests could not be restored ($1)"
    printf '%s\n' "$mode" > "$MODE_OUT"
    echo "::error title=Targeted tests::${CONSUMER:-the consumer}: $mode"
    summary_section "$mode"
    exit 1
  fi
  printf '%s\n' "$mode" > "$MODE_OUT"
  echo "Tests: $mode"
  echo "::notice title=Targeted tests::${CONSUMER:-the consumer}: $mode"
  summary_section "$mode"
  exit 0
}
trap 'fallback "internal error at line $LINENO of targeted-tests.sh"' ERR

finish() { # finish <mode line>: the mode line first, then the details (never fatal)
  printf '%s\n' "$1" > "$MODE_OUT"
  echo "Tests: $1"
  echo "::notice title=Targeted tests::${CONSUMER:-the consumer}: $1"
  trap - ERR
  local details
  details=$(python3 - "$DIR/report.json" "$DIR/skipped.json" 2>/dev/null <<'PY'
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
  summary_section "$1" "$details"
  exit 0
}
show_log() { echo "--- last lines of $1"; tail -n 30 "$1" 2>/dev/null || true; }
field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$DIR/report.json" "$1"; }

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

analyse() {
  python3 "$HERE/affected-modules.py" --effective-pom "$DIR/effective-pom.xml" --repo "$REPO" \
    --upstream-groups "$upstream_groups" \
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

case "$(field decision)" in
  full) fallback "$(field reason | tr '\n' ' ')" ;;
  all) finish "full: every module is affected" ;;
  targeted)
    # A copy of every pom that may be edited, before the first edit.
    mkdir -p "$BACKUP"
    python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["skip"]))' "$DIR/report.json" > "$BACKUP/list"
    while IFS= read -r rel; do
      mkdir -p "$BACKUP/$rel"
      cp "$REPO/$rel/pom.xml" "$BACKUP/$rel/pom.xml"
    done < "$BACKUP/list"
    edits_started=true
    python3 "$SKIP_TESTS_PY" --repo "$REPO" --report "$DIR/report.json" --out "$DIR/skipped.json" \
      || fallback "the pom edits failed"
    n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["skipped"]))' "$DIR/skipped.json")
    finish "targeted: tests skipped in $n module(s) (still compiled)"
    ;;
  *) fallback "unexpected analysis decision '$(field decision)'" ;;
esac
