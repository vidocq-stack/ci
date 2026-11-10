#!/usr/bin/env bash
# Tests of check_brick_versions.py on fixture poms, with the graph, releases and dev versions given
# as files (no network). Run: bash check-brick-versions/check-brick-versions-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/check_brick_versions.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; failures=$((failures + 1)); fi
}

cat > "$TMP/graph.json" <<'J'
{"artifacts": {
  "io.vidocq.vauban:vauban-core": {"produced_by": "Vidocq/vauban", "consumed_by": []},
  "io.vidocq.chappe:chappe-core": {"produced_by": "Vidocq/chappe", "consumed_by": []},
  "io.vidocq.foy:foy-core": {"produced_by": "Vidocq/foy", "consumed_by": []}}}
J
echo '{"vauban": "0.4.0", "chappe": "0.4.0", "foy": "0.3.0"}' > "$TMP/releases.json"
echo '{"vauban": "0.5.0-SNAPSHOT", "chappe": "0.5.0-SNAPSHOT", "foy": "0.3.0-SNAPSHOT"}' > "$TMP/devs.json"

# repo NAME ROOT-VERSION PROPERTIES-XML [MODULE-PROPERTIES-XML]
repo() {
  mkdir -p "$TMP/$1/sub"
  printf '<project xmlns="http://maven.apache.org/POM/4.0.0"><version>%s</version><properties>%s</properties></project>' "$2" "$3" > "$TMP/$1/pom.xml"
  [ -n "${4:-}" ] && printf '<project xmlns="http://maven.apache.org/POM/4.0.0"><properties>%s</properties></project>' "$4" > "$TMP/$1/sub/pom.xml"
}
run() { # repo-name [extra args]
  local name="$1"; shift
  python3 -I "$SCRIPT" --repo "Vidocq/$name" --pom-dir "$TMP/$name" --graph "$TMP/graph.json" \
    --releases "$TMP/releases.json" --devs "$TMP/devs.json" "$@" 2>&1
  echo "rc=$?"
}

repo ok 0.5.0-SNAPSHOT '<vauban.version>0.5.0-SNAPSHOT</vauban.version><chappe.version>0.4.0</chappe.version>'
out=$(run ok)
check "dev SNAPSHOT and latest release are both accepted" "0" "$(grep -c '::warning' <<<"$out")"
check "aligned: exit 0" "1" "$(grep -c '^rc=0' <<<"$out")"

repo stale 0.5.0-SNAPSHOT '<vauban.version>0.3.0-SNAPSHOT</vauban.version><junit.version>5.0</junit.version>'
out=$(run stale)
check "a superseded SNAPSHOT is flagged" "1" "$(grep -c '::warning.*vauban.version> is 0.3.0-SNAPSHOT.*superseded by the release 0.4.0' <<<"$out")"
check "report mode: exit 0 despite the finding" "1" "$(grep -c '^rc=0' <<<"$out")"
check "--strict: exit 1" "1" "$(run stale --strict | grep -c '^rc=1')"

repo old 0.5.0-SNAPSHOT '<vauban.version>0.3.0</vauban.version>'
check "an older release is not the latest release" "1" "$(run old | grep -c '::warning.*0.3.0, expected the latest release 0.4.0 or the development version 0.5.0-SNAPSHOT')"

repo module 0.5.0-SNAPSHOT '' '<chappe.version>0.3.0-SNAPSHOT</chappe.version>'
check "a stale property in a module pom is found, with its path" "1" "$(run module | grep -c '::warning.*sub/pom.xml')"

repo expr 0.5.0-SNAPSHOT '<vauban.version>${some.other}</vauban.version>'
check "a property defined by an expression is not judged" "0" "$(run expr | grep -c '::warning')"

repo vauban 0.5.0-SNAPSHOT '<vauban.version>0.1.0-SNAPSHOT</vauban.version>'
check "the repository's own property is not judged against itself" "0" "$(run vauban | grep -c 'vauban.version')"

# own-version stragglers
repo foy 0.3.0-SNAPSHOT ''
check "a SNAPSHOT superseded by its own release is flagged (straggler)" "1" "$(run foy | grep -c '::warning.*own version 0.3.0-SNAPSHOT is superseded by its release 0.3.0')"
echo '{"vauban": "0.4.0", "chappe": "0.4.0", "foy": "0.2.0"}' > "$TMP/releases.json"
check "a SNAPSHOT behind the development line is flagged" "1" "$(run foy | grep -c '::warning.*own version 0.3.0-SNAPSHOT lags the development line (0.5.0-SNAPSHOT)')"
check "a brick on the development line is not flagged" "0" "$(run ok | grep -c 'own version')"

# unknown brick data: no guess
echo '{}' > "$TMP/releases.json"; echo '{}' > "$TMP/devs.json"
check "no data about a brick: no finding" "0" "$(run stale | grep -c '::warning')"

[ "$failures" -eq 0 ] && echo "all check-brick-versions tests passed" || { echo "$failures test(s) failed"; exit 1; }
