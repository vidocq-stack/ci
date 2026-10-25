#!/usr/bin/env bash
# Tests of build-consumer.sh (flat mode, mini-chain of companion branches) and of the shared
# rebuild-consumer.sh it calls. The forge is a directory of local bare repositories (file://),
# and mvn is a stub that records each call and the upstream versions of the pom it builds.
# Run: bash build-one-consumer/build-consumer-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/build-consumer.sh"
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

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

pom() { # pom <artifactId> <properties xml>
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>io.vidocq.$1</groupId>
  <artifactId>$1</artifactId>
  <version>0.4.0-SNAPSHOT</version>
  <packaging>pom</packaging>
  <properties>
$2
  </properties>
</project>
EOF
}
repo() { # repo <name> <properties of main> [<branch> <properties of branch>]
  local work="$TMP/src/$1"
  mkdir -p "$work"
  git -C "$work" init -q -b main
  pom "$1" "$2" > "$work/pom.xml"
  git -C "$work" add pom.xml && git -C "$work" commit -q -m init
  if [ $# -ge 4 ]; then
    git -C "$work" checkout -q -b "$3"
    pom "$1" "$4" > "$work/pom.xml"
    git -C "$work" commit -q -am branch
  fi
  git clone -q --bare "$work" "$TMP/forge/Vidocq/$1.git"
}
mkdir -p "$TMP/forge/Vidocq"
repo ravel '<vauban.version>0.4.0-SNAPSHOT</vauban.version>' \
  feat/x '<vauban.version>0.4.0-SNAPSHOT</vauban.version><on.version>companion</on.version>'
repo cyrano '<vauban.version>0.4.0-SNAPSHOT</vauban.version><ravel.version>0.4.0-SNAPSHOT</ravel.version>'
repo foy '<vauban.version>0.4.0-SNAPSHOT</vauban.version>' \
  feat/x '<vauban.version>0.4.0-SNAPSHOT</vauban.version><on.version>companion</on.version>'
repo grimm '<ravel.version>0.4.0-SNAPSHOT</ravel.version>'

# mvn: records "<repo> <goals>" and, on install, the *.version properties of the root pom.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/mvn" <<EOF
#!/usr/bin/env bash
name=\$(basename "\$PWD")
echo "\$name \$*" >> "$TMP/mvn-calls"
case " \$* " in
  *" install"*)
    props=\$(grep -o '<[a-z.]*\.version>[^<]*' pom.xml | sed 's/^<//; s/>/=/' | sort | tr '\n' ' ')
    echo "\$name \$props" >> "$TMP/installs"
    [ "\$name" = "\${MVN_FAIL:-}" ] && exit 1
    ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/mvn"

run() { # run [VAR=value...] -> exit status; output in $TMP/out
  rm -f "$TMP/mvn-calls" "$TMP/installs" "$TMP/summary"
  rm -rf "$TMP/runner"; mkdir -p "$TMP/runner"
  env PATH="$TMP/bin:$PATH" RUNNER_TEMP="$TMP/runner" GITHUB_STEP_SUMMARY="$TMP/summary" \
    GITHUB_SERVER_URL="file://$TMP/forge" GITHUB_REPOSITORY=Vidocq/vauban \
    PRODUCER_SLUG=Vidocq/vauban PRODUCER_VERSION=0.4.0-PR7.abcdef12 VERSION_SUFFIX=PR7.abcdef12 \
    COMPANION_BRANCHES=true HEAD_REF=feat/x HEAD_REPO=Vidocq/vauban LOOKUP_ATTEMPTS=1 CLONE_ATTEMPTS=1 \
    BOT_TOKEN= MVN_ARGS='-B -ntp' "$@" bash "$SCRIPT" > "$TMP/out" 2>&1
  echo $?
}
installs() { tr '\n' '|' < "$TMP/installs" | sed 's/ |/|/g; s/|$//'; }

