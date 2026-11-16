#!/usr/bin/env bash
# Tests of sonar-analysis/security-scans.sh: the release asset each scanner is downloaded as, by the
# architecture of the machine, and the scans without a result, handed to the quality-gate step
# (BUG-20261116-01). Offline: uname, curl and sha256sum are stubs on the PATH, and the "release" curl
# hands over is one stub tool that writes an empty SARIF report.
# Run: bash sonar-analysis/security-scans-test.sh
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

mkdir -p "$TMP/bin" "$TMP/fixtures/rules/java/lang" "$TMP/ws/target"
echo '{"bomFormat":"CycloneDX"}' > "$TMP/ws/target/bom.json"
echo '<project><modelVersion>4.0.0</modelVersion></project>' > "$TMP/ws/pom.xml"

# The machine's architecture is the one the test names.
cat > "$TMP/bin/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-m" ]; then echo "$STUB_ARCH"; else exec /usr/bin/uname "$@"; fi
EOF

# Every scanner: records that it ran, and writes an empty report where it was told to. STUB_TOOL_EXIT
# makes it end with that status and no report: 126 is what a binary of another architecture gives.
cat > "$TMP/fixtures/trivy" <<'EOF'
#!/usr/bin/env bash
if [ -n "${STUB_TOOL_EXIT:-}" ]; then exit "$STUB_TOOL_EXIT"; fi
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output-file | --output) out="$2"; shift ;;
    --sarif-output=*) out="${1#--sarif-output=}" ;;
  esac
  shift
done
basename "$0" >> "$STUB_LOG/ran"
printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"stub","rules":[]}},"results":[]}]}' > "$out"
EOF

# Records the address asked for, and hands over the stub: as a file, or packed the way the real
# release is (Trivy and the rules come as archives). STUB_NO_DOWNLOAD names what cannot be downloaded.
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
if [ -n "${STUB_NO_DOWNLOAD:-}" ]; then
  case "$url" in *"$STUB_NO_DOWNLOAD"*) exit 22 ;; esac
fi
case "$url" in
  *opengrep-rules*) tar -czf "$out" -C "$STUB_FIXTURES" rules ;;
  *.tar.gz) tar -czf "$out" -C "$STUB_FIXTURES" trivy ;;
  *) cp "$STUB_FIXTURES/trivy" "$out" ;;
esac
EOF

# Records the "<sha256>  <file>" line the script checks, and accepts the stub.
cat > "$TMP/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
cat >> "$STUB_LOG/sums"
EOF
chmod +x "$TMP/bin/uname" "$TMP/bin/curl" "$TMP/bin/sha256sum" "$TMP/fixtures/trivy"

run() { # run <architecture> [VAR=value...] -> exit status; what happened is under $TMP/log and in $TMP/out
  local arch="$1"
  shift
  rm -rf "$TMP/log" "$TMP/runner"
  mkdir -p "$TMP/log" "$TMP/runner"
  env PATH="$TMP/bin:$PATH" STUB_ARCH="$arch" STUB_LOG="$TMP/log" STUB_FIXTURES="$TMP/fixtures" \
    GITHUB_WORKSPACE="$TMP/ws" RUNNER_TEMP="$TMP/runner" GITHUB_ENV="$TMP/log/env" "$@" \
    bash "$HERE/security-scans.sh" > "$TMP/out" 2>&1
  echo $?
}
# The assets asked for, without the rules (one archive for every architecture) and without a version.
assets() {
  grep -v 'opengrep-rules' "$TMP/log/urls" 2>/dev/null | sed -e 's|.*/||' -e 's/^trivy_[0-9.]*_/trivy_/' | paste -sd'|' -
}
# The checksums the three binaries were checked against, one per line.
sums() { grep -v 'rules.tar.gz' "$TMP/log/sums" 2>/dev/null | awk '{print $1}'; }
ran() { paste -sd'|' "$TMP/log/ran" 2>/dev/null; }
warnings() { grep -c '::warning::' "$TMP/out"; }
# What the job's environment holds for a variable: "unset" when the script wrote no line for it.
handed() { grep "^$1=" "$TMP/log/env" 2>/dev/null | cut -d= -f2- || true; grep -q "^$1=" "$TMP/log/env" 2>/dev/null || echo unset; }

