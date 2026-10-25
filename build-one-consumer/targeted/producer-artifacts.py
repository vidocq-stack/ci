#!/usr/bin/env python3
"""List the artifacts of the producer reactor, one groupId:artifactId per line.

  producer-artifacts.py EFF.xml OUT

EFF.xml is `mvn help:effective-pom -Doutput=EFF.xml` of the producer, run with the same Maven
args as its rebuild, so it holds exactly the modules that the rebuild installed. Every module
counts, pom-packaged ones (parents, BOMs) included: the targeted mode treats the whole producer
as changed. Exits non-zero, writing nothing, when the file does not parse or lists no module.
"""
import sys
import xml.etree.ElementTree as ET


def strip(tag):
    return tag.split('}', 1)[1] if isinstance(tag, str) and tag.startswith('{') else tag


def text(el, name):
    for c in (el if el is not None else []):
        if strip(c.tag) == name:
            return (c.text or '').strip()
    return ''


def child(el, name):
    for c in el:
        if strip(c.tag) == name:
            return c
    return None


def main(argv):
    if len(argv) != 2:
        sys.stderr.write(__doc__)
        return 2
    try:
        root = ET.parse(argv[0]).getroot()
    except (ET.ParseError, OSError) as e:
        sys.stderr.write(f'producer-artifacts.py: {e}\n')
        return 1
    projects = [root] if strip(root.tag) == 'project' else [c for c in root if strip(c.tag) == 'project']
    gas = set()
    for p in projects:
        g = text(p, 'groupId') or text(child(p, 'parent'), 'groupId')
        a = text(p, 'artifactId')
        if g and a:
            gas.add(f'{g}:{a}')
    if not gas:
        sys.stderr.write(f'producer-artifacts.py: no module in {argv[0]}\n')
        return 1
    with open(argv[1], 'w', encoding='utf-8') as f:
        f.writelines(ga + '\n' for ga in sorted(gas))
    print(f'{len(gas)} producer artifact(s): ' + ' '.join(sorted(gas)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
