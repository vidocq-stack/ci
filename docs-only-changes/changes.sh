#!/usr/bin/env bash
# The change set of a pull request, from the forge's API: is it documentation only, or tests only?
# Shared by the producers' pr.yml (job `producer`, step id `changes`), which each carried this script inline until
# Forgejo v17 changed the answer for the page after the last one (`null`, not `[]`) and broke all of them at once.
#
# Environment:
#   FILES_API  .../api/v1/repos/<owner>/<repo>/pulls/<number>/files
#   TOKEN      optional bot token (rate limits only; a fork pull request reads anonymously, the repository is public)
#   GITHUB_OUTPUT  where `docs-only=` and `test-only=` are written
#   FILES_OUT  where the changed paths are written, one per line (select-tck reads them)
# Run from the repository's checkout: the test-only rule looks for a published test jar in its pom.xml files.
set -euo pipefail

auth=()
if [ -n "${TOKEN:-}" ]; then
  auth=(-H "Authorization: token ${TOKEN}")
fi
files=""
page=1
# A page past the last one is `null` (Forgejo v17) or `[]` (before): both end the loop.
while :; do
  chunk=$(curl -fsS "${auth[@]}" "${FILES_API}?page=${page}&limit=50" \
    | python3 -c 'import sys,json; print("\n".join(f["filename"] for f in (json.load(sys.stdin) or [])))')
  [ -z "$chunk" ] && break
  files="${files}${chunk}"$'\n'
  page=$((page+1))
done
echo "Changed files:"; printf '%s' "$files" | sed 's/^/  /'
printf '%s' "$files" > "$FILES_OUT"

# Docs-only change set: *.md, *.adoc, docs/, LICENSE*, NOTICE*. Files under any src/ directory never count as docs
# (they may be packaged in the artifact). An empty change set is not docs-only.
docs_only=true
[ -n "$(printf '%s' "$files" | tr -d '[:space:]')" ] || docs_only=false
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    src/*|*/src/*) docs_only=false; break ;;
    *.md|*.adoc|docs/*|LICENSE|LICENSE.*|NOTICE|NOTICE.*) ;;
    *) docs_only=false; break ;;
  esac
done <<< "$files"
echo "docs-only=$docs_only" >> "$GITHUB_OUTPUT"
echo "docs-only: $docs_only"

# Test-only change set: every file is under a src/test/ directory (any module), is CI configuration (.forgejo/), or is
# a doc file accepted above. None of them is part of the produced artifacts, so consumers cannot observe the change:
# only the downstream rebuild is skipped. The producer's own build, unit tests and TCK still run (they also exercise a
# changed workflow). When test files changed, forced to false if a pom.xml declares `<goal>test-jar</goal>`: a
# published test jar makes test changes visible downstream.
test_only=true
has_test=false
[ -n "$(printf '%s' "$files" | tr -d '[:space:]')" ] || test_only=false
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    src/test/*|*/src/test/*) has_test=true ;;
    .forgejo/*) ;;
    src/*|*/src/*) test_only=false; break ;;
    *.md|*.adoc|docs/*|LICENSE|LICENSE.*|NOTICE|NOTICE.*) ;;
    *) test_only=false; break ;;
  esac
done <<< "$files"
if [ "$test_only" = true ] && [ "$has_test" = true ] \
    && grep -rqs --include=pom.xml -e '<goal>test-jar</goal>' .; then
  test_only=false
fi
echo "test-only=$test_only" >> "$GITHUB_OUTPUT"
echo "test-only: $test_only"
