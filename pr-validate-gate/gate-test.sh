#!/usr/bin/env bash
# Tests of gate.py, against a local stub of the Forgejo API (no network).
# Run: bash pr-validate-gate/gate-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/gate.py"
TMP="$(mktemp -d)"

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
contains() { # contains <name> <needle> <haystack>
  case "$3" in
    *"$2"*) echo "ok   $1" ;;
    *) echo "FAIL $1: '$2' not in: $3"; failures=$((failures + 1)) ;;
  esac
}

REPO=Vidocq/demo
HEAD=1111111111111111111111111111111111111111
echo '{}' > "$TMP/routes.json"
# Forgejo sets github.workflow to the workflow's NAME (seen on Forgejo 16): the gate must find the file itself.
export GITHUB_WORKFLOW=pr-validate
python3 "$HERE/stub_forge.py" "$TMP/routes.json" "$TMP/calls.log" > "$TMP/port" &
STUB=$!
trap 'kill $STUB 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/port" ] && break; sleep 0.2; done
API="http://127.0.0.1:$(cat "$TMP/port")"

# The forge, rebuilt by each test: forge pr <title> <labels,csv> [body] [draft], forge run <id> <index> <workflow>
# <stopped|-> <aggregator status> <payload title> <payload labels,csv>, forge runs-broken, forge reset.
cat > "$TMP/forge.py" <<'EOF'
import json, sys
path, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3:]
repo, head = "Vidocq/demo", "1" * 40
routes = json.load(open(path))
listing = f"/repos/{repo}/actions/runs?head_sha={head}&limit=50&page=1"
labels = lambda csv: [{"name": n} for n in csv.split(",") if n]
if cmd == "reset":
    # This run (GATE_RUN_ID=500): the actions API names its workflow file.
    routes = {f"/repos/{repo}/actions/runs/500": {"id": 500, "workflow_id": "pr.yml"},
              f"/repos/{repo}/actions/runs/500/jobs": [{"id": 5001, "name": "pr-state", "status": "success"},
                                                       {"id": 5002, "name": "pr-validate", "status": "running"}]}
elif cmd == "self-broken":
    routes[f"/repos/{repo}/actions/runs/500"] = {"status": 500, "body": {"message": "boom"}}
elif cmd == "pr":
    title, csv = args[0], args[1]
    body = args[2] if len(args) > 2 else ""
    draft = len(args) > 3 and args[3] == "draft"
    routes[f"/repos/{repo}/pulls/7"] = {"number": 7, "title": title, "body": body, "draft": draft,
                                        "labels": labels(csv), "head": {"sha": head}}
elif cmd == "run":
    # The aggregator's log ends with the record its verdict step printed: by default the mode its payload
    # suggests and its job status; "none" for a log without a record (a run older than the gate).
    rid, idx, wf, stopped, agg, ptitle, pcsv = args[:7]
    nosha = rid.endswith("!")
    rid = rid.rstrip("!")
    names = [n.lower() for n in pcsv.split(",") if n]
    guess = "train" if "train-member" in names else ("wip" if ptitle.upper().startswith("WIP:") or "wip" in names else "ready")
    rmode = args[7] if len(args) > 7 else guess
    rverdict = args[8] if len(args) > 8 else agg
    runs = routes.get(listing, {"workflow_runs": []})["workflow_runs"]
    payload = {"action": "edited", "pull_request": {"title": ptitle, "labels": labels(pcsv), "body": ""}}
    entry = {"id": int(rid), "index_in_repo": int(idx), "workflow_id": wf, "commit_sha": head,
             "status": "running" if stopped == "-" else agg,
             "stopped": "1970-01-01T00:00:00Z" if stopped == "-" else stopped,
             "html_url": f"https://forge/{repo}/actions/runs/{idx}", "event_payload": json.dumps(payload)}
    if nosha:
        del entry["commit_sha"]
    runs.append(entry)
    routes[listing] = {"workflow_runs": runs, "total_count": len(runs)}
    routes[f"/repos/{repo}/actions/runs/{rid}/jobs"] = [
        {"id": int(rid) * 10 + 1, "name": "producer", "status": "success"},
        {"id": int(rid) * 10 + 2, "name": "pr-validate", "status": agg}]
    record = {"mode": rmode, "verdict": None if rverdict == "null" else rverdict, "run-id": rid,
              "job-id": str(int(rid) * 10 + 2)}
    log = "2026-10-25T10:00:00.1Z Runner received task\n2026-10-25T10:00:01.2Z ::notice title=pr-validate::done\n"
    if rmode != "none":
        log += "2026-10-25T10:00:01.3Z PR-VALIDATE-RECORD " + json.dumps(record, separators=(",", ":")) + "\n"
    routes[f"/repos/{repo}/actions/jobs/{int(rid) * 10 + 2}/logs"] = {"status": 200, "text": log}
