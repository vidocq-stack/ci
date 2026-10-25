#!/usr/bin/env python3
"""The verdict of a producer's pull-request validation, and the gating that decides it (Vidocq/vidocq#285).

Subcommands:

  classify --pr-json FILE         what a pull request is: ready, WIP or a train member (also used by the
                                  merge-bot and the train script). Prints key=value lines.
  state                           first job of the run: reads the pull request NOW through the API and says
                                  which jobs run (GITHUB_OUTPUT: state, mode, run-producer, run-downstream).
  verdict                         the aggregator: from the results of every job (NEEDS, toJSON(needs)),
                                  says whether the pull request is validated. Exits 1 when it is not.

Modes, decided from the pull request as it is when the run starts (never from the event payload alone: a
re-run replays an old payload):

  train   the label TRAIN_LABEL. Validated through the train's top pull request, named by a line
          "Train-top: #N" in the description. No build runs, and the aggregator FAILS: a member is merged
          by the train script, after its top, never on its own.
  wip     the maintainer's rule: "wip" anywhere in the title as a word (any case), a "Draft:" or "[draft]"
          prefix, the forge's draft flag, a label containing "wip"; or blocked, a label containing "blocked".
          The producer still builds and tests (feedback), the downstream check does not run, and the
          aggregator FAILS. Never a skip: on Forgejo a skipped job satisfies the branch protection.
  ready   the full validation.

A run triggered by an edit or a label change (any activity but opened, reopened, synchronize) on a commit
that a completed run already judged, in the same mode, does not build again: it reproduces that run's
verdict, green or red, so that a description edit never turns a red check green nor a green one red (each
new run overwrites the commit statuses of the previous one). The previous run is the latest completed run
of the same workflow on the same head commit (the one whose status stands), read through the actions API.
Its verdict and the mode it judged come from the record its aggregator prints as the last line of its log
(PR-VALIDATE-RECORD {"mode": ..., "verdict": ...}): not from the pull request it was triggered with, since a
run may be judged after the pull request changed. A verdict that judged nothing (governance checks, an
undetermined state, a pull request changed during the run) records no mode. When that verdict cannot be
established (no completed run, a cancelled one, no record, an unreadable API or log, a mode that changed,
a re-run), the run validates in full.

Every Forgejo API read goes through Api; FORGE_API (or --api) points it at a stub in the tests.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

# The maintainer's rule ("WIP/blocked label, draft, WIP in the title: never merged"), shared by the check, the
# merge-bot and the train script (Vidocq/vidocq#285, review 75-I2).
WIP_WORD = re.compile(r"(?<![a-z0-9])wip(?![a-z0-9])", re.IGNORECASE)
DRAFT_PREFIXES = ("draft:", "[draft]")
DEFAULT_WIP_LABELS = "wip"          # substrings of a label name, any case
DEFAULT_BLOCKED_LABELS = "blocked"  # idem
DEFAULT_TRAIN_LABEL = "train-member"
TRAIN_TOP = re.compile(r"^[ \t>*_-]*train[ -]?top[ \t*_]*:[ \t*_]*#(\d+)\b", re.IGNORECASE | re.MULTILINE)
# Activities that bring code to validate: a new or reopened pull request, a new head.
FULL_ACTIVITIES = {"", "opened", "reopened", "synchronize", "synchronized"}
TERMINAL_JOB = {"success", "failure"}
EPOCH = "1970-01-01"


class ApiError(Exception):
    pass


class Api:
    def __init__(self, base, token="", retries=3, pause=2.0):
        self.base = base.rstrip("/")
        self.token = token
        self.retries = retries
        self.pause = pause

    def get(self, path):
        return json.loads(self.get_text(path, "application/json"))

    def get_text(self, path, accept="text/plain"):
        headers = {"Accept": accept}
        if self.token:
            headers["Authorization"] = "token " + self.token
        last = None
        for attempt in range(self.retries):
            try:
                req = urllib.request.Request(self.base + path, headers=headers)
                with urllib.request.urlopen(req, timeout=30) as resp:
                    text = resp.read().decode("utf-8", errors="replace")
                if accept == "application/json":
                    json.loads(text)
                return text
            except urllib.error.HTTPError as err:
                last = f"HTTP {err.code} on {path}"
                if err.code < 500:
                    break
            except (urllib.error.URLError, OSError, ValueError) as err:
                last = f"{type(err).__name__} on {path}: {err}"
            if attempt + 1 < self.retries:
                time.sleep(self.pause)
        raise ApiError(last)


# ------------------------------------------------------------------------------------------- classification

def label_names(pr):
    return [str(label.get("name") or "") for label in (pr.get("labels") or []) if isinstance(label, dict)]


def split_labels(text):
    return [name.strip() for name in (text or "").split(",") if name.strip()]


def classify(pr, wip_labels=DEFAULT_WIP_LABELS, train_label=DEFAULT_TRAIN_LABEL,
             blocked_labels=DEFAULT_BLOCKED_LABELS):
    """What a pull request is. pr is the API (or event payload) pull request object.

    WIP: "wip" anywhere in the title as a word (any case: "WIP: x", "x (WIP)", "[wip] x"), a "Draft:" or
    "[draft]" prefix, the forge's draft flag, or a label whose name contains one of wip_labels. Blocked: a label
    whose name contains one of blocked_labels. Either one makes the mode "wip" (not ready), unless the pull
    request is a train member."""
    title = (pr.get("title") or "").strip()
    labels = label_names(pr)
    lowered = {name.lower() for name in labels}
    wip_parts = [part.lower() for part in split_labels(wip_labels)]
    blocked_parts = [part.lower() for part in split_labels(blocked_labels)]

    wip = []
    if WIP_WORD.search(title):
        wip.append("the title says wip")
    prefix = next((p for p in DRAFT_PREFIXES if title.lower().startswith(p)), None)
    if prefix:
        wip.append(f"the title starts with {title[:len(prefix)]}")
    if pr.get("draft") and not wip:
        wip.append("the forge reports a draft")
    hit = sorted(name for name in labels if any(part in name.lower() for part in wip_parts))
    if hit:
        wip.append("label " + ", ".join(hit))
    blocked = sorted(name for name in labels if any(part in name.lower() for part in blocked_parts))

    match = TRAIN_TOP.search(pr.get("body") or "")
    top = match.group(1) if match else ""
    train = bool(train_label) and train_label.lower() in lowered
    mode = "train" if train else ("wip" if wip or blocked else "ready")
    return {
        "mode": mode,
        "wip": bool(wip),
        "blocked": bool(blocked),
        "wip-reason": "; ".join(wip + (["label " + ", ".join(blocked)] if blocked else [])),
        "train": train,
        "train-top": top,
        "labels": labels,
        "title": title,
    }


def train_message(state):
    top = state.get("train-top")
    if top:
        return (f"Train member: validated through the train's top PR #{top}. "
                f"It is merged by the train script after #{top}, never on its own.")
    return ("Train member, but the description names no top PR: add a line 'Train-top: #N'. "
            "It is merged by the train script after its top, never on its own.")


WIP_MESSAGE = "WIP: downstream not run; remove WIP to validate"


def not_ready_message(state):
    """The failure of a pull request in mode wip: WIP, blocked, or both."""
    wip, blocked = state.get("wip", True), state.get("blocked", False)
    if blocked and wip:
        return "WIP and blocked: downstream not run; remove WIP and the blocked label to validate"
    if blocked:
        return "Blocked: downstream not run; remove the blocked label to validate"
    return WIP_MESSAGE


# -------------------------------------------------------------------------------------- previous runs

def runs_of_commit(api, repo, head, workflow):
    """The runs of this workflow on exactly this commit. Codefloe ignores `limit` and answers every run of the
    commit on page 1 (seen with 203 runs): a page that is not exactly `limit` long is the last one."""
    runs, seen = [], set()
    for page in (1, 2, 3):
        doc = api.get(f"/repos/{repo}/actions/runs?head_sha={head}&limit=50&page={page}")
        batch = doc.get("workflow_runs") if isinstance(doc, dict) else None
        if not isinstance(batch, list):
            raise ApiError("the actions runs listing is not a list")
        for run in batch:
            if isinstance(run, dict) and run.get("id") not in seen:
                seen.add(run.get("id"))
                runs.append(run)
        if len(batch) != 50:
            break
    # A run that does not name its commit is not taken as being on it (fail closed).
    return [r for r in runs if r.get("workflow_id") == workflow and r.get("commit_sha") == head]


def workflow_file(api, repo, run_id, given=""):
    """The workflow file of this run (the workflow_id of the actions runs API). Forgejo sets github.workflow to
    the workflow's name, not its file, so the file is read from this run itself."""
    if given:
        return given
    run = api.get(f"/repos/{repo}/actions/runs/{run_id}")
    workflow = run.get("workflow_id") if isinstance(run, dict) else None
    if not workflow:
        raise ApiError(f"run {run_id} names no workflow file")
    return workflow


