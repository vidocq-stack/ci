#!/usr/bin/env bash
# Tests of the targeted test mode of build-one-consumer: the analysis (affected-modules.py),
# the pom edits (skip-tests.py), the producer artifact list (producer-artifacts.py, through
# rebuild-producer.sh) and the orchestration with every fallback (targeted-tests.sh).
# Offline: the effective POM is a fixture, and mvn is a stub that copies it or writes the
# closures of the synthetic project.
# Run: bash build-one-consumer/targeted/targeted-test.sh
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

# ---------------------------------------------------------------------------------------------
# Fixture: the consumer reactor "acme" (raw poms on disk + its effective POM) and the producer
# "knock" (artifacts knock-parent, knock-api, knock-core).
# ---------------------------------------------------------------------------------------------
ROOT="$TMP/acme"
EFF="$TMP/acme-eff.xml"
G=io.vidocq.acme
dep() { # dep <g:a> <version> [scope] [extra xml]
  printf '<dependency><groupId>%s</groupId><artifactId>%s</artifactId><version>%s</version>%s%s</dependency>' \
    "${1%%:*}" "${1#*:}" "$2" "${3:+<scope>$3</scope>}" "${4:-}"
}
module() { # module <dir> <artifactId> <packaging> <parent artifactId|-> <deps xml> <plugins xml> [raw extra] [eff extra]
  local dir="$ROOT/$1" parent=""
  mkdir -p "$dir"
  case "$4" in
    -) ;;
    *:*:*) parent="<parent><groupId>${4%%:*}</groupId><artifactId>$(echo "$4" | cut -d: -f2)</artifactId><version>${4##*:}</version></parent>" ;;
    *) parent="<parent><groupId>$G</groupId><artifactId>$4</artifactId><version>0.4.0-PR1.x</version></parent>" ;;
  esac
  cat > "$dir/pom.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  ${parent}
  <groupId>$G</groupId>
  <artifactId>$2</artifactId>
  <version>0.4.0-PR1.x</version>
  <packaging>$3</packaging>
${7:-}
</project>
EOF
  cat >> "$EFF.body" <<EOF
  <project>
    <modelVersion>4.0.0</modelVersion>
    ${parent}
    <groupId>$G</groupId>
    <artifactId>$2</artifactId>
    <version>0.4.0-PR1.x</version>
    <packaging>$3</packaging>
    <properties><knock.version>0.4.0-PR1.abc</knock.version><peano.version>1.0</peano.version></properties>
    ${8:-}
    <dependencies>$5</dependencies>
    <build><directory>$dir/target</directory><plugins>$6</plugins></build>
  </project>
EOF
}
compiler_apt() { # annotationProcessorPaths naming <g:a> [version]
  printf '<plugin><groupId>org.apache.maven.plugins</groupId><artifactId>maven-compiler-plugin</artifactId><version>3.14.0</version><configuration><annotationProcessorPaths><path><groupId>%s</groupId><artifactId>%s</artifactId>%s</path></annotationProcessorPaths></configuration></plugin>' \
    "${1%%:*}" "${1#*:}" "${2:+<version>$2</version>}"
}
INVOKER='<plugin><groupId>org.apache.maven.plugins</groupId><artifactId>maven-invoker-plugin</artifactId><version>3.9.0</version></plugin>'
nested_pom() { # nested_pom <file> <groupId> <artifactId> <deps xml>
  mkdir -p "$(dirname "$1")"
  printf '<project><modelVersion>4.0.0</modelVersion><groupId>%s</groupId><artifactId>%s</artifactId><version>1.0</version><dependencies>%s</dependencies></project>\n' \
    "$2" "$3" "$4" > "$1"
}

build_fixture() {
  rm -rf "$ROOT" "$EFF" "$EFF.body"
  module . acme-parent pom - "" ""
  module core acme-core jar acme-parent "$(dep org.junit.jupiter:junit-jupiter 5.11.0 test)" ""
  module knock-user acme-knock-user jar acme-parent "$(dep io.vidocq.knock:knock-core 0.4.0-PR1.abc)" ""
  module app acme-app jar acme-parent "$(dep $G:acme-knock-user 0.4.0-PR1.x)" ""
  module testscope acme-testscope jar acme-parent "$(dep io.vidocq.knock:knock-api 0.4.0-PR1.abc test)" ""
  module plugindep acme-plugindep jar acme-parent "" \
    "<plugin><groupId>org.example</groupId><artifactId>gen-maven-plugin</artifactId><version>1.0</version><dependencies>$(dep io.vidocq.knock:knock-core 0.4.0-PR1.abc)</dependencies></plugin>"
  module codegen acme-codegen jar acme-parent "$(dep io.vidocq.knock:knock-core 0.4.0-PR1.abc provided)" ""
  module apt-user acme-apt-user jar acme-parent "" "$(compiler_apt $G:acme-codegen 0.4.0-PR1.x)"
  module bom acme-bom pom acme-parent "" "" "" \
    "<dependencyManagement><dependencies>$(dep io.vidocq.knock:knock-core 0.4.0-PR1.abc)</dependencies></dependencyManagement>"
  module invoker acme-invoker maven-plugin acme-parent "" "$INVOKER"
  nested_pom "$ROOT/invoker/src/it/simple/pom.xml" com.example simple "$(dep io.vidocq.knock:knock-core @knock.version@)"
  module invoker-clean acme-invoker-clean maven-plugin acme-parent "" "$INVOKER"
  nested_pom "$ROOT/invoker-clean/src/it/x/pom.xml" io.vidocq.it fixture-app \
    "$(dep io.vidocq.it:fixture-lib 1.0)$(dep io.vidocq.peano:peano-api @peano.version@)$(dep org.example:thing 2.0)"
  nested_pom "$ROOT/invoker-clean/src/it/x/lib/pom.xml" io.vidocq.it fixture-lib ""
  module via-cyrano acme-via-cyrano jar acme-parent "$(dep io.vidocq.cyrano:cyrano-core 0.4.0-SNAPSHOT)" "" "" \
    "<dependencyManagement><dependencies>$(dep org.slf4j:slf4j-api 2.0.16)</dependencies></dependencyManagement>"
  module via-peano acme-via-peano jar acme-parent "$(dep io.vidocq.peano:peano-api 1.0)" ""
  module grouped acme-grouped pom acme-parent "$(dep io.vidocq.knock:knock-core 0.4.0-PR1.abc)" ""
  module grouped/child acme-grouped-child jar acme-grouped "" ""
  module own-skip acme-own-skip jar acme-parent "" "" "  <properties><skipTests>false</skipTests></properties>"
  { echo '<?xml version="1.0" encoding="UTF-8"?>'; echo '<projects>'; cat "$EFF.body"; echo '</projects>'; } > "$EFF"
  rm -f "$EFF.body"
}

