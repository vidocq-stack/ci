#!/usr/bin/env bash
# Rebuild ONE consumer repository against upstream versions already installed in the local
# Maven repository. Shared by build-impacted (one call per consumer of the sequential chain)
# and build-one-consumer (the flat matrix: one consumer per job).
#
#   rebuild-consumer.sh --slug OWNER/NAME --clone-url URL --dir DIR --suffix SUFFIX
#                       [--branch BRANCH] [--pin NAME=VERSION]... [--log FILE]
#                       [--version-out FILE] [--skip-tests] [--warn-unpinned NAME]
#                       [--prepare SCRIPT]
#
#   1. clone URL (BRANCH, or the default branch) into DIR, with retries;
#   2. pin each NAME.version property of the consumer's reactor to VERSION, in one pass
#      without Maven (pin-upstreams.py), else one versions:set-property per pin;
#   3. give the consumer its own release-style version <base>-SUFFIX (versions:set), and keep
#      the hand-written plugin.xml descriptors in step;
#   4. --prepare: run SCRIPT (bash, in DIR) just before the install; build-one-consumer's
#      targeted test mode edits the poms there;
#   5. mvn install (tests run unless --skip-tests), the output copied to FILE with --log.
#
# --version-out writes the consumer version to a file, so the caller can pin it in the next
# consumers. --warn-unpinned NAME prints a warning when no pom of the consumer declares
# <NAME.version>: the consumer then resolves that upstream from central-snapshots, not from the
# version just pinned, and the build says nothing about the change under test.
#
# Env: MVN_ARGS (common Maven args, word-split as given); UNPINNED_OUT, when set, is a file to
# which each NAME of --warn-unpinned that was not pinned is appended. DIR is left in place.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MVN_ARGS="${MVN_ARGS--B -ntp}"

slug="" url="" dir="" suffix="" branch="" log="" version_out="" skip_tests=false prepare=""
pins=() warn_unpinned=()
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) slug="$2"; shift 2 ;;
    --clone-url) url="$2"; shift 2 ;;
    --dir) dir="$2"; shift 2 ;;
    --suffix) suffix="$2"; shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
    --pin) pins+=("$2"); shift 2 ;;
    --log) log="$2"; shift 2 ;;
    --version-out) version_out="$2"; shift 2 ;;
    --skip-tests) skip_tests=true; shift ;;
    --warn-unpinned) warn_unpinned+=("$2"); shift 2 ;;
    --prepare) prepare="$2"; shift 2 ;;
    *) echo "rebuild-consumer.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done
: "${slug:?--slug}" "${url:?--clone-url}" "${dir:?--dir}" "${suffix:?--suffix}"

bash "$HERE/clone-retry.sh" "$url" "$dir" "$branch"
cd "$dir"

# 1) Pin every given upstream to its local PR version.
#    -D<prop>=<val> on the CLI does not reliably override <version>${prop}</version>
#    resolution, so we physically rewrite the property in every reactor pom.
#    One pass, without starting Maven (pin-upstreams.py makes the same edits as one
#    versions:set-property per upstream). When it cannot tell exactly which poms Maven
#    would rewrite, it changes nothing and exits non-zero: Maven then does it.
if [ "${#pins[@]}" -gt 0 ]; then
  pin_args=()
  for p in "${pins[@]}"; do pin_args+=(--pin "$p"); done
  if ! python3 "$HERE/pin-upstreams.py" --maven-args="$MVN_ARGS" "${pin_args[@]}" .; then
    echo "::warning::${slug}: upstream versions not pinned in one pass, falling back to one versions:set-property per upstream"
    for p in "${pins[@]}"; do
      up="${p%%=*}" v="${p#*=}"
      if grep -rqlF "<${up}.version>" --include=pom.xml .; then
        echo "  set ${up}.version=${v}"
        # shellcheck disable=SC2086
        mvn $MVN_ARGS versions:set-property \
          -Dproperty="${up}.version" -DnewVersion="${v}" \
          -DprocessAllModules=true -DgenerateBackupPoms=false </dev/null
      fi
    done
  fi
fi
for up in ${warn_unpinned[@]+"${warn_unpinned[@]}"}; do
  if ! grep -rqlF "<${up}.version>" --include=pom.xml .; then
    if [ -n "${UNPINNED_OUT:-}" ]; then printf '%s\n' "$up" >> "$UNPINNED_OUT"; fi
    echo "::warning title=Upstream not pinned in ${slug}::no pom of ${slug} declares <${up}.version>, so it was not pinned to the pull-request version: ${slug} resolves ${up} as declared (usually its SNAPSHOT on central-snapshots), and this build does not check the change under test against it."
  fi
done

# 2) Give this consumer its own release-style PR version so the next level
#    resolves it from local M2 (release = immutable, never re-fetched).
base=$(python3 "$HERE/pom-version.py" pom.xml)
cver="${base}-${suffix}"
echo "  consumer version: $cver"
# shellcheck disable=SC2086
mvn $MVN_ARGS versions:set \
  -DnewVersion="$cver" -DprocessAllModules=true -DgenerateBackupPoms=false </dev/null
python3 "$HERE/sync-plugin-descriptors.py" .
if [ -n "$version_out" ]; then printf '%s\n' "$cver" > "$version_out"; fi
if [ -n "$prepare" ]; then bash "$prepare" </dev/null; fi

# 3) install (runs unit + integration tests unless --skip-tests) -> available for downstream
#    levels. The log is kept for the flaky-test report (pipefail keeps Maven's exit status).
goals=(install)
if [ "$skip_tests" = true ]; then goals+=(-DskipTests); fi
if [ -n "$log" ]; then
  # shellcheck disable=SC2086
  mvn $MVN_ARGS "${goals[@]}" </dev/null 2>&1 | tee "$log"
else
  # shellcheck disable=SC2086
  mvn $MVN_ARGS "${goals[@]}" </dev/null
fi
