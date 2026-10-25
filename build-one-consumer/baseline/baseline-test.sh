#!/usr/bin/env bash
# Tests of the baseline-on-failure mode of build-one-consumer: compare.py (are the failures of the
# pull-request build all pre-existing?) and baseline.sh (the baseline and the complete rerun, with a
# mvn stub). Offline.
# Run: bash build-one-consumer/baseline/baseline-test.sh
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

# A run: <dir>/<module>/target/{surefire,failsafe}-reports/TEST-*.xml and <dir>.log
run_dir() { rm -rf "$TMP/$1" "$TMP/$1.log" "$TMP/first" "$TMP/first.log"; mkdir -p "$TMP/$1"; : > "$TMP/$1.log"; }
first_dir() { rm -rf "$TMP/first" "$TMP/first.log"; mkdir -p "$TMP/first"; : > "$TMP/first.log"; }
# The surefire summary of a module, as the log prints it (the count check reads it).
summary_line() { log "$1" "[ERROR] Tests run: $3, Failures: $2, Errors: 0, Skipped: 0"; }
testcase() { # testcase <run> <module> <plugin: surefire|failsafe> <class> <method> <ok|failure|error|flaky>
  local f="$TMP/$1/$2/target/$3-reports/TEST-$4.xml" body=""
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || printf '<?xml version="1.0"?>\n<testsuite name="%s">\n</testsuite>\n' "$4" > "$f"
  case "$6" in
    ok) body="<testcase name=\"$5\" classname=\"$4\"/>" ;;
    failure) body="<testcase name=\"$5\" classname=\"$4\"><failure message=\"boom\"/><rerunFailure message=\"boom\"/></testcase>" ;;
    error) body="<testcase name=\"$5\" classname=\"$4\"><error message=\"boom\"/></testcase>" ;;
    flaky) body="<testcase name=\"$5\" classname=\"$4\"><flakyFailure message=\"once\"/></testcase>" ;;
  esac
  python3 - "$f" "$body" <<'PY'
import sys
p, body = sys.argv[1:]
s = open(p).read().replace('</testsuite>', body + '\n</testsuite>')
open(p, 'w').write(s)
PY
}
invoker() { # invoker <run> <module> <project> <success|failure-build>
  local f="$TMP/$1/$2/target/invoker-reports/BUILD-$3.xml"
  mkdir -p "$(dirname "$f")"
  printf '<build-job project="%s/pom.xml" result="%s"/>\n' "$3" "$4" > "$f"
}
log() { printf '%s\n' "$2" >> "$TMP/$1.log"; }
builderr() { # builderr <run> <artifactId> <goal>
  log "$1" "[ERROR] Failed to execute goal org.apache.maven.plugins:maven-$3 (default-$3) on project $2: Compilation failure"
}
skipped() { log "$1" "[INFO] Vidocq :: $2 ................................ SKIPPED"; }
compare() { # compare -> exit status; decision in $TMP/out.json (the first PR build: $TMP/first, when it exists)
  local first=()
  [ -d "$TMP/first" ] && first=(--pr-first "$TMP/first" --pr-first-log "$TMP/first.log")
  python3 "$HERE/compare.py" --pr "$TMP/pr" --pr-log "$TMP/pr.log" --baseline "$TMP/base" --baseline-log "$TMP/base.log" \
    ${first[@]+"${first[@]}"} \
    --json "$TMP/out.json" --summary "$TMP/summary.md" > "$TMP/compare.out" 2>&1
  echo $?
}
field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))[sys.argv[2]]; print(v if not isinstance(v, list) else " ".join(v))' "$TMP/out.json" "$1"; }

# 1. A failure of the PR build only: caused by the PR.
run_dir pr; run_dir base
testcase pr core surefire acme.ATest a failure; testcase pr core surefire acme.ATest b ok
testcase base core surefire acme.ATest a ok; testcase base core surefire acme.ATest b ok
check "PR-only failure: exit 1" "1" "$(compare)"
check "PR-only failure: decision" "caused-by-pr" "$(field decision)"
check "PR-only failure: names it, with its module and report kind" "core:surefire:acme.ATest#a" "$(field new)"

