#!/usr/bin/env bash
# Tests of the producer-side targeted test mode: changed-modules.py (which modules a pull request
# changes, with their reactor dependents) and producer-tests.sh (changed paths from git, the
# orchestration with every fallback, restore and guard). Offline: the effective POMs are fixtures,
# mvn is a stub, the forge is a local bare repository.
# Run: bash targeted-producer-tests/producer-tests-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

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

# Reactor "rt" (default profiles):
#   core <- ext-knock <- ext-knock-dev ; ext-knock <- example ; core <- ext-other ;
#   codegen: annotation processor of ext-other ; tooling names ext-knock in a TEST resource,
#   tooling-user depends on tooling ; agg-mention names the pom module "exts" ;
#   plugin-p (maven-plugin) names codegen in its MAIN code, u-app uses plugin-p as a build plugin ;
#   t-helper names codegen in its test sources, t-user uses t-helper's test-jar, t-plain uses
#   t-helper plainly ; exts/ is a pom parent of ext-x ; tck-runner is in the default reactor.
# Profile tck (ci.tck.modules=tck-runner): tck-runner also depends on codegen, and tck-extra (a
# profile-only module) depends on core.
ROOT="$TMP/rt"
EFF="$TMP/eff.xml"
EFF_TCK="$TMP/eff-tck.xml"
G=io.vidocq.rt
dep() { printf '<dependency><groupId>%s</groupId><artifactId>%s</artifactId><version>1</version>%s</dependency>' "$G" "$1" "${2:-}"; }
apt() { printf '<plugin><artifactId>maven-compiler-plugin</artifactId><configuration><annotationProcessorPaths><path><groupId>%s</groupId><artifactId>%s</artifactId><version>1</version></path></annotationProcessorPaths></configuration></plugin>' "$G" "$1"; }
plug() { printf '<plugin><groupId>%s</groupId><artifactId>%s</artifactId><version>1</version></plugin>' "$G" "$1"; }
module() { # module <dir> <artifactId> <packaging> <parent|-> <deps> [plugins] [tck-only deps] [yes: tck-only module | default: default-only module] [default-only deps]
  local dir="$ROOT/$1" parent=""
  [ "$1" = "." ] && dir="$ROOT"
  mkdir -p "$dir/src/main/java"
  [ "$4" != "-" ] && parent="<parent><groupId>$G</groupId><artifactId>$4</artifactId><version>1</version></parent>"
  printf '<project><modelVersion>4.0.0</modelVersion>%s<groupId>%s</groupId><artifactId>%s</artifactId><version>1</version><packaging>%s</packaging>%s</project>\n' \
    "$parent" "$G" "$2" "$3" "$([ "$1" = . ] && echo "<properties><ci.tck.modules>tck-runner</ci.tck.modules>${MENTION_LOCAL:+<ci.targeted.mention-local>$MENTION_LOCAL</ci.targeted.mention-local>}</properties>")" > "$dir/pom.xml"
  local p='<project><modelVersion>4.0.0</modelVersion>%s<groupId>%s</groupId><artifactId>%s</artifactId><version>1</version><packaging>%s</packaging><dependencies>%s</dependencies><build><directory>%s/target</directory><plugins>%s</plugins></build></project>\n'
  [ "${8:-}" = yes ] || printf "$p" "$parent" "$G" "$2" "$3" "$5${9:-}" "$dir" "${6:-}" >> "$EFF.body"
  [ "${8:-}" = default ] || printf "$p" "$parent" "$G" "$2" "$3" "$5${7:-}" "$dir" "${6:-}" >> "$EFF_TCK.body"
}
fixture() {
  rm -rf "$ROOT" "$TMP/origin.git" "$EFF.body" "$EFF_TCK.body"; : > "$EFF.body"; : > "$EFF_TCK.body"
  module .              root          pom -    ""
  module core           core          jar root ""
  module codegen        codegen       jar root ""
  module ext-knock      ext-knock     jar root "$(dep core)"
  module ext-knock-dev  ext-knock-dev jar root "$(dep ext-knock)"
  module example        example       jar root "$(dep ext-knock)"
  module ext-other      ext-other     jar root "$(dep core)" "$(apt codegen)"
  module tooling        tooling       jar root ""
  mkdir -p "$ROOT/tooling/src/test/resources" && echo 'known: ext-knock' > "$ROOT/tooling/src/test/resources/catalog.txt"
  module tooling-user   tooling-user  jar root "$(dep tooling)"
  module agg-mention    agg-mention   jar root ""
  mkdir -p "$ROOT/agg-mention/src/main/resources" && echo 'part of exts' > "$ROOT/agg-mention/src/main/resources/about.txt"
  module plugin-p       plugin-p      maven-plugin root ""
  echo 'class P { static final String CODEGEN = "codegen"; }' > "$ROOT/plugin-p/src/main/java/P.java"
  module u-app          u-app         jar root "" "$(plug plugin-p)"
  module t-helper       t-helper      jar root ""
  mkdir -p "$ROOT/t-helper/src/test/java" && echo 'class H { String c = "io.vidocq.rt:codegen"; }' > "$ROOT/t-helper/src/test/java/H.java"
  module t-user         t-user        jar root "$(dep t-helper '<type>test-jar</type><scope>test</scope>')"
  module t-plain        t-plain       jar root "$(dep t-helper)"
  module tck-runner     tck-runner    jar root "" "" "$(dep codegen)"
  module tck-extra      tck-extra     jar root "$(dep core)" "" "" yes
  module abd            abd           jar root "" "" "" "" "$(dep codegen)"
  module abd-only       abd-only      jar root "" "" "" default "$(dep codegen)"
  module tooling-mentioner tooling-mentioner jar root ""
  mkdir -p "$ROOT/tooling-mentioner/src/it/p" && echo '<project><artifactId>p</artifactId><build><plugins><plugin><groupId>io.vidocq.rt</groupId><artifactId>tooling</artifactId></plugin></plugins></build></project>' > "$ROOT/tooling-mentioner/src/it/p/pom.xml"
  module catalog-holder catalog-holder jar root ""
  mkdir -p "$ROOT/catalog-holder/src/main/resources" && echo 'knock = ext-knock' > "$ROOT/catalog-holder/src/main/resources/catalog.properties"
  module catalog-user   catalog-user  jar root "$(dep catalog-holder)"
  module res-holder     res-holder    jar root ""
  mkdir -p "$ROOT/res-holder/src/main/resources" && echo 'uses ext-knock' > "$ROOT/res-holder/src/main/resources/other.txt"
  module res-user       res-user      jar root "$(dep res-holder)"
  module exts           exts          pom root ""
  module exts/ext-x     ext-x         jar exts ""
  { echo '<projects>'; cat "$EFF.body"; echo '</projects>'; } > "$EFF"
  { echo '<projects>'; cat "$EFF_TCK.body"; echo '</projects>'; } > "$EFF_TCK"
}