def completed(run):
    stopped = str(run.get("stopped") or "")
    return bool(stopped) and not stopped.startswith(EPOCH) \
        and str(run.get("status") or "") not in ("running", "waiting", "blocked", "unknown")


RECORD = "PR-VALIDATE-RECORD"
# At the start of a line, after the runner's timestamp only. The FIRST one counts: the Verdict step is the
# aggregator's first step and prints it before anything a later step could print (review 75-M1).
RECORD_LINE = re.compile(r"^(?:\S+Z )?" + re.escape(RECORD) + r" (\{[^\n]*\})[ \t\r]*$", re.MULTILINE)


def judged(api, repo, run, aggregator):
    """(verdict, mode, why) of a completed run, from the record its aggregator printed at the end of its log:
    the mode it actually judged and its verdict. The event payload is not enough: a run triggered with one
    state may be judged after the pull request changed (seen on Forgejo 16)."""
    name = run.get("index_in_repo") or run["id"]
    doc = api.get(f"/repos/{repo}/actions/runs/{run['id']}/jobs")
    jobs = doc if isinstance(doc, list) else (doc.get("jobs") if isinstance(doc, dict) else None)
    if not isinstance(jobs, list):
        raise ApiError("the jobs listing is not a list")
    job = next((j for j in jobs if j.get("name") == aggregator), None)
    if job is None:
        return None, None, f"run {name} has no {aggregator} job"
    status = str(job.get("status") or "")
    if status not in TERMINAL_JOB:
        return None, None, f"the {aggregator} job of run {name} is {status or 'unknown'}"
    first = RECORD_LINE.search(api.get_text(f"/repos/{repo}/actions/jobs/{job.get('id')}/logs"))
    try:
        record = json.loads(first.group(1)) if first else None
    except ValueError:
        record = None
    if not isinstance(record, dict):
        return None, None, f"run {name} recorded no verdict"
    if str(record.get("run-id")) != str(run.get("id")) or str(record.get("job-id")) != str(job.get("id")):
        return None, None, f"run {name}'s record names another run or job"
    if record.get("mode") not in ("ready", "wip", "train") or record.get("verdict") != status:
        return None, None, (f"run {name} judged nothing reusable (mode {record.get('mode')}, "
                            f"verdict {record.get('verdict')}, job {status})")
    return status, record["mode"], ""


