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
#   TESTS               full (default): every test of the consumer runs | targeted: test
#                       execution is turned off in the modules that cannot see any artifact of
#                       the producer (targeted/targeted-tests.sh); full instead, with the
#                       reason, when the consumer has intermediate upstreams or a companion
#                       branch, or on any doubt of the analysis
#   GRAPH_PRUNING       true: the targeted analysis trusts the dependency graph to skip the
#                       closure of the externals of repositories that do not consume the
#                       producer (faster, but the graph is not checked); false (default): every
#                       suspect external gets its closure resolved
#   GRAPH_REPO, GRAPH_REF  dependency graph read when GRAPH_PRUNING is true (Vidocq/dep-graph, main)
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
TESTS="${TESTS:-full}"
case "$TESTS" in
  full|targeted) ;;
  *) echo "::error::tests must be 'full' or 'targeted', not '$TESTS'" >&2; exit 1 ;;
esac

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
# Upstreams the consumer could not be pinned to (no <name.version> in its poms), for the summary.
UNPINNED="$WORK/unpinned.txt"
: > "$UNPINNED"
# One line for the summary: how the consumer's tests ran (written by targeted-tests.sh).
export TESTS_MODE_OUT="$WORK/tests-mode.txt"
echo full > "$TESTS_MODE_OUT"

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
      echo "| Consumer | Branch | PR versions | Not pinned (no property) | Rebuilt first (companion) | Result | Build time | Tests |"
      echo "|---|---|---|---|---|---|---|---|"
      echo "| ${CONSUMER} | ${consumer_branch:-default} | $(for k in "${!PRV[@]}"; do printf '%s=%s ' "$k" "${PRV[$k]}"; done)| $(sort -u "$UNPINNED" | tr '\n' ' ')| ${chain[*]:-none} | ${result} | $((took / 60)) min $((took % 60)) s | $(head -n 1 "$TESTS_MODE_OUT" 2>/dev/null) |"
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
# Targeted tests: never with a mini-chain or a companion branch (the changed set would have to
# include their artifacts too), and never on any doubt of the analysis.
prepare=()
if [ "$TESTS" = targeted ]; then
  why=""
  if [ -n "$UPSTREAMS" ]; then
    why="the consumer has impacted intermediate upstreams ($UPSTREAMS)"
  elif [ -n "$consumer_branch" ]; then
    why="the consumer is built on its companion branch '$consumer_branch'"
  fi
  if [ -n "$why" ]; then
    echo "full (fallback: $why)" > "$TESTS_MODE_OUT"
    echo "Tests: full (fallback: $why)"
  else
    prepare=(--prepare "$HERE/targeted/targeted-tests.sh")
    # Replaced by the analysis' own line; stays if it stops before writing one.
    echo "full (the targeted analysis did not complete)" > "$TESTS_MODE_OUT"
    if [ "${GRAPH_PRUNING:-false}" = true ]; then
      export GRAPH_URL="${GITHUB_SERVER_URL%/}/${GRAPH_REPO:-Vidocq/dep-graph}/raw/branch/${GRAPH_REF:-main}/graph/inverted.json"
    else
      export GRAPH_URL=""
    fi
  fi
fi
echo "::group::Build $CONSUMER (pinned: ${!PRV[*]})"
mapfile -t args < <(pin_args)
# Listed before the build, so the flaky-test report reads the log of a failed build too.
printf '%s\t%s\n' "$CONSUMER" "$LOGS/$s.log" >> "$LOGS/consumers.tsv"
UNPINNED_OUT="$UNPINNED" bash "$SHARED/rebuild-consumer.sh" --slug "$CONSUMER" --clone-url "$url" \
  --dir "$WORK/$s" --branch "$consumer_branch" --suffix "$VERSION_SUFFIX" \
  --log "$LOGS/$s.log" ${prepare[@]+"${prepare[@]}"} "${args[@]}" </dev/null
rm -rf "${WORK:?}/$s"
echo "::endgroup::"
if [ -n "$consumer_branch" ] || [ "${#chain[@]}" -gt 0 ]; then
  echo "::notice::${CONSUMER} built against the companion branch '$companion' of: ${consumer_branch:+$CONSUMER }${chain[*]:-}"
fi
