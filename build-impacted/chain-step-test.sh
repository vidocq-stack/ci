#!/usr/bin/env bash
# Tests of the sequential rebuild step of build-impacted/action.yml (the chain): the step's own
# script is read from action.yml and run against a forge of local bare repositories (file://)
# with a stub mvn, to check that each consumer is pinned to the producer AND to every consumer
# rebuilt before it, on its companion branch when it has one.
# Run: bash build-impacted/chain-step-test.sh
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

# The run: block of the "Rebuild impacted consumers against local PR artifacts" step.
python3 - "$HERE/action.yml" > "$TMP/step.sh" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
i = next(n for n, l in enumerate(lines) if l.strip() == "- name: Rebuild impacted consumers against local PR artifacts")
i = next(n for n in range(i, len(lines)) if lines[n].strip() == "run: |") + 1
out = []
for l in lines[i:]:
    if l.strip() and not l.startswith("        "):
        break
    out.append(l[8:])
print("\n".join(out))
PY

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
pom() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>io.vidocq.$1</groupId>
  <artifactId>$1</artifactId>
  <version>$2</version>
  <packaging>pom</packaging>
  <properties>
$3
  </properties>
</project>
EOF
}
repo() { # repo <name> <version> <properties> [<branch>]
  local work="$TMP/src/$1"
  mkdir -p "$work"
  git -C "$work" init -q -b main
  pom "$1" "$2" "$3" > "$work/pom.xml"
  git -C "$work" add pom.xml && git -C "$work" commit -q -m init
  if [ $# -ge 4 ]; then
    git -C "$work" checkout -q -b "$4"
    pom "$1" "$2" "$3<on.version>companion</on.version>" > "$work/pom.xml"
    git -C "$work" commit -q -am branch
  fi
  git clone -q --bare "$work" "$TMP/forge/Vidocq/$1.git"
}
mkdir -p "$TMP/forge/Vidocq" "$TMP/bin"
repo ravel 0.4.0-SNAPSHOT '<vauban.version>0.4.0-SNAPSHOT</vauban.version>' feat/x
repo cyrano 0.5.0-SNAPSHOT '<vauban.version>0.4.0-SNAPSHOT</vauban.version><ravel.version>0.4.0-SNAPSHOT</ravel.version>'

cat > "$TMP/bin/mvn" <<EOF
#!/usr/bin/env bash
name=\$(basename "\$PWD")
echo "\$name \$*" >> "$TMP/mvn-calls"
case " \$* " in
  *" install "*)
    echo "\$name \$(grep -o '<[a-z.]*\.version>[^<]*' pom.xml | sed 's/^<//; s/>/=/' | sort | tr '\n' ' ')" >> "$TMP/installs"
    [ "\$name" = "\${MVN_FAIL:-}" ] && exit 1 ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/mvn"

run() {
  rm -f "$TMP/mvn-calls" "$TMP/installs"; rm -rf "$TMP/runner"; mkdir -p "$TMP/runner"
  printf 'Vidocq/ravel\nVidocq/cyrano\n' > "$TMP/impacted.txt"
  sed "s|/tmp/impacted.txt|$TMP/impacted.txt|g" "$TMP/step.sh" > "$TMP/step-run.sh"
  env PATH="$TMP/bin:$PATH" RUNNER_TEMP="$TMP/runner" ACTION_PATH="$HERE" \
    GITHUB_SERVER_URL="file://$TMP/forge" GITHUB_REPOSITORY=Vidocq/vauban \
    PRODUCER_SLUG=Vidocq/Vauban PRODUCER_VERSION=0.4.0-PR7.abcdef12 VERSION_SUFFIX=PR7.abcdef12 \
    COMPANION_BRANCHES=true HEAD_REF=feat/x HEAD_REPO=Vidocq/vauban LOOKUP_ATTEMPTS=1 CLONE_ATTEMPTS=1 \
    BOT_TOKEN= MVN_ARGS='-B -ntp -Dsurefire.rerunFailingTestsCount=1' "$@" \
    bash "$TMP/step-run.sh" > "$TMP/out" 2>&1
  echo $?
}
installs() { tr '\n' '|' < "$TMP/installs" | sed 's/ |/|/g; s/|$//'; }

check "the step script was found in action.yml" "1" "$(grep -cF 'bash "${ACTION_PATH}/rebuild-consumer.sh"' "$TMP/step.sh")"
check "the chain succeeds" "0" "$(run)"
check "each consumer is pinned to the producer and to the consumers rebuilt before it" \
  "ravel on.version=companion vauban.version=0.4.0-PR7.abcdef12|cyrano ravel.version=0.4.0-PR7.abcdef12 vauban.version=0.4.0-PR7.abcdef12" \
  "$(installs)"
check "each consumer gets <its base version>-<suffix>" \
  "ravel -B -ntp -Dsurefire.rerunFailingTestsCount=1 versions:set -DnewVersion=0.4.0-PR7.abcdef12 -DprocessAllModules=true -DgenerateBackupPoms=false|cyrano -B -ntp -Dsurefire.rerunFailingTestsCount=1 versions:set -DnewVersion=0.5.0-PR7.abcdef12 -DprocessAllModules=true -DgenerateBackupPoms=false" \
  "$(grep 'versions:set ' "$TMP/mvn-calls" | tr '\n' '|' | sed 's/|$//')"
check "every consumer runs its tests with the maven-args" "2" \
  "$(grep -c ' -B -ntp -Dsurefire.rerunFailingTestsCount=1 install$' "$TMP/mvn-calls")"
check "both logs are listed for the flaky-test report" "2" \
  "$(wc -l < "$TMP/runner/downstream-logs/consumers.tsv" | tr -d ' ')"
check "the companion branch is named in a notice" "1" \
  "$(grep -c "::notice::Rebuilt on the companion branch 'feat/x': Vidocq/ravel" "$TMP/out")"
check "a failing consumer fails the step" "1" "$(run MVN_FAIL=ravel)"
check "the chain stops at the first failure" "ravel on.version=companion vauban.version=0.4.0-PR7.abcdef12" "$(installs)"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
