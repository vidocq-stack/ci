#!/usr/bin/env python3
"""Are all the failures of a consumer's pull-request build pre-existing?

  compare.py --pr DIR --pr-log LOG --baseline DIR --baseline-log LOG [--json OUT] [--summary MD]

DIR is a consumer checkout after `mvn -fae -Dmaven.test.failure.ignore=true install`: the
pull-request build (producer pinned to its PR version) or the baseline (the same consumer commit
against the producer's current main SNAPSHOT). LOG is that build's Maven output.

A failure is one of:
  - a test case (class#method) with a <failure> or <error> in a surefire or failsafe report
    (TEST-*.xml); a test that failed then passed on rerun (<flakyFailure> only) is no failure;
  - a maven-invoker-plugin build whose result is not success or skipped (BUILD-*.xml);
  - a build error: "[ERROR] Failed to execute goal <plugin:goal> (...) on project <module>",
    compared by module and goal (compilation, codegen, packaging...).

Decision (exit 0 only for "pre-existing"):
  pre-existing    every failure of the pull-request build also fails on the baseline, and the
                  pull-request build skipped no module the baseline built;
  caused-by-pr    a failure that the baseline does not have (listed), or a module the
                  pull-request build skipped that the baseline built (its tests never ran);
  doubt           the log reports test failures that no report names (missing reports), on
                  either side;
  not-reproduced  the pull-request rerun has no failure at all: the original failure cannot be
                  attributed (it fails as before).
"""
import argparse
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

GOAL = re.compile(r'\[ERROR\] Failed to execute goal (\S+) \([^)]*\) on project ([^\s:]+)')
SKIPPED = re.compile(r'^\[INFO\] (.+?) \.*\s*SKIPPED\s*$')
TEST_SUMMARY = re.compile(r'Tests run: \d+, Failures: (\d+), Errors: (\d+)(?:, Skipped: \d+)?\s*$')


def strip(tag):
    return tag.split('}', 1)[1] if isinstance(tag, str) and tag.startswith('{') else tag


def collect(root, log):
    tests, invoker = set(), set()
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if not x.startswith('.') and x != 'node_modules']
        base = os.path.basename(d)
        for name in files:
            path = os.path.join(d, name)
            if base in ('surefire-reports', 'failsafe-reports') and name.startswith('TEST-') and name.endswith('.xml'):
                try:
                    suite = ET.parse(path).getroot()
                except (ET.ParseError, OSError):
                    tests.add(f'unreadable report {os.path.relpath(path, root)}')
                    continue
                for case in suite.iter():
                    if strip(case.tag) != 'testcase':
                        continue
                    kinds = {strip(c.tag) for c in case}
                    if kinds & {'failure', 'error'}:
                        tests.add(f"{case.get('classname', '?')}#{case.get('name', '?')}")
            elif base == 'invoker-reports' and name.startswith('BUILD-') and name.endswith('.xml'):
                try:
                    job = ET.parse(path).getroot()
                except (ET.ParseError, OSError):
                    invoker.add(f'unreadable invoker report {os.path.relpath(path, root)}')
                    continue
                if job.get('result', '') not in ('success', 'skipped'):
                    module = os.path.relpath(os.path.dirname(os.path.dirname(d)), root)
                    invoker.add(f"invoker {module}/{job.get('project', name)}")
    errors, skipped, signalled = set(), set(), 0
    with open(log, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.rstrip('\n')
            m = GOAL.search(line)
            if m:
                coord = m.group(1).split(':', 1)[-1]
                coord = coord[len('maven-'):] if coord.startswith('maven-') else coord
                errors.add(f'build error {m.group(2)} {coord}')
                continue
            m = SKIPPED.match(line)
            if m:
                skipped.add(m.group(1).strip())
                continue
            m = TEST_SUMMARY.search(line)
            if m and 'Time elapsed' not in line and (int(m.group(1)) or int(m.group(2))):
                signalled += 1
    return {'tests': tests, 'invoker': invoker, 'errors': errors, 'skipped': skipped,
            'signalled': signalled}


def decide(pr, base):
    pr_all = pr['tests'] | pr['invoker'] | pr['errors']
    base_all = base['tests'] | base['invoker'] | base['errors']
    out = {'pr': sorted(pr_all), 'baseline': sorted(base_all), 'new': [], 'pre_existing': [],
           'skipped_extra': sorted(pr['skipped'] - base['skipped'])}
    for side, name in ((pr, 'pull-request'), (base, 'baseline')):
        if side['signalled'] and not side['tests']:
            out.update(decision='doubt', reason=f'the {name} log reports test failures that no surefire or '
                       'failsafe report names (missing reports)')
            return out
    if not pr_all:
        out.update(decision='not-reproduced', reason='the pull-request rerun has no failure: the original '
                   'failure cannot be attributed to the baseline')
        return out
    out['new'] = sorted(pr_all - base_all)
    out['pre_existing'] = sorted(pr_all & base_all)
    if out['new']:
        out.update(decision='caused-by-pr', reason=f"{len(out['new'])} failure(s) the baseline does not have")
    elif out['skipped_extra']:
        out.update(decision='caused-by-pr', reason='modules skipped by the pull-request build but built by the '
                   'baseline (their tests never ran): ' + ', '.join(out['skipped_extra']))
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
    else:
        lines += ['### Baseline comparison: the failures are not all pre-existing', '', f"Decision: **{out['decision']}** ({out['reason']}).", '']
        if out['new']:
            lines += ['Failing with this PR, passing on the baseline:', ''] + [f'- `{x}`' for x in out['new']] + ['']
        if out.get('pre_existing'):
            lines += ['Also failing on the baseline (pre-existing):', ''] + [f'- `{x}`' for x in out['pre_existing']]
    return '\n'.join(lines) + '\n'


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--pr', required=True)
    ap.add_argument('--pr-log', required=True)
    ap.add_argument('--baseline', required=True)
    ap.add_argument('--baseline-log', required=True)
    ap.add_argument('--json')
    ap.add_argument('--summary')
    a = ap.parse_args(argv)
    out = decide(collect(a.pr, a.pr_log), collect(a.baseline, a.baseline_log))
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