elif cmd == "log":
    # forge log <run id> <text>: the aggregator's whole log, \n as line breaks
    routes[f"/repos/{repo}/actions/jobs/{int(args[0]) * 10 + 2}/logs"] = {"status": 200, "text": args[1].replace("\\n", "\n")}
elif cmd == "many":
    # forge many <n>: n other runs on the commit in one page, as codefloe answers (it ignores limit)
    runs = routes.get(listing, {"workflow_runs": []})["workflow_runs"]
    for i in range(int(args[0])):
        runs.append({"id": 100 + i, "index_in_repo": 100 + i, "workflow_id": "sonar.yml", "commit_sha": head,
                     "status": "success", "stopped": "2026-10-25T08:00:00Z"})
    routes[listing] = {"workflow_runs": runs, "total_count": len(runs)}
    routes[listing.replace("page=1", "page=2")] = {"workflow_runs": runs, "total_count": len(runs)}
elif cmd == "raw-route":
    routes[args[0]] = json.loads(args[1])
elif cmd == "logs-broken":
    for k in list(routes):
        if k.endswith("/logs"):
            routes[k] = {"status": 500, "body": {"message": "boom"}}
elif cmd == "runs-broken":
    routes[listing] = {"status": 500, "body": {"message": "boom"}}
elif cmd == "pr-broken":
    routes[f"/repos/{repo}/pulls/7"] = {"status": 500, "body": {"message": "boom"}}
json.dump(routes, open(path, "w"))
EOF
forge() { python3 "$TMP/forge.py" "$TMP/routes.json" "$@"; }

# An event payload, as GITHUB_EVENT_PATH holds it.
payload() { # payload <title> <labels,csv> [base-changed]
  python3 -c '
import json, sys
doc = {"pull_request": {"title": sys.argv[1], "body": "", "labels": [{"name": n} for n in sys.argv[2].split(",") if n]}}
if sys.argv[3] == "base-changed":
    doc["changes"] = {"base": {"ref": {"from": "release"}}}
print(json.dumps(doc))' "$1" "${2:-}" "${3:-}" > "$TMP/event.json"
}
payload "x" ""

state() { # state <activity> [attempt] -> GITHUB_OUTPUT lines (and stdout)
  : > "$TMP/out"
  FORGE_API="$API" GITHUB_REPOSITORY="$REPO" GATE_PR=7 GATE_HEAD="$HEAD" GATE_ACTIVITY="$1" \
    GATE_ATTEMPT="${2:-1}" GATE_RUN_ID=500 GITHUB_EVENT_PATH="$TMP/event.json" \
    GITHUB_OUTPUT="$TMP/out" python3 "$SCRIPT" state > "$TMP/stdout" 2>&1
  echo "rc=$?" >> "$TMP/out"
}
out() { grep "^$1=" "$TMP/out" | head -1 | cut -d= -f2-; }
plan() { echo "$(out mode) producer=$(out run-producer) downstream=$(out run-downstream) reproduce=$(out reproduce)"; }

classify() { # classify <json> -> "mode wip train top blocked"
  printf '%s' "$1" > "$TMP/pr.json"
  python3 "$SCRIPT" classify --pr-json "$TMP/pr.json" | python3 -c '
import sys; d = dict(l.rstrip("\n").split("=", 1) for l in sys.stdin)
print(d["mode"], d["wip"], d["train"], d["train-top"] or "-", d["blocked"])'
}

# ------------------------------------------------------------------------------------------- classify
check "a WIP: title is WIP" "wip true false - false" "$(classify '{"title": "WIP: faster parser"}')"
check "the [WIP] prefix, any case, is WIP" "wip true false - false" "$(classify '{"title": "[wip] faster parser"}')"
check "a title merely starting with Wip is not WIP" "ready false false - false" "$(classify '{"title": "Wipe the cache"}')"
check "a draft the forge reports is WIP" "wip true false - false" "$(classify '{"title": "faster parser", "draft": true}')"
check "the WIP label, any case, is WIP" "wip true false - false" "$(classify '{"title": "x", "labels": [{"name": "wip"}]}')"
check "a train member names its top" "train false true 12 false" \
  "$(classify '{"title": "x", "body": "Part of a train.\nTrain-top: #12\n", "labels": [{"name": "train-member"}]}')"
