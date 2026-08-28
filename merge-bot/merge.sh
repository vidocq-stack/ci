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
#
# Assumes the calling workflow already ran actions/checkout@v4 with
# fetch-depth: 0 and a token with push rights (VIDOCQ_BOT_TOKEN).

set -euo pipefail

die()  { echo "❌ $*" >&2; exit 1; }
info() { echo "ℹ️  $*"; }
ok()   { echo "✅ $*"; }

require_env() {
  local missing=()
  for v in "$@"; do [[ -n "${!v:-}" ]] || missing+=("$v"); done
  (( ${#missing[@]} == 0 )) || die "missing required env: ${missing[*]}"
}

require_env PR_NUMBER REPO BASE_URL BOT_TOKEN \
            GIT_SIGNING_PRIVATE_KEY GIT_SIGNING_PASSPHRASE GIT_SIGNING_KEY_ID

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
git fetch origin "$base_ref" "$head_ref"
git checkout -B "$head_ref" "origin/${head_ref}"

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

new_head=$(git rev-parse HEAD)

info "Force-pushing rebased+signed ${head_ref}"
git push --force-with-lease origin "HEAD:${head_ref}"

# ---------------------------------------------------------------- 4. fast-forward merge (optional)

if [[ "${MERGE_AFTER_REBASE:-true}" != "true" ]]; then
  ok "Rebase-only mode: ${head_ref} is up to date with ${base_ref} and fully signed — PR #${PR_NUMBER} left open"
  exit 0
fi

info "Waiting for required status checks on ${new_head} (force-push always retriggers them)"
# 120 attempts * 5s = 10 minutes: some consumer repos run a full Maven build
# (pr-validate) as part of the required checks, which routinely takes 3-5
# minutes — the previous 60s budget was only enough for the lightweight
# governance-only checks on ci/vidocq-parent.
for attempt in $(seq 1 120); do
  status=$(curl -fsS -H "$auth_hdr" "${API}/repos/${REPO}/commits/${new_head}/status" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("state"))')
  [[ "$status" == "success" ]] && break
  [[ "$status" == "failure" || "$status" == "error" ]] && die "required status checks on ${new_head} reported ${status}"
  sleep 5
done
[[ "$status" == "success" ]] || die "required status checks on ${new_head} did not succeed within 10 minutes (last state: ${status})"

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