# Flat: only the producer is pinned; the intermediate upstream comes from central-snapshots.
check "flat: the build succeeds" "0" "$(run CONSUMER=Vidocq/cyrano UPSTREAMS=Vidocq/ravel HEAD_REF=)"
check "flat: only the producer is pinned, the intermediate is not rebuilt" \
  "cyrano ravel.version=0.4.0-SNAPSHOT vauban.version=0.4.0-PR7.abcdef12" "$(installs)"
check "flat: the consumer gets its own PR version" "1" \
  "$(grep -c '^cyrano -B -ntp versions:set -DnewVersion=0.4.0-PR7.abcdef12 ' "$TMP/mvn-calls")"
check "flat: the consumer runs its tests" "cyrano -B -ntp install" "$(grep ' install' "$TMP/mvn-calls")"
check "flat: the build log is listed for the flaky-test report" \
  "Vidocq/cyrano	$TMP/runner/downstream-logs/cyrano.log" "$(cat "$TMP/runner/downstream-logs/consumers.tsv")"
check "flat: the job summary has the result" "1" "$(grep -c '| Vidocq/cyrano | default | vauban=0.4.0-PR7.abcdef12 | | none | success |' "$TMP/summary")"

# Mini-chain: an intermediate upstream that has the companion branch is rebuilt first.
check "chain: the build succeeds" "0" "$(run CONSUMER=Vidocq/cyrano UPSTREAMS=Vidocq/ravel)"
check "chain: the intermediate is rebuilt on its companion branch, then pinned in the consumer" \
  "ravel on.version=companion vauban.version=0.4.0-PR7.abcdef12|cyrano ravel.version=0.4.0-PR7.abcdef12 vauban.version=0.4.0-PR7.abcdef12" \
  "$(installs)"
check "chain: the intermediate is rebuilt without its tests" "ravel -B -ntp install -DskipTests" \
  "$(grep '^ravel .* install' "$TMP/mvn-calls")"
check "chain: only the consumer's log goes to the flaky-test report" "1" \
  "$(wc -l < "$TMP/runner/downstream-logs/consumers.tsv" | tr -d ' ')"
check "chain: a notice names the companion builds" "1" \
  "$(grep -c "::notice::Vidocq/cyrano built against the companion branch 'feat/x' of: Vidocq/ravel" "$TMP/out")"

# A pull request from a fork never selects a companion branch.
run CONSUMER=Vidocq/cyrano UPSTREAMS=Vidocq/ravel HEAD_REPO=someone/vauban >/dev/null
check "fork: no mini-chain" "cyrano ravel.version=0.4.0-SNAPSHOT vauban.version=0.4.0-PR7.abcdef12" "$(installs)"

# The consumer itself on its companion branch.
run CONSUMER=Vidocq/foy >/dev/null
check "companion: the consumer is built on its companion branch" \
  "foy on.version=companion vauban.version=0.4.0-PR7.abcdef12" "$(installs)"
check "companion: the summary names the branch" "1" "$(grep -c '| Vidocq/foy | feat/x |' "$TMP/summary")"

# A consumer that declares no <vauban.version> is not checked against the pull request.
check "unpinned: the build still runs" "0" "$(run CONSUMER=Vidocq/grimm UPSTREAMS=Vidocq/ravel HEAD_REF=)"
check "unpinned: a warning says the producer was not pinned" "1" \
  "$(grep -c '::warning title=Upstream not pinned in Vidocq/grimm::no pom of Vidocq/grimm declares <vauban.version>' "$TMP/out")"
check "unpinned: the summary names the upstream not pinned" "1" \
  "$(grep -c '| Vidocq/grimm | default | vauban=0.4.0-PR7.abcdef12 | vauban | none | success |' "$TMP/summary")"

# A failing consumer build fails the step, and the summary says so.
check "failure: the step fails" "1" "$(run CONSUMER=Vidocq/cyrano MVN_FAIL=cyrano HEAD_REF=)"
check "failure: the summary says so" "1" "$(grep -c '| failure (exit 1) |' "$TMP/summary")"
check "failure: the log is still listed for the flaky-test report" "1" \
  "$(grep -c '^Vidocq/cyrano' "$TMP/runner/downstream-logs/consumers.tsv")"