check "Train top: with a space also names it" "train false true 9 false" \
  "$(classify '{"title": "x", "body": "**Train top:** #9", "labels": [{"name": "train-member"}]}')"
check "a train member without a top is still a train member" "train false true - false" \
  "$(classify '{"title": "x", "labels": [{"name": "train-member"}]}')"
check "a train member that is also WIP is a train member" "train true true 3 false" \
  "$(classify '{"title": "WIP: x", "body": "Train-top: #3", "labels": [{"name": "train-member"}]}')"
check "the blocked label: not ready, and reported" "wip false false - true" "$(classify '{"title": "x", "labels": [{"name": "blocked"}]}')"
# The maintainer's rule (75-I2): wip anywhere in the title as a word, Draft:/[draft], labels containing wip or blocked.
check "wip at the end of the title" "wip true false - false" "$(classify '{"title": "feat: thing (WIP)"}')"
check "WIP followed by a dash" "wip true false - false" "$(classify '{"title": "WIP - thing"}')"
check "a Draft: prefix" "wip true false - false" "$(classify '{"title": "Draft: thing"}')"
check "a [draft] prefix" "wip true false - false" "$(classify '{"title": "[draft] thing"}')"
check "a label containing wip" "wip true false - false" "$(classify '{"title": "thing", "labels": [{"name": "wip-do-not-merge"}]}')"
check "a label containing blocked" "wip false false - true" "$(classify '{"title": "thing", "labels": [{"name": "status/blocked"}]}')"
check "a lowercase wip: prefix" "wip true false - false" "$(classify '{"title": "wip: thing"}')"
check "swipe is not wip" "ready false false - false" "$(classify '{"title": "swipe gestures"}')"
check "a draft in the middle of a title is not a draft marker" "ready false false - false" "$(classify '{"title": "rewrite the draft parser"}')"
check "a top named without the label is not a train member" "ready false false 4 false" "$(classify '{"title": "x", "body": "Train-top: #4"}')"

# ---------------------------------------------------------------------------------------------- state
forge reset; forge pr "faster parser" ""
state opened
check "opened, ready: everything runs" "ready producer=true downstream=true reproduce=false" "$(plan)"

forge pr "WIP: faster parser" ""
state opened
check "opened, WIP: the producer runs, not the downstream check" "wip producer=true downstream=false reproduce=false" "$(plan)"
contains "the WIP run says why" "WIP: downstream not run; remove WIP to validate" "$(cat "$TMP/stdout")"

forge pr "faster parser" "train-member" "Train-top: #12"
state synchronize
check "a train member builds nothing" "train producer=false downstream=false reproduce=false" "$(plan)"
contains "and names its top" "validated through the train's top PR #12" "$(cat "$TMP/stdout")"

payload "WIP: faster parser" ""
forge pr "faster parser" ""
state opened
check "the title is read now, not from the event payload (WIP removed since)" "ready producer=true downstream=true reproduce=false" "$(plan)"
payload "faster parser" ""
forge pr "faster parser" "WIP"
state opened
check "a WIP label added since the event counts" "wip producer=true downstream=false reproduce=false" "$(plan)"

forge pr-broken
payload "WIP: faster parser" ""
state opened
check "an unreadable API falls back to the event payload" "wip producer=true downstream=false reproduce=false" "$(plan)"
contains "with a warning" "using the event payload" "$(cat "$TMP/stdout")"
payload "x" ""

# An edit on a commit already judged in the same mode reproduces that verdict.
forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z success "faster parser" ""
state edited
check "edited, same mode as the last completed run: nothing builds" "ready producer=false downstream=false reproduce=true" "$(plan)"
check "the previous run is kept in the state" "success" \
  "$(out state | python3 -c 'import json,sys; print(json.load(sys.stdin)["previous"]["verdict"])')"

forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z failure "faster parser" ""
state edited
check "a red verdict is reproduced too" "ready producer=false downstream=false reproduce=true" "$(plan)"

forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z failure "WIP: faster parser" ""
state edited
check "WIP removed since the last completed run: full validation" "ready producer=true downstream=true reproduce=false" "$(plan)"
contains "and says so" "changed from wip to ready" "$(out reason)"

forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z failure "faster parser" "train-member"
state unlabeled
check "the train label removed: full validation" "ready producer=true downstream=true reproduce=false" "$(plan)"

forge reset; forge pr "faster parser" "WIP"
forge run 401 41 pr.yml 2026-10-25T10:00:00Z failure "faster parser" "WIP"
state label_updated
check "still WIP after a label change: the producer does not run again" "wip producer=false downstream=false reproduce=true" "$(plan)"

forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z cancelled "faster parser" ""
state edited
check "the last completed run was cancelled: full validation" "ready producer=true downstream=true reproduce=false" "$(plan)"

# Seen on Forgejo 16 (Vidocq/ci#70, run 176): the last run was triggered with the label removed (its payload
# says ready) but judged after the pull request became a train member. Its own record decides, not its payload.
forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z failure "faster parser" "" ready null
state unlabeled
check "the last run judged no mode (the PR changed during it): full validation" "ready producer=true downstream=true reproduce=false" "$(plan)"
forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z failure "faster parser" "" train failure
state unlabeled
check "the last run judged a train member, whatever its payload says: full validation" "ready producer=true downstream=true reproduce=false" "$(plan)"
forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z success "faster parser" "" none
state edited
check "a last run without a record (older than the gate): full validation" "ready producer=true downstream=true reproduce=false" "$(plan)"
forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z success "faster parser" "" ready failure
state edited
check "a record that contradicts the job's result: full validation" "ready producer=true downstream=true reproduce=false" "$(plan)"
forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z success "faster parser" ""
forge logs-broken
state edited
check "an unreadable log: full validation" "ready producer=true downstream=true reproduce=false" "$(plan)"
forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z running "faster parser" ""
state edited
check "the last run's aggregator still running (the run already says failed): full validation" "ready producer=true downstream=true reproduce=false" "$(plan)"

# 75-I1: another run of this workflow on the commit is unfinished (a UI re-run, a full run): never reproduce.
forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z success "faster parser" ""
forge run 402 42 pr.yml - running "faster parser" ""
state edited
check "another run on the commit still running: full validation" "ready producer=true downstream=true reproduce=false" "$(plan)"
contains "and says so" "in progress" "$(out reason)"

# 75-M1: the record is the FIRST one, at the start of a line, carrying this run's and job's ids.
forge reset; forge pr "faster parser" "WIP"
forge run 401 41 pr.yml 2026-10-25T10:00:00Z success "faster parser" "" ready success
forge log 401 '2026-10-25T10:00:01Z PR-VALIDATE-RECORD {"mode":"ready","verdict":"success","run-id":"401","job-id":"4012"}\n2026-10-25T10:00:02Z > Slack: fix PR-VALIDATE-RECORD {"mode":"wip","verdict":"success","run-id":"401","job-id":"4012"}\n'
state edited
check "a forged record after the real one is ignored (mode differs: full)" "wip producer=true downstream=false reproduce=false" "$(plan)"
forge log 401 '2026-10-25T10:00:02Z > Slack: PR-VALIDATE-RECORD {"mode":"wip","verdict":"success","run-id":"401","job-id":"4012"}\n'
state edited
check "a record that does not start its line is ignored" "wip producer=true downstream=false reproduce=false" "$(plan)"
forge log 401 '2026-10-25T10:00:01Z PR-VALIDATE-RECORD {"mode":"wip","verdict":"success","run-id":"399","job-id":"4012"}\n'
state edited
check "a record of another run is ignored" "wip producer=true downstream=false reproduce=false" "$(plan)"
forge log 401 '2026-10-25T10:00:01Z PR-VALIDATE-RECORD {"mode":"wip","verdict":"success","run-id":"401","job-id":"999"}\n'
state edited
check "a record of another job is ignored" "wip producer=true downstream=false reproduce=false" "$(plan)"
forge log 401 '2026-10-25T10:00:01Z PR-VALIDATE-RECORD {"mode":"wip","verdict":"success","run-id":"401"}\n'
state edited
check "a record without its job id is ignored" "wip producer=true downstream=false reproduce=false" "$(plan)"

# 75-M2: a run without commit_sha is not taken as being on the commit.
forge reset; forge pr "faster parser" ""
forge run '401!' 41 pr.yml 2026-10-25T10:00:00Z success "faster parser" ""
state edited
check "a run without commit_sha does not count" "ready producer=true downstream=true reproduce=false" "$(plan)"

