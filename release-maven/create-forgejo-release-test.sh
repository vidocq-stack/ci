#!/usr/bin/env bash
# Tests of create-forgejo-release.sh with a stub curl (no network, no forge).
# Run: bash release-maven/create-forgejo-release-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/create-forgejo-release.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

failures=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; failures=$((failures + 1)); fi
}

# curl stub: logs "METHOD URL BODY"; the answer of the GET on the tag comes from $TMP/existing
# (404 unless the file holds 200); the POST answers $TMP/post-status (default 201).
cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
out="" url="" data="" method=GET
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -X) method="\$2"; shift 2 ;;
    -w|-H) shift 2 ;;
    -d) data="\$2"; shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
printf '%s %s %s\n' "\$method" "\$url" "\$data" >> "$TMP/calls"
[ -n "\$out" ] && echo '{}' > "\$out"
if [ "\$method" = POST ]; then cat "$TMP/post-status" 2>/dev/null || printf 201
else cat "$TMP/existing" 2>/dev/null || printf 404; fi
EOF
chmod +x "$BIN/curl"

run() { # run NAME VERSION [DRY_RUN]
  : > "$TMP/calls"
  PATH="$BIN:$PATH" PRODUCER_SLUG=Vidocq/bodoni RELEASE_VERSION="$2" BOT_TOKEN=secret-token-value \
    RELEASE_API_BASE=https://forge.test/api/v1 DRY_RUN="${3:-false}" bash "$SCRIPT" > "$TMP/out-$1" 2>&1
}
posts() { grep -c '^POST ' "$TMP/calls"; }

run dry 0.4.0-RC2 true
check "dry run exits 0" "0" "$?"
check "dry run calls nothing" "0" "$(wc -l < "$TMP/calls" | tr -d ' ')"

run rc 0.4.0-RC2
check "release candidate exits 0" "0" "$?"
check "one release is created" "1" "$(posts)"
check "it targets the producer's repository" "yes" "$(grep -q '^POST https://forge.test/api/v1/repos/Vidocq/bodoni/releases ' "$TMP/calls" && echo yes || echo no)"
check "it uses the release tag" "yes" "$(grep -q '"tag_name":"v0.4.0-RC2"' "$TMP/calls" && echo yes || echo no)"
check "a release candidate is a pre-release" "yes" "$(grep -q '"prerelease":true' "$TMP/calls" && echo yes || echo no)"
check "the body points at Maven Central" "yes" "$(grep -q 'repo1.maven.org/maven2/io/vidocq' "$TMP/calls" && echo yes || echo no)"
check "the token never reaches the output" "no" "$(grep -q secret-token-value "$TMP/out-rc" && echo yes || echo no)"

run final 0.4.0
check "a final release is not a pre-release" "yes" "$(grep -q '"prerelease":false' "$TMP/calls" && echo yes || echo no)"

printf 200 > "$TMP/existing"
run again 0.4.0
check "an existing release is left alone" "0" "$(posts)"
check "an existing release exits 0" "0" "$?"
rm -f "$TMP/existing"

printf 500 > "$TMP/post-status"
run broken 0.4.0
check "a failing forge never fails the job" "0" "$?"
check "it warns instead" "yes" "$(grep -q '::warning' "$TMP/out-broken" && echo yes || echo no)"

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failure(s)"; exit 1; }