def latest_judgement(api, repo, head, workflow, aggregator, exclude=None, newer_than=None, quiet=False):
    """The verdict of the latest completed run of this workflow on head (the one whose commit status stands),
    as a dict, or (None, why). quiet: none when another run of the workflow on head is unfinished (queued,
    waiting, running, a UI re-run): it will write its own verdict after this one (review 75-I1)."""
    others = [r for r in runs_of_commit(api, repo, head, workflow) if str(r.get("id")) != str(exclude)]
    if quiet:
        busy = [r for r in others if not completed(r)]
        if busy:
            names = ", ".join(str(r.get("index_in_repo") or r.get("id")) for r in busy)
            return None, f"another run of this workflow on this commit is in progress (run {names})"
    runs = [r for r in others if completed(r)
            and (newer_than is None or int(r.get("id") or 0) > int(newer_than))]
    if not runs:
        return None, "no completed run of this workflow on this commit"
    runs.sort(key=lambda r: (str(r.get("stopped")), int(r.get("id") or 0)), reverse=True)
    run = runs[0]
    verdict, mode, why = judged(api, repo, run, aggregator)
    if verdict is None:
        return None, why
    return {"verdict": verdict, "mode": mode, "run-id": str(run.get("id")),
            "run-url": run.get("html_url") or "", "run-index": str(run.get("index_in_repo") or "")}, ""


