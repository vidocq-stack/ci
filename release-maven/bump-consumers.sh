#!/usr/bin/env bash
# After a REAL release of a producer: open one pull request per direct consumer of the dependency
# graph (Vidocq/dep-graph, graph/inverted.json) that sets the consumer's <producer>.version property
# to the producer's NEW development version (<next-dev>-SNAPSHOT). Vidocq/ci#19.
#
# Without it, every consumer on main keeps pointing at the SNAPSHOT of the line that has just been
# released (0.3.0-SNAPSHOT after the 0.3.0 release): a stale pre-release the producer no longer
# publishes, so a change merged on the producer never reaches a consumer's local build.
#
# Env:
#   PRODUCER_SLUG        forge slug of the producer that released, e.g. Vidocq/vauban (required)
#   NEXT_DEV_VERSION     its next development version, with or without -SNAPSHOT (required)
#   BOT_TOKEN            token with push + pull-request access on every consumer (required)
#   GITHUB_SERVER_URL    forge base URL (set by the runner)
#   GRAPH_REPO/GRAPH_REF the dependency-graph repository (Vidocq/dep-graph, main)
#   BOT_NAME/BOT_EMAIL   git identity of the bump commits
#   GIT_SIGNING_PRIVATE_KEY/_PASSPHRASE/_KEY_ID  the bot's commit-signing key (as in release.sh);
#                        unset: the commits are unsigned (the consumer's branch protection refuses them)
#   DRY_RUN              "true": print the targets and touch nothing (no clone, no push, no PR)
#   Test hooks: BUMP_GRAPH_FILE (a local inverted.json instead of the download),
#               BUMP_CLONE_URL_TEMPLATE (printf format taking the slug; default <forge>/<slug>.git),
#               BUMP_API_BASE (forge API base, default <forge>/api/v1), BUMP_WORK_DIR.
#
# It never fails the job: the release is published by the time it runs. A consumer that cannot be
# bumped is reported as a ::warning, and check-brick-versions flags the skew on the next consumer PR.
# It is idempotent: a consumer that already has the bump branch, or whose property is already at the
# target, is skipped.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN="$HERE/../build-impacted/pin-upstreams.py"

: "${PRODUCER_SLUG:?PRODUCER_SLUG}" "${NEXT_DEV_VERSION:?NEXT_DEV_VERSION}"
FORGE="${GITHUB_SERVER_URL:-https://codefloe.com}"; FORGE="${FORGE%/}"
GRAPH_REPO="${GRAPH_REPO:-Vidocq/dep-graph}"
GRAPH_REF="${GRAPH_REF:-main}"
API="${BUMP_API_BASE:-$FORGE/api/v1}"
CLONE_TEMPLATE="${BUMP_CLONE_URL_TEMPLATE:-$FORGE/%s.git}"
BOT_NAME="${BOT_NAME:-Vidocq CI Bot}"
BOT_EMAIL="${BOT_EMAIL:-ci@vidocq.io}"
DRY_RUN="${DRY_RUN:-false}"

SHORT="${PRODUCER_SLUG##*/}"
NEXT="${NEXT_DEV_VERSION%-SNAPSHOT}"
TARGET="${NEXT}-SNAPSHOT"
BRANCH="chore/bump-${SHORT}-${NEXT}"
PROPERTY="${SHORT}.version"

info() { printf '[bump-consumers] %s\n' "$*"; }
warn() { printf '::warning title=Consumer bump::%s\n' "$*"; }

# The direct consumers of every artifact the producer publishes, minus the producer itself. Direct
# only: a consumer declares <producer>.version only when it depends on the producer itself.
resolve_consumers() {
  local graph="$1"
  PRODUCER_SLUG="$PRODUCER_SLUG" python3 - "$graph" <<'PY'
import json, os, sys
producer = os.environ['PRODUCER_SLUG']
data = json.load(open(sys.argv[1]))
seen = set()
for meta in (data.get('artifacts') or {}).values():
    if (meta or {}).get('produced_by') != producer:
        continue
    for c in (meta.get('consumed_by') or []):
        repo = ((c or {}).get('repo') or '').strip()
        if repo and repo != producer:
            seen.add(repo)
print('\n'.join(sorted(seen)))
PY
}

