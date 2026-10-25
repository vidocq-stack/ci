#!/usr/bin/env python3
"""Downstream job: install the producer artifacts the producer job shared, if they are sound.

  fetch_install.py --api API --run RUN_ID --name NAME --token TOKEN --version VERSION
                   --modules FILE --eff EFF.xml --repo LOCAL_REPO --work DIR [--list-out FILE]

API is <server>/api/v1/repos/<owner>/<repo>. The run's artifact NAME (pack.py's archive and
manifest, zipped by upload-artifact) is downloaded with the job token when the run has exactly one
artifact of that name, then checked against the producer reactor as this job's checkout describes
it (FILE, its modules; EFF.xml, its effective POM, read by reactor.py for the modules that skip
install): the manifest's version is VERSION; its modules are exactly those of FILE; the modules it
says skip install are exactly those that skip install here; every manifest path is a file directly
in <group path>/<artifactId>/<VERSION>/ of a module that does not skip install, and each such
module has at least one; every archive member is a file of the manifest with its sha256, and every
manifest file is there. Only then are the files written into LOCAL_REPO. Exit 0 when installed; 1
otherwise, the last line of the output saying why (the caller rebuilds the producer).
"""
import argparse
import hashlib
import io
import json
import os
import sys
import tarfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reactor  # noqa: E402 - next to this script


class Refused(Exception):
    pass


def get(url, token):
    req = urllib.request.Request(url, headers={'Authorization': 'token ' + token} if token else {})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    for opt in ('--api', '--run', '--name', '--token', '--version', '--modules', '--eff', '--repo', '--work'):
        ap.add_argument(opt, required=opt != '--token', default='')
    ap.add_argument('--list-out')
    a = ap.parse_args(argv)
    try:
        try:
            listing = json.loads(get(f'{a.api}/actions/runs/{a.run}/artifacts', a.token))
        except Exception as e:  # noqa: BLE001 - any failure: rebuild
            raise Refused(f'the artifact list could not be read for the download ({e})')
        found = [x for x in listing if x.get('name') == a.name and not x.get('expired')]
        if not found:
            raise Refused(f'artifact {a.name} not found in run {a.run}')
        if len(found) > 1:
            raise Refused(f'several artifacts named {a.name} in run {a.run} ({len(found)}): which one the producer job uploaded is unknown')
        try:
            data = get(found[0]['archive_download_url'], a.token)
            z = zipfile.ZipFile(io.BytesIO(data))
            manifest = json.loads(z.read('manifest.json'))
            archive = z.read('artifacts.tar.gz')
        except Exception as e:  # noqa: BLE001
            raise Refused(f'the download of {a.name} failed ({e})')
        if manifest.get('version') != a.version:
            raise Refused(f"version {manifest.get('version')} in the manifest, {a.version} expected")
        with open(a.modules, encoding='utf-8') as f:
            modules = sorted({line.strip() for line in f if line.strip()})
        if sorted(manifest.get('modules', [])) != modules:
            raise Refused('the manifest modules differ from the producer reactor: '
                          f"{sorted(set(manifest.get('modules', [])) ^ set(modules))}")
        try:
            reactor_modules = reactor.read(a.eff)
        except (ET.ParseError, OSError) as e:
            raise Refused(f'the effective POM of the producer could not be read ({e})')
        skipped = sorted(ga for ga in modules if ga in reactor_modules and reactor_modules[ga].install_skipped)
        if sorted(manifest.get('install_skipped', [])) != skipped:
            raise Refused('the modules that skip install differ between the manifest and the producer checkout: '
                          f"{sorted(set(manifest.get('install_skipped', [])) ^ set(skipped))}")
        files = manifest.get('files', {})
        dirs = {'/'.join(ga.split(':', 1)[0].split('.') + [ga.split(':', 1)[1], a.version]): ga
                for ga in modules if ga not in skipped}
        installed = set()
        for rel in files:
            d, _, n = rel.rpartition('/')
            if d not in dirs or n in ('', '.', '..'):
                raise Refused(f"manifest path {rel} outside the modules' {a.version} directories")
            installed.add(dirs[d])
        nothing = sorted(set(dirs.values()) - installed)
        if nothing:
            raise Refused(f'{nothing} installed nothing according to the manifest, and they do not skip install')
        contents = {}
        with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
            for m in tar.getmembers():
                if m.name not in files or not m.isfile():
                    raise Refused(f'archive member {m.name} outside the manifest')
                data = tar.extractfile(m).read()
                if hashlib.sha256(data).hexdigest() != files[m.name]:
                    raise Refused(f'checksum mismatch for {m.name}')
                contents[m.name] = data
        missing = sorted(set(files) - set(contents))
        if missing:
            raise Refused(f'files of the manifest missing from the archive: {missing[:3]}')
        for rel, data in contents.items():
            path = os.path.join(a.repo, *rel.split('/'))
            if os.path.commonpath([os.path.realpath(path), os.path.realpath(a.repo)]) != os.path.realpath(a.repo):
                raise Refused(f'archive member {rel} outside the local repository')
        for rel, data in contents.items():
            path = os.path.join(a.repo, *rel.split('/'))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'wb') as f:
                f.write(data)
        if a.list_out:
            os.makedirs(os.path.dirname(a.list_out) or '.', exist_ok=True)
            with open(a.list_out, 'w', encoding='utf-8') as f:
                f.writelines(ga + '\n' for ga in modules)
        print(f'installed {len(contents)} file(s) of {a.name} ({len(archive)} bytes), every sha256 checked')
        return 0
    except Refused as e:
        print(f'REASON: {e}')
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