# --------------------------------------------------------------------------------------------- outputs

def emit(outputs, path):
    lines = []
    for key, value in outputs.items():
        text = value if isinstance(value, str) else json.dumps(value, separators=(",", ":"))
        lines.append(f"{key}={text}")
    out = "\n".join(lines) + "\n"
    sys.stdout.write(out)
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(out)


def notice(kind, title, message):
    print(f"::{kind} title={title}::{message}")


def read_pr(api, repo, number, event_path, fallback=True):
    """The pull request now, through the API; the event payload only when the API cannot be read (and
    fallback allows it)."""
    try:
        pr = api.get(f"/repos/{repo}/pulls/{number}")
        if isinstance(pr, dict) and "title" in pr:
            return pr, "api"
        raise ApiError("not a pull request")
    except ApiError as err:
        if not fallback:
            return None, ""
        notice("warning", "pr-validate-gate", f"cannot read the pull request ({err}); using the event payload")
    try:
        with open(event_path, encoding="utf-8") as fh:
            pr = json.load(fh).get("pull_request")
        if isinstance(pr, dict):
            return pr, "event"
    except (OSError, ValueError, AttributeError, TypeError):
        pass
    return None, ""


# ---------------------------------------------------------------------------------------------- state

def base_changed(event_path):
    """An `edited` event that retargets the pull request carries changes.base: never reproduce then."""
    try:
        with open(event_path, encoding="utf-8") as fh:
            changes = json.load(fh).get("changes")
    except (OSError, ValueError, AttributeError, TypeError):
        return False
    return isinstance(changes, dict) and "base" in changes


def cmd_state(a):
    api = Api(a.api, a.token)
    started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    if not a.pr:
        state = {"mode": "ready", "reproduce": False, "why": "not a pull request event", "started-at": started,
                 "run-id": a.run_id}
        emit({"state": state, "mode": "ready", "run-producer": "true", "run-downstream": "true",
              "reproduce": "false", "reason": state["why"]}, a.output)
        return 0
    pr, source = read_pr(api, a.repo, a.pr, a.event_path)
    if pr is None:
        notice("error", "pr-validate-gate", "the pull request can be read neither from the API nor from the event")
        return 1
    c = classify(pr, a.wip_labels, a.train_label, a.blocked_labels)
    head = a.head or ((pr.get("head") or {}).get("sha") or "")
    state = {"mode": c["mode"], "wip": c["wip"], "blocked": c["blocked"], "wip-reason": c["wip-reason"],
             "train-top": c["train-top"], "source": source,
             "head": head, "activity": a.activity, "attempt": a.attempt, "run-id": a.run_id,
             "started-at": started, "reproduce": False}

    why = ""
    if c["mode"] == "train":
        why = "train member: nothing to build"
    elif a.activity in FULL_ACTIVITIES:
        why = f"activity '{a.activity or 'none'}' brings code to validate"
    elif str(a.attempt or "1") != "1":
        why = f"attempt {a.attempt}: a re-run validates again"
    elif base_changed(a.event_path):
        why = f"activity '{a.activity}': the base branch changed: full validation"
    elif not head or not a.run_id:
        why = "head commit or run unknown: full validation"
    else:
        try:
            workflow = workflow_file(api, a.repo, a.run_id, a.workflow)
            prev, missing = latest_judgement(api, a.repo, head, workflow, a.aggregator, exclude=a.run_id, quiet=True)
        except ApiError as err:
            prev, missing = None, f"the previous runs cannot be read ({err})"
        if prev is None:
            why = f"activity '{a.activity}': {missing}: full validation"
        elif prev["mode"] != c["mode"]:
            why = (f"activity '{a.activity}': the pull request changed from {prev['mode']} to {c['mode']} "
                   f"since run {prev['run-index'] or prev['run-id']}: full validation")
        else:
            state["reproduce"] = True
            state["previous"] = prev
            why = (f"activity '{a.activity}': nothing relevant changed since run {prev['run-index'] or prev['run-id']} "
                   f"({prev['mode']}, {prev['verdict']}): its verdict is reproduced, nothing is built")
    state["why"] = why

    run_producer = c["mode"] != "train" and not state["reproduce"]
    run_downstream = c["mode"] == "ready" and not state["reproduce"]
    summary = {"train": train_message(state), "wip": f"{not_ready_message(state)} ({c['wip-reason']})",
               "ready": "ready"}[c["mode"]]
    notice("notice", "pr-validate-gate", f"{summary.rstrip('.')}. {why}")
    emit({"state": state, "mode": c["mode"], "run-producer": str(run_producer).lower(),
          "run-downstream": str(run_downstream).lower(), "reproduce": str(state["reproduce"]).lower(),
          "reason": why}, a.output)
    return 0