# 75-M4: a retargeted pull request (edited, changes.base) validates in full.
forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z success "faster parser" ""
payload "faster parser" "" base-changed
state edited
check "a base branch change validates in full" "ready producer=true downstream=true reproduce=false" "$(plan)"
contains "and says so" "base branch" "$(out reason)"
payload "x" ""

# 75-M6: codefloe ignores limit and answers every run on page 1: no second page is read.
forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z success "faster parser" ""
forge many 60
: > "$TMP/calls.log"
state edited
check "60 runs on one page: the verdict is still found" "ready producer=false downstream=false reproduce=true" "$(plan)"
check "and page 2 is not read" "0" "$(grep -c 'page=2' "$TMP/calls.log")"

forge reset; forge pr "faster parser" ""
state edited
check "no completed run on the commit: full validation" "ready producer=true downstream=true reproduce=false" "$(plan)"

forge reset; forge pr "faster parser" ""; forge runs-broken
state edited
check "the runs cannot be read: full validation" "ready producer=true downstream=true reproduce=false" "$(plan)"
check "and the state job still succeeds" "0" "$(out rc)"

forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z success "faster parser" ""
forge self-broken
state edited
check "this run's workflow file cannot be read: full validation" "ready producer=true downstream=true reproduce=false" "$(plan)"

forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z success "faster parser" ""
state edited 2
check "a re-run validates in full" "ready producer=true downstream=true reproduce=false" "$(plan)"
state synchronize
check "a new head validates in full" "ready producer=true downstream=true reproduce=false" "$(plan)"

forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z success "faster parser" ""
forge run 402 42 pr.yml 2026-10-25T11:00:00Z failure "faster parser" ""
forge run 404 44 sonar.yml 2026-10-25T12:00:00Z success "faster parser" ""
forge run 500 45 pr.yml 2026-10-25T13:00:00Z success "faster parser" ""
state edited
check "the latest completed run of this workflow, not this run nor another workflow, decides" "failure 42" \
  "$(out state | python3 -c 'import json,sys; p=json.load(sys.stdin)["previous"]; print(p["verdict"], p["run-index"])')"

: > "$TMP/out"
GITHUB_REPOSITORY="$REPO" FORGE_API="$API" GITHUB_OUTPUT="$TMP/out" python3 "$SCRIPT" state > /dev/null 2>&1
check "outside a pull request: full validation" "ready true" "$(out mode) $(out run-downstream)"

# -------------------------------------------------------------------------------------------- verdict
# ------------------------------------------------------------------- scheduled merges (merge-bot)
# With a token, the state job cancels Forgejo's scheduled merge (which does not pin the head) when the pull
# request is not ready, and on a push the merge-bot did not announce in a comment of its own.
R=/repos/Vidocq/demo
announce() { # announce <login> <head>: a merge-bot comment announcing the head it schedules
  python3 -c '
import json, sys
p, login, head = sys.argv[1:4]
r = json.load(open(p))
c = r.get("/repos/Vidocq/demo/issues/7/comments", [])
c.append({"id": len(c) + 1, "user": {"login": login},
          "body": "merge-bot: scheduled.\n\n<!-- merge-bot-scheduled-head: " + head + " -->"})
r["/repos/Vidocq/demo/issues/7/comments"] = c
json.dump(r, open(p, "w"))' "$TMP/routes.json" "$1" "$2"
}
cancel_routes() {
  forge raw-route "/user" '{"login": "vidocq-ci-bot"}'
  forge raw-route "DELETE $R/pulls/7/merge" '{"status": 204, "body": {}}'
}
state_tok() { # state with the bot token
  : > "$TMP/out"; : > "$TMP/calls.log"
  FORGE_API="$API" GITHUB_REPOSITORY="$REPO" GATE_PR=7 GATE_HEAD="$HEAD" GATE_ACTIVITY="$1" GATE_TOKEN=t \
    GATE_ATTEMPT=1 GATE_RUN_ID=500 GITHUB_EVENT_PATH="$TMP/event.json" \
    GITHUB_OUTPUT="$TMP/out" python3 "$SCRIPT" state > "$TMP/stdout" 2>&1
  echo "rc=$?" >> "$TMP/out"
}
deleted() { grep -c "^DELETE $R/pulls/7/merge" "$TMP/calls.log"; }