PY="$HERE/changed-modules.py"
analyse() { # analyse <changed paths, one per line> -> exit status; report in $TMP/report.json
  printf '%s\n' "$1" > "$TMP/changed.txt"
  python3 "$PY" --effective-pom "${2:-$EFF_TCK}" --build-effective-pom "$EFF" --repo "$ROOT" --keep-modules tck-runner \
    ${LOCAL:+--mention-local "$LOCAL"} \
    --changed-files "$TMP/changed.txt" --report "$TMP/report.json" > "$TMP/analysis.out" 2>&1
  echo $?
}
field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print(v if not isinstance(v,(list,dict)) else " ".join(sorted(v)))' "$TMP/report.json" "$1"; }
skipped() { python3 -c 'import json,sys; print("skip" if sys.argv[2] in json.load(open(sys.argv[1])).get("skip", []) else "kept")' "$TMP/report.json" "$1"; }

fixture
check "extension change: exits 0" "0" "$(analyse 'ext-knock/src/main/java/A.java')"
check "extension change: targeted" "targeted" "$(field decision)"
check "extension change: the module, its dependents, the modules naming it" \
  "catalog-holder catalog-user example ext-knock ext-knock-dev res-holder res-user tooling" "$(field affected)"
check "a test-source mention keeps the module's tests, not its plain dependents" "skip" "$(skipped tooling-user)"
check "naming a module affected only through its tests does not count (its artifact does not change)" "skip" "$(skipped tooling-mentioner)"
check "the reason names the changed path" "owns ext-knock/src/main/java/A.java" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["affected"]["ext-knock"])' "$TMP/report.json")"