# A failing intermediate rebuild fails the step before the consumer is built.
check "chain failure: the step fails" "1" "$(run CONSUMER=Vidocq/cyrano UPSTREAMS=Vidocq/ravel MVN_FAIL=ravel)"
check "chain failure: the consumer is not built" "0" "$(grep -c '^cyrano' "$TMP/installs")"

# A consumer missing from the forge fails (clone error), it is never silently skipped.
check "missing consumer: the step fails" "1" "$(run CONSUMER=Vidocq/nowhere HEAD_REF=)"

# Test mode. The default and an explicit 'full' run exactly the same Maven commands.
run CONSUMER=Vidocq/cyrano HEAD_REF= >/dev/null
cp "$TMP/mvn-calls" "$TMP/calls-default"
check "default: the summary says every test ran" "1" "$(grep -c '| success | .* | full |$' "$TMP/summary")"
check "tests=full: the build succeeds" "0" "$(run CONSUMER=Vidocq/cyrano HEAD_REF= TESTS=full)"
check "tests=full: byte for byte the commands of the default" "" "$(diff "$TMP/calls-default" "$TMP/mvn-calls")"
check "tests=full: no effective POM" "0" "$(grep -c 'effective-pom' "$TMP/mvn-calls")"

# Targeted, the analysis runs between versions:set and the install, which stays the same command.
printf 'io.vidocq.vauban:vauban-core\n' > "$TMP/producer-artifacts.txt"
check "targeted: the build succeeds" "0" \
  "$(run CONSUMER=Vidocq/cyrano HEAD_REF= TESTS=targeted PRODUCER_ARTIFACTS="$TMP/producer-artifacts.txt")"
check "targeted: the effective POM of the consumer runs after its versions:set, before its install" \
  "versions:set|effective-pom|install" \
  "$(grep '^cyrano ' "$TMP/mvn-calls" | grep -oE 'versions:set |:effective-pom| install' | sed 's/^://; s/ //g' | paste -sd'|' -)"
check "targeted: the install is the command of the full mode" "cyrano -B -ntp install" "$(grep ' install' "$TMP/mvn-calls")"
check "targeted: never -DskipTests on the command line" "0" "$(grep -c -- '-DskipTests' "$TMP/mvn-calls")"
check "targeted: a failed analysis falls back to full, and the summary says why" "1" \
  "$(grep -c '| full (fallback: Maven wrote no effective POM of the consumer) |$' "$TMP/summary")"

check "targeted, no producer artifact list: the build succeeds" "0" "$(run CONSUMER=Vidocq/cyrano HEAD_REF= TESTS=targeted)"
check "targeted, no producer artifact list: falls back to full" "1" \
  "$(grep -c '| full (fallback: the producer artifact list is missing or empty (see the producer rebuild step)) |$' "$TMP/summary")"

run CONSUMER=Vidocq/cyrano UPSTREAMS=Vidocq/ravel HEAD_REF= TESTS=targeted PRODUCER_ARTIFACTS="$TMP/producer-artifacts.txt" >/dev/null
check "targeted, intermediate upstreams: falls back to full without any analysis" "0" "$(grep -c 'effective-pom' "$TMP/mvn-calls")"
check "targeted, intermediate upstreams: the summary says why" "1" \
  "$(grep -c '| full (fallback: the consumer has impacted intermediate upstreams (Vidocq/ravel)) |$' "$TMP/summary")"

run CONSUMER=Vidocq/foy TESTS=targeted PRODUCER_ARTIFACTS="$TMP/producer-artifacts.txt" >/dev/null
check "targeted, companion branch of the consumer: falls back to full without any analysis" "0" "$(grep -c 'effective-pom' "$TMP/mvn-calls")"
check "targeted, companion branch of the consumer: the summary says why" "1" \
  "$(grep -c "| full (fallback: the consumer is built on its companion branch 'feat/x') |\$" "$TMP/summary")"

check "an unknown test mode fails the step" "1" "$(run CONSUMER=Vidocq/cyrano HEAD_REF= TESTS=some)"
check "an unknown test mode builds nothing" "0" "$(cat "$TMP/mvn-calls" 2>/dev/null | grep -c ' install')"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