forge reset; forge pr "faster parser" "WIP"; cancel_routes
state_tok labeled
check "a pull request that becomes WIP: its scheduled merge is cancelled" "1" "$(deleted)"
contains "and says so" "scheduled merge" "$(cat "$TMP/stdout")"
forge reset; forge pr "faster parser" "status/blocked"; cancel_routes
state_tok labeled
check "a blocked pull request: cancelled" "1" "$(deleted)"
forge reset; forge pr "faster parser" "train-member" "Train-top: #12"; cancel_routes
state_tok labeled
check "a train member: cancelled" "1" "$(deleted)"
forge reset; forge pr "faster parser" ""; cancel_routes
state_tok edited
check "a ready pull request edited: nothing cancelled" "0" "$(deleted)"
forge reset; forge pr "faster parser" ""; cancel_routes; announce vidocq-ci-bot "$HEAD"
state_tok synchronized
check "a push the merge-bot announced: nothing cancelled" "0" "$(deleted)"
forge reset; forge pr "faster parser" ""; cancel_routes; announce vidocq-ci-bot "$HEAD"; announce vidocq-ci-bot 3333333333333333333333333333333333333333
state_tok synchronized
check "a push of another head than the last announced one: cancelled" "1" "$(deleted)"
forge reset; forge pr "faster parser" ""; cancel_routes
state_tok synchronized
check "a push nobody announced: cancelled" "1" "$(deleted)"
forge reset; forge pr "faster parser" ""; cancel_routes; announce someone-else "$HEAD"
state_tok synchronized
check "an announcement by anyone but the bot does not count: cancelled" "1" "$(deleted)"
forge reset; forge pr "faster parser" "WIP"; cancel_routes
: > "$TMP/calls.log"
state labeled
check "without a token nothing is written" "0" "$(grep -vc '^GET ' "$TMP/calls.log")"
forge reset; forge pr "faster parser" "WIP"; forge raw-route "/user" '{"login": "vidocq-ci-bot"}'
forge raw-route "DELETE $R/pulls/7/merge" '{"status": 500, "body": {}}'
state_tok labeled
check "a failed cancellation does not fail the state job" "0" "$(out rc)"

# needs <governance> <state result> <state json> <producer> <impacted> <downstream> [docs-only] [test-only] [count] [reused]
needs() {
  python3 - "$@" <<'EOF'
import json, sys
g, sr, sj, p, i, d = sys.argv[1:7]
rest = sys.argv[7:] + [""] * 4
docs, test, count, reused = rest[:4]
print(json.dumps({
  "governance-checks": {"result": g, "outputs": {}},
  "pr-state": {"result": sr, "outputs": {"state": sj}},
  "producer": {"result": p, "outputs": {"docs-only": docs, "test-only": test, "reused": reused}},
  "impacted": {"result": i, "outputs": {"count": count}},
  "downstream": {"result": d, "outputs": {}},
}))
EOF
}
st() { # st <mode> [reproduce previous-verdict previous-mode] [top]
  python3 -c '
import json, sys
mode, rep, verdict, pmode, top = (sys.argv[1:] + [""] * 5)[:5]
s = {"mode": mode, "head": "1" * 40, "train-top": top, "wip-reason": "the title starts with WIP:" if mode == "wip" else "",
     "wip": mode == "wip", "blocked": False,
     "reproduce": rep == "reproduce", "run-id": "500"}
if rep == "reproduce":
    s["previous"] = {"verdict": verdict, "mode": pmode, "run-id": "401", "run-index": "41", "run-url": "https://forge/run/41"}
print(json.dumps(s))' "$@"
}
verdict() { # verdict <needs json> -> "<rc> <verdict> <notify>" ; the message in $TMP/stdout
  : > "$TMP/out"
  FORGE_API="$API" GITHUB_REPOSITORY="$REPO" GATE_PR=7 GATE_RUN_ID=500 \
    GITHUB_EVENT_PATH="$TMP/event.json" GITHUB_OUTPUT="$TMP/out" GATE_NEEDS="$1" \
    python3 "$SCRIPT" verdict > "$TMP/stdout" 2>&1
  echo "$? $(out verdict) $(out notify)"
}

forge reset; forge pr "faster parser" ""
check "ready, every job green: validated, Slack notified" "0 success true" \
  "$(verdict "$(needs success success "$(st ready)" success success success false false 3)")"
check "docs-only, downstream skipped: validated" "0 success true" \
  "$(verdict "$(needs success success "$(st ready)" success success skipped true false 3)")"
check "test-only, downstream skipped: validated" "0 success true" \
  "$(verdict "$(needs success success "$(st ready)" success success skipped false true 3)")"