# 2. The same failures on both sides: pre-existing.
run_dir pr; run_dir base
testcase pr core surefire acme.ATest a failure; testcase pr it failsafe acme.BIT b error
testcase base core surefire acme.ATest a failure; testcase base it failsafe acme.BIT b failure
check "same failures: exit 0" "0" "$(compare)"
check "same failures: decision" "pre-existing" "$(field decision)"
check "same failures: lists them" "core:surefire:acme.ATest#a it:failsafe:acme.BIT#b" "$(field pre_existing)"
check "same failures: the summary has the section" "1" "$(grep -c '^### Pre-existing failures, not caused by this PR' "$TMP/summary.md")"

# 3. A superset: one new failure besides the pre-existing ones.
run_dir pr; run_dir base
testcase pr core surefire acme.ATest a failure; testcase pr core surefire acme.ATest c failure
testcase base core surefire acme.ATest a failure; testcase base core surefire acme.ATest c ok
check "superset: exit 1" "1" "$(compare)"
check "superset: the new one" "core:surefire:acme.ATest#c" "$(field new)"

# 4. Flaky: a test that passed on rerun is no failure.
run_dir pr; run_dir base
testcase pr core surefire acme.ATest a failure; testcase pr core surefire acme.ATest f flaky
testcase base core surefire acme.ATest a failure
check "flaky test passed on rerun: not counted" "0" "$(compare)"

# 5. The baseline build is green: everything is caused by the PR.
run_dir pr; run_dir base
testcase pr core surefire acme.ATest a failure
testcase base core surefire acme.ATest a ok
check "green baseline: exit 1" "1" "$(compare)"

# 6. Compilation error on both sides, same module, same goal: pre-existing.
run_dir pr; run_dir base
builderr pr acme-core compiler-plugin:3.14.0:compile
log pr "[ERROR] $TMP/pr/core/src/main/java/acme/Old.java:[9,1] cannot find symbol OldApi (0.4.0-PR7.abc)"
builderr base acme-core compiler-plugin:3.14.0:compile
log base "[ERROR] $TMP/base/core/src/main/java/acme/Old.java:[9,1] cannot find symbol OldApi (0.4.0-SNAPSHOT)"
check "same build error both sides: exit 0" "0" "$(compare)"
check "same build error both sides: listed by goal and by error line" \
  "build error acme-core compiler-plugin:3.14.0:compile error core/src/main/java/acme/Old.java:[9,1] cannot find symbol OldApi (V)" "$(field pre_existing)"

# 7. Build error at another module or goal on the baseline: caused by the PR.
run_dir pr; run_dir base
builderr pr acme-core compiler-plugin:3.14.0:compile
builderr base acme-app compiler-plugin:3.14.0:compile
check "build error elsewhere on the baseline: exit 1" "1" "$(compare)"
run_dir pr; run_dir base
builderr pr acme-core compiler-plugin:3.14.0:testCompile
builderr base acme-core compiler-plugin:3.14.0:compile
check "build error at another goal: exit 1" "1" "$(compare)"

# 8. A module the baseline built but the PR build skipped: untested, so caused by the PR.
run_dir pr; run_dir base
builderr pr acme-core compiler-plugin:3.14.0:compile; skipped pr "App"; skipped pr "Cli"
builderr base acme-core compiler-plugin:3.14.0:compile; skipped base "App"
check "PR skipped more modules than the baseline: exit 1" "1" "$(compare)"

# 9. Missing reports: the log says tests failed, no report says which.
run_dir pr; run_dir base
log pr "[ERROR] Tests run: 3, Failures: 1, Errors: 0, Skipped: 0"
log base "[ERROR] Tests run: 3, Failures: 1, Errors: 0, Skipped: 0"
check "missing reports: exit 1" "1" "$(compare)"
check "missing reports: the decision says why" "doubt" "$(field decision)"

# 10. The PR rerun shows no failure at all (the first failure did not reproduce): no attribution.
run_dir pr; run_dir base
testcase pr core surefire acme.ATest a ok
testcase base core surefire acme.ATest a failure
check "nothing failing in the PR rerun: exit 1" "1" "$(compare)"

