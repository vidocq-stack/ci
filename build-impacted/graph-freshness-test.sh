#!/usr/bin/env bash
# Tests of graph-freshness.py.
# Run: bash build-impacted/graph-freshness-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/graph-freshness.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected '$expected', got '$actual'"
    failures=$((failures + 1))
  fi
}

graph() { printf '{"schema_version": 1, "generated_at": "%s", "artifacts": {}}' "$1" > "$TMP/inverted.json"; }
data() { printf '{"schema_version": 1, "repo": "Vidocq/vauban", "updated_at": "%s", "produces": []}' "$1" > "$TMP/data.json"; }
run() { # run <require-fresh-graph> -> "<exit status>|<first line of output>"
  local out rc
  out=$(python3 "$SCRIPT" "$TMP/inverted.json" "$TMP/data.json" "$1" 2>&1); rc=$?
  echo "$rc|$(echo "$out" | head -1)"
}

graph 2026-10-22T23:00:00Z; data 2026-10-22T22:55:58Z
check "a graph newer than the producer data passes" \
  "0|dep-graph is fresh: graph generated 2026-10-22T23:00:00Z, producer data updated 2026-10-22T22:55:58Z" "$(run true)"

graph 2026-10-22T22:55:58Z
check "a graph generated the same second passes" "0" "$(run true | cut -d'|' -f1)"

graph 2026-06-08T14:46:12Z
check "a stale graph is an error when freshness is required" \
  "1|::error title=Stale dependency graph::graph/inverted.json was generated at 2026-06-08T14:46:12Z, before the producer data (Vidocq/vauban) was updated at 2026-10-22T22:55:58Z. The list of consumers to rebuild may miss repositories. Rebuild the graph in the dependency-graph repository, then run this job again." \
  "$(run true)"
check "a stale graph is only a warning when freshness is not required" \
  "0|::warning title=Stale dependency graph::graph/inverted.json was generated at 2026-06-08T14:46:12Z, before the producer data (Vidocq/vauban) was updated at 2026-10-22T22:55:58Z. The list of consumers to rebuild may miss repositories. Rebuild the graph in the dependency-graph repository, then run this job again." \
  "$(run false)"

graph 2026-10-23T00:55:57+02:00
check "timestamps with an offset are compared as instants" "1" "$(run true | cut -d'|' -f1)"

printf '{"artifacts": {}}' > "$TMP/inverted.json"
check "a graph without generated_at is an error when freshness is required" \
  "1|::error title=Stale dependency graph::cannot tell whether the dependency graph is fresh: graph/inverted.json has no valid generated_at." \
  "$(run true)"
check "a graph without generated_at is a warning otherwise" "0|::warning" "$(run false | cut -c1-11)"

graph 2026-10-22T23:00:00Z
printf '{"produces": []}' > "$TMP/data.json"
check "producer data without updated_at is an error when freshness is required" \
  "1|::error title=Stale dependency graph::cannot tell whether the dependency graph is fresh: the producer data has no valid updated_at." \
  "$(run true)"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