check "no consumer, downstream skipped: validated" "0 success true" \
  "$(verdict "$(needs success success "$(st ready)" success success skipped false false 0)")"
check "same validated code tree (ci#57), downstream skipped: validated" "0 success true" \
  "$(verdict "$(needs success success "$(st ready)" success success skipped false false 3 true)")"
check "downstream skipped although consumers were expected: refused" "1 failure false" \
  "$(verdict "$(needs success success "$(st ready)" success success skipped false false 3)")"
contains "and says so" "downstream skipped although 3 consumer(s) were expected" "$(cat "$TMP/stdout")"
check "a failed consumer: refused" "1 failure false" \
  "$(verdict "$(needs success success "$(st ready)" success success failure false false 3)")"
check "a failed producer: refused" "1 failure false" \
  "$(verdict "$(needs success success "$(st ready)" failure success skipped false false 3)")"
check "a skipped producer in ready mode: refused" "1 failure false" \
  "$(verdict "$(needs success success "$(st ready)" skipped success skipped false false 3)")"
check "unresolved consumers: refused" "1 failure false" \
  "$(verdict "$(needs success success "$(st ready)" success failure skipped false false)")"
check "failed governance checks: refused" "1 failure false" \
  "$(verdict "$(needs failure success "$(st ready)" skipped skipped skipped)")"
check "an undetermined state: refused" "1 failure false" \
  "$(verdict "$(needs success failure "" skipped skipped skipped)")"
contains "and says so" "the pull request state was not determined (pr-state: failure)" "$(cat "$TMP/stdout")"
check "an aggregator that does not need every job: refused" "1 failure false" \
  "$(verdict '{"governance-checks": {"result": "success"}, "producer": {"result": "success"}}')"
check "unreadable needs: refused" "1 failure false" "$(verdict 'not json')"

forge pr "faster parser" "train-member" "Train-top: #12"
check "a train member fails, whatever ran" "1 failure false" \
  "$(verdict "$(needs success success "$(st train "" "" "" 12)" skipped skipped skipped)")"
contains "naming its top" "Train member: validated through the train's top PR #12" "$(cat "$TMP/stdout")"

forge pr "WIP: faster parser" ""
check "a WIP pull request fails even with every job green" "1 failure false" \
  "$(verdict "$(needs success success "$(st wip)" success skipped skipped false false 3)")"
contains "with the WIP message and the producer result" "WIP: downstream not run; remove WIP to validate (the title starts with WIP:; producer: success)" "$(cat "$TMP/stdout")"
check "a WIP pull request with a red producer fails too" "1 failure false" \
  "$(verdict "$(needs success success "$(st wip)" failure skipped skipped)")"

forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z success "faster parser" ""
check "a reproduced green verdict passes, without a new Slack message" "0 success false" \
  "$(verdict "$(needs success success "$(st ready reproduce success ready)" skipped skipped skipped)")"
contains "and names the run it reproduces" "Nothing relevant changed since run 41" "$(cat "$TMP/stdout")"
check "a reproduced red verdict fails" "1 failure false" \
  "$(verdict "$(needs success success "$(st ready reproduce failure ready)" skipped skipped skipped)")"
check "a reproduced verdict still needs green governance checks" "1 failure false" \
  "$(verdict "$(needs failure success "$(st ready reproduce success ready)" skipped skipped skipped)")"

# 75-I1 at verdict time: the reproduced run must still be the latest completed one, with nothing unfinished.
forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z success "faster parser" ""
forge run 402 42 pr.yml 2026-10-25T11:00:00Z failure "faster parser" ""
check "a newer completed run judged red meanwhile: its verdict, not the reproduced green" "1 failure false" \
  "$(verdict "$(needs success success "$(st ready reproduce success ready)" skipped skipped skipped)")"
contains "and says so" "run 42" "$(cat "$TMP/stdout")"
forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z success "faster parser" ""
forge run 402 42 pr.yml - running "faster parser" ""
check "another run unfinished at verdict time: no reproduced green" "1 failure false" \
  "$(verdict "$(needs success success "$(st ready reproduce success ready)" skipped skipped skipped)")"
contains "and says so" "in progress" "$(cat "$TMP/stdout")"
forge reset; forge pr "faster parser" ""
check "the reproduced run cannot be found again: no reproduced green" "1 failure false" \
  "$(verdict "$(needs success success "$(st ready reproduce success ready)" skipped skipped skipped)")"

