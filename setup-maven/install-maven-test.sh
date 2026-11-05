#!/usr/bin/env bash
# Tests of install-maven.sh: Maven is extracted only once its archive matches the SHA-512 published next to it, a
# failed or truncated download is tried again, and a bad version is refused before anything is downloaded.
# Offline: MAVEN_DIST_BASE points at a file:// copy of the Central layout, and a curl on the PATH can cut the first
# downloads short.
# Run: bash setup-maven/install-maven-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected '$expected' in '$actual'"
    failures=$((failures + 1))
  fi
}

sha512() { if command -v sha512sum >/dev/null; then sha512sum "$1"; else shasum -a 512 "$1"; fi | awk '{print $1}'; }

# A repository in the Central layout: <base>/org/apache/maven/apache-maven/<v>/apache-maven-<v>-bin.tar.gz(.sha512)
REPO="$WORK/repo"
publish() { # publish <version> -> a distribution with bin/mvn, and its .sha512 as Central serves it (the hash alone)
  local v="$1" dir="$REPO/org/apache/maven/apache-maven/$1" src="$WORK/src-$1"
  mkdir -p "$dir" "$src/apache-maven-$v/bin"
  printf '#!/bin/sh\necho "Apache Maven %s"\n' "$v" > "$src/apache-maven-$v/bin/mvn"
  chmod +x "$src/apache-maven-$v/bin/mvn"
  head -c 200000 /dev/urandom > "$src/apache-maven-$v/lib.bin" # big enough for a cut to land inside the archive
  tar -czf "$dir/apache-maven-$v-bin.tar.gz" -C "$src" "apache-maven-$v"
  sha512 "$dir/apache-maven-$v-bin.tar.gz" > "$dir/apache-maven-$v-bin.tar.gz.sha512"
}
publish 3.9.16
publish 3.9.9

# A curl that cuts the first <n> archive downloads short (a truncated body, exit 0) and passes everything else to
# the real curl.
STUB="$WORK/stub"
mkdir -p "$STUB"
REAL_CURL="$(command -v curl)"
cat > "$STUB/curl" <<EOF
#!/usr/bin/env bash
out=""; args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do [ "\${args[i]}" = -o ] && out="\${args[i+1]}"; done
count="\$(cat "$WORK/cuts" 2>/dev/null || echo 0)"
if [[ "\${args[*]}" == *-bin.tar.gz\ * || "\${args[*]}" == *-bin.tar.gz ]] && [ "\$count" -gt 0 ] && [ -n "\$out" ]; then
  echo \$((count - 1)) > "$WORK/cuts"
  "$REAL_CURL" "\$@" || exit \$?
  head -c 1000 "\$out" > "\$out.cut" && mv "\$out.cut" "\$out"
  exit 0
fi
exec "$REAL_CURL" "\$@"
EOF
chmod +x "$STUB/curl"

# run <version> [<cuts>] [<base>] -> the script's output, exit status and the mvn it left, as "<out>|<rc>|<mvn>"
run() {
  local v="$1" cuts="${2:-0}" base="${3:-file://$REPO}" dest out rc
  dest="$(mktemp -d "$WORK/dest.XXXX")"
  echo "$cuts" > "$WORK/cuts"
  out=$(env -i PATH="$STUB:$PATH" HOME="$HOME" MAVEN_DIST_BASE="$base" MAVEN_RETRY_DELAY=0 \
      bash "$HERE/install-maven.sh" "$v" "$dest" 2>&1); rc=$?
  echo "$out|$rc|$( [ -x "$dest/apache-maven-$v/bin/mvn" ] && "$dest/apache-maven-$v/bin/mvn" || echo no-mvn)"
}

check "a matching archive is extracted"            "|0|Apache Maven 3.9.16" "$(run 3.9.16)"
check "a version dlcdn no longer serves"           "|0|Apache Maven 3.9.9"  "$(run 3.9.9)"
check "a cut download is tried again"              "|0|Apache Maven 3.9.16" "$(run 3.9.16 1)"
check "the cut is reported"                        "attempt 1 of 4: the SHA-512 does not match" "$(run 3.9.16 1)"
check "three cuts in a row still end well"         "|0|Apache Maven 3.9.16" "$(run 3.9.16 3)"
check "four cuts: refused, nothing extracted"      "|1|no-mvn"              "$(run 3.9.16 4)"
check "the refusal names the archive"              "no apache-maven-3.9.16-bin.tar.gz matching its SHA-512 after 4 attempts" "$(run 3.9.16 4)"
check "a missing version: refused"                 "|1|no-mvn"              "$(run 3.9.99)"
check "a missing version names its checksum URL"   "cannot read the SHA-512 of Maven 3.9.99" "$(run 3.9.99)"
check "a version with a path in it: refused"       "not a Maven version (got '3.9.16/../x')" "$(run 3.9.16/../x)"
check "an empty version: refused"                  "not a Maven version (got '')" "$(run '')"
check "a refused version downloads nothing"        "|2|no-mvn"              "$(run '3.9;rm')"

# A published hash that is not a SHA-512 at all (an HTML error page served with 200, say).
mkdir -p "$WORK/html/org/apache/maven/apache-maven/3.9.16"
cp "$REPO/org/apache/maven/apache-maven/3.9.16/apache-maven-3.9.16-bin.tar.gz" "$WORK/html/org/apache/maven/apache-maven/3.9.16/"
echo '<html>Moved</html>' > "$WORK/html/org/apache/maven/apache-maven/3.9.16/apache-maven-3.9.16-bin.tar.gz.sha512"
check "a checksum file without a SHA-512: refused" "is not a SHA-512" "$(run 3.9.16 0 "file://$WORK/html")"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all install-maven tests passed"