check "main-resource mention: the holder and its users keep their tests" "kept|kept" "$(skipped catalog-holder)|$(skipped catalog-user)"
LOCAL=catalog-holder/src/main/resources/catalog.properties analyse 'ext-knock/src/main/java/A.java' > /dev/null
check "mention-local: a mention in a listed file keeps the holder's tests" "kept" "$(skipped catalog-holder)"
check "mention-local: ... and does not reach its dependents" "skip" "$(skipped catalog-user)"
check "mention-local: an unlisted resource still propagates" "kept|kept" "$(skipped res-holder)|$(skipped res-user)"
check "mention-local: the reason says so" "1" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["affected"]["catalog-holder"])' "$TMP/report.json" | grep -c 'mention-local')"
LOCAL='catalog-holder/**/catalog.*, nothing/else' analyse 'ext-knock/src/main/java/A.java' > /dev/null
check "mention-local: globs, comma-separated" "kept|skip" "$(skipped catalog-holder)|$(skipped catalog-user)"
LOCAL=catalog-holder/src/main/resources/catalog.properties analyse 'catalog-holder/src/main/resources/catalog.properties' > /dev/null
check "mention-local: a changed listed file propagates normally" "kept|kept" "$(skipped catalog-holder)|$(skipped catalog-user)"

analyse 'codegen/src/main/java/G.java' > /dev/null
check "processor change: the module using it as annotation processor" "kept" "$(skipped ext-other)"
check "main-source mention: the plugin naming codegen in its code" "kept" "$(skipped plugin-p)"
check "main-source mention: propagates to the plugin's users" "kept" "$(skipped u-app)"
check "test-source mention: the helper" "kept" "$(skipped t-helper)"
check "test-source mention: reaches the users of its test-jar" "kept" "$(skipped t-user)"
check "test-source mention: not its plain users" "skip" "$(skipped t-plain)"
check "profile tck: a runner using codegen only in that profile keeps its TCK" "kept" "$(skipped tck-runner)"
check "profile-only modules are never in the skip list" "0" "$(field skip | tr ' ' '\n' | grep -c '^tck-extra$')"
check "default and -Ptck models combined: a default-profile dependency the -Ptck model drops still counts" "kept" "$(skipped abd)"
check "default and -Ptck models combined: a module only in the default model is analysed" "kept" "$(skipped abd-only)"

analyse 'core/src/main/java/C.java' > /dev/null
check "core change: everything depending on core and what names those; never a ci.tck.modules runner" \
  "abd abd-only agg-mention codegen exts/ext-x plugin-p t-helper t-plain t-user tooling-mentioner tooling-user u-app" "$(field skip)"

analyse 'exts/pom.xml' > /dev/null
check "pom parent change: its children; naming the pom module itself does not count" "exts exts/ext-x" "$(field affected)"

