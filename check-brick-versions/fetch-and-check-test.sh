#!/usr/bin/env bash
# Tests of fetch-and-check.sh with a stub curl serving a fixture archive (no network).
# Run: bash check-brick-versions/fetch-and-check-test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
failures=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; failures=$((failures + 1)); fi; }

mkdir -p "$TMP/bin" "$TMP/src/repo-abc"
echo '<project xmlns="http://maven.apache.org/POM/4.0.0"><version>1.0-SNAPSHOT</version></project>' > "$TMP/src/repo-abc/pom.xml"
echo 'not a pom' > "$TMP/src/repo-abc/README.md"
tar -czf "$TMP/archive.tgz" -C "$TMP/src" repo-abc
cat > "$TMP/bin/curl" <<S
#!/usr/bin/env bash
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; -H|--retry) shift 2 ;; -*) shift ;; *) url="\$1"; shift ;; esac; done
echo "\$url" >> "$TMP/urls"
case "\$url" in */archive/*) cp "$TMP/archive.tgz" "\$out" ;; *) exit 22 ;; esac
S
chmod +x "$TMP/bin/curl"

# The graph is read by python on a dead local port: the script must reach it and skip politely.
out=$(PATH="$TMP/bin:$PATH" CHECK_REPO=Vidocq/foy CHECK_REF=abc123 BASE_URL=http://127.0.0.1:9 bash "$HERE/fetch-and-check.sh" 2>&1); rc=$?
check "exit 0 in report mode" "0" "$rc"
check "the archive of the right repository and commit is requested" "1" "$(grep -c 'api/v1/repos/Vidocq/foy/archive/abc123.tar.gz' "$TMP/urls")"
check "the poms were extracted and the guard ran (graph unreadable: skipped)" "1" "$(grep -c 'dependency graph unreadable' <<<"$out")"

rm "$TMP/archive.tgz"
out=$(PATH="$TMP/bin:$PATH" CHECK_REPO=Vidocq/foy CHECK_REF=abc123 BASE_URL=http://127.0.0.1:9 bash "$HERE/fetch-and-check.sh" 2>&1); rc=$?
check "archive unreadable: notice and exit 0" "1" "$(grep -c '::notice.*check skipped' <<<"$out")"
[ "$failures" -eq 0 ] && echo "all fetch-and-check tests passed" || { echo "$failures test(s) failed"; exit 1; }