# -------------------------------------------------------------------------------------------- verdict

def result_of(needs, job):
    entry = needs.get(job)
    return (entry or {}).get("result") if isinstance(entry, dict) else None


def output_of(needs, job, key):
    entry = needs.get(job)
    outputs = (entry or {}).get("outputs") if isinstance(entry, dict) else None
    return str((outputs or {}).get(key) or "")


def full_verdict(needs):
    """The validation verdict from the jobs' results: (ok, message)."""
    producer, impacted, downstream = (result_of(needs, j) for j in ("producer", "impacted", "downstream"))
    docs_only = output_of(needs, "producer", "docs-only") == "true"
    test_only = output_of(needs, "producer", "test-only") == "true"
    reused = output_of(needs, "producer", "reused") == "true"
    count = output_of(needs, "impacted", "count")
    if producer != "success":
        return False, f"producer build, tests or checks: {producer}"
    if impacted != "success":
        return False, f"the impacted consumers were not resolved: {impacted}"
    if downstream == "success":
        return True, f"Every impacted consumer ({count or '?'}) built against the pull request."
    if downstream == "skipped":
        if reused:
            return True, "Same code tree as a validated run (Vidocq/ci#57): no build expected."
        if docs_only or test_only:
            return True, "Docs-only or test-only change set: no downstream build expected."
        if count == "0":
            return True, "No impacted consumer on the forge: nothing to build."
        return False, f"downstream skipped although {count or 'an unknown number of'} consumer(s) were expected"
    return False, (f"downstream: {downstream}. At least one consumer failed or was cancelled; "
                   "see the downstream jobs.")