# git with the token as an HTTP header for this one call (not in the remote URL, not in argv).
authgit() {
  if [[ -n "${BOT_TOKEN:-}" ]]; then
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader \
      GIT_CONFIG_VALUE_0="Authorization: token ${BOT_TOKEN}" git "$@"
  else
    git "$@"
  fi
}

SIGN=false
setup_signing_key() {
  [[ -n "${GIT_SIGNING_PRIVATE_KEY:-}" ]] || { info "no git signing key: bump commits will be UNSIGNED"; return 0; }
  : "${GIT_SIGNING_PASSPHRASE:?GIT_SIGNING_PASSPHRASE}" "${GIT_SIGNING_KEY_ID:?GIT_SIGNING_KEY_ID}"
  if ! { echo "$GIT_SIGNING_PRIVATE_KEY" | base64 -d 2>/dev/null | gpg --batch --import 2>/dev/null \
         || echo "$GIT_SIGNING_PRIVATE_KEY" | gpg --batch --import 2>/dev/null; }; then
    warn "could not import the git signing key: bump commits will be UNSIGNED"; return 0
  fi
  local passfile
  passfile="$WORK/.passphrase"; printf '%s' "$GIT_SIGNING_PASSPHRASE" > "$passfile"; chmod 600 "$passfile"
  printf '#!/bin/sh\nexec gpg --batch --pinentry-mode loopback --passphrase-file "%s" "$@"\n' "$passfile" > "$WORK/gpg-wrapper"
  chmod 700 "$WORK/gpg-wrapper"
  SIGN=true
}

# Pin PROPERTY to TARGET in every pom of the consumer's reactor (exit 3 of pin-upstreams: it
# cannot decide what Maven would do, so Maven does it).
pin_property() {
  python3 "$PIN" --pin "${SHORT}=${TARGET}" . && return 0
  local rc=$?
  [[ $rc -eq 3 ]] || return $rc
  command -v mvn >/dev/null 2>&1 || return 3
  grep -rqlF "<${PROPERTY}>" --include=pom.xml . || return 0
  mvn -B -ntp -q versions:set-property -Dproperty="$PROPERTY" -DnewVersion="$TARGET" \
    -DprocessAllModules=true -DgenerateBackupPoms=false </dev/null
}

open_pull_request() {
  local slug="$1" base="$2" payload http
  payload=$(BASE="$base" SHORT="$SHORT" PROPERTY="$PROPERTY" TARGET="$TARGET" BRANCH="$BRANCH" python3 - <<'PY'
import json, os
e = os.environ
body = (
    "Automated follow-up of the %(SHORT)s release (Vidocq/ci#19).\n\n"
    "`%(SHORT)s` has released and its main moved to `%(TARGET)s`. This pull request moves the "
    "`<%(PROPERTY)s>` property of this repository from the SNAPSHOT of the released line to the new "
    "development version, so a local build of this repository resolves the current dev line of "
    "`%(SHORT)s`, not a stale pre-release.\n\n"
    "Only the property is changed; pr-validate builds this repository against it as for any pull "
    "request. The `%(TARGET)s` SNAPSHOT must be on central-snapshots first (published by the main "
    "build of `%(SHORT)s` after its post-release commit): if pr-validate cannot resolve it yet, "
    "re-run it a few minutes later.\n\n"
    "Opened by the release automation: `Vidocq/ci/release-maven/bump-consumers.sh`." % e)
print(json.dumps({"title": "chore(deps): bump %(PROPERTY)s to %(TARGET)s" % e,
                  "head": e["BRANCH"], "base": e["BASE"], "body": body}))
PY
)
  http=$(curl -sS -o "$WORK/pr.out" -w '%{http_code}' -X POST "${API}/repos/${slug}/pulls" \
    -H "Authorization: token ${BOT_TOKEN:-}" -H 'Content-Type: application/json' -H 'Accept: application/json' \
    -d "$payload" || echo 000)
  case "$http" in
    2*) info "  PR opened on ${slug}" ;;
    *)  warn "${slug}: branch ${BRANCH} pushed but the pull request could not be opened (HTTP ${http})"; return 1 ;;
  esac
}