analyse "$(printf 'example/src/main/java/E.java\ndocs/guide.adoc\nREADME.md')" > /dev/null
check "documentation outside every module is ignored" "example" "$(field affected)"
analyse "$(printf 'example/src/main/java/E.java\next-other/README.md')" > /dev/null
check "documentation inside a module belongs to that module" "kept" "$(skipped ext-other)"

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
src="$EFF"
case " \$* " in *" -Ptck "*) src="$EFF_TCK"; [ "\${MVN_FAIL:-}" = tck ] && exit 1 ;; esac
for a in "\$@"; do
  case "\$a" in
    *:effective-pom)
      [ "\${MVN_FAIL:-}" = effective-pom ] && exit 1
      for b in "\$@"; do case "\$b" in -Doutput=*) sed "s|$ROOT|\$PWD|g" "\$src" > "\${b#-Doutput=}" ;; esac; done ;;
  esac
done
exit 0
EOF
chmod +x "$TMP/bin/mvn"

# The forge: a bare repository with main and the pull request's head (refs/pull/7/head). The
# checkout is a clone of the pull request; the paths given are changed (or created) on it.
forge() { # forge <changed paths> [rename FROM TO]
  rm -rf "$TMP/origin.git" "$TMP/seed"
  cp -R "$ROOT" "$TMP/seed"
  git -C "$TMP/seed" init -q -b main && git -C "$TMP/seed" add -A && git -C "$TMP/seed" commit -q -m base
  for i in 1 2 3; do echo "$i" > "$TMP/seed/core/history-$i.txt"; git -C "$TMP/seed" add -A; git -C "$TMP/seed" commit -q -m "main $i"; done
  git -C "$TMP/seed" checkout -q -b pr
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    mkdir -p "$(dirname "$TMP/seed/$p")"
    case "$p" in *.xml) echo '<!-- change -->' >> "$TMP/seed/$p" ;; *) echo change >> "$TMP/seed/$p" ;; esac
  done <<< "$1"
  if [ "${2:-}" = rename ]; then mkdir -p "$(dirname "$TMP/seed/$4")"; git -C "$TMP/seed" mv "$3" "$4"; fi
  git -C "$TMP/seed" add -A && git -C "$TMP/seed" commit -q -m change
  git clone -q --bare "$TMP/seed" "$TMP/origin.git"
  git -C "$TMP/origin.git" update-ref refs/pull/7/head refs/heads/pr
  rm -rf "$ROOT"
  git clone -q ${DEPTH:+--depth "$DEPTH"} --branch pr "file://$TMP/origin.git" "$ROOT"
}
run() { # run [VAR=value...] -> exit status
  rm -f "$TMP/mvn-calls" "$TMP/summary" "$TMP/out-vars" "$TMP/env-vars"
  (cd "$ROOT" && env PATH="$TMP/bin:$PATH" MODE=targeted BASE_REF=main PR_NUMBER=7 \
    MVN_ARGS='-B -ntp' TARGETED_DIR="$TMP/work" GITHUB_STEP_SUMMARY="$TMP/summary" GITHUB_OUTPUT="$TMP/out-vars" \
    GITHUB_ENV="$TMP/env-vars" GITHUB_REPOSITORY=Vidocq/rt "$@" bash "$HERE/producer-tests.sh") > "$TMP/run.out" 2>&1
  echo $?
}
edited() { grep -rl '<skipITs>true</skipITs>' --include=pom.xml "$ROOT" | sed "s|$ROOT/||; s|/pom.xml||" | sort | paste -sd' ' -; }
out() { sed -n "s/^$1=//p" "$TMP/out-vars"; }
snapshot() { rm -rf "$TMP/rt-before"; cp -R "$ROOT" "$TMP/rt-before"; rm -rf "$TMP/rt-before/.git"; }
same_poms() { diff -r -x .git "$TMP/rt-before" "$ROOT"; }

fixture; forge 'ext-knock/src/main/java/A.java'
check "targeted: exits 0" "0" "$(run)"
check "targeted: the changed paths come from git" "ext-knock/src/main/java/A.java" "$(cat "$TMP/work/changed-files.txt")"
check "targeted: the unaffected non-pom modules of the default reactor are edited, never a TCK runner" \
  "abd abd-only agg-mention codegen core ext-other exts/ext-x plugin-p t-helper t-plain t-user tooling-mentioner tooling-user u-app" "$(edited)"