printf 'io.vidocq.knock:knock-parent\nio.vidocq.knock:knock-api\nio.vidocq.knock:knock-core\n' > "$TMP/producer.txt"
cat > "$TMP/inverted.json" <<'EOF'
{"schema_version": 1, "generated_at": "2026-10-24T00:00:00Z", "artifacts": {
  "io.vidocq.knock:knock-core": {"produced_by": "Vidocq/knock",
    "consumed_by": [{"repo": "Vidocq/cyrano", "scope": "compile"}, {"repo": "Vidocq/acme", "scope": "compile"}]},
  "io.vidocq.cyrano:cyrano-core": {"produced_by": "Vidocq/cyrano",
    "consumed_by": [{"repo": "Vidocq/acme", "scope": "compile"}]},
  "io.vidocq.peano:peano-api": {"produced_by": "Vidocq/peano",
    "consumed_by": [{"repo": "Vidocq/acme", "scope": "compile"}]}
}}
EOF

ANALYSIS="$HERE/affected-modules.py"
analyse() { # analyse [extra args] -> exit status; report in $TMP/report.json
  python3 "$ANALYSIS" --effective-pom "$EFF" --repo "$ROOT" --producer-artifacts "$TMP/producer.txt" \
    --synthetic "$TMP/synth" --report "$TMP/report.json" ${UPSTREAM_GROUPS:+--upstream-groups "$UPSTREAM_GROUPS"} "$@" > "$TMP/analysis.out" 2>&1
  echo $?
}
field() { python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); v=r.get(sys.argv[2]); print(v if not isinstance(v,(list,dict)) else json.dumps(v, sort_keys=True))' "$TMP/report.json" "$1"; }
status() { # status <module dir> -> affected | skip | none
  python3 - "$TMP/report.json" "$1" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); m = sys.argv[2]
print('affected' if m in r.get('affected', {}) else 'skip' if m in r.get('skip', []) else 'none')
PY
}
reason() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["affected"].get(sys.argv[2], ""))' "$TMP/report.json" "$1"; }
synth_gas() { python3 -c 'import json,sys; print(" ".join(sorted(set(v["ga"] for v in json.load(open(sys.argv[1])).values()))))' "$TMP/synth/index.json"; }
resolve_synth() { # the stub of `dependency:list`: closure of each synthetic module from closures.txt
  python3 - "$TMP/synth" "$TMP/closures.txt" <<'PY'
import json, os, sys
d, table = sys.argv[1], {}
for line in open(sys.argv[2]):
    ga, _, deps = line.strip().partition(' ')
    table[ga] = deps.split()
for name, e in json.load(open(os.path.join(d, 'index.json'))).items():
    with open(os.path.join(d, name, 'deps.txt'), 'w') as f:
        f.write('\nThe following files have been resolved:\n')
        for x in table.get(e['ga'], []):
            f.write(f'   {x}:jar:1.0:compile -- module x\n')
PY
}
printf 'io.vidocq.cyrano:cyrano-core io.vidocq.knock:knock-core org.slf4j:slf4j-api\nio.vidocq.peano:peano-api org.slf4j:slf4j-api\n' > "$TMP/closures.txt"

# --- Analysis, with the dependency graph -----------------------------------------------------
build_fixture
check "phase 1: exits 0" "0" "$(analyse --graph "$TMP/inverted.json" --producer-slug Vidocq/knock)"
check "phase 1: asks for the closures of the suspect externals" "resolve" "$(field decision)"
check "phase 1: the graph prunes peano (it does not consume knock), cyrano stays suspect" \
  "io.vidocq.cyrano:cyrano-core" "$(synth_gas)"
check "synthetic: each module resolves its artifact as a pom (no jar download)" "1" \
  "$(grep -c '<artifactId>cyrano-core</artifactId><version>0.4.0-SNAPSHOT</version><type>pom</type>' "$TMP"/synth/m*/pom.xml)"
check "synthetic: a dependency keeps the dependencyManagement of its module" "1" \
  "$(grep -c '<dependencyManagement>' "$TMP"/synth/m*/pom.xml)"
resolve_synth
check "phase 2: exits 0" "0" "$(analyse --graph "$TMP/inverted.json" --producer-slug Vidocq/knock --closures)"
check "phase 2: targeted" "targeted" "$(field decision)"
check "leaf: a module without any producer artifact is not affected" "skip" "$(status core)"
check "direct compile dependency: affected" "affected" "$(status knock-user)"
check "direct dependency: the reason names the artifact" "dependency(compile) io.vidocq.knock:knock-core" "$(reason knock-user)"
check "reactor dependent of an affected module: affected" "affected" "$(status app)"
check "test-scope dependency: affected" "dependency(test) io.vidocq.knock:knock-api" "$(reason testscope)"
check "plugin dependency: affected" "plugin dependency io.vidocq.knock:knock-core" "$(reason plugindep)"
check "annotationProcessorPaths through a reactor codegen module: affected" "affected" "$(status apt-user)"
check "annotationProcessorPaths: the reason names the codegen module" "depends on reactor module acme-codegen" "$(reason apt-user)"
check "pom-packaged module, unaffected: never in the skip list" "none" "$(status bom)"
check "pom-packaged root: never in the skip list" "none" "$(status .)"
check "nested invoker build naming the producer: affected" "1" "$(reason invoker | grep -c 'nested build io.vidocq.knock:knock-core')"
check "nested build naming only its own projects and pruned externals: not affected" "skip" "$(status invoker-clean)"
check "intermediate upstream from central-snapshots: matched by groupId:artifactId, whatever the producer version its pom declares" \
  "1" "$(grep -c 'io.vidocq.knock:knock-core:jar:1.0' "$TMP"/synth/m*/deps.txt)"
check "transitive through an external jar: affected" \
  "io.vidocq.knock:knock-core via dependency io.vidocq.cyrano:cyrano-core" "$(reason via-cyrano)"
check "external of a repo that does not consume the producer: not affected" "skip" "$(status via-peano)"
check "affected pom parent: its child is affected" "affected" "$(status grouped/child)"
check "affected pom module: affected but never edited" "affected" "$(status grouped)"
check "skip list: every unaffected non-pom module" '["core", "invoker-clean", "own-skip", "via-peano"]' "$(field skip)"

# --- Analysis, without the graph: every io.vidocq external is suspect ------------------------
analyse > /dev/null
check "no graph: peano is resolved too" "io.vidocq.cyrano:cyrano-core io.vidocq.peano:peano-api" "$(synth_gas)"
resolve_synth
analyse --closures > /dev/null
check "no graph: same selection once the closures are known" '["core", "invoker-clean", "own-skip", "via-peano"]' "$(field skip)"

# --- Fallbacks of the analysis ---------------------------------------------------------------
: > "$TMP/empty.txt"
python3 "$ANALYSIS" --effective-pom "$EFF" --repo "$ROOT" --producer-artifacts "$TMP/empty.txt" \
  --synthetic "$TMP/synth" --report "$TMP/report.json" > /dev/null 2>&1
check "fallback: empty producer artifact set" "full" "$(field decision)"
check "fallback: the reason says so" "1" "$(field reason | grep -c 'producer artifact')"

analyse --graph "$TMP/inverted.json" --producer-slug Vidocq/knock > /dev/null
rm -f "$TMP"/synth/m000/deps.txt
analyse --graph "$TMP/inverted.json" --producer-slug Vidocq/knock --closures > /dev/null
check "fallback: a closure Maven did not write" "full" "$(field decision)"
check "fallback: the reason names the artifact" "1" "$(field reason | grep -c 'io.vidocq.cyrano:cyrano-core')"

