#!/usr/bin/env bash
# Tests of bump-consumers.sh on local bare repositories and a stub curl (no network, no forge).
# Run: bash release-maven/bump-consumers-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/bump-consumers.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name fixture; git config --global user.email fixture@example.org
git config --global init.defaultBranch main

failures=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; failures=$((failures + 1)); fi
}

REMOTES="$TMP/remotes"; BIN="$TMP/bin"; mkdir -p "$REMOTES/Vidocq" "$BIN"

# make_repo NAME POM-BODY: a bare repository Vidocq/NAME.git whose main has that root pom.
make_repo() {
  local name="$1" body="$2" w="$TMP/w-$1"
  git init -q "$w"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<project xmlns="http://maven.apache.org/POM/4.0.0">\n%s\n</project>\n' "$body" > "$w/pom.xml"
  git -C "$w" add -A; git -C "$w" commit -q -m init
  git clone -q --bare "$w" "$REMOTES/Vidocq/$name.git"
}
make_repo foy '  <properties><vauban.version>0.4.0-SNAPSHOT</vauban.version><chappe.version>0.4.0-SNAPSHOT</chappe.version><junit.version>5.12.0</junit.version></properties>'
make_repo cassini '  <properties><vauban.version>0.4.0-SNAPSHOT</vauban.version></properties>'
make_repo aligned '  <properties><vauban.version>0.5.0-SNAPSHOT</vauban.version></properties>'
make_repo nobrick '  <properties><junit.version>5.12.0</junit.version></properties>'
make_repo already '  <properties><vauban.version>0.4.0-SNAPSHOT</vauban.version></properties>'
git -C "$REMOTES/Vidocq/already.git" branch chore/bump-vauban-0.5.0

cat > "$TMP/graph.json" <<'EOF'
{"schema_version": 1, "artifacts": {
  "io.vidocq.vauban:vauban-core": {"produced_by": "Vidocq/vauban", "consumed_by": [
     {"repo": "Vidocq/foy"}, {"repo": "Vidocq/cassini"}, {"repo": "Vidocq/vauban"}, {"repo": "Vidocq/aligned"},
     {"repo": "Vidocq/nobrick"}, {"repo": "Vidocq/already"}, {"repo": "Vidocq/gone"}]},
  "io.vidocq.vauban:vauban-api": {"produced_by": "Vidocq/vauban", "consumed_by": [{"repo": "Vidocq/foy"}]},
  "io.vidocq.chappe:chappe-core": {"produced_by": "Vidocq/chappe", "consumed_by": [{"repo": "Vidocq/other"}]}
}}
EOF

# curl stub: records the pull-request POST bodies, answers 201.
cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
out="" url="" data=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -w|-H|-X) shift 2 ;;
    -d) data="\$2"; shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
printf '%s %s\n' "\$url" "\$data" >> "$TMP/pr-posts"
[ -n "\$out" ] && echo '{}' > "\$out"
printf 201
EOF
chmod +x "$BIN/curl"

run() {
  PATH="$BIN:$PATH" PRODUCER_SLUG=Vidocq/vauban NEXT_DEV_VERSION="$1" BOT_TOKEN=secret-token-value \
    BUMP_GRAPH_FILE="$TMP/graph.json" BUMP_CLONE_URL_TEMPLATE="$REMOTES/%s.git" \
    BUMP_API_BASE=https://forge.test/api/v1 BUMP_WORK_DIR="$TMP/work-$2" DRY_RUN="${3:-false}" \
    bash "$SCRIPT" > "$TMP/out-$2" 2>&1
}
prop() { git -C "$REMOTES/Vidocq/$1.git" show "$2:pom.xml" | sed -n "s|.*<$3>\([^<]*\)</$3>.*|\1|p" | head -1; }

# --- dry run: nothing at all
run 0.5.0 dry true
check "dry run exits 0" "0" "$?"
check "dry run opens no pull request" "no" "$([ -s "$TMP/pr-posts" ] && echo yes || echo no)"
check "dry run pushes no branch" "no" "$(git -C "$REMOTES/Vidocq/foy.git" branch --list 'chore/*' | grep -q . && echo yes || echo no)"

