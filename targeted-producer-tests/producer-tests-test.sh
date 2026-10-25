#!/usr/bin/env bash
# Tests of the producer-side targeted test mode: changed-modules.py (which modules a pull request
# changes, with their reactor dependents) and producer-tests.sh (the orchestration, with every
# fallback). Offline: the effective POM is a fixture and mvn is a stub.
# Run: bash targeted-producer-tests/producer-tests-test.sh
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

# Reactor "rt": core <- ext-knock <- ext-knock-dev ; ext-knock <- example ; core <- ext-other ;
# tooling names acme's ext-knock artifactId in a test resource ; exts/ is a pom parent of ext-x ;
# codegen is used by ext-other through annotationProcessorPaths only.
ROOT="$TMP/rt"
EFF="$TMP/eff.xml"
G=io.vidocq.rt
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
fixture() {
  rm -rf "$ROOT" "$EFF.body"; : > "$EFF.body"
  module .              root          pom root-none ""
  sed -i.bak 's|<parent><groupId>io.vidocq.rt</groupId><artifactId>root-none</artifactId><version>1</version></parent>||' "$ROOT/pom.xml" "$EFF.body"
  rm -f "$ROOT/pom.xml.bak" "$EFF.body.bak"
  module core           core          jar root ""
  module codegen        codegen       jar root ""
  module ext-knock      ext-knock     jar root "$(dep core)"
  module ext-knock-dev  ext-knock-dev jar root "$(dep ext-knock)"
  module example        example       jar root "$(dep ext-knock)"
  module ext-other      ext-other     jar root "$(dep core)" "$(apt codegen)"
  module tooling        tooling       jar root ""
  mkdir -p "$ROOT/tooling/src/test/resources" && echo 'known: ext-knock' > "$ROOT/tooling/src/test/resources/catalog.txt"
  module tooling-user  tooling-user  jar root "$(dep tooling)"
  module agg-mention   agg-mention   jar root ""
  mkdir -p "$ROOT/agg-mention/src/main/resources" && echo 'part of exts' > "$ROOT/agg-mention/src/main/resources/about.txt"
  module exts           exts          pom root ""
  module exts/ext-x     ext-x         jar exts ""
  { echo '<projects>'; cat "$EFF.body"; echo '</projects>'; } > "$EFF"
}

PY="$HERE/changed-modules.py"
analyse() { # analyse <changed paths, one per line> -> exit status; report in $TMP/report.json
  printf '%s\n' "$1" > "$TMP/changed.txt"
  python3 "$PY" --effective-pom "${2:-$EFF}" --repo "$ROOT" --changed-files "$TMP/changed.txt" \
    --report "$TMP/report.json" > "$TMP/analysis.out" 2>&1
  echo $?
}
field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print(v if not isinstance(v,(list,dict)) else " ".join(sorted(v)))' "$TMP/report.json" "$1"; }

fixture
check "extension change: exits 0" "0" "$(analyse 'ext-knock/src/main/java/A.java')"
check "extension change: targeted" "targeted" "$(field decision)"
check "extension change: the module, its dependents, a module naming it in src/" \
  "example ext-knock ext-knock-dev tooling" "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(" ".join(sorted(m for m in r["affected"])))' "$TMP/report.json")"
check "extension change: the others are skipped (non-pom only)" "agg-mention codegen core ext-other exts/ext-x tooling-user" "$(field skip)"
check "a module naming a changed one in src/ runs its tests, its dependents do not" "skip" \
  "$(python3 -c 'import json,sys; print("skip" if "tooling-user" in json.load(open(sys.argv[1]))["skip"] else "affected")' "$TMP/report.json")"
check "extension change: the reason names the changed path" "owns ext-knock/src/main/java/A.java" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["affected"]["ext-knock"])' "$TMP/report.json")"

analyse 'core/src/main/java/C.java' > /dev/null
check "core change: everything that depends on core, and what names those in src/" "agg-mention codegen exts/ext-x tooling-user" "$(field skip)"
analyse "$(printf 'core/src/main/java/C.java\ncodegen/src/main/java/G.java\nexts/ext-x/src/main/java/X.java\ntooling/src/main/java/T.java\nagg-mention/src/main/java/A.java')" > /dev/null
check "nothing left to skip: all" "all" "$(field decision)"

analyse 'example/src/main/java/E.java' > /dev/null
check "example change: only the example" "example" "$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["affected"])))' "$TMP/report.json")"

analyse 'codegen/src/main/java/G.java' > /dev/null
check "annotation processor change: the module using it" "codegen ext-other" "$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["affected"])))' "$TMP/report.json")"

analyse 'exts/pom.xml' > /dev/null
check "pom parent change: its children; naming the pom module itself in src/ does not count" "exts exts/ext-x" "$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["affected"])))' "$TMP/report.json")"

analyse "$(printf 'example/src/main/java/E.java\next-other/README.md\ndocs/guide.adoc')" > /dev/null
check "documentation outside src/ is ignored" "example" "$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["affected"])))' "$TMP/report.json")"

for path in pom.xml .forgejo/workflows/pr.yml .mvn/maven.config scripts/check.sh; do
  analyse "$(printf 'example/src/main/java/E.java\n%s' "$path")" > /dev/null
  check "fallback: $path is in the root module" "full|1" "$(field decision)|$(field reason | grep -c 'root module')"
done
analyse '../outside.txt' > /dev/null
check "fallback: a path that escapes the repository" "full" "$(field decision)"
analyse '' > /dev/null
check "fallback: an empty change list" "full" "$(field decision)"
analyse 'docs/only.md' > /dev/null
check "fallback: documentation only (nothing to build)" "full" "$(field decision)"
echo '<projects><project>' > "$TMP/bad.xml"
analyse 'example/src/main/java/E.java' "$TMP/bad.xml" > /dev/null
check "fallback: an effective POM that does not parse" "full" "$(field decision)"

