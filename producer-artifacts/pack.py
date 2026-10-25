#!/usr/bin/env python3
"""Pack the producer reactor's artifacts at the pull-request version, from the local repository.

  pack.py --repo LOCAL_REPO --modules FILE --eff EFF.xml --version VERSION --out DIR

FILE lists the reactor's modules, one groupId:artifactId per line (producer-artifacts.py); EFF.xml
is the producer's effective POM after the install (reactor.py: version and install skip of each
module). For each module that does not skip install, every file of
<repo>/<group path>/<artifactId>/<VERSION>/ goes into DIR/artifacts.tar.gz, test jars (classifier
tests) included, as the rebuild installs them, except sources and javadoc jars (not used by a
build), resolver caches (*.lastUpdated) and metadata (maven-metadata*: consumers pin exact
versions). DIR/manifest.json holds the version, the modules, the sha256 of every packed file
(path relative to the repository) and the modules that skip install (reactor.py: they install
nothing in the rebuild either). Fails closed: a module that does not skip install and is at
another version than VERSION, or that installed nothing at VERSION, means no pack. Exits non-zero
on any problem: the consumers then rebuild the producer as before.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import tarfile
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reactor  # noqa: E402 - next to this script

SKIP = re.compile(r'(-sources\.jar|-javadoc\.jar|-test-sources\.jar|\.lastUpdated|^maven-metadata.*)$')


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--repo', required=True)
    ap.add_argument('--modules', required=True)
    ap.add_argument('--eff', required=True)
    ap.add_argument('--version', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args(argv)
    if a.version.endswith('-SNAPSHOT'):
        sys.exit(f'pack.py: {a.version} is not a release-style pull-request version')
    with open(a.modules, encoding='utf-8') as f:
        modules = sorted({line.strip() for line in f if line.strip()})
    if not modules:
        sys.exit('pack.py: no module')
    try:
        reactor_modules = reactor.read(a.eff)
    except (ET.ParseError, OSError) as e:
        sys.exit(f'pack.py: {e}')
    files, skipped, problems = {}, [], []
    for ga in modules:
        module = reactor_modules.get(ga)
        if module is None:
            problems.append(f'{ga} is not in the effective POM')
            continue
        if module.install_skipped:
            skipped.append(ga)
            continue
        if module.version != a.version:
            problems.append(f'{ga} is at {module.version}, not at the PR version {a.version}')
            continue
        g, art = ga.split(':', 1)
        rel_dir = os.path.join(*g.split('.'), art, a.version)
        d = os.path.join(a.repo, rel_dir)
        names = sorted(n for n in os.listdir(d) if not SKIP.search(n)) if os.path.isdir(d) else []
        if not names:
            problems.append(f'{ga} installed nothing at {a.version} although it does not skip install')
            continue
        for n in names:
            rel = f'{rel_dir}/{n}'.replace(os.sep, '/')
            files[rel] = sha256(os.path.join(a.repo, rel))
    if problems:
        sys.exit('pack.py: not packed, the downstream jobs rebuild the producer: ' + '; '.join(problems))
    if not files:
        sys.exit('pack.py: no artifact of the reactor at that version in the local repository')
    os.makedirs(a.out, exist_ok=True)
    with tarfile.open(os.path.join(a.out, 'artifacts.tar.gz'), 'w:gz') as tar:
        for rel in sorted(files):
            tar.add(os.path.join(a.repo, rel), arcname=rel, recursive=False)
    with open(os.path.join(a.out, 'manifest.json'), 'w', encoding='utf-8') as f:
        json.dump({'version': a.version, 'modules': modules, 'files': files,
                   'install_skipped': skipped}, f, indent=1, sort_keys=True)
    size = os.path.getsize(os.path.join(a.out, 'artifacts.tar.gz'))
    print(f'{len(files)} file(s) of {len(modules) - len(skipped)} module(s), {size} bytes packed'
          + (f'; skipping install: {", ".join(skipped)}' if skipped else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
