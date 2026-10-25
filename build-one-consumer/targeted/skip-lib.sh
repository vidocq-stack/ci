# Shared by the targeted test modes (sourced, not run): the consumer side
# (targeted-tests.sh) and the producer side (../../targeted-producer-tests/producer-tests.sh).
#
# The caller sets, before sourcing:
#   DIR            work directory, holding report.json (the analysis decision)
#   MODE_OUT       file receiving the one-line test mode
#   REPO           the checkout whose poms may be edited
#   SKIP_TESTS_PY  the pom editor (skip-tests.py)
#   SUBJECT        what the tests belong to, in annotations and the summary (a forge slug)
#   NOTICE_TITLE   title of the ::notice / ::error annotations
#   SCRIPT_NAME    the calling script, for internal error messages
# and runs under `set -euo pipefail` and `set -E`.
#
# fallback <reason>  every test runs: the poms are put back from their copies and compared
#                    byte for byte; exit 0, or exit 1 when they cannot be restored (a run with
#                    tests skipped is never reported as a full one).
# finish <mode>      the mode line, a notice, then the details (never fatal); exit 0.
# decide             act on report.json: full -> fallback, all -> finish, targeted -> copy the
#                    poms, edit them, finish.
# Any error of the caller after sourcing falls back (ERR trap).

BACKUP="$DIR/backup"
edits_started=false

summary_section() { # summary_section <mode line> [details]
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "#### Tests of ${SUBJECT}"
      echo
      echo "Tests: $1"
      echo
      if [ -n "${2:-}" ]; then printf '%s\n\n' "$2"; fi
    } >> "$GITHUB_STEP_SUMMARY" || true
  fi
}

# Put back every pom copied before the edits and check each one byte for byte.
restore_poms() {
  [ -f "$BACKUP/list" ] || return 1
  local rel ok=0
  while IFS= read -r rel; do
    cp "$BACKUP/$rel/pom.xml" "$REPO/$rel/pom.xml" 2>/dev/null || ok=1
    cmp -s "$BACKUP/$rel/pom.xml" "$REPO/$rel/pom.xml" || ok=1
  done < "$BACKUP/list"
  return "$ok"
}

fallback() { # fallback <reason>: every test runs; never with a pom left edited
  # In a subshell (command substitution), only report the failure to the main shell.
  if [ "${BASHPID:-$$}" != "$$" ]; then exit 1; fi
  trap - ERR
  set +e
  local mode="full (fallback: $1)"
  if [ "$edits_started" = true ] && ! restore_poms; then
    mode="failed: the poms edited for the targeted tests could not be restored ($1)"
    printf '%s\n' "$mode" > "$MODE_OUT"
    echo "::error title=${NOTICE_TITLE}::${SUBJECT}: $mode"
    summary_section "$mode"
    exit 1
  fi
  printf '%s\n' "$mode" > "$MODE_OUT"
  echo "Tests: $mode"
  echo "::notice title=${NOTICE_TITLE}::${SUBJECT}: $mode"
  summary_section "$mode"
  exit 0
}
trap 'fallback "internal error at line $LINENO of $SCRIPT_NAME"' ERR

finish() { # finish <mode line>: the mode line first, then the details (never fatal)
  printf '%s\n' "$1" > "$MODE_OUT"
  echo "Tests: $1"
  echo "::notice title=${NOTICE_TITLE}::${SUBJECT}: $1"
  trap - ERR
  local details
  details=$(python3 - "$DIR/report.json" "$DIR/skipped.json" 2>/dev/null <<'PY'
import json, os, sys
r = json.load(open(sys.argv[1]))
s = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else {'skipped': [], 'own': {}}
if 'synthetic' in r:
    p = r.get('pruning', '')
    if p.startswith('dependency graph'):
        print(f"Synthetic resolution of {r.get('synthetic', 0)} external artifact(s), pruned by the {p}.")
    else:
        print(f"Synthetic resolution of {r.get('synthetic', 0)} external artifact(s), not pruned: {p}.")
    print()
print('| Affected module | Reason |')
print('|---|---|')
for m, why in r.get('affected', {}).items():
    print(f"| `{m}` | {why.replace('|', '/')} |")
print()
if s['skipped']:
    print('Tests skipped (still compiled): ' + ', '.join(f'`{m}`' for m in s['skipped']))
for m, why in s['own'].items():
    print(f'`{m}` {why}')
PY
) || details=""
  printf '%s\n' "$details"
  summary_section "$1" "$details"
  exit 0
}
show_log() { echo "--- last lines of $1"; tail -n 30 "$1" 2>/dev/null || true; }
field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$DIR/report.json" "$1"; }

decide() {
  case "$(field decision)" in
    full) fallback "$(field reason | tr '\n' ' ')" ;;
    all) finish "full: every module is affected" ;;
    targeted)
      # A copy of every pom that may be edited, before the first edit.
      mkdir -p "$BACKUP"
      python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["skip"]))' "$DIR/report.json" > "$BACKUP/list"
      local rel n
      while IFS= read -r rel; do
        mkdir -p "$BACKUP/$rel"
        cp "$REPO/$rel/pom.xml" "$BACKUP/$rel/pom.xml"
      done < "$BACKUP/list"
      edits_started=true
      python3 "$SKIP_TESTS_PY" --repo "$REPO" --report "$DIR/report.json" --out "$DIR/skipped.json" \
        || fallback "the pom edits failed"
      n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["skipped"]))' "$DIR/skipped.json")
      finish "targeted: tests skipped in $n module(s) (still compiled)"
      ;;
    *) fallback "unexpected analysis decision '$(field decision)'" ;;
  esac
}