# 11. Invoker ITs are compared too.
run_dir pr; run_dir base
invoker pr plugin it-one failure-build; invoker base plugin it-one failure-build
check "invoker IT failing on both sides: exit 0" "0" "$(compare)"
run_dir pr; run_dir base
invoker pr plugin it-one failure-build; invoker base plugin it-one success
check "invoker IT failing on the PR side only: exit 1" "1" "$(compare)"

# 12. Review 69-C1: a failure of the FIRST PR build that passes in the rerun is the PR's (flaky with
#     the PR), unless the baseline has it too.
run_dir pr; run_dir base; first_dir
testcase first core surefire acme.ATest t failure; testcase first core surefire acme.ATest p failure
summary_line first 2 3
log first "[ERROR] Failed to execute goal org.apache.maven.plugins:maven-surefire-plugin:3.5.5:test (default-test) on project acme-core: There are test failures."
testcase pr core surefire acme.ATest t ok; testcase pr core surefire acme.ATest p failure
testcase base core surefire acme.ATest t ok; testcase base core surefire acme.ATest p failure
check "first build failure gone in the rerun: exit 1" "1" "$(compare)"
check "first build failure gone in the rerun: named" "core:surefire:acme.ATest#t" "$(field new)"
run_dir pr; run_dir base; first_dir
testcase first core surefire acme.ATest p failure; summary_line first 1 3
log first "[ERROR] Failed to execute goal org.apache.maven.plugins:maven-surefire-plugin:3.5.5:test (default-test) on project acme-core: There are test failures."
testcase pr core surefire acme.ATest p failure
testcase base core surefire acme.ATest p failure
check "first build: its test-failure goal is no build error, the pre-existing failure passes" "0" "$(compare)"

# 13. Review 69-I1: the same class#method failing in another module is another test.
run_dir pr; run_dir base
testcase pr mod-a failsafe acme.SmokeIT boots failure
testcase base mod-b failsafe acme.SmokeIT boots failure
check "same test name in another module: exit 1" "1" "$(compare)"
run_dir pr; run_dir base
testcase pr mod-a surefire acme.SmokeIT boots failure
testcase base mod-a failsafe acme.SmokeIT boots failure
check "same test under another report kind: exit 1" "1" "$(compare)"

# 14. Review 69-I2: the log counts more failures than the reports name (killed fork, other reports dir).
run_dir pr; run_dir base
testcase pr core surefire acme.ATest p failure; summary_line pr 3 5
testcase base core surefire acme.ATest p failure; summary_line base 1 5
check "log counts more failures than the reports: exit 1" "1" "$(compare)"
check "log counts more failures than the reports: doubt" "doubt" "$(field decision)"
run_dir pr; run_dir base
testcase pr core surefire acme.ATest p failure; summary_line pr 1 5
log pr "[WARNING] Tests run: 5, Failures: 0, Errors: 0, Skipped: 0, Flakes: 1"
testcase base core surefire acme.ATest p failure; summary_line base 1 5
check "counts that match (a Flakes summary included): exit 0" "0" "$(compare)"

# 15. Review 69-I3: another compile error in the same module and goal is the PR's.
run_dir pr; run_dir base
builderr pr acme-core compiler-plugin:3.14.0:compile
log pr "[ERROR] $TMP/pr/core/src/main/java/acme/Foo.java:[3,1] cannot find symbol NewApi"
builderr base acme-core compiler-plugin:3.14.0:compile
log base "[ERROR] $TMP/base/core/src/main/java/acme/Bar.java:[9,1] old error"
check "another compile error, same module and goal: exit 1" "1" "$(compare)"
check "another compile error: the new line is named" "1" "$(field new | grep -c 'Foo.java:\[3,1\] cannot find symbol NewApi')"

# 16. Review 69-I4: modules the PR rerun skipped were never tested with the PR: fail, whatever the baseline.
run_dir pr; run_dir base
builderr pr acme-core compiler-plugin:3.14.0:compile; skipped pr "App"
builderr base acme-core compiler-plugin:3.14.0:compile; skipped base "App"
check "modules skipped in the PR rerun (on both sides): exit 1" "1" "$(compare)"
check "modules skipped in the PR rerun: named" "1" "$(field reason | grep -c 'App')"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
