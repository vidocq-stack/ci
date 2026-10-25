#!/usr/bin/env bash
# merge.sh — rebase a PR's head branch onto its base, re-sign every replayed
# commit with the dedicated CI bot GPG key, force-push, then (unless
# MERGE_AFTER_REBASE=false) fast-forward merge via the Forgejo API.
#
# Why this exists: any server-side merge/squash/rebase (on Forgejo, GitHub or
# GitLab alike) strips the contributor's original GPG signature, because the
# signature covers the parent hash and the merge/rebase changes it. With
# require_signed_commits enabled, that leaves only two options that don't
# require a human to rebase+resign locally before every merge: fast-forward
# (no new commit at all), or an automated re-signer — this script.
#
# Required env (passed by action.yml):
#   PR_NUMBER, REPO, BASE_URL, BOT_TOKEN
#   GIT_SIGNING_PRIVATE_KEY, GIT_SIGNING_PASSPHRASE, GIT_SIGNING_KEY_ID
#   BOT_NAME, BOT_EMAIL, MERGE_AFTER_REBASE (true/false, default true)
#   TRIGGER_EVENT, TRIGGER_COMMENTER, TRIGGER_COMMENT — what set this run off
#   TRIGGER_BOT_LOGIN — the bot's own account (default vidocq-ci-bot)
#   CHECKS_TIMEOUT_MINUTES — how long to wait for the required checks (default 60, at most 80)
#   MERGE_BOT_REASON_FILE — optional: every refusal is also written there, for the failure comment
#
# Assumes the calling workflow already ran actions/checkout@v4 with
# fetch-depth: 0 and a token with push rights (VIDOCQ_BOT_TOKEN).

set -euo pipefail

# A refusal is also written to MERGE_BOT_REASON_FILE, which the calling workflow quotes in its failure
# comment: "see the run log" told nobody that the pull request was WIP.
die()  {
  echo "❌ $*" >&2
  if [[ -n "${MERGE_BOT_REASON_FILE:-}" ]]; then printf '%s\n' "$*" > "$MERGE_BOT_REASON_FILE" || true; fi
  exit 1
}
info() { echo "ℹ️  $*"; }
ok()   { echo "✅ $*"; }