check "amd64: exit status" "0" "$(run x86_64)"
check "amd64: the amd64 assets" "osv-scanner_linux_amd64|opengrep_manylinux_x86|trivy_Linux-64bit.tar.gz" "$(assets)"
check "amd64: the three scanners ran, no warning" "osv-scanner|opengrep|trivy|0" "$(ran)|$(warnings)"
check "amd64: every scan has a result" "" "$(handed SONAR_SCANS_NOT_RUN)"
sums > "$TMP/amd64.sums"

check "arm64: exit status" "0" "$(run aarch64)"
check "arm64: the arm64 assets" "osv-scanner_linux_arm64|opengrep_manylinux_aarch64|trivy_Linux-ARM64.tar.gz" "$(assets)"
check "arm64: the three scanners ran, no warning" "osv-scanner|opengrep|trivy|0" "$(ran)|$(warnings)"
check "arm64: every scan has a result" "" "$(handed SONAR_SCANS_NOT_RUN)"
sums > "$TMP/arm64.sums"

check "each architecture checks its three binaries against its own checksums" "3|3|0" \
  "$(wc -l < "$TMP/amd64.sums" | tr -d ' ')|$(wc -l < "$TMP/arm64.sums" | tr -d ' ')|$(sort "$TMP/amd64.sums" "$TMP/arm64.sums" | uniq -d | wc -l | tr -d ' ')"

run amd64 > /dev/null
check "amd64 under its other name" "osv-scanner_linux_amd64|opengrep_manylinux_x86|trivy_Linux-64bit.tar.gz" "$(assets)"
run arm64 > /dev/null
check "arm64 under its other name" "osv-scanner_linux_arm64|opengrep_manylinux_aarch64|trivy_Linux-ARM64.tar.gz" "$(assets)"

check "an architecture with no pinned release: exit status" "0" "$(run riscv64)"
check "... nothing is downloaded, nothing runs" "|" "$(cat "$TMP/log/urls" 2>/dev/null)|$(ran)"
check "... one warning, which names the architecture" "1|1" "$(warnings)|$(grep -c '::warning::.*riscv64' "$TMP/out")"
check "... no report is handed to SonarQube, in the file and in the environment" "|" \
  "$(cat "$TMP/runner/vidocq-security/sarif-paths" 2>/dev/null)|$(handed SONAR_SARIF_PATHS)"
check "... the three scans are handed over as without a result" "OSV-Scanner, OpenGrep, Trivy" "$(handed SONAR_SCANS_NOT_RUN)"

# The incident: binaries the machine cannot execute. The analysis went on, and nothing said the scans had not run.
check "scanners that do not execute: exit status" "0" "$(run x86_64 STUB_TOOL_EXIT=126)"
check "... each one is reported" "1|1|1" \
  "$(grep -c '::warning::OSV-Scanner failed (exit 126)' "$TMP/out")|$(grep -c '::warning::OpenGrep failed (exit 126)' "$TMP/out")|$(grep -c '::warning::Trivy failed (exit 126)' "$TMP/out")"
check "... and the three are handed over as without a result" "OSV-Scanner, OpenGrep, Trivy" "$(handed SONAR_SCANS_NOT_RUN)"
check "... the log says so in one line" "1" "$(grep -c '^Security scans without a result: OSV-Scanner, OpenGrep, Trivy$' "$TMP/out")"

check "a release that cannot be downloaded: exit status" "0" "$(run x86_64 STUB_NO_DOWNLOAD=opengrep_manylinux)"
check "... the two others ran" "osv-scanner|trivy" "$(ran)"
check "... that scan alone is without a result" "OpenGrep" "$(handed SONAR_SCANS_NOT_RUN)"

check "no SBOM: exit status" "0" "$(run x86_64 SBOM_PATH="$TMP/none.json")"
check "... OSV-Scanner has no result, the two others ran" "OSV-Scanner|opengrep|trivy" "$(handed SONAR_SCANS_NOT_RUN)|$(ran)"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