build_fixture
module apt-ext acme-apt-ext jar acme-parent "" "$(compiler_apt io.vidocq.cyrano:cyrano-apt)"
sed -i.bak 's|</projects>||' "$EFF" && cat "$EFF.body" >> "$EFF" && echo '</projects>' >> "$EFF" && rm -f "$EFF.body" "$EFF.bak"
analyse --graph "$TMP/inverted.json" --producer-slug Vidocq/knock > /dev/null
check "fallback: a suspect external without a version (closure cannot be established)" "full" "$(field decision)"
check "fallback: the reason names it" "1" "$(field reason | grep -c 'io.vidocq.cyrano:cyrano-apt')"

build_fixture
nested_pom "$ROOT/core/src/test/projects/p/pom.xml" com.example p "$(dep io.vidocq.cyrano:cyrano-core @no.such.version@)"
analyse --graph "$TMP/inverted.json" --producer-slug Vidocq/knock > /dev/null
check "fallback: a suspect external of a nested build with an unknown version" "full" "$(field decision)"

build_fixture
nested_pom "$ROOT/knock-user/src/it/p/pom.xml" com.example p "$(dep io.vidocq.cyrano:cyrano-core @no.such.version@)"
analyse --graph "$TMP/inverted.json" --producer-slug Vidocq/knock > /dev/null
check "no fallback: the same doubt in a module already affected" "resolve" "$(field decision)"

build_fixture
mkdir -p "$ROOT/core/src/it/bad" && printf '<project><broken>\n' > "$ROOT/core/src/it/bad/pom.xml"
analyse --graph "$TMP/inverted.json" --producer-slug Vidocq/knock > /dev/null
resolve_synth; analyse --graph "$TMP/inverted.json" --producer-slug Vidocq/knock --closures > /dev/null
check "unreadable nested pom: its module is affected (doubt), no fallback" "affected" "$(status core)"

build_fixture
printf '<project><artifactId>acme-core</artifactId>\n' > "$ROOT/core/pom.xml"
check "fallback: an unparsable reactor pom (exit 0)" "0" "$(analyse)"
check "fallback: an unparsable reactor pom" "full" "$(field decision)"

build_fixture
echo '<projects><project>' > "$EFF"
analyse > /dev/null
check "fallback: an unparsable effective POM" "full" "$(field decision)"

build_fixture
cat > "$ROOT/bom/pom.xml" <<EOF
<project><modelVersion>4.0.0</modelVersion><groupId>$G</groupId><artifactId>acme-bom</artifactId><version>1</version><packaging>pom</packaging>
<dependencyManagement><dependencies><dependency><groupId>\${knock.group}</groupId><artifactId>knock-bom</artifactId><version>1</version><type>pom</type><scope>import</scope></dependency></dependencies></dependencyManagement></project>
EOF
analyse > /dev/null
check "fallback: a BOM import the script cannot resolve" "full" "$(field decision)"

build_fixture
cat > "$ROOT/core/pom.xml" <<EOF
<project><modelVersion>4.0.0</modelVersion><groupId>$G</groupId><artifactId>acme-core</artifactId><version>1</version>
<dependencyManagement><dependencies><dependency><groupId>io.vidocq.knock</groupId><artifactId>knock-parent</artifactId><version>1</version><type>pom</type><scope>import</scope></dependency></dependencies></dependencyManagement></project>
EOF
analyse --graph "$TMP/inverted.json" --producer-slug Vidocq/knock > /dev/null
check "BOM import of a producer artifact (inlined in the effective POM): affected" "BOM import io.vidocq.knock:knock-parent" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["direct"].get("core",""))' "$TMP/report.json")"

build_fixture
mkdir -p "$ROOT/.mvn"
printf '<extensions><extension><groupId>io.vidocq.knock</groupId><artifactId>knock-core</artifactId><version>1</version></extension></extensions>\n' > "$ROOT/.mvn/extensions.xml"
analyse > /dev/null
check "fallback: a core extension (.mvn/extensions.xml) of the producer" "full" "$(field decision)"

# --- skip-tests.py ---------------------------------------------------------------------------
build_fixture
analyse --graph "$TMP/inverted.json" --producer-slug Vidocq/knock > /dev/null; resolve_synth
analyse --graph "$TMP/inverted.json" --producer-slug Vidocq/knock --closures > /dev/null
cp -R "$ROOT" "$TMP/acme-before"
python3 "$HERE/skip-tests.py" --repo "$ROOT" --report "$TMP/report.json" --out "$TMP/skipped.json" > "$TMP/skip.out" 2>&1
check "skip: exits 0" "0" "$?"
check "skip: the properties go into the project <properties> of an unaffected module" "1" \
  "$(grep -c '<properties><skipTests>true</skipTests><skipITs>true</skipITs><invoker.skip>true</invoker.skip></properties>' "$ROOT/core/pom.xml")"
check "skip: an unaffected maven-plugin module too" "1" "$(grep -c '<invoker.skip>true</invoker.skip>' "$ROOT/invoker-clean/pom.xml")"
check "skip: a property the pom declares itself keeps its value, the others are added" \
  "<properties><skipITs>true</skipITs><invoker.skip>true</invoker.skip><skipTests>false</skipTests></properties>" \
  "$(grep -o '<properties>.*</properties>' "$ROOT/own-skip/pom.xml")"
check "skip: pom-packaged modules are never edited" "" "$(diff -r "$TMP/acme-before/bom" "$ROOT/bom"; diff "$TMP/acme-before/pom.xml" "$ROOT/pom.xml"; diff "$TMP/acme-before/grouped/pom.xml" "$ROOT/grouped/pom.xml")"
check "skip: affected modules are never edited" "" "$(diff "$TMP/acme-before/knock-user/pom.xml" "$ROOT/knock-user/pom.xml"; diff "$TMP/acme-before/app/pom.xml" "$ROOT/app/pom.xml")"
check "skip: the result lists the modules edited and the values kept" '["core", "invoker-clean", "own-skip", "via-peano"]|{"own-skip": "keeps its own skipTests=false"}' \
  "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(json.dumps(r["skipped"])+"|"+json.dumps(r["own"]))' "$TMP/skipped.json")"
check "skip: the edited pom is still well-formed XML" "ok" \
  "$(python3 -c 'import xml.etree.ElementTree as E,sys; E.parse(sys.argv[1]); print("ok")' "$ROOT/core/pom.xml")"
cp "$TMP/acme-before/core/pom.xml" "$ROOT/core/pom.xml"
printf '<project><modelVersion>4.0.0</modelVersion><artifactId>acme-core</artifactId><properties><a>1</a></properties></project>' > "$ROOT/core/pom.xml"
python3 "$HERE/skip-tests.py" --repo "$ROOT" --report "$TMP/report.json" --out "$TMP/skipped.json" > /dev/null 2>&1
check "skip: an existing <properties> gets the three properties first" "1" \
  "$(grep -c '<properties><skipTests>true</skipTests><skipITs>true</skipITs><invoker.skip>true</invoker.skip><a>1</a></properties>' "$ROOT/core/pom.xml")"

