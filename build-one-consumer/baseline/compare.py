#!/usr/bin/env python3
"""Are all the failures of a consumer's pull-request build pre-existing?

  compare.py --pr DIR --pr-log LOG --baseline DIR --baseline-log LOG [--json OUT] [--summary MD]

DIR is a consumer checkout after `mvn -fae -Dmaven.test.failure.ignore=true install`: the
pull-request build (producer pinned to its PR version) or the baseline (the same consumer commit
against the producer's current main SNAPSHOT). LOG is that build's Maven output.

A failure is one of:
  - a test case, keyed <module>:<surefire|failsafe>:<class>#<method>, with a <failure> or <error>
    in a TEST-*.xml report; a test that failed then passed on rerun (<flakyFailure> only) is no
    failure;
  - a maven-invoker-plugin build whose result is not success or skipped (BUILD-*.xml);
  - a build error: "[ERROR] Failed to execute goal <plugin:goal> (...) on project <module>", by
    module and goal (a test plugin failing on test failures is left to the reports), and every
    "[ERROR] <file>:[line,col] <message>" line, the path relative to the checkout and version
    numbers normalised.

The pull-request side is the first build (--pr-first: its reports saved before the rerun, and its
log) together with the rerun: a failure of either must fail on the baseline too.

Decision (exit 0 only for "pre-existing"):
  pre-existing    every failure of the pull-request builds also fails on the baseline, and the
                  rerun skipped no module;
  caused-by-pr    a failure the baseline does not have (listed), or a module the rerun skipped
                  (never tested with the pull request);
  doubt           a log whose test summaries count more failures than its reports name (killed
                  fork, reports elsewhere), on any side;
  not-reproduced  no failure at all on the pull-request side.
"""
import argparse
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

GOAL = re.compile(r'\[ERROR\] Failed to execute goal (\S+) \([^)]*\) on project ([^\s:]+):?(.*)')
ERROR_LINE = re.compile(r'\[ERROR\] (/\S+?):\[(\d+),(\d+)\] (.*)')
SKIPPED = re.compile(r'^\[INFO\] (.+?) \.*\s*SKIPPED\s*$')
BUILDING = re.compile(r'^\[INFO\] Building (.+?) \S+ +\[\d+/\d+\]')
TEST_SUMMARY = re.compile(r'Tests run: \d+, Failures: (\d+), Errors: (\d+)(?:, Skipped: \d+)?(?:, Flakes: \d+)?\s*$')
# A test plugin failing because tests failed is what the reports say, not a build error (the first
# pull-request build runs without -Dmaven.test.failure.ignore). A crash of the fork stays one.
TEST_FAILURE_GOAL = re.compile(r'(surefire|failsafe|invoker)', re.I)
TEST_FAILURE_MESSAGE = re.compile(r'There (are|were) test failures|There are failing tests|build\(s\) failed|failed\.?$', re.I)
VERSION = re.compile(r'\b\d+\.\d+(?:\.\d+)?(?:-[\w.]+)?\b')


def strip(tag):
    return tag.split('}', 1)[1] if isinstance(tag, str) and tag.startswith('{') else tag


def relative(path, root):
    for r in {root, os.path.realpath(root)}:
        r = r.rstrip('/') + '/'
        if path.startswith(r):
            return path[len(r):]
    real = os.path.realpath(path)
    for r in {root, os.path.realpath(root)}:
        r = r.rstrip('/') + '/'
        if real.startswith(r):
            return real[len(r):]
    return path