require_env() {
  local missing=()
  for v in "$@"; do [[ -n "${!v:-}" ]] || missing+=("$v"); done
  (( ${#missing[@]} == 0 )) || die "missing required env: ${missing[*]}"
}

require_env PR_NUMBER REPO BASE_URL BOT_TOKEN \
            GIT_SIGNING_PRIVATE_KEY GIT_SIGNING_PASSPHRASE GIT_SIGNING_KEY_ID

# The budget for the required checks, refused here rather than after the rebase
# and force-push. 80 minutes at most: the calling job stops at 90, and a wait it
# cuts short ends the run without the failure comment (Vidocq/ci#49).
checks_timeout_minutes="${CHECKS_TIMEOUT_MINUTES-60}"
[[ "$checks_timeout_minutes" =~ ^[1-9][0-9]?$ ]] && (( checks_timeout_minutes <= 80 )) \
  || die "CHECKS_TIMEOUT_MINUTES must be a whole number of minutes from 1 to 80 (got '${checks_timeout_minutes}')"

# ---------------------------------------------------------------- 0. is this trigger real?
#
# `/rebase` used to merge the pull request. The rebase-only run ends by posting
# "Still open -- use /merge when ready", the calling workflow matched /merge
# anywhere in any comment, and so the bot re-triggered itself in merge mode and
# merged six pull requests nobody had asked to merge.
#
# Refusing here rather than exiting 0 is deliberate: a successful run makes the
# caller post its "rebased, still open" comment, which would trigger the bot
# again, which would refuse again, which would comment again -- a loop. A
# failure posts a message carrying no trigger word, and stops.
if [[ "${TRIGGER_EVENT:-}" == "issue_comment" ]]; then
  [[ "${TRIGGER_COMMENTER:-}" != "${TRIGGER_BOT_LOGIN:-vidocq-ci-bot}" ]] \
    || die "this comment was written by the bot itself — refusing to act on it"
  case "${TRIGGER_COMMENT:-}" in
    /merge*|/rebase*) ;;
    *) die "a trigger is the first thing in a comment; this one only mentions one in passing" ;;
  esac
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="${BASE_URL%/}/api/v1"
auth_hdr="Authorization: token ${BOT_TOKEN}"

# ---------------------------------------------------------------- 1. PR metadata

info "Fetching pull request #${PR_NUMBER} metadata"
pr_json=$(curl -fsS -H "$auth_hdr" "${API}/repos/${REPO}/pulls/${PR_NUMBER}") \
  || die "could not fetch PR #${PR_NUMBER} (repo ${REPO})"

base_ref=$(python3 -c 'import sys,json; print(json.load(sys.stdin)["base"]["ref"])' <<<"$pr_json")
head_ref=$(python3 -c 'import sys,json; print(json.load(sys.stdin)["head"]["ref"])' <<<"$pr_json")
head_repo=$(python3 -c 'import sys,json; print(json.load(sys.stdin)["head"]["repo"]["full_name"])' <<<"$pr_json")
state=$(python3 -c 'import sys,json; print(json.load(sys.stdin)["state"])' <<<"$pr_json")
mergeable=$(python3 -c 'import sys,json; print(json.load(sys.stdin).get("mergeable"))' <<<"$pr_json")

[[ "$state" == "open" ]] || die "PR #${PR_NUMBER} is not open (state: $state)"
[[ "$head_repo" == "$REPO" ]] \
  || die "cross-repo/fork PRs are not supported (head repo: ${head_repo}) — merge manually"
[[ "$mergeable" != "False" ]] \
  || die "PR #${PR_NUMBER} has conflicts with ${base_ref} — resolve locally and retry /merge or /rebase"

info "PR #${PR_NUMBER}: ${head_ref} → ${base_ref}"

# Never merge work in progress, a member of a PR train or a blocked pull request (Vidocq/vidocq#285). Asked
# before the rebase and the force-push, which would otherwise start a new validation for nothing, and again
# right before the merge: the title or a label may change while the checks run. A rebase-only run (/rebase)
# is still allowed: it merges nothing.
# shellcheck source=refusal.sh
. "${HERE}/refusal.sh"
refuse_unmergeable() {
  local file why
  file=$(mktemp)
  printf '%s' "$1" > "$file"
  why=$(merge_refusal "$file")
  rm -f "$file"
  [[ -z "$why" ]] || die "PR #${PR_NUMBER} is not merged: ${why}."
}
if [[ "${MERGE_AFTER_REBASE:-true}" == "true" ]]; then
  refuse_unmergeable "$pr_json"
fi

# ---------------------------------------------------------------- 2. signing setup

git config user.name "${BOT_NAME:-Vidocq CI Bot}"
git config user.email "${BOT_EMAIL:-ci@vidocq.io}"

info "Importing git commit-signing key"
if base64 -d <<<"$GIT_SIGNING_PRIVATE_KEY" 2>/dev/null | gpg --batch --import 2>/dev/null; then
  ok "Signing key imported (base64-decoded)"
else
  gpg --batch --import <<<"$GIT_SIGNING_PRIVATE_KEY"
  ok "Signing key imported (ASCII-armored)"
fi
gpg --list-secret-keys --with-colons "$GIT_SIGNING_KEY_ID" | grep -q '^sec' \
  || die "signing key import failed — key ${GIT_SIGNING_KEY_ID} not visible"

# Non-interactive signing, matching release-maven/release.sh: point git at a
# wrapper that always answers the passphrase via --pinentry-mode loopback,
# read from a chmod 600 tmp file (never argv/env, to stay out of `ps`/logs).
passfile=$(mktemp)
wrapper=$(mktemp)
printf '%s' "$GIT_SIGNING_PASSPHRASE" > "$passfile"
chmod 600 "$passfile"
cat > "$wrapper" <<WRAP
#!/bin/sh
exec gpg --batch --pinentry-mode loopback --passphrase-file "$passfile" "\$@"
WRAP
chmod 700 "$wrapper"

git config gpg.program "$wrapper"
git config commit.gpgsign true
git config user.signingkey "$GIT_SIGNING_KEY_ID"

# ---------------------------------------------------------------- 3. rebase + re-sign

info "Fetching ${base_ref} and ${head_ref}"
# git has no deadline of its own: a wedged transfer would hold the runner
# until the job timeout, silent the whole time.
timeout 300 git fetch origin "$base_ref" "$head_ref"
git checkout -B "$head_ref" "origin/${head_ref}"

# Idempotence short-circuit: if the branch is already rebased onto base and
# every commit ahead already carries a valid signature, keep the existing SHA.
# Rewriting it (rebase --exec amend) would change the committer date, produce
# a new head, retrigger every required check and throw away the green ones —
# turning each retried /merge into a fresh race against the checks budget.
already_ok=false
if git merge-base --is-ancestor "origin/${base_ref}" HEAD; then
  commits=$(git rev-list "origin/${base_ref}..HEAD")
  if [[ -n "$commits" ]]; then
    already_ok=true
    for sha in $commits; do
      git verify-commit "$sha" >/dev/null 2>&1 || { already_ok=false; break; }
    done
  fi
fi

if [[ "$already_ok" == "true" ]]; then
  ok "${head_ref} is already rebased onto ${base_ref} and fully signed — keeping existing head (checks already run against it)"
else
  info "Rebasing ${head_ref} onto origin/${base_ref} (re-signing every replayed commit)"
  GIT_SEQUENCE_EDITOR=true git rebase --exec 'git commit --amend --no-edit -S' "origin/${base_ref}" \
    || die "rebase onto ${base_ref} failed (conflicts) — resolve locally and retry /merge or /rebase"

  info "Verifying every commit ahead of ${base_ref} is signed"
  commits=$(git rev-list "origin/${base_ref}..HEAD")
  [[ -n "$commits" ]] || die "no commits ahead of ${base_ref} after rebase — nothing to do"
  for sha in $commits; do
    git verify-commit "$sha" 2>&1 | sed 's/^/    /'
    git verify-commit "$sha" >/dev/null 2>&1 || die "commit ${sha} failed signature verification"
  done
  ok "All commits signed and verified"
fi

new_head=$(git rev-parse HEAD)

if [[ "$already_ok" != "true" ]]; then
  info "Force-pushing rebased+signed ${head_ref}"
  timeout 300 git push --force-with-lease origin "HEAD:${head_ref}"
fi

# ---------------------------------------------------------------- 4. fast-forward merge (optional)

if [[ "${MERGE_AFTER_REBASE:-true}" != "true" ]]; then
  ok "Rebase-only mode: ${head_ref} is up to date with ${base_ref} and fully signed — PR #${PR_NUMBER} left open"
  exit 0
fi

# The base branch says which checks it requires: wait for those only. The
# commit's combined state also covers checks it does not require, such as the
# SonarQube analysis in report mode, and waiting for it made /merge give up on a
# green pull request (Vidocq/ci#47).
# Repos without required status checks (enable_status_check=false, e.g.
# GestionProjet or governance) never report a commit status, so waiting for
# "success" would burn the whole checks budget and fail. Skip the wait.
# NOTE: use the read-level /branches/{branch} endpoint — /branch_protections/
# requires admin rights the bot token does not have (it returned an error page,
# and the fail-safe fallback made the bot wait forever on check-less repos).
# If the branch cannot be read, fall back to waiting for every status.
branch_json=$(mktemp)
curl -fsS -H "$auth_hdr" "${API}/repos/${REPO}/branches/${base_ref}" > "$branch_json" 2>/dev/null \
  && python3 -c 'import sys,json; json.load(open(sys.argv[1]))' "$branch_json" 2>/dev/null \
  || echo '{}' > "$branch_json"
checks_required=$(python3 -c 'import sys,json; print(str(json.load(open(sys.argv[1])).get("enable_status_check", True)).lower())' "$branch_json")

if [[ "$checks_required" != "true" ]]; then
  info "Branch protection on ${base_ref} does not require status checks — skipping check wait"
else
  info "Waiting for required status checks on ${new_head}"
  # CHECKS_TIMEOUT_MINUTES, 60 by default, on the clock: some repos run a full
  # Maven build (pr-validate) as part of the required checks, and Vauban's
  # rebuilds its consumers too, about 48 minutes. The 10-minute budget, then the
  # 30-minute one, lost the race whenever a slow runner or a slow repository
  # held the checks (Vidocq/ci#49). Counting attempts instead of minutes also
  # left out the time each status request takes.
  # A failed request (HTTP error, network hiccup, non-JSON body) must not end
  # the job: under `set -e -o pipefail` it used to kill the bot on the first
  # poll, typically right after the force-push while the forge was still
  # indexing the new head. Count it as "still pending" and give up only after
  # 12 failures in a row (one minute).
  status_json=$(mktemp)
  unreachable=0
  deadline=$((SECONDS + checks_timeout_minutes * 60))
  verdict="pending"
  while (( SECONDS < deadline )); do
    if curl -fsS -H "$auth_hdr" "${API}/repos/${REPO}/commits/${new_head}/status" > "$status_json" \
        && verdict=$(python3 "${HERE}/required-checks.py" "$branch_json" "$status_json" 2>/dev/null); then
      unreachable=0
    else
      unreachable=$((unreachable + 1))
      verdict="unreachable"
      info "status API not answering for ${new_head} (${unreachable}/12 in a row), retrying in 5s..."
      (( unreachable < 12 )) || die "status API failed 12 times in a row for ${new_head}"
    fi
    [[ "$verdict" == "success" ]] && break
    [[ "$verdict" == failure:* ]] && die "required status check on ${new_head} reported ${verdict}"
    sleep 5
  done
  [[ "$verdict" == "success" ]] || die "required status checks on ${new_head} did not succeed within ${checks_timeout_minutes} minutes (last state: ${verdict})"
fi

pr_json=$(curl -fsS -H "$auth_hdr" "${API}/repos/${REPO}/pulls/${PR_NUMBER}") \
  || die "could not fetch PR #${PR_NUMBER} again before merging it"
refuse_unmergeable "$pr_json"

info "Merging PR #${PR_NUMBER} (fast-forward-only)"
merge_body=$(python3 -c "
import json
print(json.dumps({
    'Do': 'fast-forward-only',
    'delete_branch_after_merge': True,
    'head_commit_id': '${new_head}',
}))
")
for attempt in $(seq 1 5); do
  resp=$(curl -sS -w '\n%{http_code}' -X POST \
    -H "$auth_hdr" -H "Content-Type: application/json" \
    -d "$merge_body" \
    "${API}/repos/${REPO}/pulls/${PR_NUMBER}/merge")
  http_code=$(tail -n1 <<<"$resp")
  body=$(sed '$d' <<<"$resp")
  case "$http_code" in
    200|201) ok "PR #${PR_NUMBER} merged (fast-forward, signed by ${GIT_SIGNING_KEY_ID})"; exit 0 ;;
    405) info "merge not yet allowed (status checks still settling), retrying in 3s..."; sleep 3 ;;
    *) die "merge API returned HTTP ${http_code}: ${body}" ;;
  esac
done
die "merge API kept returning 405 after retries: ${body}"
