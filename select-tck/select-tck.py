#!/usr/bin/env python3
"""Which of the repository's declared TCK runners a pull request must replay.

  select-tck.py --effective-pom EFF.xml --repo DIR --changed-files FILE --modules "a, b"
                [--summary OUT.md]

EFF.xml is `mvn -Ptck help:effective-pom -Doutput=EFF.xml` of the repository (the profile that
declares the runners). FILE lists the pull request's changed paths, one per line, relative to
the repository root. --modules is the `ci.tck.modules` property: runner module paths,
comma-separated.

A changed path belongs to the deepest reactor module whose directory holds it. The modules
owning a changed path, and every reactor module that depends on them by any reference (the
edges of Maven's -amd, plus annotation processor paths, plugin configurations, nested builds:
pommodel.close_dependents), are "changed". A runner is replayed when it is changed, or when its
src/ names the artifactId of a changed module as text (resolved at run time).

Every doubt replays all the runners: an empty change list, a changed path outside every module
but the root, or in the root itself (root pom, scripts, CI configuration), a path that escapes
the repository, a runner path that is not a reactor module, any error. Documentation outside
src/ (*.md, *.adoc, docs/, LICENSE*, NOTICE*) is ignored.

Prints `mode=selected|all`, `modules=<comma-separated runner paths>` and `reason=<text>`; never
exits non-zero (a failure means "all").
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'build-one-consumer', 'targeted'))


def is_doc(path):
    if path.startswith('src/') or '/src/' in path:
        return False
    name = os.path.basename(path)
    return (path.endswith(('.md', '.adoc')) or path.startswith('docs/')
            or name.startswith(('LICENSE', 'NOTICE')))


def select(eff, repo, changed, runners):
    """(mode, selected runner paths, reason, skipped runner paths)."""
    import pommodel  # imported here so that an import error also means "all"
    if not changed:
        return 'all', runners, 'no changed file listed', []
    repo = os.path.realpath(repo)
    mods = pommodel.load_reactor(eff)
    by_dir = {}
    for m in mods.values():
        rel = os.path.relpath(os.path.realpath(m.basedir), repo)
        if rel.startswith('..'):
            raise ValueError(f'module {m.ga} lies outside the repository ({m.basedir})')
        by_dir[rel] = m
    seeds = {}
    for path in changed:
        norm = os.path.normpath(path)
        if norm.startswith('..') or os.path.isabs(norm):
            return 'all', runners, f'changed path {path} escapes the repository', []
        if is_doc(norm):
            continue
        d = os.path.dirname(norm)
        while d not in by_dir and d not in ('', '.'):
            d = os.path.dirname(d)
        if d in ('', '.'):
            return 'all', runners, f'{path} belongs to the root module, not to a submodule (root pom, scripts, CI configuration)', []
        seeds.setdefault(by_dir[d].ga, f'owns {path}')
    closure = pommodel.close_dependents(seeds, mods)
    changed_ids = {mods[ga].artifact_id for ga in closure}
    selected, skipped = [], []
    for r in runners:
        m = by_dir.get(os.path.normpath(r))
        if m is None:
            return 'all', runners, f'TCK runner {r} is not a module of the -Ptck reactor', []
        if m.ga in closure or pommodel.scan_sources(m, changed_ids):
            selected.append(r)
        else:
            skipped.append(r)
    return 'selected', selected, f'{len(seeds)} module(s) changed, {len(closure)} with their dependents', skipped


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--effective-pom', required=True)
    ap.add_argument('--repo', required=True)
    ap.add_argument('--changed-files', required=True)
    ap.add_argument('--modules', required=True)
    ap.add_argument('--summary')
    a = ap.parse_args(argv)
    runners = [x.strip() for x in a.modules.split(',') if x.strip()]
    try:
        with open(a.changed_files, encoding='utf-8') as f:
            changed = [line.strip() for line in f if line.strip()]
        mode, selected, reason, skipped = select(a.effective_pom, a.repo, changed, runners)
    except Exception as e:  # any doubt: replay every runner
        mode, selected, reason, skipped = 'all', runners, f'selection failed ({type(e).__name__}: {e})', []
    print(f'mode={mode}')
    print('modules=' + ','.join(selected))
    print(f'reason={reason}')
    if a.summary:
        try:
            with open(a.summary, 'a', encoding='utf-8') as f:
                f.write(f'### TCK runners\n\nMode: **{mode}** ({reason}).\n\n')
                f.write('| Runner | Replayed |\n|---|---|\n')
                for r in runners:
                    f.write(f"| `{r}` | {'yes' if r in selected else 'no: no changed module reaches it'} |\n")
                f.write('\n')
        except OSError:
            pass
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
