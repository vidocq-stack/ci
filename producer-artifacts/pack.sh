#!/usr/bin/env bash
# Producer job, after its install: pack the reactor's artifacts at the pull-request version (pack.py)
# into OUT, for actions/upload-artifact. Run in the producer checkout.
#
# Env:
#   PRODUCER_VERSION  the release-style PR version the install used (required)
#   MVN_ARGS          Maven args of the effective-POM run (the install's profiles; -B -ntp)
#   OUT               output directory ($RUNNER_TEMP/producer-artifacts)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${PRODUCER_VERSION:?PRODUCER_VERSION}"
MVN_ARGS="${MVN_ARGS--B -ntp}"
OUT="${OUT:-${RUNNER_TEMP:-/tmp}/producer-artifacts}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
HELP=org.apache.maven.plugins:maven-help-plugin:3.5.2

# shellcheck disable=SC2086
mvn $MVN_ARGS "$HELP:effective-pom" -Doutput="$WORK/eff.xml" </dev/null > "$WORK/eff.log" 2>&1 \
  || { tail -n 20 "$WORK/eff.log"; echo "pack.sh: the effective POM failed" >&2; exit 1; }
python3 "$HERE/../build-one-consumer/targeted/producer-artifacts.py" "$WORK/eff.xml" "$WORK/modules.txt"
# shellcheck disable=SC2086
repo=$(mvn $MVN_ARGS -N -q "$HELP:evaluate" -Dexpression=settings.localRepository -DforceStdout </dev/null 2>/dev/null) \
  && [ -d "$repo" ] || { echo "pack.sh: the local repository is unknown" >&2; exit 1; }
rm -rf "$OUT"
python3 "$HERE/pack.py" --repo "$repo" --modules "$WORK/modules.txt" --eff "$WORK/eff.xml" --version "$PRODUCER_VERSION" --out "$OUT"
