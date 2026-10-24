#!/usr/bin/env bash
# Tests of resolve-consumers.sh, with a stub curl (no network) and a stub resolver.
# Run: bash build-impacted/resolve-consumers-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/resolve-consumers.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected '$expected', got '$actual'"
    failures=$((failures + 1))
  fi
}

FIX="$TMP/fixtures"; BIN="$TMP/bin"; mkdir -p "$FIX" "$BIN"
cat > "$FIX/data.json" <<'EOF'
{"schema_version": 1, "repo": "Vidocq/vauban", "updated_at": "2026-10-24T10:00:00Z",
 "produces": [{"groupId": "io.vidocq.vauban", "artifactId": "vauban-core"},
              {"groupId": "io.vidocq.vauban", "artifactId": "vauban-api"}]}
EOF
graph() { printf '{"schema_version": 1, "generated_at": "%s", "artifacts": {}}' "$1" > "$FIX/inverted.json"; }
# The resolver records its arguments and answers a fixed ordered matrix.
cat > "$FIX/resolve_impact.py" <<EOF
import sys
open("$TMP/resolver-args", "w").write(" ".join(sys.argv[1:]))
print('{"include": [{"repo": "Vidocq/foy"}, {"repo": "Vidocq/gone"}, {"repo": "Vidocq/vidocq"}]}')
EOF
# curl: files from the fixtures; the forge API answers 404 for Vidocq/gone, 200 otherwise.
cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TMP/curl-calls"
out="" url="" wcode=false
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -w) wcode=true; shift 2 ;;
    -H|--retry|--retry-delay|--connect-timeout) shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
if [ "\$wcode" = true ]; then
  case "\$url" in */api/v1/repos/Vidocq/gone) printf 404 ;; *) printf 200 ;; esac
  exit 0
fi
case "\$url" in
  */graph/inverted.json) cp "$FIX/inverted.json" "\$out" ;;
  */scripts/resolve_impact.py) cp "$FIX/resolve_impact.py" "\$out" ;;
  */data/Vidocq_vauban.json) cp "$FIX/data.json" "\$out" ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$BIN/curl"

run() { # run -> exit status; output in $TMP/out
  rm -f "$TMP/curl-calls"
  env PATH="$BIN:$PATH" PRODUCER_SLUG=Vidocq/vauban GITHUB_SERVER_URL=https://forge.example/ \
    RESOLVE_DIR="$TMP/resolve" REQUIRE_FRESH_GRAPH=true "$@" bash "$SCRIPT" > "$TMP/out" 2>&1
  echo $?
}

graph 2026-10-24T10:00:05Z
check "a fresh graph resolves" "0" "$(run)"
check "consumers missing from the forge are dropped, the order is kept" \
  "Vidocq/foy Vidocq/vidocq" "$(tr '\n' ' ' < "$TMP/resolve/impacted.txt" | sed 's/ $//')"
check "the resolver gets every produced artifact, ordered" \
  "--graph $TMP/resolve/inverted.json --changed io.vidocq.vauban:vauban-api io.vidocq.vauban:vauban-core --format matrix --ordered" \
  "$(cat "$TMP/resolver-args")"
check "the graph is read from the graph repository's raw branch" "1" \
  "$(grep -c 'https://forge.example/Vidocq/dep-graph/raw/branch/main/graph/inverted.json' "$TMP/curl-calls")"
check "no token: anonymous reads" "0" "$(grep -c 'Authorization' "$TMP/curl-calls")"
check "the count is logged" "Impacted consumers to rebuild: 2" "$(tail -1 "$TMP/out")"

run BOT_TOKEN=secret GRAPH_REF=dev >/dev/null
check "a token is sent on every request" "6" "$(grep -c 'Authorization: token secret' "$TMP/curl-calls")"
check "graph-ref selects the branch" "3" "$(grep -c '/raw/branch/dev/' "$TMP/curl-calls")"

graph 2026-06-08T14:46:12Z
check "a stale graph fails when freshness is required" "1" "$(run)"
check "a stale graph is only a warning otherwise" "0" "$(run REQUIRE_FRESH_GRAPH=false)"

printf '{"schema_version": 1, "repo": "Vidocq/vauban", "updated_at": "2026-01-01T00:00:00Z", "produces": []}' > "$FIX/data.json"
check "a producer without artifacts fails" "1" "$(run)"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
