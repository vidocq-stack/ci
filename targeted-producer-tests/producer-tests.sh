#!/usr/bin/env bash
# Producer-side targeted tests, for a repository's own pull request.
#
#   MODE=targeted  run in the checkout, after the PR version is set, just before the build's one
#                  `mvn install`. The pull request's changed paths come from git (merge base with
#                  the base branch, renames as delete + add). The modules owning them, every
#                  reactor module depending on them, and the modules naming them in src/ keep
#                  their tests (changed-modules.py, with the -Ptck model too when the repository
#                  declares ci.tck.modules); every other non-pom module of the build's reactor gets
#                  skipTests/skipITs/invoker.skip in its pom. The install that follows is the same
#                  command as without this step.
#   MODE=restore   right after the install, with if: always(): put every edited pom back, byte
#                  for byte; fails when that cannot be done. Nothing to do after a full run.
#   MODE=guard     fails while edits are still in place (guard.sh); for any later Maven step.
#   MODE=full      (default) nothing.
#
# Fallback on any doubt in targeted mode, with the reason in the log, a notice and the job
# summary: no base branch or no merge base, a path of the forge's list (CHANGED_FILES) missing
# from git, a changed path in the root module or outside every module (root pom, .mvn/,
# .forgejo/, scripts), documentation only, an effective-POM failure, a pom that cannot be read,
# any error. The poms are copied before the edits and put back on a fallback, compared byte for
# byte; when that cannot be done the step fails (build-one-consumer/targeted/skip-lib.sh).
#
# Env:
#   MODE                full | targeted | restore | guard
#   BASE_REF            the pull request's base branch (default GITHUB_BASE_REF)
#   PR_NUMBER           the pull request number, to deepen a shallow checkout through
#                       refs/pull/<n>/head (optional)
#   CHANGED_FILES       optional cross-check: the forge's list of changed paths; any path missing
#                       from git's list means full
#   MVN_ARGS            Maven args of the effective-POM runs, the same as the build's (-B -ntp)
#   TARGETED_DIR        work directory ($RUNNER_TEMP/targeted/producer)
#   TESTS_MODE_OUT      file receiving the one-line test mode (TARGETED_DIR/mode.txt)
#   GITHUB_OUTPUT       receives mode=full|targeted and skipped=<count>
#   GITHUB_ENV          receives TARGETED_PRODUCER_EDITS=<marker> once poms are edited
#   GITHUB_REPOSITORY   for the annotations and the summary
#   SKIP_TESTS_PY, CHANGED_MODULES_PY   the scripts used (tests replace them)
set -euo pipefail
set -E

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../build-one-consumer/targeted"
MODE="${MODE:-full}"
MVN_ARGS="${MVN_ARGS--B -ntp}"
DIR="${TARGETED_DIR:-${RUNNER_TEMP:-/tmp}/targeted/producer}"
MODE_OUT="${TESTS_MODE_OUT:-$DIR/mode.txt}"
EDIT_MARKER="$DIR/EDITS-IN-PLACE"
SKIP_TESTS_PY="${SKIP_TESTS_PY:-$LIB/skip-tests.py}"
CHANGED_MODULES_PY="${CHANGED_MODULES_PY:-$HERE/changed-modules.py}"
HELP_PLUGIN=org.apache.maven.plugins:maven-help-plugin:3.5.2
REPO="$PWD"
SUBJECT="${GITHUB_REPOSITORY:-the repository}"
NOTICE_TITLE="Targeted producer tests"

outputs() { # the step outputs, from the mode line
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  local line skipped=0 mode=full
  line=$(head -n 1 "$MODE_OUT" 2>/dev/null || true)
  case "$line" in
    targeted:*) mode=targeted; skipped=$(printf '%s' "$line" | sed -n 's/.*skipped in \([0-9]*\) module.*/\1/p') ;;
  esac
  { echo "mode=$mode"; echo "skipped=${skipped:-0}"; } >> "$GITHUB_OUTPUT"
}

case "$MODE" in
  full)
    echo "Producer tests: full (mode: full)"
    mkdir -p "$(dirname "$MODE_OUT")"; echo full > "$MODE_OUT"
    outputs
    exit 0 ;;
  guard)
    TARGETED_DIR="$DIR" exec bash "$HERE/guard.sh" ;;
  restore)
    if [ ! -e "$EDIT_MARKER" ]; then
      echo "Producer tests: nothing to restore (no pom edited)"
      exit 0
    fi
    BACKUP="$DIR/backup"
    ok=0
    if [ -f "$BACKUP/list" ]; then
      while IFS= read -r rel; do
        cp "$BACKUP/$rel/pom.xml" "$REPO/$rel/pom.xml" 2>/dev/null || ok=1
        cmp -s "$BACKUP/$rel/pom.xml" "$REPO/$rel/pom.xml" || ok=1
      done < "$BACKUP/list"
    else
      ok=1
    fi
    if [ "$ok" -ne 0 ]; then
      echo "::error title=${NOTICE_TITLE}::${SUBJECT}: the poms edited for the targeted tests could not be restored; no later Maven step may run in this checkout"
      exit 1
    fi
    rm -f "$EDIT_MARKER"
    echo "Producer tests: $(wc -l < "$BACKUP/list" | tr -d ' ') pom(s) restored byte for byte"
    exit 0 ;;
  targeted) ;;
  *) echo "::error::mode must be 'full', 'targeted', 'restore' or 'guard', not '$MODE'" >&2; exit 1 ;;
