#!/usr/bin/env python3
"""Which modules of a repository's own reactor a pull request changes, with their dependents.

  changed-modules.py --effective-pom EFF.xml --repo DIR --changed-files FILE --report OUT.json

EFF.xml is `mvn help:effective-pom -Doutput=EFF.xml` of the repository, with the same Maven args
and environment as the build that follows. FILE lists the pull request's changed paths, one per
line, relative to the repository root.

A changed path belongs to the deepest reactor module whose directory holds it, as in
select-tck.py. Those modules, every reactor module that depends on them by any reference
(pommodel.close_dependents: dependencies of every scope, plugins, plugin dependencies, processor
paths, plugin configurations, parents, BOM imports, nested builds), and every non-pom module
whose src/ names the artifactId of one of those non-pom modules as text (main sources: with its
dependents; test sources only: with the modules using its test classes), are affected. Documentation outside every module (*.md, *.adoc, docs/, LICENSE*, NOTICE*) is
ignored; inside a module directory it belongs to that module (it may be packaged or tested).

With --build-effective-pom, the analysis model (--effective-pom) may add profiles such as -Ptck,
so that what those profiles use counts, and only the modules of the build's own reactor are
ever put in the skip list.

The report has the same shape as affected-modules.py's: "decision" is "targeted" (with "skip",
the unaffected non-pom modules), "all" (nothing to skip) or "full" with a "reason": an empty
change list, documentation only, a changed path in the root module (root pom, .mvn/, .forgejo/,
scripts) or escaping the repository, a pom that cannot be read, any error. Never exits non-zero
on such a doubt; a crash makes the caller fall back.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(HERE, '..', 'build-one-consumer', 'targeted'))
import pommodel  # noqa: E402


class Fallback(Exception):
    pass


def is_doc(path):
    if path.startswith('src/') or '/src/' in path:
        return False
    name = os.path.basename(path)
    return (path.endswith(('.md', '.adoc')) or path.startswith('docs/')
            or name.startswith(('LICENSE', 'NOTICE')))


def analyse(eff, repo, changed, build_eff=None):
    if not changed:
        raise Fallback('the changed-file list is empty')
    repo = os.path.realpath(repo)
    mods = pommodel.load_reactor(eff)
    built = set(pommodel.load_reactor(build_eff)) if build_eff else set(mods)
    rel, by_dir = {}, {}
    for ga, m in mods.items():
        r = os.path.relpath(os.path.realpath(m.basedir), repo)
        if r.startswith('..'):
            raise Fallback(f'module {ga} lies outside the repository ({m.basedir})')
        rel[ga] = r
        by_dir[r] = ga
    seeds = {}
    for path in changed:
        norm = os.path.normpath(path)
        if norm.startswith('..') or os.path.isabs(norm):
            raise Fallback(f'changed path {path} escapes the repository')
        d = os.path.dirname(norm)
        while d not in by_dir and d not in ('', '.'):
            d = os.path.dirname(d)
        if d in ('', '.'):
            if is_doc(norm):
                continue                  # documentation outside every module
            raise Fallback(f'{path} belongs to the root module (root pom, .mvn/, CI configuration, '
                           'scripts): it may change every module')
        seeds.setdefault(by_dir[d], f'owns {path}')
    if not seeds:
        raise Fallback('only documentation changed: nothing to select')
    # A module whose src/ names an affected jar may resolve it at run time. Named in its main
    # sources or resources, the module's own behaviour changes: it is a seed, with its
    # dependents. Named in its test sources only, its tests run, and so do the modules using its
    # test classes (pommodel.close_with_test_only). pom modules (aggregators, parents) are no
    # artifact anything resolves: their names do not count.
    test_only = {}
    while True:
        affected = pommodel.close_with_test_only(seeds, test_only, mods)
        ids = {mods[ga].artifact_id for ga in affected if mods[ga].packaging != 'pom'}
        grew = False
        for ga, m in mods.items():
            if ga in affected or m.packaging == 'pom':
                continue
            main = pommodel.scan_sources(m, ids, where='main')
            if main:
                seeds[ga] = main[0]
                grew = True
            elif ga not in test_only:
                tests = pommodel.scan_sources(m, ids, where='test')
                if tests:
                    test_only[ga] = tests[0] + ' (tests only)'
                    grew = True
        if not grew:
            break
    # Only modules the build itself runs (the default reactor) are ever edited.
    skip = sorted(rel[ga] for ga, m in mods.items()
                  if ga not in affected and m.packaging != 'pom' and ga in built)
    return {
        'decision': 'targeted' if skip else 'all',
        'changed': {rel[ga]: why for ga, why in sorted(seeds.items())},
        'affected': {rel[ga]: why for ga, why in sorted(affected.items(), key=lambda kv: rel[kv[0]])},
        'skip': skip,
        'modules': len(mods),
    }


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--effective-pom', required=True)
    ap.add_argument('--repo', required=True)
    ap.add_argument('--changed-files', required=True)
    ap.add_argument('--build-effective-pom', help='effective POM of the build itself (default '
                    'profiles), when --effective-pom adds profiles (-Ptck): only its modules are skipped')
    ap.add_argument('--report', required=True)
    a = ap.parse_args(argv)
    try:
        with open(a.changed_files, encoding='utf-8') as f:
            changed = [line.strip() for line in f if line.strip()]
        report = analyse(a.effective_pom, a.repo, changed, a.build_effective_pom)
    except Fallback as e:
        report = {'decision': 'full', 'reason': str(e)}
    except pommodel.PomError as e:
        report = {'decision': 'full', 'reason': f'a pom cannot be read: {e}'}
    with open(a.report, 'w', encoding='utf-8') as f:
        json.dump(report, f, indent=1, sort_keys=True)
    print(f"decision: {report['decision']}" + (f" ({report['reason']})" if 'reason' in report else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
