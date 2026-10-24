#!/usr/bin/env bash
# Build ONE downstream consumer against the producer under pull request, in "flat" mode: only
# the producer's version is pinned to its PR version (already installed by
# rebuild-producer.sh); every other io.vidocq upstream comes from central-snapshots as
# published. That is what Central holds right after the producer is merged: the new producer
# next to the downstream SNAPSHOTs built against the old one.
#
# Companion branches (a change spanning several repositories, PR from a branch of the producer
# repo only, never from a fork; see build-impacted/companion-branch.sh):
#   - the consumer is built on its companion branch when it has one;
#   - each intermediate upstream of the consumer (UPSTREAMS, from resolve-impacted) that has the
#     companion branch is rebuilt first, in this job, on that branch, without its tests, at its
#     own PR version, and pinned in the consumer (the "mini-chain"). Its tests run in its own
#     matrix job. An intermediate upstream WITHOUT a companion branch is never rebuilt: it comes
#     from central-snapshots, as in plain flat mode.
#
# Env:
#   CONSUMER            forge slug of the consumer, e.g. Vidocq/foy (required)
#   UPSTREAMS           impacted intermediate upstreams of the consumer, space-separated, in
#                       topological order (may be empty)
#   PRODUCER_SLUG       forge slug of the producer (required)
#   PRODUCER_VERSION    PR version of the producer, installed locally (required)
#   VERSION_SUFFIX      suffix of the consumers' PR versions, e.g. PR42.abc12345 (required)
#   MVN_ARGS            Maven args of the consumer builds
#   BOT_TOKEN           optional token for the clones (rate limits); empty on fork PRs
#   COMPANION_BRANCHES, HEAD_REF, HEAD_REPO, GITHUB_REPOSITORY   see companion-branch.sh
#   GITHUB_SERVER_URL   forge base URL
#   SHARED              directory of the shared scripts (../build-impacted)
#
# Writes the consumer's build log and lists it in $RUNNER_TEMP/downstream-logs/consumers.tsv for
# the flaky-test report, and one summary table to $GITHUB_STEP_SUMMARY when set.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED="${SHARED:-$HERE/../build-impacted}"
: "${CONSUMER:?CONSUMER}" "${PRODUCER_SLUG:?PRODUCER_SLUG}" "${PRODUCER_VERSION:?PRODUCER_VERSION}"
: "${VERSION_SUFFIX:?VERSION_SUFFIX}" "${GITHUB_SERVER_URL:?GITHUB_SERVER_URL}"
export MVN_ARGS="${MVN_ARGS--B -ntp}"
UPSTREAMS="${UPSTREAMS:-}"

short_name() { local s="${1##*/}"; printf '%s\n' "${s,,}"; }
clone_url() {
  # Anonymous clone on fork PRs (no token); token-auth on internal PRs (rate limits).
  if [ -n "${BOT_TOKEN:-}" ]; then
    printf '%s/%s.git\n' "$(printf %s "${GITHUB_SERVER_URL%/}" | sed "s|https://|https://oauth2:${BOT_TOKEN}@|")" "$1"
  else
    printf '%s/%s.git\n' "${GITHUB_SERVER_URL%/}" "$1"
  fi
}

WORK="${RUNNER_TEMP:-/tmp}/downstream"
LOGS="${RUNNER_TEMP:-/tmp}/downstream-logs"
mkdir -p "$WORK"
rm -rf "$LOGS"; mkdir -p "$LOGS"

# short name -> PR version installed in the local repository: the producer, then each
# intermediate rebuilt on its companion branch.
declare -A PRV
PRV["$(short_name "$PRODUCER_SLUG")"]="$PRODUCER_VERSION"
chain=()
consumer_branch=""
started=$(date +%s)

summary() {
  local rc=$? result=success
  [ "$rc" -eq 0 ] || result="failure (exit $rc)"
  local took=$(( $(date +%s) - started ))
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### Flat downstream build of ${CONSUMER}"
      echo
      echo "| Consumer | Branch | Pinned to a PR version | Rebuilt first (companion) | Result | Build time |"
      echo "|---|---|---|---|---|---|"
      echo "| ${CONSUMER} | ${consumer_branch:-default} | $(for k in "${!PRV[@]}"; do printf '%s=%s ' "$k" "${PRV[$k]}"; done)| ${chain[*]:-none} | ${result} | $((took / 60)) min $((took % 60)) s |"
      echo
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  echo "Consumer ${CONSUMER}: ${result} in ${took} s"
}
trap summary EXIT

companion=$(bash "$SHARED/companion-branch.sh" select)
if [ -n "$companion" ]; then
  echo "Companion branch: '$companion' (the consumer and its intermediate upstreams that have it are built on it)."
  for up in $UPSTREAMS; do
    b=$(bash "$SHARED/companion-branch.sh" lookup "$(clone_url "$up")" "$companion")
    if [ -n "$b" ]; then chain+=("$up"); fi
  done
fi
if [ -n "$UPSTREAMS" ]; then
  echo "Intermediate upstreams of ${CONSUMER}: ${UPSTREAMS}"
  if [ "${#chain[@]}" -gt 0 ]; then
    echo "  rebuilt first on '$companion': ${chain[*]}; the others come from central-snapshots."
  else
    echo "  all from central-snapshots, as published (flat mode)."
  fi
fi

pin_args() {
  local k
  for k in "${!PRV[@]}"; do printf -- '--pin\n%s=%s\n--warn-unpinned\n%s\n' "$k" "${PRV[$k]}" "$k"; done
}

# Mini-chain: intermediate upstreams that have the companion branch, in topological order,
# without their tests.
for up in ${chain[@]+"${chain[@]}"}; do
  s=$(short_name "$up")
  echo "::group::Rebuild intermediate upstream $up on '$companion' (no tests)"
  mapfile -t args < <(pin_args)
  bash "$SHARED/rebuild-consumer.sh" --slug "$up" --clone-url "$(clone_url "$up")" \
    --dir "$WORK/$s" --branch "$companion" --suffix "$VERSION_SUFFIX" \
    --version-out "$WORK/$s.version" --skip-tests "${args[@]}" </dev/null
  PRV["$s"]="$(cat "$WORK/$s.version")"
  rm -rf "${WORK:?}/$s"
  echo "::endgroup::"
done

# The consumer itself, with its tests.
s=$(short_name "$CONSUMER")
url=$(clone_url "$CONSUMER")
consumer_branch=$(bash "$SHARED/companion-branch.sh" lookup "$url" "$companion")
if [ -n "$consumer_branch" ]; then
  echo "  branch: $consumer_branch (companion branch of the PR)"
else
  echo "  branch: default"
fi
echo "::group::Build $CONSUMER (pinned: ${!PRV[*]})"
mapfile -t args < <(pin_args)
# Listed before the build, so the flaky-test report reads the log of a failed build too.
printf '%s\t%s\n' "$CONSUMER" "$LOGS/$s.log" >> "$LOGS/consumers.tsv"
bash "$SHARED/rebuild-consumer.sh" --slug "$CONSUMER" --clone-url "$url" \
  --dir "$WORK/$s" --branch "$consumer_branch" --suffix "$VERSION_SUFFIX" \
  --log "$LOGS/$s.log" "${args[@]}" </dev/null
rm -rf "${WORK:?}/$s"
echo "::endgroup::"
if [ -n "$consumer_branch" ] || [ "${#chain[@]}" -gt 0 ]; then
  echo "::notice::${CONSUMER} built against the companion branch '$companion' of: ${consumer_branch:+$CONSUMER }${chain[*]:-}"
fi