esac

rm -rf "$DIR"
mkdir -p "$DIR"
trap outputs EXIT
# fallback, finish, decide and the ERR trap, shared with the consumer side.
# shellcheck source=../build-one-consumer/targeted/skip-lib.sh
. "$LIB/skip-lib.sh"

# The changed paths, from git: never trust a forge list alone (renames lose their old path, long
# lists may be truncated).
changed_from_git() {
  local base="${BASE_REF-${GITHUB_BASE_REF:-}}" mb="" shallow
  [ -n "$base" ] || return 1
  local refs=("+refs/heads/$base:refs/remotes/origin/$base")
  [ -n "${PR_NUMBER:-}" ] && refs+=("+refs/pull/$PR_NUMBER/head:refs/remotes/origin/targeted-pr-head")
  shallow=$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)
  if [ "$shallow" = true ]; then
    git fetch -q --no-tags --depth=200 origin "${refs[@]}" 2>/dev/null || return 1
  else
    git fetch -q --no-tags origin "${refs[@]}" 2>/dev/null || return 1
  fi
  mb=$(git merge-base "refs/remotes/origin/$base" HEAD 2>/dev/null) || mb=""
  if [ -z "$mb" ] && [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    git fetch -q --no-tags --unshallow origin "${refs[@]}" 2>/dev/null || return 1
    mb=$(git merge-base "refs/remotes/origin/$base" HEAD 2>/dev/null) || mb=""
  fi
  [ -n "$mb" ] || return 1
  git diff --name-only --no-renames "$mb" HEAD > "$DIR/changed-files.txt"
}
changed_from_git || fallback "no merge base with the base branch '${BASE_REF-${GITHUB_BASE_REF:-}}' (not a pull request, or its history cannot be fetched)"
echo "Changed paths (git): $(wc -l < "$DIR/changed-files.txt" | tr -d ' ')"
if [ -n "${CHANGED_FILES:-}" ] && [ -s "$CHANGED_FILES" ]; then
  missing=$(grep -v '^[[:space:]]*$' "$CHANGED_FILES" | sort -u | comm -23 - <(sort -u "$DIR/changed-files.txt") | head -n 3 | paste -sd' ' -)
  [ -z "$missing" ] || fallback "the forge lists changed paths that git does not: $missing"
fi

effective_pom() { # effective_pom <out> [extra Maven args...]
  local out="$1"; shift
  # shellcheck disable=SC2086
  mvn $MVN_ARGS "$@" "$HELP_PLUGIN:effective-pom" -Doutput="$out" </dev/null > "$out.log" 2>&1 \
    && [ -s "$out" ]
}
echo "Effective POM of the build"
effective_pom "$DIR/effective-pom.xml" || { show_log "$DIR/effective-pom.xml.log"; fallback "Maven error in the effective POM"; }
analysis="$DIR/effective-pom.xml"
tck=$(python3 - <<'PY' 2>/dev/null || true
import xml.etree.ElementTree as ET
root = ET.parse("pom.xml").getroot()
for el in root:
    if el.tag.split('}')[-1] == 'properties':
        for p in el:
            if p.tag.split('}')[-1] == 'ci.tck.modules':
                print((p.text or '').strip())
PY
)
if [ -n "$tck" ]; then
  echo "Effective POM with -Ptck (ci.tck.modules: $tck): what the TCK uses counts too"
  effective_pom "$DIR/effective-pom-tck.xml" -Ptck || { show_log "$DIR/effective-pom-tck.xml.log"; fallback "Maven error in the -Ptck effective POM"; }
  analysis="$DIR/effective-pom-tck.xml"
fi

rc=0
python3 "$CHANGED_MODULES_PY" --effective-pom "$analysis" --build-effective-pom "$DIR/effective-pom.xml" \
  --keep-modules "$tck" \
  --repo "$REPO" --changed-files "$DIR/changed-files.txt" --report "$DIR/report.json" || rc=$?
[ "$rc" -eq 0 ] || fallback "the analysis failed (exit $rc)"

decide