def decide(needs, state_job, a, api):
    """(ok, message, notify, judged mode). The judged mode is recorded for later runs: None when the verdict
    says nothing about the code in a mode (undetermined state, governance, a pull request changed meanwhile)."""
    state_result = result_of(needs, state_job)
    try:
        state = json.loads(output_of(needs, state_job, "state") or "null")
    except ValueError:
        state = None
    if state_result != "success" or not isinstance(state, dict) or state.get("mode") not in ("ready", "wip", "train"):
        return False, f"the pull request state was not determined ({state_job}: {state_result})", False, None

    governance = result_of(needs, "governance-checks")
    summary = " ".join(f"{job}={result_of(needs, job)}" for job in
                       ("governance-checks", state_job, "producer", "impacted", "downstream"))
    print(f"{summary} mode={state['mode']} reproduce={state.get('reproduce')} "
          f"docs-only={output_of(needs, 'producer', 'docs-only') or '?'} "
          f"test-only={output_of(needs, 'producer', 'test-only') or '?'} "
          f"consumers={output_of(needs, 'impacted', 'count') or '?'}")

    mode = state["mode"]
    # The pull request may have changed while this run worked (a label, a title). The run triggered by that
    # change decides; this one must neither pass a pull request that became WIP or a train member, nor write
    # a stale red over a newer verdict.
    if a.pr:
        pr, _ = read_pr(api, a.repo, a.pr, a.event_path, fallback=False)
        if pr is None:
            # Fail closed (review 75-M3): without the state now, a pull request that became WIP or a train
            # member during the run could pass.
            return False, "the pull request state cannot be re-read at the end of the run: re-run the jobs", False, None
        if pr is not None:
            now = classify(pr, a.wip_labels, a.train_label, a.blocked_labels)
            if now["mode"] != mode:
                newer = None
                if a.run_id and state.get("head"):
                    try:
                        workflow = workflow_file(api, a.repo, a.run_id, a.workflow)
                        newer, _ = latest_judgement(api, a.repo, state["head"], workflow, a.aggregator,
                                                    exclude=a.run_id, newer_than=a.run_id)
                    except ApiError:
                        newer = None
                if newer and newer["mode"] == now["mode"]:
                    ok = newer["verdict"] == "success"
                    return ok, (f"The pull request changed during this run ({mode} -> {now['mode']}); the newer run "
                                f"{newer['run-index'] or newer['run-id']} already judged it: {newer['verdict']}."), False, None
                extra = {"train": train_message(now), "wip": not_ready_message(now), "ready": ""}[now["mode"]]
                return False, (f"The pull request changed during this run ({mode} -> {now['mode']}); the run "
                               f"triggered by that change gives the verdict. {extra}").strip(), False, None

    if mode == "train":
        return False, train_message(state), False, "train"
    if governance != "success":
        return False, f"governance checks: {governance}", False, None
    if mode == "wip":
        producer = result_of(needs, "producer")
        if state.get("reproduce"):
            prev = state.get("previous") or {}
            ran = f"the producer ran in run {prev.get('run-index') or prev.get('run-id')}"
        else:
            ran = f"producer: {producer}"
        return False, f"{not_ready_message(state)} ({state.get('wip-reason') or 'WIP'}; {ran}).", False, "wip"
    if state.get("reproduce"):
        prev = state.get("previous") or {}
        ref = prev.get("run-index") or prev.get("run-id")
        # The run reproduced must still be the latest completed one, with no other run unfinished
        # (review 75-I1): a re-run or a newer run may have judged this commit since the state job looked.
        try:
            workflow = workflow_file(api, a.repo, a.run_id, a.workflow)
            latest, why = latest_judgement(api, a.repo, state.get("head") or "", workflow, a.aggregator,
                                           exclude=a.run_id, quiet=True)
        except ApiError as err:
            latest, why = None, f"the runs cannot be re-read ({err})"
        if latest is None:
            return False, (f"The verdict of run {ref} cannot be reproduced: {why}. That run, or a re-run of "
                           "this one, gives the verdict."), False, None
        if latest["run-id"] != str(prev.get("run-id")):
            newer = latest["run-index"] or latest["run-id"]
            if latest["mode"] == mode:
                return latest["verdict"] == "success", (
                    f"A newer run {newer} judged this commit since run {ref}: its verdict stands, "
                    f"{latest['verdict']} ({latest['run-url']})."), False, mode
            return False, (f"A newer run {newer} judged this commit in another mode ({latest['mode']}): "
                           "re-run all jobs to validate."), False, None
        if prev.get("verdict") == "success":
            return True, (f"Nothing relevant changed since run {ref} on this commit: its verdict stands, "
                          f"success ({prev.get('run-url') or ''})."), False, mode
        return False, (f"Nothing relevant changed since run {ref} on this commit: its verdict stands, failure "
                       f"({prev.get('run-url') or ''}). Re-run all jobs, or push, to validate again."), False, mode
    ok, message = full_verdict(needs)
    return ok, message, ok, mode


def own_job_id(api, a):
    """This aggregator job's id, so a later run can tell this record from any other line (review 75-M1)."""
    try:
        doc = api.get(f"/repos/{a.repo}/actions/runs/{a.run_id}/jobs")
    except ApiError:
        return None
    jobs = doc if isinstance(doc, list) else (doc.get("jobs") if isinstance(doc, dict) else None)
    hits = [j for j in jobs or [] if isinstance(j, dict) and j.get("name") == a.aggregator]
    return str(hits[0].get("id")) if len(hits) == 1 else None


def print_record(mode, verdict, a, job_id=None):
    """The line a later run reads back from this job's log (judged()): the first one, at the start of a line,
    naming this run and this job. Without the job id, it is never reproduced."""
    record = {"mode": mode, "verdict": verdict if mode else None, "run-id": a.run_id, "job-id": job_id}
    print(f"{RECORD} {json.dumps(record, separators=(',', ':'))}")


