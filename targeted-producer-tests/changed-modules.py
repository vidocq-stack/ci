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

With --build-effective-pom, the analysis model (--effective-pom) may add profiles such as -Ptck:
the references of both models are combined (what -Ptck uses counts, and so does an
activeByDefault profile that -Ptck turns off), and only the modules of the build's own reactor
are ever put in the skip list. --keep-modules (ci.tck.modules) are never skipped.

--mention-local (the root pom's ci.targeted.mention-local): files whose mentions keep the tests of
the module holding them, without its dependents (a generated catalog of names, for instance). A
listed file that is itself a changed path makes its module a changed module, as any other.

The report has the same shape as affected-modules.py's: "decision" is "targeted" (with "skip",
the unaffected non-pom modules), "all" (nothing to skip) or "full" with a "reason": an empty
change list, documentation only, a changed path in the root module (root pom, .mvn/, .forgejo/,
scripts) or escaping the repository, a pom that cannot be read, any error. Never exits non-zero
on such a doubt; a crash makes the caller fall back.
"""
import argparse
import fnmatch
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


def combine(mods, build):
    """The references of both models: a module of the build model gets the -Ptck model's
    references added to its own (an activeByDefault profile that -Ptck turns off still counts),
    and a module only in one model is analysed as that model has it."""
    out = dict(build)
    for ga, m in mods.items():
        if ga not in out:
            out[ga] = m
            continue
        b = out[ga]
        b.refs = b.refs + m.refs
        b.imports = sorted(set(b.imports) | set(m.imports))
        b.nested_refs = b.nested_refs + m.nested_refs
        b.doubts = b.doubts + [d for d in m.doubts if d not in b.doubts]
    return out


def local_matcher(repo, patterns):
    """True for a file whose repository-relative path matches one of the ci.targeted.mention-local
    patterns (fnmatch globs: * matches / too)."""
    pats = [p.strip().strip('/') for p in patterns if p.strip()]

    def match(path):
        rel = os.path.relpath(os.path.realpath(path), repo).replace(os.sep, '/')
        return any(fnmatch.fnmatchcase(rel, p) for p in pats)
    return match


def analyse(eff, repo, changed, build_eff=None, keep=(), mention_local=()):
    if not changed:
        raise Fallback('the changed-file list is empty')
    repo = os.path.realpath(repo)
    mods = pommodel.load_reactor(eff)
    if build_eff:
        build = pommodel.load_reactor(build_eff)
        built = set(build)
        mods = combine(mods, build)
    else:
        built = set(mods)
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
    is_local = local_matcher(repo, mention_local)

    def not_local(path):
        return not is_local(path)
    while True:
        affected = pommodel.close_with_test_only(seeds, test_only, mods)
        ids = {mods[ga].artifact_id for ga in affected if mods[ga].packaging != 'pom'}
        grew = False
        for ga, m in mods.items():
            if ga in affected or m.packaging == 'pom':
                continue
            main = pommodel.scan_sources(m, ids, where='main', accept=not_local)
            if main:
                seeds[ga] = main[0]
                grew = True
            elif ga not in test_only:
                local = pommodel.scan_sources(m, ids, accept=is_local) if mention_local else []
                tests = pommodel.scan_sources(m, ids, where='test', accept=not_local)
                if local:
                    test_only[ga] = local[0] + ' (ci.targeted.mention-local: its dependents are not affected)'
                    grew = True
                elif tests:
                    test_only[ga] = tests[0] + ' (tests only)'
                    grew = True
        if not grew:
            break
    # Only modules the build itself runs (the default reactor) are ever edited.
    # The declared TCK runners (ci.tck.modules) are never skipped either: their TCK must run even
    # if a later step forgot the restore.
    keep = {os.path.normpath(k) for k in keep}
    skip = sorted(rel[ga] for ga, m in mods.items()
                  if ga not in affected and m.packaging != 'pom' and ga in built and rel[ga] not in keep)
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
    ap.add_argument('--mention-local', default='', help='comma-separated repository-relative paths or '
                    'globs (ci.targeted.mention-local) whose mentions keep their module\'s tests only')
    ap.add_argument('--keep-modules', default='', help='comma-separated module paths never skipped (ci.tck.modules)')
    ap.add_argument('--build-effective-pom', help='effective POM of the build itself (default '
                    'profiles), when --effective-pom adds profiles (-Ptck): only its modules are skipped')
    ap.add_argument('--report', required=True)
    a = ap.parse_args(argv)
    try:
        with open(a.changed_files, encoding='utf-8') as f:
            changed = [line.strip() for line in f if line.strip()]
        keep = [k.strip() for k in a.keep_modules.split(',') if k.strip()]
        local = [p for p in a.mention_local.split(',') if p.strip()]
        report = analyse(a.effective_pom, a.repo, changed, a.build_effective_pom, keep, local)
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
