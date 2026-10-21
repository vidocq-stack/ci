#!/usr/bin/env bash
# Security scans run between the build and the SonarQube analysis (Vidocq/vidocq#269, report mode):
#   OSV-Scanner  known vulnerabilities in the dependencies the build ships: it reads the CycloneDX
#                SBOM the build just wrote (SBOM_PATH, target/bom.json by default), so it resolves
#                nothing itself and leaves out test dependencies and unpublished modules
#   OpenGrep     security patterns in the Java sources, from the community rules at a pinned commit
#   Trivy        leaked secrets and Dockerfile misconfigurations, offline; its dependency scan would
#                duplicate OSV-Scanner
#
# None of them sends a request to Maven Central: dependency resolution by the scanners themselves
# got a runner's address rate-limited (HTTP 429, blocked for 30 minutes) during the trial.
#
# Each tool is a pinned release, at least two weeks old when it was chosen, and its SHA-256 is
# checked before it runs. The SARIF reports get paths relative to the repository and stable rule
# ids, and lose the findings of modules SonarQube does not analyse (normalize-sarif.py); the
# analysis then imports them through sonar.sarifReportPaths, as external issues. A tool that cannot
# be downloaded or fails is reported and skipped: the scans never stop the analysis.
#
# Writes the comma-separated report list (possibly empty) to $RUNNER_TEMP/vidocq-security/sarif-paths
# and to SONAR_SARIF_PATHS in $GITHUB_ENV.
set -uo pipefail

ROOT="${GITHUB_WORKSPACE:-$PWD}"
WORK="${RUNNER_TEMP:-/tmp}/vidocq-security"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/reports"

OSV_VERSION=2.6.0
OSV_SHA256=ca69b3d3cd08f889a49dc0a383122f71cc528b83803671df5fd874d97485b108
OPENGREP_VERSION=1.30.1
OPENGREP_SHA256=d3195b9d8d5ae93179f6aa5f5daaba6a920a5a09d38c5d5ae5e60924050210c4
# opengrep-rules: the community rules, forked from semgrep-rules before its 2025 licence change
# (LGPL-2.1 with the Commons Clause, which forbids selling them; scanning our own code is fine).
RULES_COMMIT=f1d2b562b414783763fd02a6ed2736eaed622efa
RULES_SHA256=9a5f1cd5c625418cc1c776120123e2d4371df9bb66e099426b17c3488e13619d
TRIVY_VERSION=0.75.0
TRIVY_SHA256=c6e65abddb348e25f10549df887045629cf28cc72453cd1c63acb717316b3f3f

# fetch <url> <file> <sha256>: downloads and checks; returns non-zero, with a warning, otherwise.
fetch() {
    if ! curl -fsSL --retry 3 --retry-delay 5 -o "$2" "$1"; then
        echo "::warning::security scans: cannot download $1"
        return 1
    fi
    if ! echo "$3  $2" | sha256sum -c --status; then
        echo "::warning::security scans: SHA-256 mismatch for $1, not run"
        rm -f "$2"
        return 1
    fi
}

reports=()

# keep <tool> <raw-sarif>: normalises a report and keeps it when it holds at least one result.
keep() {
    local out="$WORK/reports/$1.sarif"
    if [ ! -s "$2" ]; then
        echo "::warning::security scans: $1 wrote no report"
        return
    fi
    local count
    if count=$(python3 "$HERE/normalize-sarif.py" "$ROOT" "$2" "$out" "$1"); then
        echo "$1: $count finding(s)"
        [ "$count" -gt 0 ] && reports+=("$out")
    else
        echo "::warning::security scans: cannot read the $1 report"
    fi
}

echo "::group::OSV-Scanner $OSV_VERSION (dependencies)"
SBOM="${SBOM_PATH:-$ROOT/target/bom.json}"
if [ ! -s "$SBOM" ]; then
    echo "::warning::security scans: no SBOM at $SBOM, OSV-Scanner skipped"
elif fetch "https://github.com/google/osv-scanner/releases/download/v$OSV_VERSION/osv-scanner_linux_amd64" "$WORK/bin/osv-scanner" "$OSV_SHA256"; then
    chmod +x "$WORK/bin/osv-scanner"
    # The file name tells OSV-Scanner it is a CycloneDX SBOM (bom.json, per the specification).
    "$WORK/bin/osv-scanner" scan source -L "$SBOM" --format sarif --output-file "$WORK/osv.sarif"
    rc=$?
    # 0: nothing found, 1: vulnerabilities found; anything else is a failure of the tool.
    if [ "$rc" -le 1 ]; then keep osv-scanner "$WORK/osv.sarif"; else echo "::warning::OSV-Scanner failed (exit $rc)"; fi
fi
echo "::endgroup::"

echo "::group::OpenGrep $OPENGREP_VERSION (security patterns)"
if fetch "https://github.com/opengrep/opengrep/releases/download/v$OPENGREP_VERSION/opengrep_manylinux_x86" "$WORK/bin/opengrep" "$OPENGREP_SHA256" \
    && fetch "https://codeload.github.com/opengrep/opengrep-rules/tar.gz/$RULES_COMMIT" "$WORK/rules.tar.gz" "$RULES_SHA256"; then
    chmod +x "$WORK/bin/opengrep"
    mkdir -p "$WORK/rules" && tar -xzf "$WORK/rules.tar.gz" -C "$WORK/rules" --strip-components=1
    # Run from the rules directory: OpenGrep builds rule ids from the config path, so they read
    # java.lang.security... on every runner. Only the rule families that match our stack.
    (
        cd "$WORK/rules" || exit 2
        "$WORK/bin/opengrep" scan --quiet \
            --config java/lang --config java/jax-rs --config java/servlets \
            --config java/java-jwt --config java/jjwt --config java/rmi \
            --exclude='src/test' --exclude='target' \
            --sarif-output="$WORK/opengrep.sarif" "$ROOT"
    )
    rc=$?
    if [ "$rc" -eq 0 ]; then keep opengrep "$WORK/opengrep.sarif"; else echo "::warning::OpenGrep failed (exit $rc)"; fi
fi
echo "::endgroup::"

echo "::group::Trivy $TRIVY_VERSION (secrets, Dockerfiles)"
if fetch "https://github.com/aquasecurity/trivy/releases/download/v$TRIVY_VERSION/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" "$WORK/trivy.tar.gz" "$TRIVY_SHA256"; then
    tar -xzf "$WORK/trivy.tar.gz" -C "$WORK/bin" trivy
    # Offline: without --offline-scan Trivy resolves the pom.xml dependencies on Maven Central even
    # when the vulnerability scanner is off; the misconfiguration checks embedded in the release
    # are used instead of a download.
    "$WORK/bin/trivy" fs --quiet --scanners secret,misconfig \
        --offline-scan --skip-db-update --skip-check-update --skip-dirs target \
        --cache-dir "$WORK/trivy-cache" --format sarif --output "$WORK/trivy.sarif" --exit-code 0 "$ROOT"
    rc=$?
    if [ "$rc" -eq 0 ]; then keep trivy "$WORK/trivy.sarif"; else echo "::warning::Trivy failed (exit $rc)"; fi
fi
echo "::endgroup::"

paths=$(IFS=,; echo "${reports[*]:-}")
printf '%s' "$paths" > "$WORK/sarif-paths"
echo "SONAR_SARIF_PATHS=$paths" >> "${GITHUB_ENV:-/dev/null}"
echo "Reports handed to SonarQube: ${paths:-none}"
