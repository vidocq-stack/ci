#!/usr/bin/env python3
"""Turn off test execution in the consumer modules the producer cannot affect.

  skip-tests.py --repo DIR --report REPORT.json --out RESULT.json

REPORT.json is the report of affected-modules.py with decision "targeted"; its "skip" list
holds the unaffected non-pom modules (paths relative to DIR). Each of their pom.xml gets

    <skipTests>true</skipTests>          surefire and failsafe
    <skipITs>true</skipITs>              failsafe
    <invoker.skip>true</invoker.skip>    maven-invoker-plugin

at the start of its project-level <properties> (created before </project> when missing).
Every module still compiles, test-compiles, runs its codegen, packages and installs: only test
execution is skipped. The build must not pass -DskipTests itself (a command-line property
would override these per-module values). pom-packaged modules are never edited, here as in the
report: their properties would leak into children that may be affected. A property the pom
already declares itself (in its properties or a profile's, e.g. invoker.skip=${skipTests}) is
not added and keeps its own value: such a value can only keep more tests running, never fewer.
The rest of each file stays byte for byte.

All edits are computed first, then written; on any error nothing is left edited and the
script exits non-zero (the caller then runs the full build).
"""
import argparse
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

NAMES = ('skipTests', 'skipITs', 'invoker.skip')
TAG = re.compile(r'<(/?)([A-Za-z_][\w.\-]*)([^>]*?)(/?)>')
BLANK = [re.compile(p, re.S) for p in (r'<!--.*?-->', r'<\?.*?\?>', r'<!\[CDATA\[.*?\]\]>',
                                        r'<!DOCTYPE(?:[^>\[]|\[[^\]]*\])*>')]


def strip(tag):
    return tag.split('}', 1)[1] if isinstance(tag, str) and tag.startswith('{') else tag


def declared(path):
    """{name: value} for the NAMES the pom declares in its properties or a profile's."""
    root = ET.parse(path).getroot()
    holders = [c for c in root if strip(c.tag) == 'properties']
    for profiles in (c for c in root if strip(c.tag) == 'profiles'):
        for profile in profiles:
            holders += [c for c in profile if strip(c.tag) == 'properties']
    out = {}
    for h in holders:
        for p in h:
            if strip(p.tag) in NAMES:
                out.setdefault(strip(p.tag), (p.text or '').strip())
    return out


def edited(text, path, props):
    scan = text
    for rx in BLANK:
        scan = rx.sub(lambda m: ' ' * len(m.group(0)), scan)
    depth, project_close, props_open_end, props_empty = 0, None, None, None
    for m in TAG.finditer(scan):
        closing, name, _attrs, selfclose = m.groups()
        if selfclose:
            if depth == 1 and name == 'properties' and props_open_end is None and props_empty is None:
                props_empty = m
            continue
        if closing:
            depth -= 1
            if depth == 0 and name == 'project':
                project_close = m.start()
        else:
            depth += 1
            if depth == 2 and name == 'properties' and props_open_end is None:
                props_open_end = m.end()
    if props_empty is not None and (props_open_end is None or props_empty.start() < props_open_end):
        return text[:props_empty.start()] + '<properties>' + props + '</properties>' + text[props_empty.end():]
    if props_open_end is not None:
        return text[:props_open_end] + props + text[props_open_end:]
    if project_close is not None:
        return text[:project_close] + '<properties>' + props + '</properties>\n' + text[project_close:]
    raise ValueError(f'{path}: no </project> to place the properties before')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--repo', required=True)
    ap.add_argument('--report', required=True)
    ap.add_argument('--out', required=True)
    args = ap.parse_args()
    with open(args.report, encoding='utf-8') as f:
        report = json.load(f)
    if report.get('decision') != 'targeted':
        raise SystemExit(f"skip-tests.py: decision is {report.get('decision')!r}, not 'targeted'")
    plan, own = [], {}
    for rel in report.get('skip', []):
        path = os.path.join(args.repo, rel, 'pom.xml')
        root = ET.parse(path).getroot()
        if (root.findtext('{*}packaging') or root.findtext('packaging') or 'jar').strip() == 'pom':
            raise SystemExit(f'skip-tests.py: {rel} is pom-packaged, never edited')
        mine = declared(path)
        if mine:
            own[rel] = 'keeps its own ' + ', '.join(f'{k}={v}' for k, v in sorted(mine.items()))
        props = ''.join(f'<{n}>true</{n}>' for n in NAMES if n not in mine)
        if not props:
            continue
        with open(path, 'rb') as f:
            original = f.read()
        new = edited(original.decode('utf-8'), path, props).encode('utf-8')
        tree = ET.fromstring(new)                    # still well-formed, one <properties>
        if sum(1 for c in tree if c.tag.split('}')[-1] == 'properties') != 1:
            raise SystemExit(f'skip-tests.py: {rel}: the edit would not leave exactly one <properties>')
        plan.append((rel, path, original, new))
    # The result first: once a pom is written, nothing but the pom writes may fail.
    result = {'skipped': [rel for rel, *_ in plan], 'own': own}
    with open(args.out, 'w', encoding='utf-8') as f:
        json.dump(result, f, indent=1, sort_keys=True)
    try:
        for _rel, path, original, new in plan:
            with open(path, 'wb') as f:
                f.write(new)
    except BaseException:
        # Restore every planned pom, the one whose write failed halfway included.
        for _rel, path, original, _new in plan:
            with open(path, 'wb') as f:
                f.write(original)
        os.remove(args.out)
        raise
    print(f"tests skipped in {len(plan)} module(s); own values kept in {len(own)}")


if __name__ == '__main__':
    sys.exit(main())