# --- producer-tests.sh -----------------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/mvn" <<EOF
#!/usr/bin/env bash
echo "\$(basename "\$PWD") \$*" >> "$TMP/mvn-calls"
for a in "\$@"; do
  case "\$a" in
    *:effective-pom)
      [ "\${MVN_FAIL:-}" = effective-pom ] && exit 1
      for b in "\$@"; do case "\$b" in -Doutput=*) cp "$EFF" "\${b#-Doutput=}" ;; esac; done ;;
  esac
done
exit 0
EOF
chmod +x "$TMP/bin/mvn"
run() { # run <changed paths> [VAR=value...] -> exit status
  local changed="$1"; shift
  printf '%s\n' "$changed" > "$TMP/pr-changed-files.txt"
  rm -f "$TMP/mvn-calls" "$TMP/summary" "$TMP/out-vars"; rm -rf "$TMP/work"
  (cd "$ROOT" && env PATH="$TMP/bin:$PATH" CHANGED_FILES="$TMP/pr-changed-files.txt" MODE=targeted \
    MVN_ARGS='-B -ntp' TARGETED_DIR="$TMP/work" GITHUB_STEP_SUMMARY="$TMP/summary" GITHUB_OUTPUT="$TMP/out-vars" \
    GITHUB_REPOSITORY=Vidocq/rt "$@" bash "$HERE/producer-tests.sh") > "$TMP/run.out" 2>&1
  echo $?
}
edited() { grep -rl '<skipITs>true</skipITs>' --include=pom.xml "$ROOT" | sed "s|$ROOT/||; s|/pom.xml||" | sort | paste -sd' ' -; }
out() { sed -n "s/^$1=//p" "$TMP/out-vars"; }

fixture
check "targeted: exits 0" "0" "$(run 'ext-knock/src/main/java/A.java')"
check "targeted: the unaffected non-pom modules are edited" "agg-mention codegen core ext-other exts/ext-x tooling-user" "$(edited)"
check "targeted: the outputs" "targeted|6" "$(out mode)|$(out skipped)"
check "targeted: a notice" "1" "$(grep -c '^::notice title=Targeted producer tests::Vidocq/rt: targeted: tests skipped in 6 module(s) (still compiled)' "$TMP/run.out")"
check "targeted: the summary lists the affected modules" "1" "$(grep -c '| `ext-knock` | owns ext-knock/src/main/java/A.java |' "$TMP/summary")"
check "targeted: one effective POM with the given Maven args, never -DskipTests" "1|0" \
  "$(grep -c '^rt -B -ntp org.apache.maven.plugins:maven-help-plugin:[0-9.]*:effective-pom -Doutput=' "$TMP/mvn-calls")|$(grep -c -- '-DskipTests' "$TMP/mvn-calls")"

fixture
check "full mode: exits 0" "0" "$(run 'ext-knock/src/main/java/A.java' MODE=full)"
check "full mode: no Maven call, no pom edited" "0|" "$(cat "$TMP/mvn-calls" 2>/dev/null | wc -l | tr -d ' ')|$(edited)"
check "full mode: the outputs" "full|0" "$(out mode)|$(out skipped)"
check "an unknown mode fails" "1" "$(run 'ext-knock/src/main/java/A.java' MODE=some)"

fallback_case() { # fallback_case <name> <reason fragment> <changed paths> [VAR=value...]
  local name="$1" frag="$2" changed="$3"; shift 3
  fixture
  check "fallback $name: exits 0" "0" "$(run "$changed" "$@")"
  check "fallback $name: no pom edited" "" "$(edited)"
  check "fallback $name: outputs full" "full|0" "$(out mode)|$(out skipped)"
  check "fallback $name: a notice with the reason" "1" "$(grep -c "^::notice title=Targeted producer tests::Vidocq/rt: full (fallback: .*$frag" "$TMP/run.out")"
  check "fallback $name: the summary says why" "1" "$(grep -c "Tests: full (fallback: .*$frag" "$TMP/summary")"
}
fallback_case "root pom" "root module" 'pom.xml'
fallback_case "CI configuration" "root module" '.forgejo/workflows/pr.yml'
fallback_case "empty list" "changed-file list is missing or empty" ''
fallback_case "missing list" "changed-file list is missing or empty" 'x' CHANGED_FILES="$TMP/none.txt"
fallback_case "effective POM" "effective POM" 'example/src/main/java/E.java' MVN_FAIL=effective-pom
fallback_case "analysis crash" "analysis failed" 'example/src/main/java/E.java' CHANGED_MODULES_PY=/dev/null/none.py

# A failing pom edit puts every pom back, byte for byte.
cat > "$TMP/bad-skip.py" <<'EOF'
import json, os, sys
a = dict(zip(sys.argv[1::2], sys.argv[2::2]))
for rel in json.load(open(a['--report']))['skip']:
    p = os.path.join(a['--repo'], rel, 'pom.xml')
    open(p, 'w').write('broken')
sys.exit(1)
EOF
fixture; rm -rf "$TMP/rt-before"; cp -R "$ROOT" "$TMP/rt-before"
check "restore: a failing pom edit still exits 0" "0" "$(run 'example/src/main/java/E.java' SKIP_TESTS_PY="$TMP/bad-skip.py")"
check "restore: every pom back byte for byte" "" "$(diff -r "$TMP/rt-before" "$ROOT")"
check "restore: full with the reason" "full|1" "$(out mode)|$(grep -c '^Tests: full (fallback: the pom edits failed' "$TMP/run.out")"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
