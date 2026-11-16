#!/usr/bin/env bash
# Tests of sonar-analysis/infer.sh: what the script answers when Infer gives no result
# (BUG-20261116-02). It used to end with status 0, like an analysis without a finding: now status 3,
# and SONAR_INFER_NOT_RUN handed to the quality-gate step. Offline: uname, curl, sha256sum and mvn are
# stubs on the PATH, and Infer is one stub the test steers.
# Run: bash sonar-analysis/infer-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

mkdir -p "$TMP/bin" "$TMP/fixtures"

# A reactor of one module with one main source, as the build left it: the class path file is the one
# dependency:build-classpath writes (the mvn stub writes nothing).
mkdir -p "$TMP/ws/app/src/main/java/demo" "$TMP/ws/app/target"
echo '<project><modelVersion>4.0.0</modelVersion><modules><module>app</module></modules></project>' > "$TMP/ws/pom.xml"
echo '<project><modelVersion>4.0.0</modelVersion></project>' > "$TMP/ws/app/pom.xml"
echo 'package demo; class A { }' > "$TMP/ws/app/src/main/java/demo/A.java"
: > "$TMP/ws/app/target/vidocq-infer.cp"

# The same reactor without a main source: nothing for Infer to read.
mkdir -p "$TMP/nosource/app/target"
echo '<project><modelVersion>4.0.0</modelVersion><modules><module>app</module></modules></project>' > "$TMP/nosource/pom.xml"
echo '<project><modelVersion>4.0.0</modelVersion></project>' > "$TMP/nosource/app/pom.xml"
: > "$TMP/nosource/app/target/vidocq-infer.cp"

# The same reactor with its source and no class path file: dependency:build-classpath wrote none.
mkdir -p "$TMP/noclasspath/app/src/main/java/demo"
echo '<project><modelVersion>4.0.0</modelVersion><modules><module>app</module></modules></project>' > "$TMP/noclasspath/pom.xml"
echo '<project><modelVersion>4.0.0</modelVersion></project>' > "$TMP/noclasspath/app/pom.xml"
echo 'package demo; class A { }' > "$TMP/noclasspath/app/src/main/java/demo/A.java"

# The machine's architecture is the one the test names.
cat > "$TMP/bin/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-m" ]; then echo "$STUB_ARCH"; else exec /usr/bin/uname "$@"; fi
EOF

# Records the address asked for. STUB_NO_DOWNLOAD: the release cannot be downloaded. What it hands
# over is no archive, so a download that succeeds ends where the script unpacks it.
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
echo "$url" >> "$STUB_LOG/urls"
if [ -n "${STUB_NO_DOWNLOAD:-}" ]; then exit 22; fi
echo "not an archive" > "$out"
EOF

# Accepts what was downloaded, or refuses it (STUB_SHA_FAIL).
cat > "$TMP/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
if [ -n "${STUB_SHA_FAIL:-}" ]; then exit 1; fi
EOF

# Resolves the class paths, or fails to (STUB_MVN_EXIT).
cat > "$TMP/bin/mvn" <<'EOF'
#!/usr/bin/env bash
exit "${STUB_MVN_EXIT:-0}"
EOF

# Infer. STUB_VERSION_EXIT: it does not start, the way the release fails on an older glibc.
# STUB_CAPTURE_EXIT and STUB_ANALYZE_EXIT: that step fails. STUB_REPORT: the report of the analysis.
cat > "$TMP/fixtures/infer" <<'EOF'
#!/usr/bin/env bash
echo "${1:-}" >> "$STUB_LOG/infer"
out=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = "-o" ]; then out="${args[$((i + 1))]}"; fi
done
case "${1:-}" in
  --version)
    if [ -n "${STUB_VERSION_EXIT:-}" ]; then
      echo "infer: /lib/x86_64-linux-gnu/libc.so.6: version \`GLIBC_2.38' not found (required by infer)" >&2
      exit "$STUB_VERSION_EXIT"
    fi
    echo "Infer version v1.3.0"
    ;;
  capture)
    if [ -n "${STUB_CAPTURE_EXIT:-}" ]; then echo "javac: error"; exit "$STUB_CAPTURE_EXIT"; fi
    mkdir -p "$out"
    ;;
  analyze)
    if [ -n "${STUB_ANALYZE_EXIT:-}" ]; then exit "$STUB_ANALYZE_EXIT"; fi
    mkdir -p "$out"
    printf '%s' "${STUB_REPORT:-[]}" > "$out/report.json"
    ;;
