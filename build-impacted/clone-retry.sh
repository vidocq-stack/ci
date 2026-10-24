#!/usr/bin/env bash
# Shallow clone with retries, shared by build-impacted and build-one-consumer.
#
#   clone-retry.sh <url> <dest> [branch]
#
# git has no built-in retry, and the forge occasionally returns 504 on a clone under load:
# retry with exponential backoff (CLONE_ATTEMPTS, 5 by default; CLONE_DELAY seconds, 5 by
# default, doubled each time), cleaning <dest> between attempts. A token in the URL is stripped
# from the log (${url##*@}). An empty branch clones the default branch.
set -euo pipefail

url="${1:?clone url}"
dest="${2:?destination}"
branch="${3:-}"
attempt=1
max="${CLONE_ATTEMPTS:-5}"
delay="${CLONE_DELAY:-5}"
branch_args=()
[ -n "$branch" ] && branch_args=(--branch "$branch")
while :; do
  rm -rf "$dest"
  if git clone --quiet --depth 1 ${branch_args[@]+"${branch_args[@]}"} "$url" "$dest"; then exit 0; fi
  if [ "$attempt" -ge "$max" ]; then
    echo "::error::git clone failed after ${max} attempts: ${url##*@}" >&2
    exit 1
  fi
  echo "  clone attempt ${attempt}/${max} failed (${url##*@}); retrying in ${delay}s..." >&2
  sleep "$delay"; attempt=$((attempt + 1)); delay=$((delay * 2))
done
