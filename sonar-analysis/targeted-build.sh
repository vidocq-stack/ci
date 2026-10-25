#!/usr/bin/env bash
# The Sonar build, with targeted producer tests on a pull request (targeted-tests: true):
#
#   targeted-build.sh <build command...>
#
# On a pull request, targeted-producer-tests (mode targeted) first turns off the tests of the
# modules the change does not reach: the coverage of the changed code comes from the tests of the
# modules that hold it or depend on it, which still run. The build command runs, then every edited
# pom is put back (mode restore) before anything else (the security scans, the analysis) reads the
# checkout. Returns the build's exit status; 1 when the poms cannot be restored. Off (or on a push
# to main), only the build command runs.
#
# Env:
#   TARGETED_TESTS   true | false
#   EVENT_NAME       pull_request: targeted; anything else: full
#   BASE_REF, PR_NUMBER  the pull request (targeted-producer-tests reads the changed paths from git)
#   ANALYSIS_ARGS    Maven args with the build's profiles, for the effective POM (-B -ntp -Pquality)
#   PRODUCER_TESTS   targeted-producer-tests/producer-tests.sh
#   TARGETED_DIR     work directory of targeted-producer-tests ($RUNNER_TEMP/targeted/sonar)
set -uo pipefail

TARGETED_TESTS="${TARGETED_TESTS:-false}"
case "$TARGETED_TESTS" in
  true|false) ;;
  *) echo "::error::targeted-tests must be 'true' or 'false', not '$TARGETED_TESTS'" >&2; exit 1 ;;
esac
if [ "$TARGETED_TESTS" != true ] || [ "${EVENT_NAME:-}" != pull_request ]; then
  "$@"
  exit $?
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCER_TESTS="${PRODUCER_TESTS:-$HERE/../targeted-producer-tests/producer-tests.sh}"
export TARGETED_DIR="${TARGETED_DIR:-${RUNNER_TEMP:-/tmp}/targeted/sonar}"

if ! MODE=targeted MVN_ARGS="${ANALYSIS_ARGS:--B -ntp}" BASE_REF="${BASE_REF:-}" PR_NUMBER="${PR_NUMBER:-}" \
     TESTS_MODE_OUT="$TARGETED_DIR/mode.txt" bash "$PRODUCER_TESTS"; then
  echo "::error::Targeted tests: the poms could not be restored after a failed preparation; no Sonar build."
  exit 1
fi
rc=0
"$@" || rc=$?
if ! MODE=restore bash "$PRODUCER_TESTS"; then
  echo "::error::Targeted tests: the edited poms could not be restored; no analysis on an edited checkout."
  exit 1
fi
exit "$rc"