esac
EOF
chmod +x "$TMP/bin/"* "$TMP/fixtures/infer"

# Runs the script in a workspace, for one architecture; the other arguments are variables of the run
# (INFER_BIN=... for an installed Infer, the STUB_* ones). Prints its exit status; its stdout is in
# $TMP/stdout, the rest in $TMP/err, and what it hands to the next steps in $TMP/env.
run() {
  local arch="$1" workspace="$2"
  shift 2
  rm -rf "$TMP/log" "$TMP/runner" "$TMP/env"
  mkdir -p "$TMP/log" "$TMP/runner"
  : > "$TMP/env"
  (cd "$workspace" && env PATH="$TMP/bin:$PATH" STUB_ARCH="$arch" STUB_LOG="$TMP/log" JAVA_HOME= \
      GITHUB_WORKSPACE="$workspace" RUNNER_TEMP="$TMP/runner" GITHUB_ENV="$TMP/env" "$@" \
      bash "$HERE/infer.sh" > "$TMP/stdout" 2> "$TMP/err")
  echo $?
}
warnings() { grep -c '^::warning::' "$TMP/err"; }
steps() { tr '\n' ' ' < "$TMP/log/infer" 2>/dev/null | sed 's/ $//'; }
handed() { grep "^$1=" "$TMP/env" | tail -1 | cut -d= -f2-; }
STUB="INFER_BIN=$TMP/fixtures/infer"

# Infer publishes a Linux release for x86_64 only: on another machine nothing is worth downloading.
for arch in aarch64 arm64; do
  check "$arch, no installed Infer: exit status" "3" "$(run "$arch" "$TMP/ws")"
  check "... nothing is downloaded" "" "$(cat "$TMP/log/urls" 2>/dev/null)"
  check "... one warning, which names the architecture" "1|1" "$(warnings)|$(grep -c "::warning::.*$arch" "$TMP/err")"
  check "... no report, and the quality-gate step is told" "|true" "$(cat "$TMP/stdout")|$(handed SONAR_INFER_NOT_RUN)"
done

check "x86_64, a release that cannot be downloaded: exit status" "3" "$(run x86_64 "$TMP/ws" STUB_NO_DOWNLOAD=1)"
check "... the release asked for is the Linux x86_64 one" "1" "$(grep -c '/infer-linux-x86_64-v[0-9.]*\.tar\.xz$' "$TMP/log/urls")"
check "... one warning, and the quality-gate step is told" "1|true" "$(warnings)|$(handed SONAR_INFER_NOT_RUN)"

check "x86_64, a release with another checksum: exit status" "3" "$(run x86_64 "$TMP/ws" STUB_SHA_FAIL=1)"
check "... one warning, and the quality-gate step is told" "1|true" \
  "$(grep -c '::warning::.*SHA-256 mismatch' "$TMP/err")|$(handed SONAR_INFER_NOT_RUN)"

check "x86_64, a release that cannot be unpacked: exit status" "3" "$(run x86_64 "$TMP/ws")"
check "... one warning, and the quality-gate step is told" "1|true" \
  "$(grep -c '::warning::.*cannot unpack' "$TMP/err")|$(handed SONAR_INFER_NOT_RUN)"