check "targeted: the outputs" "targeted|14" "$(out mode)|$(out skipped)"
check "targeted: a notice" "1" "$(grep -c '^::notice title=Targeted producer tests::Vidocq/rt: targeted: tests skipped in 14 module(s) (still compiled)' "$TMP/run.out")"
check "targeted: the summary lists the affected modules" "1" "$(grep -c '| `ext-knock` | owns ext-knock/src/main/java/A.java |' "$TMP/summary")"
check "targeted: two effective POMs, the second with -Ptck (ci.tck.modules), never -DskipTests" "1|1|0" \
  "$(grep -c '^rt -B -ntp org.apache.maven.plugins:maven-help-plugin:[0-9.]*:effective-pom -Doutput=' "$TMP/mvn-calls")|$(grep -c '^rt -B -ntp -Ptck org.apache.maven.plugins:maven-help-plugin:[0-9.]*:effective-pom' "$TMP/mvn-calls")|$(grep -c -- '-DskipTests' "$TMP/mvn-calls")"
check "targeted: later steps are told the poms are edited" "1" "$(grep -c '^TARGETED_PRODUCER_EDITS=' "$TMP/env-vars")"

MENTION_LOCAL=catalog-holder/src/main/resources/catalog.properties fixture; forge 'ext-knock/src/main/java/A.java'
run > /dev/null
check "mention-local: read from the root pom property ci.targeted.mention-local" "kept|skip" \
  "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("|".join("skip" if m in r["skip"] else "kept" for m in ("catalog-holder","catalog-user")))' "$TMP/work/report.json")"
fixture; forge 'ext-knock/src/main/java/A.java'

# The edits never outlive the install: guard fails while they are in place, restore puts back.
check "guard: fails while the edits are in place" "1" "$(run MODE=guard)"
check "guard: an error annotation" "1" "$(grep -c '^::error title=Targeted producer tests::' "$TMP/run.out")"
fixture; forge 'ext-knock/src/main/java/A.java'; snapshot
run > /dev/null
check "restore: exits 0" "0" "$(run MODE=restore)"
check "restore: every pom back byte for byte" "" "$(same_poms)"
check "restore: guard passes afterwards" "0" "$(run MODE=guard)"
check "restore: a second restore has nothing to do" "0|1" "$(run MODE=restore)|$(grep -c 'nothing to restore' "$TMP/run.out")"
run > /dev/null
rm -rf "$TMP/work/backup"
check "restore impossible: the step fails" "1" "$(run MODE=restore)"
check "restore impossible: an error annotation" "1" "$(grep -c '^::error title=Targeted producer tests::' "$TMP/run.out")"
check "restore impossible: guard still fails" "1" "$(run MODE=guard)"
check "guard.sh (run-tck calls it) refuses while the edits are in place" "1" \
  "$(RUNNER_TEMP="$TMP" TARGETED_DIR="$TMP/work" bash "$HERE/guard.sh" > /dev/null 2>&1; echo $?)"
check "run-tck calls the guard first" "1" "$(grep -c 'targeted-producer-tests/guard.sh' "$HERE/../run-tck/action.yml")"

# Changed paths from git: shallow checkouts are deepened, renames list both paths.
fixture; DEPTH=1 forge 'ext-knock/src/main/java/A.java'
check "shallow checkout: deepened until the merge base, targeted" "0|targeted" "$(run)|$(out mode)"
fixture
mkdir -p "$ROOT/ext-other/src/main/java" && echo x > "$ROOT/ext-other/src/main/java/Moved.java"
forge '' rename ext-other/src/main/java/Moved.java example/src/main/java/Moved.java
run > /dev/null
check "rename: the old and the new path are both changed" "example/src/main/java/Moved.java|ext-other/src/main/java/Moved.java" \
  "$(sort "$TMP/work/changed-files.txt" | paste -sd'|' -)"
