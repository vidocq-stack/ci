#!/usr/bin/env bash
# Fetch the poms of CHECK_REPO@CHECK_REF through the forge archive API (no checkout needed) and run
# check_brick_versions.py on them. Report mode: every failure to fetch is a ::notice and exit 0.
#
# Env: CHECK_REPO, CHECK_REF (required); CHECK_SELF (slug whose own version is checked, default
#      CHECK_REPO); BOT_TOKEN (optional, lifts rate limits); STRICT ("true": findings fail);
#      BASE_URL (https://codefloe.com).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${CHECK_REPO:?CHECK_REPO}" "${CHECK_REF:?CHECK_REF}"
BASE_URL="${BASE_URL:-https://codefloe.com}"

if ! { command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; }; then
  (apt-get update && apt-get install -y --no-install-recommends python3 curl ca-certificates) >/dev/null 2>&1 || {
    echo "::notice title=brick versions::python3/curl unavailable: check skipped"; exit 0; }
fi
work="$(mktemp -d)"
auth=(); [ -n "${BOT_TOKEN:-}" ] && auth=(-H "Authorization: token ${BOT_TOKEN}")
# One archive request, poms only: the guard never needs the sources.
if ! curl -fsSL --retry 3 ${auth[@]+"${auth[@]}"} \
      "${BASE_URL%/}/api/v1/repos/${CHECK_REPO}/archive/${CHECK_REF}.tar.gz" -o "$work/src.tgz" \
   || ! tar -xzf "$work/src.tgz" -C "$work" '*pom.xml' 2>/dev/null; then
  echo "::notice title=brick versions::cannot read ${CHECK_REPO}@${CHECK_REF}: check skipped"; exit 0
fi
top="$(find "$work" -mindepth 1 -maxdepth 1 -type d | head -1)"
args=(--repo "${CHECK_SELF:-$CHECK_REPO}" --pom-dir "$top" --forge "${BASE_URL%/}")
[ "${STRICT:-false}" = true ] && args+=(--strict)
python3 -I "$HERE/check_brick_versions.py" "${args[@]}"
