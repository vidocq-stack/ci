#!/usr/bin/env bash
# Infer's RacerD (data races) over the main sources of the build's modules, between the build and the
# SonarQube analysis (Vidocq/vidocq#269), report mode, opt-in (input infer).
#
# Infer's Maven integration recompiles with -source 11, which Java 25 code refuses. So this script runs
# javac itself, under Infer, once per module: the module's main sources (module-info.java left out, as
# the capture compiles on the class path), its compile class path (dependency:build-classpath) plus
# the classes the build compiled, annotation processing off. Then one analysis over every capture.
#
# Infer is a pinned release, more than two weeks old when it was chosen, checked by SHA-256 (INFER_BIN
# points at an installed infer instead, to try the script on a workstation). A module whose capture
# fails is reported and skipped.
#
# Infer publishes its Linux release for x86_64 only, and that release needs glibc 2.38 or later: on
# another machine Infer gives no result (BUG-20261116-02).
#
# Prints the path of the report, in SonarQube's generic format (data races as reliability issues of high
# severity), on stdout when it holds at least one finding, nothing otherwise; everything else goes to
# stderr.
#
# Exit status: 0 when Infer ran, or had no main source to read; 3 when it gave no result (no release
# for the machine, a release that cannot be downloaded, checked, unpacked or started, no module
# captured, an analysis or a report that failed). With status 3 the script also writes
# SONAR_INFER_NOT_RUN=true to GITHUB_ENV: the quality-gate step says so on the pull request, where a
# status 0 read as "no data race found".
set -uo pipefail

ROOT="${GITHUB_WORKSPACE:-$PWD}"
WORK="${RUNNER_TEMP:-/tmp}/vidocq-infer"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFER_VERSION=1.3.0
INFER_SHA256=02be62ba931cb43e2d42bbf7abf4bd9a410cf8464cce5453934e25c90a825850
DEPENDENCY_PLUGIN=org.apache.maven.plugins:maven-dependency-plugin:3.11.0
JAVAC="${JAVA_HOME:+$JAVA_HOME/bin/}javac"
rm -rf "$WORK"
mkdir -p "$WORK"

log() { echo "$@" >&2; }

# Infer gave no result: says why, tells the quality-gate step, and ends with the status that says so.
no_result() {
    log "::warning::$1"
    echo "SONAR_INFER_NOT_RUN=true" >> "${GITHUB_ENV:-/dev/null}"
    exit 3
}

if [ -n "${INFER_BIN:-}" ]; then
    INFER="$INFER_BIN"
else
    # Asked before the download: the release is 276 MB.
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64 | amd64) ;;
        *) no_result "Infer: no Linux release for the architecture $ARCH, not run" ;;
    esac
    tarball="$WORK/infer.tar.xz"
    if ! curl -fsSL --retry 3 --retry-delay 5 -o "$tarball" \
        "https://github.com/facebook/infer/releases/download/v$INFER_VERSION/infer-linux-x86_64-v$INFER_VERSION.tar.xz"; then
        no_result "Infer: cannot download release $INFER_VERSION"
    fi
    if ! echo "$INFER_SHA256  $tarball" | sha256sum -c --status; then
        no_result "Infer: SHA-256 mismatch, not run"
    fi
    if ! tar -xJf "$tarball" -C "$WORK"; then
        no_result "Infer: cannot unpack the release (xz installed?)"
    fi
    rm -f "$tarball"
    INFER="$WORK/infer-linux-x86_64-v$INFER_VERSION/bin/infer"
fi
if ! version=$("$INFER" --version 2>&1); then
    no_result "Infer does not run here: $(echo "$version" | head -3 | tr '\n' ' ')"
fi
log "Infer: $(echo "$version" | head -1)"

cd "$ROOT" || no_result "Infer: cannot enter $ROOT"
# The compile class path of every module, from the job's local repository, where the build installed
# the reactor. The *_ARGS variable is split on purpose: several arguments.
# shellcheck disable=SC2086
# -fae: a module whose class path cannot be resolved (an aggregator of test modules) stops no other.
classpaths=complete
if ! mvn ${ANALYSIS_ARGS:--B -ntp -Pquality} -q -fae "$DEPENDENCY_PLUGIN:build-classpath" \
    -Dmdep.outputFile=target/vidocq-infer.cp -Dmdep.includeScope=compile > "$WORK/classpath.log" 2>&1; then
    log "Infer: some modules have no class path, see $WORK/classpath.log"
    classpaths=partial
fi

captured=0
with_sources=0
continue_flag=()
while IFS= read -r cpfile; do
    module="${cpfile%/target/vidocq-infer.cp}"
    [ -d "$module/src/main/java" ] || continue
    sources="$WORK/sources-$captured.txt"
    find "$module/src/main/java" -name '*.java' ! -name module-info.java | sort > "$sources"
    [ -s "$sources" ] || continue
    with_sources=$((with_sources + 1))
    classpath="$(cat "$cpfile")"
    classpath="${classpath:+$classpath:}$module/target/classes"
    if "$INFER" capture "${continue_flag[@]}" -o "$WORK/out" -- "$JAVAC" -proc:none -nowarn -encoding UTF-8 \
        -cp "$classpath" -d "$WORK/classes/$captured" "@$sources" > "$WORK/capture.log" 2>&1; then
        log "Infer: captured ${module#./} ($(wc -l < "$sources" | tr -d ' ') files)"
        captured=$((captured + 1))
        continue_flag=(--continue)
    else
        log "::warning::Infer: the capture of ${module#./} failed, module skipped:"
        grep -v '^\s*$' "$WORK/capture.log" | tail -5 >&2
    fi
done < <(find . -path '*/target/vidocq-infer.cp' -not -path '*/node_modules/*' | sort)

if [ "$with_sources" -eq 0 ]; then
    # No module to read: for want of main sources, or because no class path could be resolved at all.
    if [ "$classpaths" = partial ]; then
        no_result "Infer: no module with a class path, see $WORK/classpath.log"
    fi
    log "Infer: no module with main sources, nothing to read"
    exit 0
fi
if [ "$captured" -eq 0 ]; then
    no_result "Infer: no module captured out of $with_sources"
fi
if ! "$INFER" analyze --racerd-only -o "$WORK/out" > "$WORK/analyze.log" 2>&1; then
    no_result "Infer: the analysis failed, see $WORK/analyze.log"
fi
found=$(python3 "$HERE/infer-sarif.py" "$WORK/out/report.json" "$WORK/raw.sarif") \
    || no_result "Infer: cannot read its report"
python3 "$HERE/normalize-sarif.py" "$ROOT" "$WORK/raw.sarif" "$WORK/infer.sarif" infer > /dev/null \
    || no_result "Infer: cannot normalise its report"
kept=$(python3 "$HERE/sarif-to-generic.py" "$WORK/infer.sarif" "$WORK/infer.json" "$ROOT" infer RELIABILITY HIGH LOGICAL) \
    || no_result "Infer: cannot convert its report"
log "Infer: $captured module(s), $found finding(s), $kept kept"
if [ "$kept" -gt 0 ]; then echo "$WORK/infer.json"; fi