# The incident: a job image with glibc 2.36, where the release does not start. The analysis went on,
# and nothing said that Infer had not run.
check "an Infer that does not start: exit status" "3" "$(run x86_64 "$TMP/ws" "$STUB" STUB_VERSION_EXIT=1)"
check "... nothing is captured" "--version" "$(steps)"
check "... the warning carries what Infer answered" "1|1" "$(warnings)|$(grep -c "::warning::Infer does not run here: .*GLIBC_2.38" "$TMP/err")"
check "... no report, and the quality-gate step is told" "|true" "$(cat "$TMP/stdout")|$(handed SONAR_INFER_NOT_RUN)"

check "a capture that fails for the only module: exit status" "3" "$(run x86_64 "$TMP/ws" "$STUB" STUB_CAPTURE_EXIT=2)"
check "... no analysis is run" "--version capture" "$(steps)"
check "... the module is named, and the quality-gate step is told" "1|true" \
  "$(grep -c '::warning::Infer: the capture of app failed' "$TMP/err")|$(handed SONAR_INFER_NOT_RUN)"

check "an analysis that fails: exit status" "3" "$(run x86_64 "$TMP/ws" "$STUB" STUB_ANALYZE_EXIT=2)"
check "... one warning, and the quality-gate step is told" "1|true" \
  "$(grep -c '::warning::Infer: the analysis failed' "$TMP/err")|$(handed SONAR_INFER_NOT_RUN)"

# Controls: Infer ran. Without a finding it prints no report; with one it prints the path of the report.
check "an analysis without a finding: exit status" "0" "$(run x86_64 "$TMP/ws" "$STUB")"
check "... the three steps ran" "--version capture analyze" "$(steps)"
check "... no report, no warning, nothing for the quality-gate step" "||0|" \
  "$(cat "$TMP/stdout")|$(handed SONAR_INFER_NOT_RUN)|$(warnings)|$(cat "$TMP/env")"
check "... the summary line" "1" "$(grep -c '^Infer: 1 module(s), 0 finding(s), 0 kept$' "$TMP/err")"

REPORT='[{"bug_type":"THREAD_SAFETY_VIOLATION","qualifier":"Unprotected write.","severity":"ERROR","file":"app/src/main/java/demo/A.java","line":1,"hash":"h1"}]'
check "an analysis with one finding: exit status" "0" "$(run x86_64 "$TMP/ws" "$STUB" "STUB_REPORT=$REPORT")"
check "... the report is printed, and nothing for the quality-gate step" "$TMP/runner/vidocq-infer/infer.json|" \
  "$(cat "$TMP/stdout")|$(handed SONAR_INFER_NOT_RUN)"
check "... the summary line" "1" "$(grep -c '^Infer: 1 module(s), 1 finding(s), 1 kept$' "$TMP/err")"

check "an installed Infer on arm64: the architecture is not asked" "0" "$(run aarch64 "$TMP/ws" "$STUB")"
check "... the three steps ran" "--version capture analyze" "$(steps)"

check "a reactor without a main source: exit status" "0" "$(run x86_64 "$TMP/nosource" "$STUB")"
check "... nothing is captured, no warning, nothing for the quality-gate step" "--version|0|" \
  "$(steps)|$(warnings)|$(handed SONAR_INFER_NOT_RUN)"

# Class paths that cannot be resolved for some modules are usual (an aggregator of test modules); for
# every module, Infer has nothing to read although there are sources.
check "class paths resolved for some modules only: exit status" "0" "$(run x86_64 "$TMP/ws" "$STUB" STUB_MVN_EXIT=1)"
check "... the module that has one is analysed" "--version capture analyze" "$(steps)"
check "no class path at all: exit status" "3" "$(run x86_64 "$TMP/noclasspath" "$STUB" STUB_MVN_EXIT=1)"
check "... one warning, and the quality-gate step is told" "1|true" \
  "$(grep -c '::warning::Infer: no module with a class path' "$TMP/err")|$(handed SONAR_INFER_NOT_RUN)"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
