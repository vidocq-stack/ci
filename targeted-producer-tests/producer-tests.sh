#!/usr/bin/env bash
# Producer-side targeted tests, for a repository's own pull request: run in the checkout, after
# the PR version is set, just before the build's one `mvn install`. From the pull request's
# changed paths, keep the tests of the changed modules and of every reactor module depending on
# them (changed-modules.py), and turn off test EXECUTION in every other non-pom module
# (skipTests/skipITs/invoker.skip in their poms, never on the command line). Every module still
# compiles, test-compiles, runs its codegen, packages and installs: the install that follows is
# the same command as without this step.
#
# Fallback on any doubt, with the reason in the log, a notice and the job summary: a changed path
# in the root module or outside every module (root pom, .mvn/, .forgejo/, scripts), an empty or
# missing list, documentation only, an effective-POM failure, a pom that cannot be read, any
# error. The poms are copied before the edits and put back on a fallback, compared byte for
# byte; when that cannot be done the step fails (build-one-consumer/targeted/skip-lib.sh).
#
# Env:
#   MODE                full (default: nothing is done) | targeted
#   CHANGED_FILES       the pull request's changed paths, one per line (required in targeted mode)
#   MVN_ARGS            Maven args of the effective-POM run, the same as the build's (-B -ntp)
#   TARGETED_DIR        work directory ($RUNNER_TEMP/targeted/producer)
#   TESTS_MODE_OUT      file receiving the one-line test mode (TARGETED_DIR/mode.txt)
#   GITHUB_OUTPUT       receives mode=full|targeted and skipped=<count>
#   GITHUB_REPOSITORY   for the annotations and the summary
#   SKIP_TESTS_PY, CHANGED_MODULES_PY   the scripts used (tests replace them)
set -euo pipefail
set -E

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../build-one-consumer/targeted"
MODE="${MODE:-full}"
MVN_ARGS="${MVN_ARGS--B -ntp}"
DIR="${TARGETED_DIR:-${RUNNER_TEMP:-/tmp}/targeted/producer}"
MODE_OUT="${TESTS_MODE_OUT:-$DIR/mode.txt}"
SKIP_TESTS_PY="${SKIP_TESTS_PY:-$LIB/skip-tests.py}"
CHANGED_MODULES_PY="${CHANGED_MODULES_PY:-$HERE/changed-modules.py}"
HELP_PLUGIN=org.apache.maven.plugins:maven-help-plugin:3.5.2
REPO="$PWD"

outputs() { # the step outputs, from the mode line
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  local line skipped=0 mode=full
  line=$(head -n 1 "$MODE_OUT" 2>/dev/null || true)
  case "$line" in
    targeted:*) mode=targeted; skipped=$(printf '%s' "$line" | sed -n 's/.*skipped in \([0-9]*\) module.*/\1/p') ;;
  esac
  { echo "mode=$mode"; echo "skipped=${skipped:-0}"; } >> "$GITHUB_OUTPUT"
}

case "$MODE" in
  full)
    echo "Producer tests: full (mode: full)"
    mkdir -p "$(dirname "$MODE_OUT")"; echo full > "$MODE_OUT"
    outputs
    exit 0 ;;
  targeted) ;;
  *) echo "::error::mode must be 'full' or 'targeted', not '$MODE'" >&2; exit 1 ;;
esac

rm -rf "$DIR"
mkdir -p "$DIR"
SUBJECT="${GITHUB_REPOSITORY:-the repository}"
NOTICE_TITLE="Targeted producer tests"
SCRIPT_NAME=producer-tests.sh
trap outputs EXIT
# fallback, finish, decide and the ERR trap, shared with the consumer side.
# shellcheck source=../build-one-consumer/targeted/skip-lib.sh
. "$LIB/skip-lib.sh"

if [ -z "${CHANGED_FILES:-}" ] || [ ! -s "$CHANGED_FILES" ] || ! grep -q '[^[:space:]]' "$CHANGED_FILES"; then
  fallback "the changed-file list is missing or empty"
fi

echo "Effective POM of the repository"
# shellcheck disable=SC2086
if ! mvn $MVN_ARGS "$HELP_PLUGIN:effective-pom" -Doutput="$DIR/effective-pom.xml" \
     </dev/null > "$DIR/effective-pom.log" 2>&1; then
  show_log "$DIR/effective-pom.log"
  fallback "Maven error in the effective POM"
fi
[ -s "$DIR/effective-pom.xml" ] || fallback "Maven wrote no effective POM"

rc=0
python3 "$CHANGED_MODULES_PY" --effective-pom "$DIR/effective-pom.xml" --repo "$REPO" \
  --changed-files "$CHANGED_FILES" --report "$DIR/report.json" || rc=$?
[ "$rc" -eq 0 ] || fallback "the analysis failed (exit $rc)"

decide
