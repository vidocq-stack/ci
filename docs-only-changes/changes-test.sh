#!/usr/bin/env bash
# Tests of changes.sh: the docs-only and test-only change sets, read page by page from a stub of the forge's
# /pulls/N/files. The page after the last one is `null` (Forgejo v17) or `[]` (before): both must end the list.
# Offline: a local python HTTP server answers from fixture files.
# Run: bash docs-only-changes/changes-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
SERVER_PID=""
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"' EXIT

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

# The stub serves $TMP/pages/<case>/<page>.json for /<case>/files?page=<page>; a missing page answers the case's
# end-of-list body ($TMP/pages/<case>/end, `null` or `[]`).
mkdir -p "$TMP/pages"
cat > "$TMP/server.py" <<'EOF'
import http.server, os, sys, urllib.parse
ROOT = sys.argv[1]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        case = url.path.strip('/').split('/')[0]
        page = urllib.parse.parse_qs(url.query).get('page', ['1'])[0]
        body_file = os.path.join(ROOT, case, page + '.json')
        if not os.path.exists(body_file):
            body_file = os.path.join(ROOT, case, 'end')
        body = open(body_file, 'rb').read()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
EOF
python3 "$TMP/server.py" "$TMP/pages" > "$TMP/port" &
SERVER_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
PORT=$(head -1 "$TMP/port")

# fixture <case> <end-body> <page1 paths...> -- one page per call of `page`
fixture() {
  local case="$1" end="$2"; shift 2
  mkdir -p "$TMP/pages/$case"
  printf '%s' "$end" > "$TMP/pages/$case/end"
  local n=1 json="["
  for f in "$@"; do
    if [ "$f" = "--" ]; then
      printf '%s]' "${json%,}" > "$TMP/pages/$case/$n.json"; n=$((n + 1)); json="["
    else
      json="$json{\"filename\":\"$f\"},"
    fi
  done
  [ "$json" != "[" ] && printf '%s]' "${json%,}" > "$TMP/pages/$case/$n.json"
}

# run <case> [checkout-dir]: prints "docs=<v> test=<v> files=<n>"
run() {
  local case="$1" dir="${2:-$TMP/empty-checkout}"
  mkdir -p "$dir"
  : > "$TMP/out"
  ( cd "$dir" && FILES_API="http://127.0.0.1:$PORT/$case/files" TOKEN="" GITHUB_OUTPUT="$TMP/out" \
      FILES_OUT="$TMP/files-$case" bash "$HERE/changes.sh" >/dev/null 2>"$TMP/err-$case" ) \
    || { echo "error"; cat "$TMP/err-$case" >&2; return; }
  local docs test n
  docs=$(sed -n 's/^docs-only=//p' "$TMP/out")
  test=$(sed -n 's/^test-only=//p' "$TMP/out")
  n=$(grep -c . "$TMP/files-$case" || true)
  echo "docs=$docs test=$test files=$n"
}

fixture null-end    'null' README.md docs/guide.adoc
check "a null page ends the list (Forgejo v17)" "docs=true test=true files=2" "$(run null-end)"

fixture empty-end   '[]'   README.md docs/guide.adoc
check "an empty page ends the list" "docs=true test=true files=2" "$(run empty-end)"

fixture two-pages   'null' README.md -- LICENSE NOTICE.txt
check "every page is read" "docs=true test=true files=3" "$(run two-pages)"

fixture mixed       'null' README.md core/src/main/java/A.java
check "a source file makes it neither docs-only nor test-only" "docs=false test=false files=2" "$(run mixed)"

fixture doc-in-src  '[]'   core/src/main/resources/notes.md
check "a doc under src/ is not documentation" "docs=false test=false files=1" "$(run doc-in-src)"

fixture tests       'null' core/src/test/java/ATest.java .forgejo/workflows/pr.yml README.md
check "tests, CI and docs make a test-only change set" "docs=false test=true files=3" "$(run tests)"

mkdir -p "$TMP/with-test-jar"
printf '<project><build><plugins><plugin><executions><execution><goals><goal>test-jar</goal></goals></execution></executions></plugin></plugins></build></project>\n' \
  > "$TMP/with-test-jar/pom.xml"
check "a published test jar makes test changes visible downstream" "docs=false test=false files=3" \
  "$(run tests "$TMP/with-test-jar")"

fixture nothing     'null'
check "an empty change set is neither" "docs=false test=false files=0" "$(run nothing)"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