check "rename: both owners keep their tests" "kept|kept" \
  "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("|".join("skip" if m in r["skip"] else "kept" for m in ("ext-other","example")))' "$TMP/work/report.json")"

fixture; forge 'example/src/main/java/E.java'
printf 'example/src/main/java/E.java\ncore/src/main/java/Hidden.java\n' > "$TMP/api-files.txt"
run CHANGED_FILES="$TMP/api-files.txt" > /dev/null
check "cross-check: a path of the forge's list missing from git falls back" "1" "$(grep -c '^Tests: full (fallback: .*core/src/main/java/Hidden.java' "$TMP/run.out")"
fixture; forge 'example/src/main/java/E.java'
printf 'example/src/main/java/E.java\n' > "$TMP/api-files.txt"
check "cross-check: a forge list included in git's is fine" "0|targeted" "$(run CHANGED_FILES="$TMP/api-files.txt")|$(out mode)"

fixture; forge 'ext-knock/src/main/java/A.java'
check "full mode: exits 0" "0" "$(run MODE=full)"
check "full mode: no Maven call, no pom edited, no marker" "0||0" \
  "$(cat "$TMP/mvn-calls" 2>/dev/null | wc -l | tr -d ' ')|$(edited)|$(cat "$TMP/env-vars" 2>/dev/null | grep -c TARGETED_PRODUCER_EDITS)"
check "full mode: the outputs" "full|0" "$(out mode)|$(out skipped)"
check "an unknown mode fails" "1" "$(run MODE=some)"

fallback_case() { # fallback_case <name> <reason fragment> <changed paths> [VAR=value...]
  local name="$1" frag="$2" changed="$3"; shift 3
  fixture; forge "$changed"; snapshot
  check "fallback $name: exits 0" "0" "$(run "$@")"
  check "fallback $name: a notice with the reason" "1" "$(grep -c "^::notice title=Targeted producer tests::Vidocq/rt: full (fallback: .*$frag" "$TMP/run.out")"
  check "fallback $name: the summary says why" "1" "$(grep -c "Tests: full (fallback: .*$frag" "$TMP/summary")"
  check "fallback $name: no pom edited" "" "$(same_poms)"
  check "fallback $name: outputs full, guard passes" "full|0|0" "$(out mode)|$(out skipped)|$(run MODE=guard)"
}
fallback_case "root pom" "root module" 'pom.xml'
fallback_case "CI configuration" "root module" '.forgejo/workflows/pr.yml'
fallback_case "no base branch" "merge base" 'example/src/main/java/E.java' BASE_REF=
fallback_case "unknown base branch" "merge base" 'example/src/main/java/E.java' BASE_REF=nowhere
fallback_case "effective POM" "effective POM" 'example/src/main/java/E.java' MVN_FAIL=effective-pom
fallback_case "tck effective POM" "effective POM" 'example/src/main/java/E.java' MVN_FAIL=tck
fallback_case "analysis crash" "analysis failed" 'example/src/main/java/E.java' CHANGED_MODULES_PY=/dev/null/none.py

# A failing pom edit puts every pom back, byte for byte, and leaves no marker.
cat > "$TMP/bad-skip.py" <<'EOF'
import json, os, sys
a = dict(zip(sys.argv[1::2], sys.argv[2::2]))
for rel in json.load(open(a['--report']))['skip']:
    p = os.path.join(a['--repo'], rel, 'pom.xml')
    open(p, 'w').write('broken')
sys.exit(1)
EOF
fixture; forge 'example/src/main/java/E.java'; snapshot
check "edit failure: still exits 0" "0" "$(run SKIP_TESTS_PY="$TMP/bad-skip.py")"
check "edit failure: full with the reason" "full|1" "$(out mode)|$(grep -c '^Tests: full (fallback: the pom edits failed' "$TMP/run.out")"
check "edit failure: every pom back byte for byte" "" "$(same_poms)"
check "edit failure: no marker left, guard passes" "0" "$(run MODE=guard)"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
