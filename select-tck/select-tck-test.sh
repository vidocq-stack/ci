#!/usr/bin/env bash
# Tests of select-tck.py: which declared TCK runners a pull request must replay.
# Offline: the effective POM is a fixture written next to raw poms on disk.
# Run: bash select-tck/select-tck-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Reactor "rt": core <- ext-knock <- tck-knock ; core <- ext-jwt <- tck-jwt ; codegen used by
# ext-jwt through annotationProcessorPaths only; tests/ aggregator parents the two runners.
ROOT="$TMP/rt"
EFF="$TMP/eff.xml"
G=io.vidocq.rt
: > "$EFF.body"
dep() { printf '<dependency><groupId>%s</groupId><artifactId>%s</artifactId><version>1</version></dependency>' "$G" "$1"; }
apt() { printf '<plugin><artifactId>maven-compiler-plugin</artifactId><configuration><annotationProcessorPaths><path><groupId>%s</groupId><artifactId>%s</artifactId><version>1</version></path></annotationProcessorPaths></configuration></plugin>' "$G" "$1"; }
module() { # module <dir> <artifactId> <packaging> <parent|-> <deps> [plugins]
  local dir="$ROOT/$1" parent=""
  [ "$1" = "." ] && dir="$ROOT"
  mkdir -p "$dir/src/main/java"
  [ "$4" != "-" ] && parent="<parent><groupId>$G</groupId><artifactId>$4</artifactId><version>1</version></parent>"
  printf '<project><modelVersion>4.0.0</modelVersion>%s<groupId>%s</groupId><artifactId>%s</artifactId><version>1</version><packaging>%s</packaging></project>\n' \
    "$parent" "$G" "$2" "$3" > "$dir/pom.xml"
  printf '<project><modelVersion>4.0.0</modelVersion>%s<groupId>%s</groupId><artifactId>%s</artifactId><version>1</version><packaging>%s</packaging><dependencies>%s</dependencies><build><directory>%s/target</directory><plugins>%s</plugins></build></project>\n' \
    "$parent" "$G" "$2" "$3" "$5" "$dir" "${6:-}" >> "$EFF.body"
}
module .              root      pom -    ""
module core           core      jar root ""
module codegen        codegen   jar root ""
module tools          tools     jar root ""
module ext-knock      ext-knock jar root "$(dep core)"
module ext-jwt        ext-jwt   jar root "$(dep core)" "$(apt codegen)"
module tests          tests     pom root ""
module tests/tck-knock tck-knock jar tests "$(dep ext-knock)"
module tests/tck-jwt  tck-jwt   jar tests "$(dep ext-jwt)"
{ echo '<projects>'; cat "$EFF.body"; echo '</projects>'; } > "$EFF"
RUNNERS="tests/tck-knock, tests/tck-jwt"

run() { # run <changed files, one per line> -> prints "selected|reason-kind"
  printf '%s\n' "$1" > "$TMP/changed.txt"
  python3 "$HERE/select-tck.py" --effective-pom "${2:-$EFF}" --repo "$ROOT" --changed-files "$TMP/changed.txt" \
    --modules "${3:-$RUNNERS}" --summary "$TMP/summary.md" 2>"$TMP/err.txt"
}
sel() { run "$@" | sed -n 's/^modules=//p'; }
mode() { run "$@" | sed -n 's/^mode=//p'; }

check "a change in one extension replays its runner only" "tests/tck-knock" "$(sel 'ext-knock/src/main/java/A.java')"
check "the mode says selected" "selected" "$(mode 'ext-knock/src/main/java/A.java')"
check "a change in core replays every runner (both depend on it)" "tests/tck-knock,tests/tck-jwt" "$(sel 'core/src/main/java/C.java')"
check "an annotation processor used by one extension replays its runner" "tests/tck-jwt" "$(sel 'codegen/src/main/java/P.java')"
check "a change in a runner replays that runner" "tests/tck-jwt" "$(sel 'tests/tck-jwt/src/test/java/T.java')"
check "the runners' aggregator pom replays both (parent of both)" "tests/tck-knock,tests/tck-jwt" "$(sel 'tests/pom.xml')"
check "a module no runner depends on replays none" "" "$(sel 'tools/README.md
tools/src/main/resources/x.txt')"
check "  ... and says so" "selected" "$(mode 'tools/src/main/resources/x.txt')"
check "a normalised path is owned by its real module" "tests/tck-jwt" "$(sel 'ext-knock/../codegen/src/main/resources/x.txt')"
check "the root pom replays all" "all" "$(mode 'pom.xml')"
check "  ... every runner" "tests/tck-knock,tests/tck-jwt" "$(sel 'pom.xml')"
check "a file outside every module (.forgejo) replays all" "all" "$(mode '.forgejo/workflows/pr.yml
ext-knock/src/main/java/A.java')"
check "a root script replays all" "all" "$(mode 'check-doc-versions.sh')"
check "docs outside src/ do not count" "tests/tck-knock" "$(sel 'README.md
docs/guide.adoc
ext-knock/src/main/java/A.java')"
check "an empty change list replays all" "all" "$(mode '')"
check "an unknown runner path replays all" "all" "$(mode 'ext-knock/src/main/java/A.java' "$EFF" 'tests/tck-knock, tests/tck-nope')"
check "a missing effective POM replays all" "all" "$(mode 'ext-knock/src/main/java/A.java' "$TMP/nope.xml")"
check "a missing effective POM still lists every runner" "tests/tck-knock,tests/tck-jwt" "$(sel 'ext-knock/src/main/java/A.java' "$TMP/nope.xml")"
echo 'not xml' > "$TMP/bad.xml"
check "a malformed effective POM replays all" "all" "$(mode 'ext-knock/src/main/java/A.java' "$TMP/bad.xml")"
check "a path escaping the repository replays all" "all" "$(mode '../elsewhere/A.java')"

# A runner whose sources name a changed module's artifactId (resolved at run time) is replayed.
mkdir -p "$ROOT/tests/tck-jwt/src/test/resources"
echo "io.vidocq.rt:ext-knock" > "$ROOT/tests/tck-jwt/src/test/resources/deps.txt"
check "a runner naming a changed artifact in src/ is replayed" "tests/tck-knock,tests/tck-jwt" "$(sel 'ext-knock/src/main/java/A.java')"
rm -rf "$ROOT/tests/tck-jwt/src/test/resources"

run 'ext-knock/src/main/java/A.java' >/dev/null
check "the summary names the skipped runner" "yes" "$(grep -q 'tests/tck-jwt' "$TMP/summary.md" && echo yes || echo no)"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
