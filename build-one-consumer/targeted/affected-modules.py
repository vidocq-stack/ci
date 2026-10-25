#!/usr/bin/env python3
"""Which modules of a consumer reactor can see an artifact of the producer under pull request.

  affected-modules.py --effective-pom EFF.xml --repo DIR --producer-artifacts FILE
                      --synthetic DIR --report OUT.json
                      [--graph inverted.json --producer-slug OWNER/NAME] [--closures]

EFF.xml is `mvn help:effective-pom -Doutput=EFF.xml` of the consumer, run with the build's own
Maven args and environment (so with its profiles). FILE lists the producer artifacts, one
groupId:artifactId per line: every module of the producer reactor (whole-producer changed set).

A module is affected when it names a producer artifact, by any kind of reference: a dependency
of any scope (test included), a plugin, a plugin dependency, a build extension, an artifact
named in a plugin configuration (annotationProcessorPaths, artifactItems...) or in its text, a
parent, a BOM import (read from the raw pom: the effective POM inlines it), or a nested build
under src/ (maven-invoker-plugin ITs, test projects); or when it depends on an affected reactor
module by any of these references (Maven -amd, plus processor paths and nested builds: a module
whose annotationProcessorPaths name a reactor codegen module is affected with it).

Coordinates written as text in a plugin configuration (`g:a[:...][:version]` tokens) count as
references too: a reactor module named that way is a reactor edge, an external one gets its
closure (its version from the token, the module's dependencyManagement or its dependencies), and
one that cannot be resolved makes the module affected (doubt). So do a nested pom that does not
parse or names a coordinate that cannot be resolved, and a producer artifactId named in any text
file of the module's src/ (a test or the module's code may resolve it at run time; when only its
test sources name it, the module's own artifact does not change, so its dependents are not added).

A producer artifact can also reach a module through an external artifact (a jar of another
repository that depends on the producer). The external io.vidocq artifacts of the modules not
yet affected are "suspect" (assumption: only io.vidocq artifacts, or artifacts of the producer's
groups, can carry the producer; a third-party artifact wrapping or shading one is not seen);
with the dependency graph (inverted.json, opt-in), only those produced by a repository that
consumes the producer, directly or not, or unknown to the graph.

The parent chain and the BOM import chains that leave the reactor through an io.vidocq artifact
are followed through the poms of the local repository (--local-repo; Maven read them to build
the effective POM): a producer pom anywhere in a chain (an ancestor of an external parent, a BOM
imported by an external BOM or parent) makes the module affected; a chain pom that cannot be read
or an import version that cannot be resolved is a doubt (module affected); without the local
repository, every such chain is a doubt. Their closures
come from one Maven run on a synthetic project written to --synthetic (one module per
artifact, resolved as a pom so that no jar is downloaded; a dependency keeps the
dependencyManagement of the module that declares it):

  phase 1 (no --closures): when suspects exist, write the synthetic project and report
          decision "resolve"; the caller runs
          mvn -f DIR/pom.xml dependency:list -DoutputFile=deps.txt   (in DIR)
  phase 2 (--closures):    read DIR/m*/deps.txt and report the final decision.

The report (JSON) has "decision": "targeted" (the "skip" list holds the unaffected non-pom
modules, paths relative to the repository), "all" (every non-pom module is affected),
"resolve", or "full" with a "reason": the fallback on any doubt (empty producer set, a pom that
does not parse or cannot be located, an import the script cannot resolve, a producer artifact
or io.vidocq artifact as a core extension, a suspect external whose closure cannot be
established in a module not already affected, a closure Maven did not write).
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True     # no __pycache__ next to the action's scripts
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pommodel  # noqa: E402
from pommodel import PomError, child, children, text  # noqa: E402

VIDOCQ_GROUP = 'io.vidocq'
CLOSURE_KINDS = ('dependency', 'plugin', 'plugin dependency', 'extension', 'plugin configuration',
                 'plugin configuration text', 'nested build')
TEXT = 'plugin configuration text'


class Fallback(Exception):
    """A doubt: the build runs every test."""


def read_lines(path):
    with open(path, encoding='utf-8') as f:
        return [line.strip() for line in f if line.strip()]


def group_of(ga):
    return ga.split(':', 1)[0]


def is_vidocq(ga, producer_groups):
    g = group_of(ga)
    return g == VIDOCQ_GROUP or g.startswith(VIDOCQ_GROUP + '.') or g in producer_groups


def load_graph(path, producer_slug, changed):
    """(produced_by, reached repos) from inverted.json: the repositories that consume a
    producer artifact, directly or through the artifacts of another such repository. Every
    scope counts. Raises ValueError when the graph cannot be read."""
    with open(path, encoding='utf-8') as f:
        doc = json.load(f)
    arts = doc['artifacts']
    produced_by = {ga: a['produced_by'] for ga, a in arts.items()}
    reached = {producer_slug}
    frontier = set(changed) | {ga for ga, r in produced_by.items() if r == producer_slug}
    while frontier:
        repos = {c['repo'] for ga in frontier for c in arts.get(ga, {}).get('consumed_by', [])}
        new = repos - reached
        reached |= new
        frontier = {ga for ga, r in produced_by.items() if r in new}
    return produced_by, reached


def check_core_extensions(repo, changed, producer_groups):
    path = os.path.join(repo, '.mvn', 'extensions.xml')
    if not os.path.exists(path):
        return
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as e:
        raise Fallback(f'.mvn/extensions.xml does not parse: {e}')
    for e in children(root, 'extension'):
        ga = f"{text(e, 'groupId')}:{text(e, 'artifactId')}"
        if ga in changed or is_vidocq(ga, producer_groups):
            raise Fallback(f'core extension {ga} in .mvn/extensions.xml applies to every module')


class Analysis:
    def __init__(self, args):
        self.args = args
        self.repo = os.path.realpath(args.repo)
        self.changed = set(read_lines(args.producer_artifacts))
        if not self.changed:
            raise Fallback('the producer artifact set is empty (the producer artifacts could not '
                           'be listed after its rebuild)')
        self.producer_groups = {group_of(ga) for ga in self.changed}
        self.produced_by, self.reached, self.pruning = None, None, 'none (no dependency graph given)'
        if args.graph:
            try:
                self.produced_by, self.reached = load_graph(args.graph, args.producer_slug, self.changed)
                self.pruning = ('dependency graph: only the externals of '
                                + ', '.join(sorted(self.reached)) + ' or unknown to the graph')
            except Exception as e:  # noqa: BLE001 - any malformed graph: no pruning
                self.pruning = f'none (dependency graph unreadable: {e})'
        check_core_extensions(self.repo, self.changed, self.producer_groups)
        self.mods = pommodel.load_reactor(args.effective_pom)
        self.chains = (pommodel.ExternalChains(args.local_repo, self.changed)
                       if args.local_repo and os.path.isdir(args.local_repo) else None)
        self.rel = {}
        for ga, m in self.mods.items():
            r = os.path.relpath(os.path.realpath(m.basedir), self.repo)
            if r.startswith('..'):
                raise PomError(f'module {ga} lies outside the repository ({m.basedir})')
            self.rel[ga] = r

    def suspect(self, ga):
        if ga in self.mods or ga in self.changed or not is_vidocq(ga, self.producer_groups):
            return False
        if self.produced_by is None:
            return True
        owner = self.produced_by.get(ga)
        return owner is None or owner in self.reached

    @staticmethod
    def text_version(m, r):
        """Version of a coordinate written as text: its own, else the one the module manages
        or declares for that artifact."""
        if r.version and not pommodel.TOKEN.search(r.version):
            return r.version
        return m.dm_versions.get(r.ga) or next(
            (d.version for d in m.refs if d.kind == 'dependency' and d.ga == r.ga and d.version), None)

    def chain_reasons(self, m):
        """Reasons from the external io.vidocq parent chain and BOM import chains of m."""
        starts = []
        if m.parent and m.parent not in self.mods and is_vidocq(m.parent, self.producer_groups):
            starts.append(('parent', m.parent, m.parent_version))
        for ga in m.imports:
            if ga not in self.mods and is_vidocq(ga, self.producer_groups):
                starts.append(('BOM import', ga, m.import_versions.get(ga)))
        reasons = []
        for kind, ga, version in starts:
            if ga in self.changed:
                continue                      # already a direct reference
            if self.chains is None:
                reasons.append(f'{kind} {ga}: local repository unknown (doubt)')
                continue
            g, a = ga.split(':', 1)
            reasons += self.chains.walk(kind, g, a, version)
        return reasons

    def direct_hits(self):
        artifact_ids = {ga.split(':', 1)[1] for ga in self.changed}
        hits = {}
        for ga, m in self.mods.items():
            reasons = {f'{r.label()} {r.ga}' for r in m.all_refs() if r.ga in self.changed}
            for t in m.config_text:
                reasons |= {f'named in a plugin configuration: {c}' for c in self.changed if c in t}
            for r in m.refs:
                if r.kind != TEXT or r.ga in self.changed:
                    continue
                if pommodel.TOKEN.search(r.ga):
                    reasons.add(f'plugin configuration names {r.ga}, which cannot be resolved (doubt)')
                elif self.suspect(r.ga) and not self.text_version(m, r):
                    reasons.add(f'plugin configuration names {r.ga} without a version, closure unknown (doubt)')
            reasons |= set(m.doubts)
            reasons |= set(self.chain_reasons(m))
            if m.packaging != 'pom':
                main = pommodel.scan_sources(m, artifact_ids, where='main')
                reasons |= set(main)
                if not main:
                    tests = pommodel.scan_sources(m, artifact_ids, where='test')
                    if tests:
                        self.test_only[ga] = tests[0] + ' (tests only: dependents that do not use its test classes are not affected)'
            if reasons:
                hits[ga] = sorted(reasons)
        return hits

    def close(self, direct):
        """Direct hits closed over the reactor, plus the modules whose test sources only name a
        producer artifact: their tests run, their artifact does not change, so no dependent."""
        return pommodel.close_with_test_only({ga: '; '.join(sorted(r)) for ga, r in direct.items()},
                                             self.test_only, self.mods)

    def closure_needs(self, affected):
        """{key: entry} for the suspect externals of the modules not affected yet; key =
        (ga, version, dm hash). Raises Fallback for one whose version is unknown."""
        needs = {}
        for ga, m in sorted(self.mods.items()):
            if ga in affected:
                continue
            for r in m.all_refs():
                if r.kind not in CLOSURE_KINDS or r.ga in m.nested_local or not self.suspect(r.ga):
                    continue
                version = r.version
                if r.kind == TEXT:
                    version = self.text_version(m, r)
                elif not version and r.kind == 'plugin configuration':
                    version = m.dm_versions.get(r.ga) or None
                if not version or '${' in version or '@' in version:
                    raise Fallback(f'cannot establish the transitive closure of {r.ga} '
                                   f'({r.kind} of {self.rel[ga]}): no version')
                dm = m.dm_xml if r.kind == 'dependency' and m.dm_xml else ''
                key = (r.ga, version, hashlib.sha1(dm.encode()).hexdigest()[:12] if dm else '')
                e = needs.setdefault(key, {'ga': r.ga, 'version': version, 'dm': dm, 'refs': []})
                e['refs'].append((ga, r.kind))
        return needs

    def write_synthetic(self, needs):
        d = self.args.synthetic
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
        root = next((m for ga, m in self.mods.items() if self.rel[ga] == '.'), None)
        repos = root.repositories_xml if root else ''
        index, names = {}, []
        for i, key in enumerate(sorted(needs)):
            e = needs[key]
            name = f'm{i:03d}'
            names.append(name)
            index[name] = {'ga': e['ga'], 'version': e['version'], 'dm': key[2],
                           'modules': sorted({self.rel[ga] for ga, _ in e['refs']})}
            g, a = e['ga'].split(':', 1)
            os.makedirs(os.path.join(d, name))
            with open(os.path.join(d, name, 'pom.xml'), 'w', encoding='utf-8') as f:
                f.write('<?xml version="1.0" encoding="UTF-8"?>\n'
                        '<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion>'
                        '<parent><groupId>ci.targeted</groupId><artifactId>synthetic</artifactId>'
                        '<version>1</version></parent>'
                        f'<artifactId>{name}</artifactId>{e["dm"]}<dependencies><dependency>'
                        f'<groupId>{pommodel.escape(g)}</groupId><artifactId>{pommodel.escape(a)}</artifactId>'
                        f'<version>{pommodel.escape(e["version"])}</version><type>pom</type>'
                        '</dependency></dependencies></project>\n')
        with open(os.path.join(d, 'pom.xml'), 'w', encoding='utf-8') as f:
            f.write('<?xml version="1.0" encoding="UTF-8"?>\n'
                    '<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion>'
                    '<groupId>ci.targeted</groupId><artifactId>synthetic</artifactId><version>1</version>'
                    f'<packaging>pom</packaging>{repos}<modules>'
                    + ''.join(f'<module>{n}</module>' for n in names) + '</modules></project>\n')
        with open(os.path.join(d, 'index.json'), 'w', encoding='utf-8') as f:
            json.dump(index, f, indent=1, sort_keys=True)

    def read_closures(self, needs):
        d = self.args.synthetic
        try:
            with open(os.path.join(d, 'index.json'), encoding='utf-8') as f:
                index = json.load(f)
        except (OSError, ValueError) as e:
            raise Fallback(f'no synthetic project to read the closures from: {e}')
        by_key = {(e['ga'], e['version'], e['dm']): name for name, e in index.items()}
        hits = {}
        for key, e in needs.items():
            name = by_key.get(key)
            path = os.path.join(d, name, 'deps.txt') if name else None
            if not path or not os.path.exists(path):
                raise Fallback(f'the synthetic resolution wrote no closure for {e["ga"]}:{e["version"]}')
            found = pommodel.read_dependency_list(path) & self.changed
            for ga, kind in e['refs']:
                for x in sorted(found):
                    hits.setdefault(ga, set()).add(f'{x} via {kind} {e["ga"]}')
        return hits

    def run(self):
        self.test_only = {}
        direct = {ga: set(r) for ga, r in self.direct_hits().items()}
        affected = self.close(direct)
        needs = self.closure_needs(affected)
        report = {'pruning': self.pruning, 'synthetic': len(needs), 'modules': len(self.mods),
                  'direct': {self.rel[ga]: '; '.join(sorted(r)) for ga, r in sorted(direct.items())}}
        if needs and not self.args.closures:
            self.write_synthetic(needs)
            report.update(decision='resolve')
            return report
        if needs:
            for ga, reasons in self.read_closures(needs).items():
                direct.setdefault(ga, set()).update(reasons)
            affected = self.close(direct)
        skip = sorted(self.rel[ga] for ga, m in self.mods.items()
                      if ga not in affected and m.packaging != 'pom')
        report.update(
            decision='targeted' if skip else 'all',
            direct={self.rel[ga]: '; '.join(sorted(r)) for ga, r in sorted(direct.items())},
            affected={self.rel[ga]: why for ga, why in sorted(affected.items(), key=lambda kv: self.rel[kv[0]])},
            skip=skip)
        return report


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--effective-pom', required=True)
    ap.add_argument('--repo', required=True)
    ap.add_argument('--producer-artifacts', required=True)
    ap.add_argument('--synthetic', required=True)
    ap.add_argument('--report', required=True)
    ap.add_argument('--graph')
    ap.add_argument('--producer-slug', default='')
    ap.add_argument('--closures', action='store_true')
    ap.add_argument('--local-repo', help='the local Maven repository, to follow the external parent '
                    'and BOM import chains; without it an external io.vidocq chain is a doubt')
    args = ap.parse_args()
    try:
        if not os.path.exists(args.producer_artifacts):
            raise Fallback('the producer artifact set is missing (the producer artifacts could not '
                           'be listed after its rebuild)')
        report = Analysis(args).run()
    except Fallback as e:
        report = {'decision': 'full', 'reason': str(e)}
    except PomError as e:
        report = {'decision': 'full', 'reason': f'a pom cannot be read: {e}'}
    with open(args.report, 'w', encoding='utf-8') as f:
        json.dump(report, f, indent=1, sort_keys=True)
    print(f"decision: {report['decision']}" + (f" ({report['reason']})" if 'reason' in report else ''))


if __name__ == '__main__':
    main()
