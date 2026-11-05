#!/usr/bin/env bash
# Installs Apache Maven <version> in <dest-dir>/apache-maven-<version>, from Maven Central.
#
#   install-maven.sh <version> <dest-dir>
#
# Central keeps every version, where dlcdn.apache.org serves the current releases only (3.9.9 is already gone from
# it, and 3.9.16 goes when the next one comes out), and it publishes a SHA-512 next to each archive. The archive is
# extracted only once it matches that SHA-512; a failed or truncated download is tried again rather than handed to
# tar.
#
#   MAVEN_DIST_BASE    the repository to read, https://repo.maven.apache.org/maven2 by default
#   MAVEN_RETRY_DELAY  seconds to wait after a failed attempt, times its number, 5 by default
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: install-maven.sh <version> <dest-dir>" >&2; exit 2; }
version=$1
dest=$2
# The version goes into a URL and a path: digits and dots, and a qualifier such as -rc-4, nothing else.
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*)?$ ]] \
  || { echo "install-maven.sh: not a Maven version (got '$version')" >&2; exit 2; }

attempts=4
delay=${MAVEN_RETRY_DELAY:-5}
base=${MAVEN_DIST_BASE:-https://repo.maven.apache.org/maven2}
name="apache-maven-$version-bin.tar.gz"
url="$base/org/apache/maven/apache-maven/$version/$name"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fetch() { curl -fsSL --connect-timeout 20 --max-time 300 -o "$2" "$1"; }
sha512() { if command -v sha512sum >/dev/null; then sha512sum "$1"; else shasum -a 512 "$1"; fi | awk '{print $1}'; }
pause() { if [ "$1" -lt "$attempts" ]; then sleep $((delay * $1)); fi; }

# The published hash: Central serves the hash alone, other mirrors "<hash>  <file>"; the first word either way.
expected=""
for ((i = 1; i <= attempts; i++)); do
  if fetch "$url.sha512" "$tmp/sha512"; then
    expected=$(awk 'NR == 1 { print tolower($1) }' "$tmp/sha512")
    break
  fi
  echo "attempt $i of $attempts: cannot read $url.sha512" >&2
  pause "$i"
done
[ -n "$expected" ] || { echo "install-maven.sh: cannot read the SHA-512 of Maven $version ($url.sha512)" >&2; exit 1; }
[[ $expected =~ ^[0-9a-f]{128}$ ]] \
  || { echo "install-maven.sh: $url.sha512 is not a SHA-512 (starts with '${expected:0:40}')" >&2; exit 1; }

for ((i = 1; i <= attempts; i++)); do
  if ! fetch "$url" "$tmp/$name"; then
    echo "attempt $i of $attempts: cannot download $url" >&2
  elif [ "$(sha512 "$tmp/$name")" != "$expected" ]; then
    echo "attempt $i of $attempts: the SHA-512 does not match, the download was cut short or altered" >&2
  else
    mkdir -p "$dest"
    tar -xzf "$tmp/$name" -C "$dest"
    echo "Maven $version installed in $dest/apache-maven-$version (SHA-512 checked, from $base)"
    exit 0
  fi
  pause "$i"
done
echo "install-maven.sh: no $name matching its SHA-512 after $attempts attempts ($url)" >&2
exit 1
