#!/usr/bin/env bash
# Companion branches of build-impacted: a pull request whose change spans several
# repositories rebuilds each consumer on the branch of the same name, when the
# consumer has one, instead of on its default branch.
#
#   companion-branch.sh select
#     Print the branch to look for in the consumers, or nothing. Reads COMPANION_BRANCHES
#     (true|false), HEAD_REF and HEAD_REPO (the pull request's head branch and repository)
#     and GITHUB_REPOSITORY. A push, or a pull request from a fork, names no branch: a fork
#     must not choose the code that is rebuilt next to its change.
#
#   companion-branch.sh lookup <clone-url> <branch>
#     Print <branch> if the consumer at <clone-url> has it, or nothing. Retries a forge
#     that does not answer (LOOKUP_ATTEMPTS, LOOKUP_DELAY seconds, doubled each time) and
#     then fails: a consumer that cannot be asked is never rebuilt on the wrong branch.
set -euo pipefail

select_branch() {
  [ "${COMPANION_BRANCHES:-true}" = "true" ] || return 0
  [ -n "${HEAD_REF:-}" ] || return 0
  [ "${HEAD_REPO:-}" = "${GITHUB_REPOSITORY:-}" ] || return 0
  printf '%s\n' "$HEAD_REF"
}

lookup_branch() {
  local url="$1" branch="$2" attempt=1 max="${LOOKUP_ATTEMPTS:-5}" delay="${LOOKUP_DELAY:-5}" code
  [ -n "$branch" ] || return 0
  while :; do
    # The full ref, so that feat/x does not match other/feat/x. Exit 2: no such ref.
    code=0
    git ls-remote --exit-code --heads "$url" "refs/heads/$branch" >/dev/null 2>&1 || code=$?
    case "$code" in
      0) printf '%s\n' "$branch"; return 0 ;;
      2) return 0 ;;
    esac
    if [ "$attempt" -ge "$max" ]; then
      echo "::error::could not list the branches of ${url##*@} after ${max} attempts" >&2
      return 1
    fi
    echo "  branch lookup ${attempt}/${max} failed (${url##*@}); retrying in ${delay}s..." >&2
    sleep "$delay"; attempt=$((attempt + 1)); delay=$((delay * 2))
  done
}

case "${1:-}" in
  select) select_branch ;;
  lookup) lookup_branch "${2:?clone url}" "${3-}" ;;
  *) echo "usage: $0 select | lookup <clone-url> <branch>" >&2; exit 64 ;;
esac
