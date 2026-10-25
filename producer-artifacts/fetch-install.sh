#!/usr/bin/env bash
# Downstream job: install the producer artifacts the producer job shared instead of rebuilding the
# producer (rebuild-producer.sh calls it first). Run in the producer checkout. Exit 0 when the
# artifacts are installed, 1 otherwise; either way a notice says what happened.
#
# Env:
#   PRODUCER_ARTIFACTS_NAME  the run's artifact (producer-artifacts-<run id>)
#   PRODUCER_VERSION         the PR version the consumers pin
#   PRODUCER_MVN_ARGS        Maven args of the effective-POM run (-B -ntp)
#   ARTIFACTS_API            <server>/api/v1/repos/<owner>/<repo>
#   ARTIFACTS_RUN            the run id
#   ARTIFACTS_TOKEN          the job token (read access to the run's artifacts)
#   TESTS, PRODUCER_ARTIFACTS  targeted mode: the producer artifact list, from the manifest
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELP=org.apache.maven.plugins:maven-help-plugin:3.5.2
MVN_ARGS="${PRODUCER_MVN_ARGS--B -ntp}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

refuse() {
  echo "::notice title=Producer artifacts::${PRODUCER_ARTIFACTS_NAME:-?} not used ($1): the producer is rebuilt in this job."
  exit 1
}
# The producer reactor as this job's checkout describes it, and the local repository.
# shellcheck disable=SC2086
mvn $MVN_ARGS "$HELP:effective-pom" -Doutput="$WORK/eff.xml" </dev/null > "$WORK/eff.log" 2>&1 \
  || refuse "the effective POM of the producer failed"
python3 "$HERE/../build-one-consumer/targeted/producer-artifacts.py" "$WORK/eff.xml" "$WORK/modules.txt" > /dev/null \
  || refuse "the producer modules could not be listed"
# shellcheck disable=SC2086
repo=$(mvn $MVN_ARGS -N -q "$HELP:evaluate" -Dexpression=settings.localRepository -DforceStdout </dev/null 2>/dev/null)
[ -n "$repo" ] && [ -d "$repo" ] || refuse "the local repository is unknown"
list_out=()
if [ "${TESTS:-full}" = targeted ]; then
  list_out=(--list-out "${PRODUCER_ARTIFACTS:-${RUNNER_TEMP:-/tmp}/targeted/producer-artifacts.txt}")
fi
out=$(python3 "$HERE/fetch_install.py" --api "${ARTIFACTS_API:-}" --run "${ARTIFACTS_RUN:-}" \
        --name "${PRODUCER_ARTIFACTS_NAME:-}" --token "${ARTIFACTS_TOKEN:-}" --version "${PRODUCER_VERSION:-}" \
        --modules "$WORK/modules.txt" --repo "$repo" --work "$WORK" ${list_out[@]+"${list_out[@]}"} 2>&1)
rc=$?
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || refuse "$(printf '%s\n' "$out" | sed -n 's/^REASON: //p' | tail -n 1)"
echo "::notice title=Producer artifacts::${PRODUCER_ARTIFACTS_NAME} installed from the producer job ($(printf '%s\n' "$out" | tail -n 1)): no rebuild of the producer."