def cmd_verdict(a):
    try:
        needs = json.loads(a.needs or "")
        if not isinstance(needs, dict):
            raise ValueError
    except ValueError:
        notice("error", "pr-validate", "the needs of the aggregator are not readable (pass toJSON(needs))")
        print_record(None, None, a)
        emit({"verdict": "failure", "notify": "false", "reason": "needs unreadable"}, a.output)
        return 1
    missing = [job for job in ("governance-checks", a.state_job, "producer", "impacted", "downstream")
               if job not in needs]
    if missing:
        message = "the aggregator does not need " + ", ".join(missing) + ": the verdict cannot be decided"
        notice("error", "pr-validate", message)
        print_record(None, None, a)
        emit({"verdict": "failure", "notify": "false", "reason": message}, a.output)
        return 1
    api = Api(a.api, a.token)
    ok, message, notify, judged_mode = decide(needs, a.state_job, a, api)
    notice("notice" if ok else "error", "pr-validate", message)
    print_record(judged_mode, "success" if ok else "failure", a, own_job_id(api, a) if judged_mode else None)
    emit({"verdict": "success" if ok else "failure", "notify": str(notify).lower(), "reason": message}, a.output)
    return 0 if ok else 1


# ------------------------------------------------------------------------------------------- classify

def cmd_classify(a):
    try:
        with open(a.pr_json, encoding="utf-8") as fh:
            pr = json.load(fh)
        if not isinstance(pr, dict):
            raise ValueError
    except (OSError, ValueError):
        print("cannot read the pull request", file=sys.stderr)
        return 2
    c = classify(pr, a.wip_labels, a.train_label, a.blocked_labels)
    for key in ("mode", "wip", "wip-reason", "train", "train-top", "blocked"):
        value = c[key]
        print(f"{key}={str(value).lower() if isinstance(value, bool) else value}")
    return 0


def main(argv):
    env = os.environ.get
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("command", choices=("classify", "state", "verdict"))
    p.add_argument("--pr-json", default="")
    p.add_argument("--api", default=env("FORGE_API") or (env("GITHUB_SERVER_URL", "https://codefloe.com").rstrip("/") + "/api/v1"))
    p.add_argument("--token", default=env("GATE_TOKEN", ""))
    p.add_argument("--repo", default=env("GITHUB_REPOSITORY", ""))
    p.add_argument("--pr", default=env("GATE_PR", ""))
    p.add_argument("--head", default=env("GATE_HEAD", ""))
    p.add_argument("--activity", default=env("GATE_ACTIVITY", ""))
    p.add_argument("--attempt", default=env("GATE_ATTEMPT", "") or env("GITHUB_RUN_ATTEMPT", "1"))
    p.add_argument("--run-id", default=env("GATE_RUN_ID", "") or env("GITHUB_RUN_ID", ""))
    p.add_argument("--workflow", default=env("GATE_WORKFLOW_FILE", ""), help="the workflow file; read from this run when empty")
    p.add_argument("--event-path", default=env("GITHUB_EVENT_PATH", ""))
    p.add_argument("--needs", default=env("GATE_NEEDS", ""))
    p.add_argument("--state-job", default=env("GATE_STATE_JOB", "") or "pr-state")
    p.add_argument("--aggregator", default=env("GATE_AGGREGATOR", "") or "pr-validate")
    p.add_argument("--wip-labels", default=env("GATE_WIP_LABELS", "") or DEFAULT_WIP_LABELS)
    p.add_argument("--blocked-labels", default=env("GATE_BLOCKED_LABELS", "") or DEFAULT_BLOCKED_LABELS)
    p.add_argument("--train-label", default=env("GATE_TRAIN_LABEL", "") or DEFAULT_TRAIN_LABEL)
    p.add_argument("--output", default=env("GITHUB_OUTPUT", ""))
    a = p.parse_args(argv)
    return {"classify": cmd_classify, "state": cmd_state, "verdict": cmd_verdict}[a.command](a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
