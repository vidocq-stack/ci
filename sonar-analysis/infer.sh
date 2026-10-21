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
# Prints the path of the report, in SonarQube's generic format (data races as reliability issues of high
# severity), on stdout when it holds at least one finding, nothing otherwise; everything else goes to
# stderr.
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

if [ -n "${INFER_BIN:-}" ]; then
    INFER="$INFER_BIN"
else
    tarball="$WORK/infer.tar.xz"
    if ! curl -fsSL --retry 3 --retry-delay 5 -o "$tarball" \
        "https://github.com/facebook/infer/releases/download/v$INFER_VERSION/infer-linux-x86_64-v$INFER_VERSION.tar.xz"; then
        log "::warning::Infer: cannot download release $INFER_VERSION"
        exit 0
    fi
    if ! echo "$INFER_SHA256  $tarball" | sha256sum -c --status; then
        log "::warning::Infer: SHA-256 mismatch, not run"
        exit 0
    fi
    if ! tar -xJf "$tarball" -C "$WORK"; then
        log "::warning::Infer: cannot unpack the release (xz installed?)"
        exit 0
    fi
    rm -f "$tarball"
    INFER="$WORK/infer-linux-x86_64-v$INFER_VERSION/bin/infer"
fi
if ! version=$("$INFER" --version 2>&1); then
    log "::warning::Infer does not run here: $(echo "$version" | head -3 | tr '\n' ' ')"
    exit 0
fi
log "Infer: $(echo "$version" | head -1)"

cd "$ROOT" || exit 0
# The compile class path of every module, from the job's local repository, where the build installed
# the reactor. The *_ARGS variable is split on purpose: several arguments.
# shellcheck disable=SC2086
# -fae: a module whose class path cannot be resolved (an aggregator of test modules) stops no other.
if ! mvn ${ANALYSIS_ARGS:--B -ntp -Pquality} -q -fae "$DEPENDENCY_PLUGIN:build-classpath" \
    -Dmdep.outputFile=target/vidocq-infer.cp -Dmdep.includeScope=compile > "$WORK/classpath.log" 2>&1; then
    log "Infer: some modules have no class path, see $WORK/classpath.log"
fi

captured=0
continue_flag=()
while IFS= read -r cpfile; do
    module="${cpfile%/target/vidocq-infer.cp}"
    [ -d "$module/src/main/java" ] || continue
    sources="$WORK/sources-$captured.txt"
    find "$module/src/main/java" -name '*.java' ! -name module-info.java | sort > "$sources"
    [ -s "$sources" ] || continue
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

if [ "$captured" -eq 0 ]; then
    log "Infer: nothing captured"
    exit 0
fi
if ! "$INFER" analyze --racerd-only -o "$WORK/out" > "$WORK/analyze.log" 2>&1; then
    log "::warning::Infer: the analysis failed, see $WORK/analyze.log"
    exit 0
fi
found=$(python3 "$HERE/infer-sarif.py" "$WORK/out/report.json" "$WORK/raw.sarif") || exit 0
python3 "$HERE/normalize-sarif.py" "$ROOT" "$WORK/raw.sarif" "$WORK/infer.sarif" infer > /dev/null || exit 0
kept=$(python3 "$HERE/sarif-to-generic.py" "$WORK/infer.sarif" "$WORK/infer.json" "$ROOT" infer RELIABILITY HIGH LOGICAL) || exit 0
log "Infer: $captured module(s), $found finding(s), $kept kept"
if [ "$kept" -gt 0 ]; then echo "$WORK/infer.json"; fi