# --- producer-artifacts.py and rebuild-producer.sh -------------------------------------------
cat > "$TMP/producer-eff.xml" <<'EOF'
<projects xmlns="http://maven.apache.org/POM/4.0.0">
  <project><groupId>io.vidocq.knock</groupId><artifactId>knock-parent</artifactId><packaging>pom</packaging></project>
  <project><parent><groupId>io.vidocq.knock</groupId><artifactId>knock-parent</artifactId></parent><artifactId>knock-core</artifactId></project>
</projects>
EOF
python3 "$HERE/producer-artifacts.py" "$TMP/producer-eff.xml" "$TMP/out.txt" > /dev/null 2>&1
check "producer artifacts: every module of the reactor, groupId inherited" \
  "io.vidocq.knock:knock-core|io.vidocq.knock:knock-parent" "$(sort "$TMP/out.txt" | paste -sd'|' -)"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/mvn" <<EOF
#!/usr/bin/env bash
echo "\$(basename "\$PWD") \$*" >> "$TMP/mvn-calls"
for a in "\$@"; do
  case "\$a" in
    *:effective-pom)
      [ "\${MVN_FAIL:-}" = effective-pom ] && exit 1
      for b in "\$@"; do case "\$b" in -Doutput=*) cp "\$EFF_FIXTURE" "\${b#-Doutput=}" ;; esac; done ;;
    *:evaluate)
      [ "\${MVN_FAIL:-}" = evaluate ] && exit 1
      printf '%s' "\${STUB_LOCAL_REPO:-}"; exit 0 ;;
    *:list)
      [ "\${MVN_FAIL:-}" = list ] && exit 1
      python3 - "\$PWD" "$TMP/closures.txt" <<'PY'
import json, os, sys
d, table = sys.argv[1], {}
for line in open(sys.argv[2]):
    ga, _, deps = line.strip().partition(' ')
    table[ga] = deps.split()
for name, e in json.load(open(os.path.join(d, 'index.json'))).items():
    with open(os.path.join(d, name, 'deps.txt'), 'w') as f:
        for x in table.get(e['ga'], []):
            f.write(f'   {x}:jar:1.0:compile\n')
PY
      ;;
  esac
done
exit 0
EOF
chmod +x "$TMP/bin/mvn"

mkdir -p "$TMP/producer"
printf '<project><groupId>io.vidocq.knock</groupId><artifactId>knock-parent</artifactId><version>0.4.0-SNAPSHOT</version></project>\n' > "$TMP/producer/pom.xml"
run_producer() { # run_producer [VAR=value...] -> exit status
  rm -f "$TMP/mvn-calls"; rm -rf "$TMP/runner"; mkdir -p "$TMP/runner"
  env PATH="$TMP/bin:$PATH" RUNNER_TEMP="$TMP/runner" PRODUCER_DIR="$TMP/producer" \
    PRODUCER_VERSION=0.4.0-PR1.abc PRODUCER_MVN_ARGS='-B -ntp' EFF_FIXTURE="$TMP/producer-eff.xml" \
    "$@" bash "$HERE/../rebuild-producer.sh" > "$TMP/producer.out" 2>&1
  echo $?
}
check "producer: full mode, the rebuild is unchanged" "0" "$(run_producer)"
check "producer: full mode runs no effective POM" "0" "$(grep -c effective-pom "$TMP/mvn-calls")"
check "producer: full mode writes no artifact list" "no" "$([ -e "$TMP/runner/targeted/producer-artifacts.txt" ] && echo yes || echo no)"
check "producer: targeted mode succeeds" "0" "$(run_producer TESTS=targeted)"
check "producer: targeted mode lists the producer artifacts after the install" \
  "io.vidocq.knock:knock-core|io.vidocq.knock:knock-parent" "$(sort "$TMP/runner/targeted/producer-artifacts.txt" | paste -sd'|' -)"
check "producer: the effective POM runs after the install, with the producer's Maven args" \
  "install|effective-pom" "$(grep -oE ' install | [^ ]*:effective-pom' "$TMP/mvn-calls" | sed 's/.*:effective-pom/effective-pom/; s/ //g' | paste -sd'|' -)"
check "producer: a failing effective POM never fails the rebuild" "0" "$(run_producer TESTS=targeted MVN_FAIL=effective-pom)"
check "producer: ... and leaves an empty artifact list (the consumer then falls back)" "0" \
  "$(wc -c < "$TMP/runner/targeted/producer-artifacts.txt" | tr -d ' ')"

# --- targeted-tests.sh: the orchestration, with every fallback --------------------------------
run_targeted() { # run_targeted [VAR=value...] -> exit status
  rm -f "$TMP/mvn-calls" "$TMP/summary" "$TMP/mode.txt"; rm -rf "$TMP/work"
  (cd "$ROOT" && env PATH="$TMP/bin:$PATH" TARGETED_DIR="$TMP/work" GITHUB_STEP_SUMMARY="$TMP/summary" \
    TESTS_MODE_OUT="$TMP/mode.txt" PRODUCER_ARTIFACTS="$TMP/producer.txt" CONSUMER=Vidocq/acme \
    PRODUCER_SLUG=Vidocq/knock MVN_ARGS='-B -ntp -Dx=1' EFF_FIXTURE="$EFF" \
    GRAPH_URL="file://$TMP/inverted.json" "$@" bash "$HERE/targeted-tests.sh") > "$TMP/targeted.out" 2>&1
  echo $?
}
edited() { grep -rl '<skipITs>true</skipITs>' --include=pom.xml "$ROOT" | sed "s|$ROOT/||; s|/pom.xml||" | sort | paste -sd' ' -; }

build_fixture
check "targeted: exits 0" "0" "$(run_targeted)"
check "targeted: the mode line counts the modules whose tests are skipped" \
  "targeted: tests skipped in 4 module(s) (still compiled)" "$(cat "$TMP/mode.txt")"
check "targeted: the unaffected non-pom modules are edited" "core invoker-clean own-skip via-peano" "$(edited)"
check "targeted: the effective POM runs with the build's Maven args" "1" \
  "$(grep -c '^acme -B -ntp -Dx=1 org.apache.maven.plugins:maven-help-plugin:[0-9.]*:effective-pom -Doutput=' "$TMP/mvn-calls")"
check "targeted: one synthetic resolution, with the build's Maven args, its modules in parallel" "1" \
  "$(grep -c '^synthetic -B -ntp -Dx=1 -T 1C -f .*/synthetic/pom.xml org.apache.maven.plugins:maven-dependency-plugin:[0-9.]*:list -DoutputFile=deps.txt' "$TMP/mvn-calls")"
check "targeted: never -DskipTests on a command line" "0" "$(grep -c -- '-DskipTests' "$TMP/mvn-calls")"
check "summary: the mode" "1" "$(grep -c 'Tests: targeted: tests skipped in 4 module(s) (still compiled)' "$TMP/summary")"
check "summary: each affected module with its reason" "1" \
  "$(grep -c '| `testscope` | dependency(test) io.vidocq.knock:knock-api |' "$TMP/summary")"
check "summary: the dependency graph pruned the synthetic resolution" "1" "$(grep -c 'dependency graph' "$TMP/summary")"

build_fixture
run_targeted GRAPH_URL="file://$TMP/no-such-graph.json" > /dev/null
check "no graph: still targeted, without pruning" "targeted: tests skipped in 4 module(s) (still compiled)" "$(cat "$TMP/mode.txt")"
check "no graph: the summary says the resolution was not pruned" "1" "$(grep -c 'not pruned' "$TMP/summary")"