# 75-M3: the pull request cannot be re-read at verdict time: fail closed.
forge reset; forge pr-broken
check "the pull request cannot be re-read: refused, even with every job green" "1 failure false" \
  "$(verdict "$(needs success success "$(st ready)" success success success false false 3)")"
contains "and says so" "cannot be re-read" "$(cat "$TMP/stdout")"

# A blocked pull request fails like WIP, and the message names the reason.
forge reset; forge pr "faster parser" "status/blocked"
check "a blocked pull request fails" "1 failure false" \
  "$(verdict "$(needs success success "$(python3 -c 'import json; print(json.dumps({"mode": "wip", "head": "1"*40, "wip": False, "blocked": True, "wip-reason": "label status/blocked", "reproduce": False}))')" success skipped skipped)")"
contains "naming blocked" "Blocked: downstream not run; remove the blocked label to validate (label status/blocked; producer: success)" "$(cat "$TMP/stdout")"

# The pull request changed while the run worked.
forge reset; forge pr "faster parser" "WIP"
check "ready at the start, WIP now: refused" "1 failure false" \
  "$(verdict "$(needs success success "$(st ready)" success success success false false 3)")"
contains "with the WIP message" "changed during this run (ready -> wip)" "$(cat "$TMP/stdout")"
forge pr "faster parser" "train-member" "Train-top: #5"
check "ready at the start, train member now: refused" "1 failure false" \
  "$(verdict "$(needs success success "$(st ready)" success success success false false 3)")"
forge reset; forge pr "faster parser" ""
check "WIP at the start, ready now, no newer verdict yet: refused" "1 failure false" \
  "$(verdict "$(needs success success "$(st wip)" success skipped skipped)")"
contains "and leaves it to the newer run" "the run triggered by that change gives the verdict" "$(cat "$TMP/stdout")"
forge run 501 46 pr.yml 2026-10-25T14:00:00Z success "faster parser" ""
check "WIP at the start, ready now, a newer run already green: that verdict" "0 success false" \
  "$(verdict "$(needs success success "$(st wip)" success skipped skipped)")"
forge reset; forge pr "faster parser" ""
forge run 499 44 pr.yml 2026-10-25T14:00:00Z success "faster parser" ""
check "an OLDER green run is not taken for a newer verdict" "1 failure false" \
  "$(verdict "$(needs success success "$(st wip)" success skipped skipped)")"

# Every verdict ends with its record, read back by later runs; no judged mode when the verdict says nothing
# about the code in that mode.
record() { grep -o 'PR-VALIDATE-RECORD .*' "$TMP/stdout" | head -1 | cut -d' ' -f2- | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["mode"], d["verdict"])'; }
forge reset; forge pr "faster parser" ""
verdict "$(needs success success "$(st ready)" success success success false false 3)" > /dev/null
check "a fresh green verdict is recorded with its mode" "ready success" "$(record)"
check "with this run's and job's ids" "500 5002" "$(grep -o 'PR-VALIDATE-RECORD .*' "$TMP/stdout" | head -1 | cut -d' ' -f2- | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["run-id"], d["job-id"])')"
verdict "$(needs success success "$(st ready)" success success failure false false 3)" > /dev/null
check "a red one too" "ready failure" "$(record)"
verdict "$(needs failure success "$(st ready)" skipped skipped skipped)" > /dev/null
check "failed governance checks judge nothing about the code" "None None" "$(record)"
verdict "$(needs success failure "" skipped skipped skipped)" > /dev/null
check "an undetermined state judges nothing" "None None" "$(record)"
forge pr "WIP: faster parser" ""
verdict "$(needs success success "$(st wip)" success skipped skipped)" > /dev/null
check "a WIP verdict is recorded as wip" "wip failure" "$(record)"
forge pr "faster parser" "train-member" "Train-top: #12"
verdict "$(needs success success "$(st train "" "" "" 12)" skipped skipped skipped)" > /dev/null
check "a train verdict is recorded as train" "train failure" "$(record)"
forge reset; forge pr "faster parser" ""
forge run 401 41 pr.yml 2026-10-25T10:00:00Z success "faster parser" ""
verdict "$(needs success success "$(st ready reproduce success ready)" skipped skipped skipped)" > /dev/null
check "a reproduced verdict is recorded again" "ready success" "$(record)"
forge pr "faster parser" "WIP"
verdict "$(needs success success "$(st ready)" success success success false false 3)" > /dev/null
check "a pull request that changed during the run: no judged mode" "None None" "$(record)"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