bump_one() {
  local slug="$1" short dir url base
  short="${slug##*/}"; dir="$WORK/$short"
  # shellcheck disable=SC2059
  url=$(printf "$CLONE_TEMPLATE" "$slug")
  info "${slug}"
  if ! authgit clone --quiet --depth 1 "$url" "$dir" 2>"$WORK/clone.err"; then
    warn "${slug}: clone failed (${url##*@}): $(tail -1 "$WORK/clone.err")"; return 1
  fi
  (
    cd "$dir" || exit 1
    base=$(git symbolic-ref --short HEAD)
    if authgit ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
      info "  branch ${BRANCH} already exists: skipped (a bump is already open or was merged)"; exit 0
    fi
    pin_property || { warn "${slug}: ${PROPERTY} could not be rewritten (pin-upstreams undecidable, no Maven)"; exit 1; }
    if git diff --quiet; then
      info "  no ${PROPERTY} to move (absent, or already ${TARGET}): skipped"; exit 0
    fi
    git config user.name "$BOT_NAME"; git config user.email "$BOT_EMAIL"
    if [[ "$SIGN" == true ]]; then
      git config gpg.program "$WORK/gpg-wrapper"; git config commit.gpgsign true
      git config user.signingkey "$GIT_SIGNING_KEY_ID"
    else
      git config commit.gpgsign false
    fi
    git checkout --quiet -b "$BRANCH"
    git add -A
    git commit --quiet -s -m "chore(deps): bump ${PROPERTY} to ${TARGET}" \
      -m "${SHORT} released and moved to ${TARGET}: align this repository on the current development line (Vidocq/ci#19)."
    authgit push --quiet origin "$BRANCH" || { warn "${slug}: push of ${BRANCH} failed"; exit 1; }
    open_pull_request "$slug" "$base"
  )
}

main() {
  if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY-RUN: no consumer bumped (no clone, no push, no pull request)"; return 0
  fi
  WORK="${BUMP_WORK_DIR:-$(mktemp -d)}"; mkdir -p "$WORK"
  local graph="$WORK/inverted.json"
  if [[ -n "${BUMP_GRAPH_FILE:-}" ]]; then
    cp "$BUMP_GRAPH_FILE" "$graph"
  elif ! curl -fsSL --retry 3 ${BOT_TOKEN:+-H "Authorization: token ${BOT_TOKEN}"} \
        "${FORGE}/${GRAPH_REPO}/raw/branch/${GRAPH_REF}/graph/inverted.json" -o "$graph"; then
    warn "cannot read the dependency graph: no consumer bumped for ${PRODUCER_SLUG}"; return 0
  fi
  local consumers
  consumers=$(resolve_consumers "$graph") || { warn "cannot read the dependency graph"; return 0; }
  if [[ -z "$consumers" ]]; then info "no consumer of ${PRODUCER_SLUG}: nothing to do"; return 0; fi
  info "${PROPERTY} -> ${TARGET} in:"; printf '  - %s\n' $consumers
  setup_signing_key
  local failed=0 slug
  for slug in $consumers; do bump_one "$slug" || failed=$((failed + 1)); done
  info "done, ${failed} consumer(s) not bumped (see the warnings; the check-brick-versions guard reports the skew)"
  return 0
}

main "$@"
