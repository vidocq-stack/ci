#!/usr/bin/env python3
"""Pack the producer reactor's artifacts at the pull-request version, from the local repository.

  pack.py --repo LOCAL_REPO --modules FILE --version VERSION --out DIR

FILE lists the reactor's modules, one groupId:artifactId per line (producer-artifacts.py). For
each, every file of <repo>/<group path>/<artifactId>/<VERSION>/ goes into DIR/artifacts.tar.gz,
except sources, javadoc and test jars (no consumer depends on a producer test-jar), resolver
caches (*.lastUpdated) and metadata. DIR/manifest.json holds the version, the modules, the sha256
of every packed file (path relative to the repository) and the modules that installed nothing
(a module skipping install installs nothing in the rebuild either). Exits non-zero on any
problem: the consumers then rebuild the producer as before.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import tarfile

SKIP = re.compile(r'(-sources\.jar|-javadoc\.jar|-tests\.jar|-test-sources\.jar|\.lastUpdated|^maven-metadata.*)$')


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
    ap.add_argument('--version', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args(argv)
    if a.version.endswith('-SNAPSHOT'):
        sys.exit(f'pack.py: {a.version} is not a release-style pull-request version')
    with open(a.modules, encoding='utf-8') as f:
        modules = sorted({line.strip() for line in f if line.strip()})
    if not modules:
        sys.exit('pack.py: no module')
    files, not_installed = {}, []
    for ga in modules:
        g, art = ga.split(':', 1)
        rel_dir = os.path.join(*g.split('.'), art, a.version)
        d = os.path.join(a.repo, rel_dir)
        names = sorted(n for n in os.listdir(d) if not SKIP.search(n)) if os.path.isdir(d) else []
        if not names:
            not_installed.append(ga)
            continue
        for n in names:
            rel = f'{rel_dir}/{n}'.replace(os.sep, '/')
            files[rel] = sha256(os.path.join(a.repo, rel))
    if not files:
        sys.exit('pack.py: no artifact of the reactor at that version in the local repository')
    os.makedirs(a.out, exist_ok=True)
    with tarfile.open(os.path.join(a.out, 'artifacts.tar.gz'), 'w:gz') as tar:
        for rel in sorted(files):
            tar.add(os.path.join(a.repo, rel), arcname=rel, recursive=False)
    with open(os.path.join(a.out, 'manifest.json'), 'w', encoding='utf-8') as f:
        json.dump({'version': a.version, 'modules': modules, 'files': files,
                   'not_installed': not_installed}, f, indent=1, sort_keys=True)
    size = os.path.getsize(os.path.join(a.out, 'artifacts.tar.gz'))
    print(f'{len(files)} file(s) of {len(modules) - len(not_installed)} module(s), {size} bytes packed'
          + (f'; not installed: {", ".join(not_installed)}' if not_installed else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
