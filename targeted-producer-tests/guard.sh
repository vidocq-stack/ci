#!/usr/bin/env bash
# Fails while the poms edited by targeted-producer-tests (mode: targeted) are still in place:
# any Maven run in that state skips the tests of the unaffected modules, a TCK runner included.
# Run it (or the composite with mode: guard) before any step that runs Maven after the install,
# when the restore step might not have run. run-tck calls it.
#
# Env: TARGETED_DIR (the composite's work directory, $RUNNER_TEMP/targeted/producer),
#      TARGETED_PRODUCER_EDITS (the marker, exported to GITHUB_ENV by the composite).
set -euo pipefail
marker="${TARGETED_DIR:-${RUNNER_TEMP:-/tmp}/targeted/producer}/EDITS-IN-PLACE"
for m in "$marker" "${TARGETED_PRODUCER_EDITS:-}"; do
  if [ -n "$m" ] && [ -e "$m" ]; then
    echo "::error title=Targeted producer tests::the poms edited for targeted producer tests are still in place ($m): run the composite with mode: restore right after the install (if: always()) before any other Maven step"
    exit 1
  fi
done
echo "No targeted-producer-tests edit in place."