# --- real run
run 0.5.0 real
check "real run exits 0" "0" "$?"
check "foy: branch pushed" "chore/bump-vauban-0.5.0" "$(git -C "$REMOTES/Vidocq/foy.git" branch --list 'chore/*' | tr -d ' *')"
check "foy: vauban.version set to the new dev SNAPSHOT" "0.5.0-SNAPSHOT" "$(prop foy chore/bump-vauban-0.5.0 vauban.version)"
check "foy: another brick property untouched" "0.4.0-SNAPSHOT" "$(prop foy chore/bump-vauban-0.5.0 chappe.version)"
check "foy: unrelated property untouched" "5.12.0" "$(prop foy chore/bump-vauban-0.5.0 junit.version)"
check "foy: main untouched" "0.4.0-SNAPSHOT" "$(prop foy main vauban.version)"
check "cassini: bumped" "0.5.0-SNAPSHOT" "$(prop cassini chore/bump-vauban-0.5.0 vauban.version)"
check "commit is signed off" "1" "$(git -C "$REMOTES/Vidocq/foy.git" log -1 --format=%B chore/bump-vauban-0.5.0 | grep -c '^Signed-off-by: Vidocq CI Bot')"
check "commit subject" "chore(deps): bump vauban.version to 0.5.0-SNAPSHOT" "$(git -C "$REMOTES/Vidocq/foy.git" log -1 --format=%s chore/bump-vauban-0.5.0)"
check "aligned consumer: no branch" "" "$(git -C "$REMOTES/Vidocq/aligned.git" branch --list 'chore/*')"
check "consumer without the property: no branch" "" "$(git -C "$REMOTES/Vidocq/nobrick.git" branch --list 'chore/*')"
check "the producer itself is not a target" "0" "$(grep -c 'Vidocq/vauban$' "$TMP/out-real")"
check "a consumer of another producer is not a target" "0" "$(grep -c 'other' "$TMP/out-real")"
check "existing bump branch: left as it is" "0.4.0-SNAPSHOT" "$(prop already chore/bump-vauban-0.5.0 vauban.version)"
check "one pull request per bumped consumer (foy, cassini)" "2" "$(grep -c '/pulls ' "$TMP/pr-posts")"
check "pull request targets the right repository and branch" "1" \
  "$(grep -c 'repos/Vidocq/foy/pulls .*"head": "chore/bump-vauban-0.5.0".*"base": "main"' "$TMP/pr-posts")"
check "a consumer missing from the forge is a warning, not a failure" "1" "$(grep -c '::warning.*Vidocq/gone' "$TMP/out-real")"
check "the token is never printed" "0" "$(grep -c 'secret-token-value' "$TMP/out-real")"

# --- idempotent: a second run changes nothing and opens nothing more
before=$(grep -c '/pulls ' "$TMP/pr-posts")
run 0.5.0 again
check "second run exits 0" "0" "$?"
check "second run opens no further pull request" "$before" "$(grep -c '/pulls ' "$TMP/pr-posts")"

# --- the -SNAPSHOT suffix on the input is accepted
run 0.6.0-SNAPSHOT snap
check "next-dev given with -SNAPSHOT: same target" "0.6.0-SNAPSHOT" "$(prop foy chore/bump-vauban-0.6.0 vauban.version)"

# --- a producer with no consumer
PATH="$BIN:$PATH" PRODUCER_SLUG=Vidocq/lonely NEXT_DEV_VERSION=1.0.0 BOT_TOKEN=x BUMP_GRAPH_FILE="$TMP/graph.json" \
  BUMP_WORK_DIR="$TMP/work-lonely" bash "$SCRIPT" > "$TMP/out-lonely" 2>&1
check "no consumer: exits 0 and says so" "1" "$(grep -c 'nothing to do' "$TMP/out-lonely")"

[ "$failures" -eq 0 ] && echo "all bump-consumers tests passed" || { echo "$failures test(s) failed"; exit 1; }
