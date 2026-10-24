#!/usr/bin/env python3
"""Report the flaky tests of the downstream consumer builds.

Usage: flakes.py CONSUMER=LOG [CONSUMER=LOG ...]

build-impacted reruns a failing test once in the consumer builds
(-Dsurefire.rerunFailingTestsCount=1, same for failsafe). A test that fails, then passes,
does not fail the build: surefire and failsafe list it under "Flakes:" instead. This script
reads those sections in each consumer's build log and prints one ::warning:: per flaky test,
plus a section of the job summary ($GITHUB_STEP_SUMMARY) naming the consumer, the module and
the test. It never fails: it only reports. A missing log (a consumer the run did not reach)
is skipped.
"""
import os
import re
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
# [INFO] --- surefire:3.5.3:test (default-test) @ module ---  (or maven-surefire-plugin:...)
HEADER = re.compile(r"^\[INFO\] --- (?:maven-)?(surefire|failsafe)(?:-plugin)?:\S+ .*@ (\S+) ---\s*$")
OTHER_HEADER = re.compile(r"^\[INFO\] --- \S+ .*@ \S+ ---\s*$")
FLAKES = re.compile(r"^\[WARNING\] Flakes:\s*$")
RUN = re.compile(r"^\[(?:ERROR|WARNING|INFO)\]\s+Run (\d+): (.*)$")
BLANK = re.compile(r"^\[INFO\]\s*$")
TESTS_RUN = re.compile(r"^\[(?:ERROR|WARNING|INFO)\] Tests run:")
TEST = re.compile(r"^\[WARNING\] (\S.*?)\s*$")
MAX_REASON = 300


def parse(lines):
    """Yield dicts {plugin, module, test, reason} for each flaky test of one build log."""
    plugin = module = None
    in_flakes = False
    current = None
    reason_open = False
    for raw in lines:
        line = ANSI.sub("", raw.rstrip("\r\n"))
        m = HEADER.match(line)
        if m:
            plugin, module = m.group(1), m.group(2)
            in_flakes, current = False, None
            continue
        if OTHER_HEADER.match(line):
            in_flakes, current = False, None
            continue
        if not in_flakes:
            in_flakes = bool(FLAKES.match(line))
            continue
        if TESTS_RUN.match(line):
            in_flakes, current, reason_open = False, None, False
            continue
        m = RUN.match(line)
        if m:
            reason_open = False
            if current is not None and m.group(2) != "PASS" and current["reason"] is None:
                current["reason"] = m.group(2).strip()
                reason_open = True
            continue
        if BLANK.match(line):
            reason_open = False
            continue
        m = TEST.match(line)
        if m:
            current = {"plugin": plugin or "?", "module": module or "?",
                       "test": m.group(1), "reason": None}
            reason_open = False
            yield current
            continue
        if not line.startswith("["):
            # Continuation of a failure message printed on several lines.
            if reason_open and current is not None and line.strip():
                current["reason"] += " " + line.strip()
            continue
        in_flakes, current, reason_open = False, None, False


def command_data(s):
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def command_property(s):
    return command_data(s).replace(":", "%3A").replace(",", "%2C")


def cell(s):
    return s.replace("\\", "\\\\").replace("|", "\\|").replace("\n", " ")


def short(reason):
    reason = reason or "(no message)"
    return reason if len(reason) <= MAX_REASON else reason[:MAX_REASON - 1] + "…"


def main(argv):
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    rows = []
    for arg in argv:
        consumer, _, log = arg.partition("=")
        if not log or not os.path.isfile(log):
            continue
        with open(log, encoding="utf-8", errors="replace") as f:
            for flake in parse(f):
                rows.append((consumer, flake))

    if not rows:
        print("No flaky test in the downstream consumers.")
        return 0

    for consumer, f in rows:
        print(f"::warning title={command_property('Flaky test in ' + consumer)}::"
              + command_data(f"{f['test']} ({f['module']}, {f['plugin']}) failed, then passed on rerun. "
                             f"First failure: {short(f['reason'])}"))

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as out:
            out.write("### Flaky tests in downstream consumers\n\n")
            out.write("These tests failed, then passed when run again (`rerunFailingTestsCount=1`, "
                      "downstream builds only), so they did not fail this run. Each one needs an "
                      "entry in the `BUG.md` of its repository.\n\n")
            out.write("| Consumer | Module | Plugin | Test | First failure |\n")
            out.write("|---|---|---|---|---|\n")
            for consumer, f in rows:
                test = f["test"].replace("`", "'")
                out.write(f"| {cell(consumer)} | {cell(f['module'])} | {f['plugin']} | `{cell(test)}` "
                          f"| {cell(short(f['reason']))} |\n")
            out.write("\n")

    consumers = sorted({c for c, _ in rows})
    print(f"{len(rows)} flaky test(s) in the downstream consumers: {', '.join(consumers)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
