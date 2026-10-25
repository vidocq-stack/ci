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
#   MAVEN_ARGS_IN    the build's Maven args: their -B, -ntp, -P, -D, -s, -f flags (with a separate value
#                    when written so; no goal or phase) make
#                    the effective POM, so that it sees the same profiles as the build
#   ANALYSIS_ARGS    fallback when MAVEN_ARGS_IN is empty
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

# The effective POM sees the build's own profiles and properties, without its goals and phases.
# Flags with a separate value (-P x, -s file, -f pom, --settings file, --file pom) keep it.
flags=()
take_next=false
for a in ${MAVEN_ARGS_IN:-}; do
  if [ "$take_next" = true ]; then flags+=("$a"); take_next=false; continue; fi
  case "$a" in
    -P|-s|-f|-gs|--activate-profiles|--settings|--file|--global-settings) flags+=("$a"); take_next=true ;;
    -B|-ntp|--batch-mode|--no-transfer-progress|-P*|-D*|-s*|-f*|--activate-profiles=*|--settings=*|--file=*|--global-settings=*) flags+=("$a") ;;
  esac
done
effective_args="${flags[*]:-${ANALYSIS_ARGS:--B -ntp}}"
if ! MODE=targeted MVN_ARGS="$effective_args" BASE_REF="${BASE_REF:-}" PR_NUMBER="${PR_NUMBER:-}" \
     TESTS_MODE_OUT="$TARGETED_DIR/mode.txt" bash "$PRODUCER_TESTS"; then
  if [ -e "$TARGETED_DIR/EDITS-IN-PLACE" ]; then
    echo "::error::Targeted tests: the poms could not be restored after a failed preparation; no Sonar build."
    exit 1
  fi
  # Nothing was edited: the full build is safe.
  echo "::warning::Targeted tests: the preparation failed before editing any pom; every test runs."
  "$@"
  exit $?
fi
rc=0
"$@" || rc=$?
if ! MODE=restore bash "$PRODUCER_TESTS"; then
  echo "::error::Targeted tests: the edited poms could not be restored; no analysis on an edited checkout."
  exit 1
fi
exit "$rc"