def collect(root, log, source=None):
    """Failures of one build: test cases keyed <module>:<surefire|failsafe>:<class>#<method>,
    invoker builds, build errors (by module and goal, and by normalised error line), the modules
    the reactor skipped, and the failures the log's test summaries count."""
    tests, invoker = set(), set()
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if not x.startswith('.') and x != 'node_modules']
        base = os.path.basename(d)
        module = os.path.relpath(os.path.dirname(os.path.dirname(d)), root)
        for name in files:
            path = os.path.join(d, name)
            if base in ('surefire-reports', 'failsafe-reports') and name.startswith('TEST-') and name.endswith('.xml'):
                kind = base.split('-')[0]
                try:
                    suite = ET.parse(path).getroot()
                except (ET.ParseError, OSError):
                    tests.add(f'{module}:{kind}:unreadable report {name}')
                    continue
                for case in suite.iter():
                    if strip(case.tag) != 'testcase':
                        continue
                    if {strip(c.tag) for c in case} & {'failure', 'error'}:
                        tests.add(f"{module}:{kind}:{case.get('classname', '?')}#{case.get('name', '?')}")
            elif base == 'invoker-reports' and name.startswith('BUILD-') and name.endswith('.xml'):
                try:
                    job = ET.parse(path).getroot()
                except (ET.ParseError, OSError):
                    invoker.add(f'invoker:{module}:unreadable report {name}')
                    continue
                if job.get('result', '') not in ('success', 'skipped'):
                    invoker.add(f"invoker:{module}:{job.get('project', name)}")
    errors, skipped = set(), set()
    summaries, current = {}, ''
    with open(log, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.rstrip('\n')
            m = BUILDING.match(line)
            if m:
                current = m.group(1)
                continue
            m = GOAL.search(line)
            if m:
                coord, project, message = m.group(1), m.group(2), m.group(3)
                if TEST_FAILURE_GOAL.search(coord) and TEST_FAILURE_MESSAGE.search(message.strip()):
                    continue
                coord = coord.split(':', 1)[-1]
                coord = coord[len('maven-'):] if coord.startswith('maven-') else coord
                errors.add(f'build error {project} {coord}')
                continue
            m = ERROR_LINE.search(line)
            if m:
                path, ln, col, message = m.groups()
                errors.add(f'error {relative(path, source or root)}:[{ln},{col}] {VERSION.sub("V", message.strip())}')
                continue
            m = SKIPPED.match(line)
            if m:
                skipped.add(m.group(1).strip())
                continue
            m = TEST_SUMMARY.search(line)
            if m and 'Time elapsed' not in line:
                summaries.setdefault(current, set()).add((int(m.group(1)), int(m.group(2)), line.split('] ', 1)[-1]))
    signalled = sum(f + e for per in summaries.values() for f, e, _ in per)
    return {'tests': tests, 'invoker': invoker, 'errors': errors, 'skipped': skipped, 'signalled': signalled}


def failures(side):
    return side['tests'] | side['invoker'] | side['errors']


def decide(pr, base, first=None):
    sides = [(pr, 'pull-request rerun'), (base, 'baseline')] + ([(first, 'first pull-request build')] if first else [])
    pr_all = failures(pr) | (failures(first) if first else set())
    base_all = failures(base)
    out = {'pr': sorted(pr_all), 'baseline': sorted(base_all), 'new': [], 'pre_existing': [],
           'skipped': sorted(pr['skipped'])}
    for side, name in sides:
        if side['signalled'] > len(side['tests']):
            out.update(decision='doubt', reason=f"the {name} log counts {side['signalled']} failing test(s), its "
                       f"surefire and failsafe reports name {len(side['tests'])} (a killed fork, a report "
                       'elsewhere?)')
            return out
    if pr['skipped']:
        out.update(decision='caused-by-pr', reason='modules the pull-request rerun skipped, never tested with this '
                   'PR: ' + ', '.join(sorted(pr['skipped'])))
        return out
    if not pr_all:
        out.update(decision='not-reproduced', reason='the pull-request builds show no failure the baseline could '
                   'explain')
        return out
    out['new'] = sorted(pr_all - base_all)
    out['pre_existing'] = sorted(pr_all & base_all)
    if out['new']:
        out.update(decision='caused-by-pr', reason=f"{len(out['new'])} failure(s) the baseline does not have")
    else:
        out.update(decision='pre-existing', reason=f"all {len(pr_all)} failure(s) also fail on the producer's "
                   'current main')
    return out


def summary(out):
    lines = []
    if out['decision'] == 'pre-existing':
        lines += ['### Pre-existing failures, not caused by this PR', '',
                  "Every failure below also fails when the same consumer commit is built against the producer's "
                  'current main SNAPSHOT (baseline). The job passes; fix them in the consumer.', '']
        lines += [f'- `{x}`' for x in out['pre_existing']]
        if out.get('baseline_producer'):
            lines += ['', f"Baseline producer, as resolved at the time of the build: {out['baseline_producer']}."]
    else:
        lines += ['### Baseline comparison: the failures are not all pre-existing', '', f"Decision: **{out['decision']}** ({out['reason']}).", '']
        if out['new']:
            lines += ['Failing with this PR, passing on the baseline:', ''] + [f'- `{x}`' for x in out['new']] + ['']
        if out.get('pre_existing'):
            lines += ['Also failing on the baseline (pre-existing):', ''] + [f'- `{x}`' for x in out['pre_existing']] + ['']
        if out.get('skipped'):
            lines += ['Skipped by the pull-request rerun (never tested with this PR):', ''] + [f'- {x}' for x in out['skipped']] + ['']
        if out.get('baseline_producer'):
            lines += [f"Baseline producer, as resolved at the time of the build: {out['baseline_producer']}."]
    return '\n'.join(lines) + '\n'


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--pr', required=True)
    ap.add_argument('--pr-log', required=True)
    ap.add_argument('--baseline', required=True)
    ap.add_argument('--baseline-log', required=True)
    ap.add_argument('--pr-first', help='the first pull-request build\'s reports, saved before the rerun')
    ap.add_argument('--pr-first-log')
    ap.add_argument('--baseline-producer', default='', help='what the baseline resolved for the producer (summary)')
    ap.add_argument('--json')
    ap.add_argument('--summary')
    a = ap.parse_args(argv)
    first = collect(a.pr_first, a.pr_first_log, a.pr) if a.pr_first else None
    out = decide(collect(a.pr, a.pr_log), collect(a.baseline, a.baseline_log), first)
    out['baseline_producer'] = a.baseline_producer
    if a.json:
        with open(a.json, 'w', encoding='utf-8') as f:
            json.dump(out, f, indent=1)
    if a.summary:
        with open(a.summary, 'a', encoding='utf-8') as f:
            f.write(summary(out))
    print(f"baseline comparison: {out['decision']} ({out['reason']})")
    return 0 if out['decision'] == 'pre-existing' else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
