#!/usr/bin/env bash
# Tests of impacted-matrix.py.
# Run: bash resolve-impacted/impacted-matrix-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/impacted-matrix.py"
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

# vauban -> foy, ravel; ravel -> cyrano; foy + cyrano -> vidocq; chappe -> foy (not impacted).
cat > "$TMP/inverted.json" <<'EOF'
{"schema_version": 1, "generated_at": "2026-10-24T00:00:00Z", "artifacts": {
  "io.vidocq.vauban:vauban-core": {"produced_by": "Vidocq/vauban",
    "consumed_by": [{"repo": "Vidocq/foy", "scope": "compile"}, {"repo": "Vidocq/ravel", "scope": "compile"},
                    {"repo": "Vidocq/vidocq", "scope": "compile"}]},
  "io.vidocq.vauban:vauban-api": {"produced_by": "Vidocq/vauban",
    "consumed_by": [{"repo": "Vidocq/foy", "scope": "provided"}]},
  "io.vidocq.ravel:ravel-core": {"produced_by": "Vidocq/ravel",
    "consumed_by": [{"repo": "Vidocq/cyrano", "scope": "compile"}, {"repo": "Vidocq/ravel", "scope": "test"}]},
  "io.vidocq.cyrano:cyrano-core": {"produced_by": "Vidocq/cyrano",
    "consumed_by": [{"repo": "Vidocq/vidocq", "scope": "compile"}]},
  "io.vidocq.foy:foy-core": {"produced_by": "Vidocq/foy",
    "consumed_by": [{"repo": "Vidocq/vidocq", "scope": "compile"}]},
  "io.vidocq.chappe:chappe-core": {"produced_by": "Vidocq/chappe",
    "consumed_by": [{"repo": "Vidocq/foy", "scope": "compile"}]}
}}
EOF
run() { python3 "$SCRIPT" --graph "$TMP/inverted.json" --producer Vidocq/vauban --impacted "$TMP/impacted.txt"; }
line() { run | grep "^$1=" | cut -d= -f2-; }

printf 'Vidocq/foy\nVidocq/ravel\nVidocq/cyrano\nVidocq/vidocq\n' > "$TMP/impacted.txt"
check "the matrix keeps the topological order" \
  '{"include":[{"repo":"Vidocq/foy"},{"repo":"Vidocq/ravel"},{"repo":"Vidocq/cyrano"},{"repo":"Vidocq/vidocq"}]}' \
  "$(line matrix)"
check "count is the number of consumers" "4" "$(line count)"
check "upstreams are transitive, impacted only, producer left out, in topological order" \
  '{"Vidocq/foy":"","Vidocq/ravel":"","Vidocq/cyrano":"Vidocq/ravel","Vidocq/vidocq":"Vidocq/foy Vidocq/ravel Vidocq/cyrano"}' \
  "$(line upstreams)"
check "the output is valid JSON for fromJSON" "ok" \
  "$(line matrix | python3 -c 'import json,sys; m=json.load(sys.stdin); print("ok" if m["include"][0]["repo"]=="Vidocq/foy" else "ko")')"

# A consumer dropped by the forge filter is not an upstream either.
printf 'Vidocq/foy\nVidocq/cyrano\nVidocq/vidocq\n' > "$TMP/impacted.txt"
check "an upstream missing from the impacted list is not listed" \
  '{"Vidocq/foy":"","Vidocq/cyrano":"","Vidocq/vidocq":"Vidocq/foy Vidocq/cyrano"}' "$(line upstreams)"

: > "$TMP/impacted.txt"
# Forgejo creates no job for an empty matrix, so the jobs that need it stay blocked forever:
# one placeholder entry instead, which the downstream job skips on count 0.
check "no consumer: one placeholder entry and count 0" '{"include":[{"repo":"none"}]}|0' "$(line matrix)|$(line count)"

printf 'Vidocq/foy\n\nVidocq/foy\nVidocq/vauban\n' > "$TMP/impacted.txt"
check "blank lines, duplicates and the producer itself are ignored" '{"include":[{"repo":"Vidocq/foy"}]}' "$(line matrix)"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
