#!/usr/bin/env bash
# Resolve the transitive downstream consumers of a producer from the Vidocq dependency graph,
# in topological order (producer before consumer), keeping only the repositories that exist on
# the forge. Shared by build-impacted (the sequential chain) and resolve-impacted (the matrix).
#
# Env:
#   PRODUCER_SLUG        forge slug of the producer, e.g. Vidocq/vauban (required)
#   GITHUB_SERVER_URL    forge base URL (set by the runner)
#   GRAPH_REPO           owner/name of the public dependency-graph repository (Vidocq/dep-graph)
#   GRAPH_REF            branch of the dependency-graph repository (main)
#   REQUIRE_FRESH_GRAPH  true: a graph older than the producer data fails; false: a warning (true)
#   BOT_TOKEN            optional token, only to lift rate limits; empty on fork pull requests
#   RESOLVE_DIR          where inverted.json, data.json, resolve_impact.py and impacted.txt are
#                        written (/tmp, which build-impacted has always used)
#
# Output: $RESOLVE_DIR/impacted.txt, one consumer slug per line, in topological order (it may be
# empty: no consumer on the forge).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${PRODUCER_SLUG:?PRODUCER_SLUG}" "${GITHUB_SERVER_URL:?GITHUB_SERVER_URL}"
GRAPH_REPO="${GRAPH_REPO:-Vidocq/dep-graph}"
GRAPH_REF="${GRAPH_REF:-main}"
REQUIRE_FRESH_GRAPH="${REQUIRE_FRESH_GRAPH:-true}"
OUT="${RESOLVE_DIR:-/tmp}"
mkdir -p "$OUT"

if ! command -v python3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 \
   || ! command -v curl >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  apt-get update && apt-get install -y --no-install-recommends python3 jq curl git ca-certificates
fi

# Forge slug -> data file name: Vidocq/vauban -> Vidocq_vauban.json
DATA_FILE="${PRODUCER_SLUG/\//_}.json"
FORGE="${GITHUB_SERVER_URL%/}"
RAW="${FORGE}/${GRAPH_REPO}/raw/branch/${GRAPH_REF}"
echo "Producer=$PRODUCER_SLUG / data file=$DATA_FILE / graph repo=$GRAPH_REPO ref=$GRAPH_REF"

# The dependency graph is public, so the token is optional. On an external fork PR
# BOT_TOKEN is empty (org secrets are withheld from forks): drop the auth header and
# read anonymously. Internal PRs still pass the token to lift rate limits.
if [ -n "${BOT_TOKEN:-}" ]; then auth=(-H "Authorization: token ${BOT_TOKEN}"); else auth=(); fi
# Retry on transient forge failures (504 gateway timeout, dropped connections).
# --retry-all-errors retries on HTTP 5xx too, not just connection errors.
retry_curl=(--retry 5 --retry-delay 3 --retry-all-errors --retry-connrefused --connect-timeout 15)
curl -fsSL "${retry_curl[@]}" ${auth[@]+"${auth[@]}"} -o "$OUT/inverted.json"     "$RAW/graph/inverted.json"
curl -fsSL "${retry_curl[@]}" ${auth[@]+"${auth[@]}"} -o "$OUT/resolve_impact.py" "$RAW/scripts/resolve_impact.py"
curl -fsSL "${retry_curl[@]}" ${auth[@]+"${auth[@]}"} -o "$OUT/data.json"         "$RAW/data/${DATA_FILE}"

# A graph older than the producer data may miss consumers: an error when
# require-fresh-graph is true, a warning otherwise.
python3 "$HERE/graph-freshness.py" "$OUT/inverted.json" "$OUT/data.json" "$REQUIRE_FRESH_GRAPH"

# Artifacts this repo produces (source of truth kept by update-dep-graph).
ARTIFACTS=$(python3 - "$OUT/data.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(" ".join(sorted({f"{p['groupId']}:{p['artifactId']}" for p in d.get("produces", [])})))
PY
)
if [ -z "$ARTIFACTS" ]; then
  echo "No io.vidocq.* artifact in data/${DATA_FILE} — graph out of sync?" >&2
  exit 1
fi
echo "Produces: $ARTIFACTS"

# --ordered = producer-before-consumer topological order (required for the
# sequential rebuild: each level installs locally before the next consumes it).
# shellcheck disable=SC2086
MATRIX=$(python3 "$OUT/resolve_impact.py" \
  --graph "$OUT/inverted.json" --changed $ARTIFACTS --format matrix --ordered)
echo "Ordered matrix (raw): $MATRIX"

# Keep only consumers that already exist on the forge (Codefloe). The migrated graph still
# lists historical/not-yet-migrated consumers; each rejoins automatically once
# created — no manual flag. Order is preserved (jq keeps array order).
: > "$OUT/impacted.txt"
for r in $(echo "$MATRIX" | jq -r '.include[].repo'); do
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    --retry 5 --retry-delay 3 --retry-all-errors --retry-connrefused --connect-timeout 15 \
    ${auth[@]+"${auth[@]}"} "${FORGE}/api/v1/repos/$r")
  if [ "$code" = "200" ]; then
    echo "  keep $r"
    echo "$r" >> "$OUT/impacted.txt"
  else
    echo "  drop $r (not on the forge yet, HTTP $code)"
  fi
done
echo "Impacted consumers to rebuild: $(wc -l < "$OUT/impacted.txt" | tr -d ' ')"
