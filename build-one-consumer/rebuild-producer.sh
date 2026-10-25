#!/usr/bin/env bash
# Rebuild the producer under pull request at its release-style PR version and install it in the
# job's local Maven repository, without its tests: the producer's own build, tests and TCK are
# the job of the producer's pull-request validation, not of each downstream job. Same version
# setting as the producers' pr.yml (versions:set + plugin.xml sync).
#
# Env:
#   PRODUCER_VERSION    release-style PR version, e.g. 0.4.0-PR42.abc12345 (required)
#   PRODUCER_DIR        the producer checkout (.)
#   PRODUCER_MVN_ARGS   Maven args (-B -ntp), word-split as given
#   SHARED              directory of the shared scripts (../build-impacted)
#   TESTS               full (default) | targeted: targeted also writes the producer artifacts to
#                       PRODUCER_ARTIFACTS ($RUNNER_TEMP/targeted/producer-artifacts.txt)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${PRODUCER_VERSION:?PRODUCER_VERSION}"
SHARED="${SHARED:-$HERE/../build-impacted}"
PRODUCER_MVN_ARGS="${PRODUCER_MVN_ARGS--B -ntp}"

cd "${PRODUCER_DIR:-.}"
case "$PRODUCER_VERSION" in
  *-SNAPSHOT) echo "::error::producer-version must be release-style (no -SNAPSHOT): $PRODUCER_VERSION" >&2; exit 1 ;;
esac
echo "Producer version: $PRODUCER_VERSION"
# shellcheck disable=SC2086
mvn $PRODUCER_MVN_ARGS versions:set \
  -DnewVersion="$PRODUCER_VERSION" -DprocessAllModules=true -DgenerateBackupPoms=false </dev/null
python3 "$SHARED/sync-plugin-descriptors.py" .
# install (not deploy): the PR artifacts land in the job's local repository only.
# shellcheck disable=SC2086
mvn $PRODUCER_MVN_ARGS install -DskipTests </dev/null

# Targeted test mode of the consumer build: list every artifact this rebuild installed (the
# modules of the reactor, same Maven args). Never fails the rebuild: an empty list makes the
# consumer build fall back to running every test.
if [ "${TESTS:-full}" = targeted ]; then
  out="${PRODUCER_ARTIFACTS:-${RUNNER_TEMP:-/tmp}/targeted/producer-artifacts.txt}"
  eff="$(dirname "$out")/producer-effective-pom.xml"
  mkdir -p "$(dirname "$out")"
  : > "$out"
  # shellcheck disable=SC2086
  if mvn $PRODUCER_MVN_ARGS org.apache.maven.plugins:maven-help-plugin:3.5.2:effective-pom \
       -Doutput="$eff" </dev/null > "$eff.log" 2>&1 \
     && python3 "$HERE/targeted/producer-artifacts.py" "$eff" "$out.tmp"; then
    mv "$out.tmp" "$out"
  else
    tail -n 20 "$eff.log" 2>/dev/null || true
    rm -f "$out.tmp"
    echo "::warning title=Targeted tests::the producer artifacts could not be listed (effective POM); the consumer build runs every test."
  fi
fi