fallback_case() { # fallback_case <name> <expected reason fragment> [VAR=value...]
  local name="$1" frag="$2"; shift 2
  build_fixture
  check "fallback $name: exits 0" "0" "$(run_targeted "$@")"
  check "fallback $name: full mode with its reason" "1" "$(grep -c "^full (fallback: .*$frag" "$TMP/mode.txt")"
  check "fallback $name: no pom edited" "" "$(edited)"
  check "fallback $name: the summary says why" "1" "$(grep -c "Tests: full (fallback: .*$frag" "$TMP/summary")"
}
fallback_case "effective POM" "effective POM" MVN_FAIL=effective-pom
fallback_case "synthetic resolution" "synthetic resolution" MVN_FAIL=list
fallback_case "empty producer set" "producer artifact" PRODUCER_ARTIFACTS="$TMP/empty.txt"
fallback_case "missing producer set" "producer artifact" PRODUCER_ARTIFACTS="$TMP/nothing-here.txt"
fallback_case "analysis crash" "analysis failed" PRODUCER_ARTIFACTS="$TMP"
fallback_case "unwritten effective POM" "effective POM" EFF_FIXTURE=/dev/null/none

build_fixture
printf '<project><artifactId>acme-core</artifactId>\n' > "$ROOT/core/pom.xml"
run_targeted > /dev/null
check "fallback unparsable pom: full mode with its reason" "1" "$(grep -c '^full (fallback: .*pom.xml' "$TMP/mode.txt")"

# Every module affected: nothing to skip, the build is the full one.
build_fixture
printf 'io.vidocq.knock:knock-core\norg.junit.jupiter:junit-jupiter\nio.vidocq.peano:peano-api\nio.vidocq.acme:acme-parent\n' > "$TMP/all.txt"
run_targeted PRODUCER_ARTIFACTS="$TMP/all.txt" > /dev/null
check "all affected: the mode line says so" "full: every module is affected" "$(cat "$TMP/mode.txt")"
check "all affected: no pom edited" "" "$(edited)"

# --- Coordinates written as text, nested coordinates, source mentions (review I3, M5, M6) ------
add_module() { # add_module <module args...>: one more module in the built fixture
  module "$@"
  sed -i.bak 's|</projects>||' "$EFF" && cat "$EFF.body" >> "$EFF" && echo '</projects>' >> "$EFF" && rm -f "$EFF.body" "$EFF.bak"
}
exec_args() { printf '<plugin><groupId>org.codehaus.mojo</groupId><artifactId>exec-maven-plugin</artifactId><version>3.5.0</version><configuration><arguments><argument>%s</argument></arguments></configuration></plugin>' "$1"; }
build_fixture
add_module txt-reactor acme-txt-reactor jar acme-parent "" "$(exec_args "-p $G:acme-knock-user")"
add_module txt-ext acme-txt-ext jar acme-parent "" "$(exec_args 'io.vidocq.cyrano:cyrano-core:0.4.0-SNAPSHOT')"
add_module txt-ext-nover acme-txt-ext-nover jar acme-parent "" "$(exec_args 'io.vidocq.cyrano:cyrano-extra')"
add_module txt-token acme-txt-token jar acme-parent "" "$(exec_args '${unknown.group}:knock-core')"
add_module nested-token acme-nested-token jar acme-parent "" ""
mkdir -p "$ROOT/nested-token/src/it/p"
printf '<project><groupId>t</groupId><artifactId>p</artifactId><version>1</version><dependencies><dependency><groupId>${knock.group}</groupId><artifactId>knock-core</artifactId><version>1</version></dependency></dependencies></project>\n' \
  > "$ROOT/nested-token/src/it/p/pom.xml"
add_module nested-own acme-nested-own jar acme-parent "" ""
nested_pom "$ROOT/nested-own/src/it/q/pom.xml" com.example q '<dependency><groupId>io.vidocq.cyrano</groupId><artifactId>cyrano-core</artifactId><version>${project.version}</version></dependency>'
sed -i.bak 's|<version>1.0</version>|<version>7.7</version>|' "$ROOT/nested-own/src/it/q/pom.xml" && rm -f "$ROOT/nested-own/src/it/q/pom.xml.bak"
add_module outside-src acme-outside-src jar acme-parent "" ""
nested_pom "$ROOT/outside-src/fixtures/p/pom.xml" com.example p "$(dep io.vidocq.knock:knock-core 1)"
add_module src-coord acme-src-coord jar acme-parent "" ""
mkdir -p "$ROOT/src-coord/src/test/java" && echo 'var a = resolve("io.vidocq.knock:knock-api:1.0");' > "$ROOT/src-coord/src/test/java/T.java"
add_module src-bare acme-src-bare jar acme-parent "" ""
mkdir -p "$ROOT/src-bare/src/main/resources" && echo 'extension: knock-core' > "$ROOT/src-bare/src/main/resources/catalog.yml"
add_module src-coord-user acme-src-coord-user jar acme-parent "$(dep $G:acme-src-coord 0.4.0-PR1.x)" ""
add_module src-bare-user acme-src-bare-user jar acme-parent "$(dep $G:acme-src-bare 0.4.0-PR1.x)" ""
add_module tj-user acme-tj-user jar acme-parent "$(dep $G:acme-src-coord 0.4.0-PR1.x test '<type>test-jar</type>')" ""
add_module tj-cls acme-tj-cls jar acme-parent "$(dep $G:acme-src-coord 0.4.0-PR1.x test '<classifier>tests</classifier>')" ""
add_module tj-scan acme-tj-scan jar acme-parent "" \
  "<plugin><groupId>org.apache.maven.plugins</groupId><artifactId>maven-surefire-plugin</artifactId><version>3.5.2</version><configuration><dependenciesToScan><dependency>$G:acme-src-coord</dependency></dependenciesToScan></configuration></plugin>"
add_module tj-user-user acme-tj-user-user jar acme-parent "$(dep $G:acme-tj-user 0.4.0-PR1.x)" ""
add_module tj-plugin-type acme-tj-plugin-type jar acme-parent "$(dep $G:acme-src-coord 0.4.0-PR1.x test '<type>maven-plugin</type>')" ""
add_module tj-nested acme-tj-nested jar acme-parent "" ""
nested_pom "$ROOT/tj-nested/src/it/p/pom.xml" com.example p "$(dep $G:acme-src-coord 0.4.0-PR1.x)"
add_module tj-nested-jar acme-tj-nested-jar jar acme-parent "" ""
nested_pom "$ROOT/tj-nested-jar/src/it/p/pom.xml" com.example p "$(dep $G:acme-src-coord 0.4.0-PR1.x test '<type>test-jar</type>')"
add_module src-comment acme-src-comment jar acme-parent "" ""
mkdir -p "$ROOT/src-comment/src/main/java" && printf '/**\n * Works like knock-core.\n */\nclass C { // see knock-api\n  // knock-core\n  String s = "http://x"; /* knock-core */\n}\n' > "$ROOT/src-comment/src/main/java/C.java"
add_module src-string acme-src-string jar acme-parent "" ""
mkdir -p "$ROOT/src-string/src/main/java" && printf 'class S { String a = "x"; // comment\n  String c = "io.vidocq.knock:knock-core"; }\n' > "$ROOT/src-string/src/main/java/S.java"
add_module src-glob acme-src-glob jar acme-parent "" ""
mkdir -p "$ROOT/src-glob/src/main/java" && printf 'class M {\n  static final String JARS = "glob:**/*.jar";\n  static final String CORE = "io.vidocq.knock:knock-core";\n  /** Docs. */\n  void run() {}\n}\n' > "$ROOT/src-glob/src/main/java/M.java"
add_module src-interm acme-src-interm jar acme-parent "" ""
mkdir -p "$ROOT/src-interm/src/test/java" && echo 'class I { String C = "io.vidocq.cyrano:cyrano-core:0.4.0-SNAPSHOT"; }' > "$ROOT/src-interm/src/test/java/I.java"
add_module src-interm-nover acme-src-interm-nover jar acme-parent "" ""
mkdir -p "$ROOT/src-interm-nover/src/test/java" && echo 'class J { String C = "io.vidocq.cyrano:cyrano-extra:" + V; }' > "$ROOT/src-interm-nover/src/test/java/J.java"
add_module src-reactor-coord acme-src-reactor-coord jar acme-parent "" ""
mkdir -p "$ROOT/src-reactor-coord/src/test/java" && echo 'class R { String C = "io.vidocq.acme:acme-core:1.0"; String D = "org.example:lib:1.0"; }' > "$ROOT/src-reactor-coord/src/test/java/R.java"
add_module src-quiet acme-src-quiet jar acme-parent "" ""
mkdir -p "$ROOT/src-quiet/src/main/resources" && echo 'see knock-core-extras and myknock-api' > "$ROOT/src-quiet/src/main/resources/notes.txt"
printf 'knock-core\0binary' > "$ROOT/src-quiet/src/main/resources/blob.bin"
add_module agg2 acme-agg2 pom acme-parent "" ""
add_module agg2/kid acme-agg2-kid jar acme-agg2 "" ""
nested_pom "$ROOT/agg2/tck-runner/pom.xml" io.vidocq.acme acme-tck-runner "$(dep io.vidocq.knock:knock-core 1)"
add_module src-other-repo acme-src-other-repo jar acme-parent "" ""
mkdir -p "$ROOT/src-other-repo/src/test/java" && echo 'class O { String C = "io.vidocq.peano:peano-api:" + V; String D = "io.vidocq.runtime:vidocq-runtime-"; }' > "$ROOT/src-other-repo/src/test/java/O.java"
UPSTREAM_GROUPS=io.vidocq.cyrano
analyse > /dev/null
check "text: phase 1 resolves the external written as a coordinate, with its version" "1" \
  "$(python3 -c 'import json,sys; print(sum(1 for e in json.load(open(sys.argv[1])).values() if e["ga"]=="io.vidocq.cyrano:cyrano-core" and "txt-ext" in e["modules"]))' "$TMP/synth/index.json")"
check "nested: \${project.version} is the nested project's own version" "1" \
  "$(python3 -c 'import json,sys; print(sum(1 for e in json.load(open(sys.argv[1])).values() if e["version"]=="7.7" and "nested-own" in e["modules"]))' "$TMP/synth/index.json")"
resolve_synth
analyse --closures > /dev/null
check "text: still targeted" "targeted" "$(field decision)"
check "text: a reactor module named as a coordinate is a reactor edge" "depends on reactor module acme-knock-user" "$(reason txt-reactor)"
check "text: an external coordinate gets its closure" "io.vidocq.knock:knock-core via plugin configuration text io.vidocq.cyrano:cyrano-core" "$(reason txt-ext)"
check "text: an external coordinate without a version makes its module affected" "affected" "$(status txt-ext-nover)"
check "text: a coordinate with an unresolved token makes its module affected" "affected" "$(status txt-token)"
check "nested: an unresolved groupId makes its module affected" "affected" "$(status nested-token)"
check "nested: a pom outside src/ is a nested build too" "nested build io.vidocq.knock:knock-core" "$(reason outside-src)"
check "nested: reactor modules under a module are not its nested builds" "none" "$(status .)"
check "nested: a profile-only module under a pom module does not reach its children" "skip" "$(status agg2/kid)"
check "sources: a producer coordinate in a test source" "affected" "$(status src-coord)"
check "sources: a producer artifactId in a resource" "affected" "$(status src-bare)"
check "sources: longer names and binary files do not count" "skip" "$(status src-quiet)"
check "sources: an external io.vidocq coordinate with a version gets its closure (intermediate upstream)" \
  "io.vidocq.knock:knock-core via source text io.vidocq.cyrano:cyrano-core" "$(reason src-interm)"
check "sources: an external io.vidocq coordinate without a version makes its module affected" "1" \
  "$(reason src-interm-nover | grep -c 'cyrano-extra without a version')"
check "sources: reactor and third-party coordinates are no suspects" "skip" "$(status src-reactor-coord)"
check "sources: coordinates of repositories that are neither the producer nor an intermediate upstream are ignored" "skip" "$(status src-other-repo)"
check "sources: a mention in test sources only does not reach the module's dependents" "skip" "$(status src-coord-user)"
check "sources: a mention in main sources does" "affected" "$(status src-bare-user)"
check "sources: the test-only reason says so" "1" "$(reason src-coord | grep -c 'tests only')"
check "test-jar: a dependent using the module's test-jar is affected" "affected" "$(status tj-user)"
check "test-jar: so is one using its tests classifier" "affected" "$(status tj-cls)"
check "test-jar: so is one naming it in a plugin configuration (dependenciesToScan)" "affected" "$(status tj-scan)"
check "test-jar: and the test-jar user propagates to its own dependents" "affected" "$(status tj-user-user)"
check "test-jar: a nested build using the module's main artifact does not reach its test classes" "skip" "$(status tj-nested)"
check "test-jar: a nested build using its test-jar does" "affected" "$(status tj-nested-jar)"
check "test-jar: a dependency on a main artifact type (maven-plugin) does not reach test classes" "skip" "$(status tj-plugin-type)"
check "test-jar: the reason names the test classes" "1" "$(reason tj-user | grep -c 'uses the test classes of acme-src-coord')"
check "comments: a producer named only in Java comments does not count" "skip" "$(status src-comment)"
check "comments: a string literal does" "affected" "$(status src-string)"
check "comments: a /* inside a string literal opens no comment (glob case)" "affected" "$(status src-glob)"
lexer() { python3 - "$HERE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from pommodel import strip_comments as s
cases = {
    'glob literal': 'a = "glob:**/*.jar"; b = "knock-core"; /** doc */',
    'escaped quote': 'a = "x\\"/*"; b = "knock-core"; /* c */',
    'char literal quote': "c = '\"'; b = \"knock-core\"; // t",
    'text block': 'a = """\n  /* not a comment\n  """; b = "knock-core"; /* c */',
    'quote in a line comment': "// it's\nb = \"knock-core\";",
    'quote in a block comment': '/* "x */ b = "knock-core";',
    'trailing line comment kept code': 'b = "knock-core"; // "x',
}
bad = [k for k, v in cases.items() if 'knock-core' not in s(v)]
gone = [k for k, v in {'javadoc': '/** knock-core */ x;', 'line': '// knock-core', 'block': 'x; /* knock-core */'}.items()
        if 'knock-core' in s(v)]
print('ok' if not bad and not gone else f'kept-lost={bad} comments-left={gone}')
PY
}
check "comments: the lexer keeps literals and drops comments" "ok" "$(lexer)"
analyse --mention-local 'src-bare/src/main/resources/catalog.yml' > /dev/null; resolve_synth
analyse --mention-local 'src-bare/src/main/resources/catalog.yml' --closures > /dev/null
check "mention-local: a mention in a listed file keeps the holder's tests" "affected" "$(status src-bare)"
check "mention-local: ... not its dependents" "skip" "$(status src-bare-user)"
check "mention-local: the reason says so" "1" "$(reason src-bare | grep -c 'mention-local')"
check "mention-local: other main mentions still propagate" "affected" "$(status src-string)"
cp "$ROOT/pom.xml" "$TMP/root-pom.bak"
sed -i.bak 's|</project>|<properties><ci.targeted.mention-local>src-bare/**/*.yml</ci.targeted.mention-local></properties></project>|' "$ROOT/pom.xml" && rm -f "$ROOT/pom.xml.bak"
run_targeted GRAPH_URL= > /dev/null
check "mention-local: read from the consumer's root pom" "affected|skip" \
  "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("affected" if "src-bare" in r["affected"] else "skip", "skip" if "src-bare-user" in r["skip"] else "affected", sep="|")' "$TMP/work/report.json")"
cp "$TMP/root-pom.bak" "$ROOT/pom.xml"
check "sources: the reason names the file" "1" "$(reason src-coord | grep -c 'src/test/java/T.java')"

# --- A malformed graph turns the pruning off (review M7) -------------------------------------
build_fixture
echo '{"generated_at": "x", "artifacts": []}' > "$TMP/bad-graph.json"
analyse --graph "$TMP/bad-graph.json" --producer-slug Vidocq/knock > /dev/null
check "malformed graph: no crash, the synthetic resolution is not pruned" "resolve|none (dependency graph unreadable" \
  "$(field decision)|$(field pruning | cut -c1-33)"

# --- skip-tests.py failures never leave a pom edited (review I1, M2) --------------------------
build_fixture
analyse > /dev/null; resolve_synth; analyse --closures > /dev/null
rm -rf "$TMP/acme-before"; cp -R "$ROOT" "$TMP/acme-before"
mkdir -p "$TMP/out-is-a-dir"
python3 "$HERE/skip-tests.py" --repo "$ROOT" --report "$TMP/report.json" --out "$TMP/out-is-a-dir" > /dev/null 2>&1
check "skip: a result that cannot be written fails the script" "1" "$?"
check "skip: ... and leaves every pom byte for byte" "" "$(diff -r "$TMP/acme-before" "$ROOT")"
printf '<project><modelVersion>4.0.0</modelVersion><artifactId>acme-core</artifactId><properties/></project>' > "$ROOT/core/pom.xml"
python3 "$HERE/skip-tests.py" --repo "$ROOT" --report "$TMP/report.json" --out "$TMP/skipped.json" > /dev/null 2>&1
check "skip: a self-closing <properties/> becomes the one properties element" \
  "<properties><skipTests>true</skipTests><skipITs>true</skipITs><invoker.skip>true</invoker.skip></properties>|1" \
  "$(grep -o '<properties.*</properties>' "$ROOT/core/pom.xml")|$(grep -o '<properties' "$ROOT/core/pom.xml" | wc -l | tr -d ' ')"

# --- targeted-tests.sh restores the poms on any failure after the edits (review I1, M1, M8) ---
# A stand-in for skip-tests.py that edits poms, truncates one, then fails (or succeeds with a
# result that cannot be read, or also removes the backups).
cat > "$TMP/bad-skip.py" <<'EOF'
import json, os, sys
a = dict(zip(sys.argv[1::2], sys.argv[2::2]))
rep = json.load(open(a['--report']))
for i, rel in enumerate(rep['skip']):
    p = os.path.join(a['--repo'], rel, 'pom.xml')
    t = open(p).read()
    open(p, 'w').write(t[:20] if i == 0 else t.replace('</project>', '<properties><skipITs>true</skipITs></properties></project>'))
mode = os.environ['BAD_SKIP']
if mode == 'drop-backup':
    import shutil; shutil.rmtree(os.path.join(os.environ['TARGETED_DIR'], 'backup'))
    sys.exit(1)
if mode == 'garbage-result':
    open(a['--out'], 'w').write('not json')
    sys.exit(0)
sys.exit(1)
EOF
snapshot() { rm -rf "$TMP/acme-before"; cp -R "$ROOT" "$TMP/acme-before"; }
build_fixture; snapshot
check "restore: a failing pom edit still exits 0" "0" "$(run_targeted SKIP_TESTS_PY="$TMP/bad-skip.py" BAD_SKIP=fail)"
check "restore: every pom is back byte for byte" "" "$(diff -r "$TMP/acme-before" "$ROOT")"
check "restore: full mode with the reason" "1" "$(grep -c '^full (fallback: the pom edits failed' "$TMP/mode.txt")"
build_fixture; snapshot
check "restore: an internal error after the edits still exits 0" "0" "$(run_targeted SKIP_TESTS_PY="$TMP/bad-skip.py" BAD_SKIP=garbage-result)"
check "restore: ... every pom back byte for byte" "" "$(diff -r "$TMP/acme-before" "$ROOT")"
check "restore: ... an honest summary" "1" "$(grep -c 'Tests: full (fallback: internal error at skip-lib.sh:[0-9]*' "$TMP/summary")"
build_fixture
check "restore impossible: the step fails" "1" "$(run_targeted SKIP_TESTS_PY="$TMP/bad-skip.py" BAD_SKIP=drop-backup)"
check "restore impossible: the mode line says so" "1" "$(grep -c '^failed: ' "$TMP/mode.txt")"
check "restore impossible: an error annotation" "1" "$(grep -c '^::error title=Targeted tests::' "$TMP/targeted.out")"

build_fixture
run_targeted > /dev/null
check "notice: a targeted run is annotated" "1" \
  "$(grep -c '^::notice title=Targeted tests::Vidocq/acme: targeted: tests skipped in 4 module(s) (still compiled)' "$TMP/targeted.out")"
build_fixture
run_targeted MVN_FAIL=effective-pom > /dev/null
check "notice: a fallback is annotated with its reason" "1" \
  "$(grep -c '^::notice title=Targeted tests::Vidocq/acme: full (fallback: Maven error in the effective POM' "$TMP/targeted.out")"

build_fixture
run_targeted MVN_ARGS='-B -T 4' > /dev/null
check "targeted: a -T of the build's Maven args is kept as it is" "1" "$(grep -c '^synthetic -B -T 4 -f ' "$TMP/mvn-calls")"

# --- External parent chains and BOM chains (review M4) ----------------------------------------
M2="$TMP/m2"
repo_pom() { # repo_pom <g:a:v> <parent g:a:v|-> [properties xml] [import g:a:v...]: a pom of the local repository
  local g="${1%%:*}" a v rest d parent="" imports=""
  a=$(echo "$1" | cut -d: -f2); v="${1##*:}"
  d="$M2/$(echo "$g" | tr . /)/$a/$v"
  mkdir -p "$d"
  if [ "$2" != - ]; then
    parent="<parent><groupId>${2%%:*}</groupId><artifactId>$(echo "$2" | cut -d: -f2)</artifactId><version>${2##*:}</version></parent>"
  fi
  local props="${3:-}"; shift 2; [ $# -gt 0 ] && shift
  for i in "$@"; do
    imports+="<dependency><groupId>${i%%:*}</groupId><artifactId>$(echo "$i" | cut -d: -f2)</artifactId><version>$(echo "$i" | cut -d: -f3-)</version><type>pom</type><scope>import</scope></dependency>"
  done
  printf '<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion>%s<groupId>%s</groupId><artifactId>%s</artifactId><version>%s</version><packaging>pom</packaging><properties>%s</properties><dependencyManagement><dependencies>%s</dependencies></dependencyManagement></project>\n' \
    "$parent" "$g" "$a" "$v" "$props" "$imports" > "$d/$a-$v.pom"
}
import_xml() { printf '<dependencyManagement><dependencies><dependency><groupId>%s</groupId><artifactId>%s</artifactId><version>%s</version><type>pom</type><scope>import</scope></dependency></dependencies></dependencyManagement>' "${1%%:*}" "$(echo "$1" | cut -d: -f2)" "$(echo "$1" | cut -d: -f3-)"; }
rm -rf "$M2"
repo_pom org.apache:apache:30 -
repo_pom io.vidocq.knock:knock-parent:1 org.apache:apache:30
repo_pom io.vidocq.mid:mid-parent:1 io.vidocq.knock:knock-parent:1
repo_pom io.vidocq:vidocq-parent:1 org.apache:apache:30
repo_pom org.junit:junit-bom:5 -
repo_pom io.vidocq:vidocq-bom:1 - "" org.junit:junit-bom:5
repo_pom io.vidocq:vidocq-bom:1.0 - "" org.junit:junit-bom:5
repo_pom io.vidocq.mid:mid-bom:1 - "<knock.v>1</knock.v>" 'io.vidocq.knock:knock-parent:${knock.v}'
repo_pom io.vidocq.mid:mid-bom2:1 - "" 'io.vidocq.x:x-bom:${nope}'
repo_pom io.vidocq:vp2:1 - "" io.vidocq.mid:mid-bom:1
repo_pom io.vidocq:vp3:2 org.apache:apache:30 "<b.v>1</b.v>"
repo_pom io.vidocq:vp3-child:2 io.vidocq:vp3:2 "" 'io.vidocq:vidocq-bom:${b.v}'
chain_fixture() {
  build_fixture
  add_module chain-producer acme-chain-producer jar io.vidocq.mid:mid-parent:1 "" ""
  add_module chain-clean acme-chain-clean jar io.vidocq:vidocq-parent:1 "" ""
  add_module chain-missing acme-chain-missing jar io.vidocq.gone:gone-parent:1 "" ""
  add_module chain-third acme-chain-third jar org.apache:apache:30 "" ""
  add_module bom-chain acme-bom-chain jar acme-parent "" "" "$(import_xml io.vidocq.mid:mid-bom:1)"
  add_module bom-clean acme-bom-clean jar acme-parent "" "" "$(import_xml 'io.vidocq:vidocq-bom:${peano.version}')"
  add_module bom-unresolved acme-bom-unresolved jar acme-parent "" "" "$(import_xml io.vidocq.mid:mid-bom2:1)"
  add_module chain-import acme-chain-import jar io.vidocq:vp2:1 "" ""
  add_module chain-inherited-prop acme-chain-inherited-prop jar io.vidocq:vp3-child:2 "" ""
}
chain_fixture
analyse --local-repo "$M2" > /dev/null; resolve_synth; analyse --local-repo "$M2" --closures > /dev/null
check "chains: still targeted" "targeted" "$(field decision)"
check "chains: a producer pom among the ancestors of an external parent" \
  "parent chain io.vidocq.mid:mid-parent:1 > io.vidocq.knock:knock-parent:1 reaches the producer" "$(reason chain-producer)"
check "chains: an external io.vidocq parent chain without the producer: not affected" "skip" "$(status chain-clean)"
check "chains: a third-party parent: not affected" "skip" "$(status chain-third)"
check "chains: an ancestor pom that cannot be read makes its module affected" "1" "$(reason chain-missing | grep -c 'io.vidocq.gone:gone-parent:1.*cannot be read (doubt)')"
check "chains: an external BOM importing a producer BOM" \
  "BOM import chain io.vidocq.mid:mid-bom:1 > io.vidocq.knock:knock-parent:1 reaches the producer" "$(reason bom-chain)"
check "chains: an external BOM chain without the producer: not affected" "skip" "$(status bom-clean)"
check "chains: an import version that cannot be resolved makes its module affected" "1" "$(reason bom-unresolved | grep -c 'cannot be resolved (doubt)')"
check "chains: a BOM imported by an external parent" "1" "$(reason chain-import | grep -c 'io.vidocq:vp2:1 > io.vidocq.mid:mid-bom:1 > io.vidocq.knock:knock-parent:1')"
check "chains: an import version from a property of the external parent's parent" "skip" "$(status chain-inherited-prop)"
analyse > /dev/null; resolve_synth; analyse --closures > /dev/null
check "chains: without the local repository, an external io.vidocq parent is a doubt" "1" "$(reason chain-clean | grep -c 'local repository unknown (doubt)')"
check "chains: ... a third-party parent is not" "skip" "$(status chain-third)"

chain_fixture
run_targeted STUB_LOCAL_REPO="$M2" GRAPH_URL= > /dev/null
check "chains: the local repository comes from Maven, non-recursively" "1" \
  "$(grep -c '^acme -B -ntp -Dx=1 -N -q org.apache.maven.plugins:maven-help-plugin:[0-9.]*:evaluate -Dexpression=settings.localRepository -DforceStdout' "$TMP/mvn-calls")"
check "chains: the orchestrator passes it on" "skip|skip" \
  "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("|".join("skip" if m in r["skip"] else "affected" for m in ("chain-clean", "bom-clean")))' "$TMP/work/report.json")"
chain_fixture
run_targeted STUB_LOCAL_REPO="$M2" GRAPH_URL= MVN_FAIL=evaluate > /dev/null
check "chains: no local repository from Maven: still targeted, the chains are doubts" "affected|1" \
  "$(python3 -c 'import json,sys; print("affected" if "chain-clean" in json.load(open(sys.argv[1]))["affected"] else "skip")' "$TMP/work/report.json")|$(grep -c '^targeted' "$TMP/mode.txt")"

# --- Graph pruning is off unless asked for (review I2) ----------------------------------------
build_fixture
run_targeted GRAPH_URL= > /dev/null
check "no GRAPH_URL: pruning off, said in the log" "1" "$(grep -c '^Dependency-graph pruning: off' "$TMP/targeted.out")"
check "no GRAPH_URL: every suspect external resolved" "targeted: tests skipped in 4 module(s) (still compiled)" "$(cat "$TMP/mode.txt")"
check "no GRAPH_URL: the summary says not pruned" "1" "$(grep -c 'not pruned' "$TMP/summary")"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
