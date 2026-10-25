"""Model of a Maven reactor read from `mvn help:effective-pom -Doutput=FILE`.

The effective POM is Maven's own view of each module, with parents merged, properties
interpolated, managed versions filled in and the active profiles applied: the analysis reads
it, never the raw poms, except for the two things the effective POM no longer shows (the BOM
imports, which it inlines, and the poms of nested builds under src/, which it does not know).

Every reference a module makes to another artifact is kept with its kind (dependency of a
given scope, plugin, plugin dependency, build extension, artifact named in a plugin
configuration such as annotationProcessorPaths, parent, BOM import, nested build): a module is
affected by an artifact when any of them names it.
"""
import os
import re
import xml.etree.ElementTree as ET
from collections import defaultdict, deque

DEFAULT_PLUGIN_GROUP = 'org.apache.maven.plugins'
TOKEN = re.compile(r'@([^@\s]+)@|\$\{([^}\s]+)\}')


class PomError(Exception):
    """A pom that cannot be read: the caller falls back to the full build."""


def strip(tag):
    return tag.split('}', 1)[1] if isinstance(tag, str) and tag.startswith('{') else tag


def child(el, name):
    if el is None:
        return None
    for c in el:
        if strip(c.tag) == name:
            return c
    return None


def children(el, name):
    return [] if el is None else [c for c in el if strip(c.tag) == name]


def text(el, name, default=''):
    c = child(el, name)
    if c is None or c.text is None:
        return default
    return c.text.strip() or default


def plain_xml(el):
    """Serialise an element without XML namespaces (for the synthetic poms)."""
    tag = strip(el.tag)
    if not isinstance(tag, str):          # comments, processing instructions
        return ''
    inner = ''.join(plain_xml(c) + (escape(c.tail) if c.tail and c.tail.strip() else '') for c in el)
    body = escape(el.text) if el.text and el.text.strip() else ''
    return f'<{tag}>{body}{inner}</{tag}>'


def escape(s):
    return s.strip().replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


class Ref:
    """One reference from a module to an artifact."""
    __slots__ = ('ga', 'version', 'kind', 'scope', 'type', 'classifier')

    def __init__(self, ga, version, kind, scope='', type='', classifier=''):
        self.ga, self.version, self.kind, self.scope = ga, version or None, kind, scope
        self.type, self.classifier = type or '', classifier or ''

    def uses_test_classes(self):
        """True when the reference may reach the referenced module's TEST classes: a test-jar
        type, any classifier or non-jar type, a plugin configuration (dependenciesToScan...) or
        a nested build."""
        return (self.type not in ('', 'jar', 'pom') or bool(self.classifier)
                or self.kind in ('plugin configuration', 'plugin configuration text', 'nested build'))

    def label(self):
        return f'{self.kind}({self.scope})' if self.scope else self.kind


class Module:
    def __init__(self):
        self.group_id = self.artifact_id = self.version = ''
        self.packaging = 'jar'
        self.basedir = ''
        self.parent = None            # GA of the parent, or None
        self.parent_version = None
        self.properties = {}
        self.refs = []                # [Ref] from the effective model
        self.config_text = []         # text of plugin configurations ("g:a" strings)
        self.dm_xml = None            # <dependencyManagement> as plain XML, or None
        self.dm_versions = {}         # GA -> managed version
        self.repositories_xml = ''    # <repositories> + <pluginRepositories>, plain XML
        self.nested_refs = []         # [Ref] named by nested builds under src/
        self.nested_local = set()     # GA declared by those nested poms themselves
        self.doubts = []              # reasons to treat the module as affected (unreadable or
                                      # unresolvable nested coordinates, ...)
        self.imports = []             # GA of BOM imports in the raw pom (dependencyManagement)
        self.import_versions = {}     # GA -> version of those imports (None: unresolved)

    @property
    def ga(self):
        return f'{self.group_id}:{self.artifact_id}'

    def all_refs(self):
        out = list(self.refs)
        if self.parent:
            out.append(Ref(self.parent, None, 'parent'))
        out += [Ref(ga, None, 'BOM import') for ga in self.imports]
        out += self.nested_refs
        return out

    def interpolate(self, value, own=None):
        """Resolve @prop@ and ${prop} from the module's effective properties; None if a token
        is left (filtering tokens a nested build would resolve some other way). @x@ is a
        filtering token of the outer build; in ${x}, the project.* values come from `own` (the
        nested project's own groupId and version) when given."""
        if not value:
            return None
        outer = {'project.version': self.version, 'project.groupId': self.group_id,
                 'project.artifactId': self.artifact_id, 'version': self.version,
                 'groupId': self.group_id, 'artifactId': self.artifact_id}

        def sub(mt):
            key = mt.group(1) or mt.group(2)
            if mt.group(2) and own and key in own:
                return own[key]
            return self.properties.get(key, outer.get(key, mt.group(0)))
        out = TOKEN.sub(sub, value)
        return None if TOKEN.search(out) else out


def _scan_config(cfg, m, kind):
    """Every element of a plugin configuration that has both a groupId and an artifactId
    (annotationProcessorPaths, artifactItems, additionalClasspathDependencies...), and every
    text, for "groupId:artifactId" strings."""
    if cfg is None:
        return
    for el in cfg.iter():
        g, a = text(el, 'groupId'), text(el, 'artifactId')
        if g and a:
            m.refs.append(Ref(f'{g}:{a}', text(el, 'version'), kind))
        if el.text and el.text.strip():
            m.config_text.append(el.text.strip())
            for g, a, v in text_coordinates(el.text):
                m.refs.append(Ref(f'{g}:{a}', v, 'plugin configuration text'))


COORDINATE = re.compile(r'^([^:/\\\s]+):([^:/\\\s]+)((?::[^:/\\\s]*)*)$')


def text_coordinates(value):
    """(groupId, artifactId, version or None) of every token of a configuration text that has
    the shape of a Maven coordinate g:a[:extension[:classifier]][:version], groupId with a dot
    (or an unresolved token). Tokens are separated by whitespace, commas and semicolons."""
    out = []
    for tok in re.split(r'[\s,;]+', value):
        mt = COORDINATE.match(tok)
        if not mt:
            continue
        g, a, rest = mt.groups()
        if '.' not in g and not TOKEN.search(g):
            continue
        segs = [x for x in rest.split(':') if x]
        out.append((g, a, segs[-1] if segs else None))
    return out


def _parse_project(p):
    m = Module()
    parent = child(p, 'parent')
    m.artifact_id = text(p, 'artifactId')
    m.group_id = text(p, 'groupId') or text(parent, 'groupId')
    m.version = text(p, 'version') or text(parent, 'version')
    m.packaging = text(p, 'packaging', 'jar')
    if not m.artifact_id or not m.group_id:
        raise PomError('a project of the effective POM has no groupId or artifactId')
    if parent is not None:
        m.parent = f"{text(parent, 'groupId')}:{text(parent, 'artifactId')}"
        m.parent_version = text(parent, 'version') or None
    props = child(p, 'properties')
    for prop in (list(props) if props is not None else []):
        if isinstance(strip(prop.tag), str):
            m.properties[strip(prop.tag)] = (prop.text or '').strip()
    for d in children(child(p, 'dependencies'), 'dependency'):
        m.refs.append(Ref(f"{text(d, 'groupId')}:{text(d, 'artifactId')}", text(d, 'version'),
                          'dependency', text(d, 'scope', 'compile'), text(d, 'type'), text(d, 'classifier')))
    dm = child(p, 'dependencyManagement')
    if dm is not None:
        m.dm_xml = plain_xml(dm)
        for d in children(child(dm, 'dependencies'), 'dependency'):
            m.dm_versions.setdefault(f"{text(d, 'groupId')}:{text(d, 'artifactId')}", text(d, 'version'))
    m.repositories_xml = ''.join(plain_xml(child(p, n)) for n in ('repositories', 'pluginRepositories')
                                 if child(p, n) is not None)
    build = child(p, 'build')
    directory = text(build, 'directory')
    if not directory:
        raise PomError(f'{m.ga}: no build directory in the effective POM, cannot locate the module')
    m.basedir = os.path.dirname(directory)
    for e in children(child(build, 'extensions'), 'extension'):
        m.refs.append(Ref(f"{text(e, 'groupId')}:{text(e, 'artifactId')}", text(e, 'version'), 'extension'))
    for pl in children(child(build, 'plugins'), 'plugin'):
        m.refs.append(Ref(f"{text(pl, 'groupId', DEFAULT_PLUGIN_GROUP)}:{text(pl, 'artifactId')}",
                          text(pl, 'version'), 'plugin'))
        for d in children(child(pl, 'dependencies'), 'dependency'):
            m.refs.append(Ref(f"{text(d, 'groupId')}:{text(d, 'artifactId')}", text(d, 'version'),
                              'plugin dependency', '', text(d, 'type'), text(d, 'classifier')))
        _scan_config(child(pl, 'configuration'), m, 'plugin configuration')
        for ex in children(child(pl, 'executions'), 'execution'):
            _scan_config(child(ex, 'configuration'), m, 'plugin configuration')
    return m


NESTED_ELEMENTS = ('dependency', 'plugin', 'path', 'artifactItem', 'extension')


def scan_nested(m, reactor_dirs=()):
    """Nested builds (maven-invoker-plugin ITs, test projects run by a test, fixtures) resolve
    artifacts their module never declares. Every pom.xml under the module's directory (not its
    own, not under target/ or a hidden directory, not in another reactor module) is read as
    plain XML and its references are recorded, with coordinates resolved from the module's
    properties where they are filtering tokens (@x.version@) and from the nested project itself
    for ${project.version}. Any module is scanned, with or without the invoker plugin. A nested
    pom that does not parse, or names a groupId or artifactId that cannot be resolved, is a
    doubt: the module counts as affected."""
    skip = {os.path.realpath(x) for x in reactor_dirs} - {os.path.realpath(m.basedir)}
    if not os.path.isdir(m.basedir):
        return
    own_pom = os.path.realpath(os.path.join(m.basedir, 'pom.xml'))
    for d, dirs, files in os.walk(m.basedir):
        dirs[:] = sorted(x for x in dirs if x != 'target' and not x.startswith('.')
                         and os.path.realpath(os.path.join(d, x)) not in skip)
        path = os.path.join(d, 'pom.xml')
        if 'pom.xml' not in files or os.path.realpath(path) == own_pom:
            continue
        rel = os.path.relpath(path, m.basedir)
        try:
            p = ET.parse(path).getroot()
        except (ET.ParseError, OSError):
            m.doubts.append(f'nested pom {rel} does not parse (doubt)')
            continue
        parent = child(p, 'parent')
        own = {'project.groupId': text(p, 'groupId') or text(parent, 'groupId'),
               'project.version': text(p, 'version') or text(parent, 'version'),
               'project.parent.groupId': text(parent, 'groupId'),
               'project.parent.version': text(parent, 'version')}
        own['groupId'], own['version'] = own['project.groupId'], own['project.version']
        props = child(p, 'properties')
        for prop in (list(props) if props is not None else []):
            if isinstance(strip(prop.tag), str):
                own.setdefault(strip(prop.tag), (prop.text or '').strip())
        own = {k: v for k, v in own.items() if v and not TOKEN.search(v)}
        if text(p, 'artifactId'):
            m.nested_local.add(f"{own.get('project.groupId', '')}:{text(p, 'artifactId')}")
        elements = [parent] if parent is not None else []
        elements += [el for el in p.iter() if strip(el.tag) in NESTED_ELEMENTS]
        for el in elements:
            tag = strip(el.tag)
            raw_g = text(el, 'groupId') or (DEFAULT_PLUGIN_GROUP if tag == 'plugin' else '')
            raw_a = text(el, 'artifactId')
            if not raw_g or not raw_a:
                continue
            g, a = m.interpolate(raw_g, own), m.interpolate(raw_a, own)
            if not g or not a:
                m.doubts.append(f'nested pom {rel} names {raw_g}:{raw_a}, which cannot be resolved (doubt)')
                continue
            m.nested_refs.append(Ref(f'{g}:{a}', m.interpolate(text(el, 'version'), own), 'nested build',
                                     '', text(el, 'type'), text(el, 'classifier')))


def scan_raw_imports(m):
    """The effective POM inlines the BOMs a module imports: read them from its raw pom.xml.
    Raises PomError when the pom does not parse, is not the module the effective POM put
    there, or names an import Maven would resolve from something the script cannot see."""
    path = os.path.join(m.basedir, 'pom.xml')
    try:
        p = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as e:
        raise PomError(f'{path}: {e}')
    if text(p, 'artifactId') != m.artifact_id:
        raise PomError(f'{path} is not the pom of {m.ga} (artifactId {text(p, "artifactId")!r})')
    dm = child(child(p, 'dependencyManagement'), 'dependencies')
    for d in children(dm, 'dependency'):
        if text(d, 'scope') != 'import':
            continue
        g, a = m.interpolate(text(d, 'groupId')), m.interpolate(text(d, 'artifactId'))
        if not g or not a:
            raise PomError(f'{path}: cannot resolve the BOM import '
                           f"{text(d, 'groupId')}:{text(d, 'artifactId')}")
        m.imports.append(f'{g}:{a}')
        m.import_versions[f'{g}:{a}'] = m.interpolate(text(d, 'version'))


def load_reactor(path):
    """GA -> Module for every project of an effective-POM file (one <project> or a
    <projects> document), nested builds and raw BOM imports included."""
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as e:
        raise PomError(f'effective POM {path}: {e}')
    if strip(root.tag) == 'project':
        projects = [root]
    else:
        projects = [c for c in root if strip(c.tag) == 'project']
    if not projects:
        raise PomError(f'effective POM {path}: no project')
    mods = {}
    for p in projects:
        m = _parse_project(p)
        scan_raw_imports(m)
        mods[m.ga] = m
    # pom-packaged modules run no tests of their own that this mode could skip, and their
    # children inherit their model, not their nested builds: scanning them would only turn the
    # profile-only modules under an aggregator (TCK runners...) into reasons to affect every child.
    dirs = [m.basedir for m in mods.values()]
    for m in mods.values():
        if m.packaging != 'pom':
            scan_nested(m, dirs)
    return mods


JVM_SOURCES = ('.java', '.kt', '.groovy', '.scala')
BLOCK_COMMENT = re.compile(r'/\*.*?\*/', re.S)
LINE_COMMENT = re.compile(r'(?m)^\s*//.*$')
TRAILING_COMMENT = re.compile(r'(?m)(;|\{|\}|\))\s*//.*$')


def strip_comments(source):
    """Remove Javadoc and block comments, whole-line // comments, and // comments after a
    statement end (;, {, } or )): a name there is never resolved at run time. Known limit: a
    comment marker inside a string literal ("/*", or "); //") may drop the rest of that literal
    from the search; rare, accepted."""
    source = BLOCK_COMMENT.sub(' ', source)
    source = LINE_COMMENT.sub('', source)
    return TRAILING_COMMENT.sub(r'\1', source)


TEST_SOURCE_DIRS = ('test', 'it', 'testFixtures', 'integration-test')


def is_test_source(rel):
    """True for a path under src/test/, src/it/, ... (relative to the module directory)."""
    parts = rel.replace(os.sep, '/').split('/')
    return len(parts) > 1 and parts[0] == 'src' and (parts[1] in TEST_SOURCE_DIRS or parts[1].startswith('test'))


def scan_sources(m, artifact_ids, cap=1 << 20, where=None):
    """Reasons for a module whose src/ names a producer artifact as text: a test or a tool may
    resolve it at run time (ShrinkWrap, a CLI, the local repository by coordinates). Any text
    file counts (binary files, with a NUL byte, and files over `cap` bytes are skipped); the
    artifactId must stand alone, so "groupId:artifactId[:version]" matches too. `where`:
    None (every file under src/), 'main' (not under a test source directory) or 'test'."""
    if not artifact_ids:
        return []
    rx = re.compile(r'(?<![\w.-])(' + '|'.join(re.escape(a) for a in sorted(artifact_ids, key=len, reverse=True))
                    + r')(?![\w-])')
    src = os.path.join(m.basedir, 'src')
    for d, dirs, files in os.walk(src):
        dirs[:] = sorted(x for x in dirs if x != 'target' and not x.startswith('.'))
        for name in sorted(files):
            path = os.path.join(d, name)
            if where is not None and is_test_source(os.path.relpath(path, m.basedir)) != (where == 'test'):
                continue
            try:
                if os.path.getsize(path) > cap:
                    continue
                with open(path, 'rb') as f:
                    data = f.read()
            except OSError:
                continue
            if b'\0' in data[:8192]:
                continue
            content = data.decode('utf-8', errors='ignore')
            if name.endswith(JVM_SOURCES):
                content = strip_comments(content)
            hit = rx.search(content)
            if hit:
                return [f'producer artifact {hit.group(1)} named in {os.path.relpath(path, m.basedir)}']
    return []


def reactor_dependents(mods):
    """dependents[R] = reactor modules that reference reactor module R, by any kind of
    reference (the edges of Maven's -amd, plus annotation processor paths, plugin
    configurations and nested builds)."""
    dependents = defaultdict(set)
    for m in mods.values():
        for r in m.all_refs():
            if r.ga in mods and r.ga != m.ga:
                dependents[r.ga].add(m.ga)
    return dependents


def close_dependents(seeds, mods):
    """{ga: reason} for the seeds and every reactor module depending on them, transitively."""
    dependents = reactor_dependents(mods)
    reason = dict(seeds)
    queue = deque(sorted(seeds))
    while queue:
        cur = queue.popleft()
        for d in sorted(dependents.get(cur, ())):
            if d not in reason:
                reason[d] = f'depends on reactor module {mods[cur].artifact_id}'
                queue.append(d)
    return reason


def close_with_test_only(seeds, test_only, mods):
    """close_dependents of the seeds, plus the "test-only" modules (only their tests may observe
    the change, their main artifact does not change): they are affected without their plain
    dependents, but a module that reaches their test classes (Ref.uses_test_classes: a test-jar
    or tests classifier, a plugin configuration such as dependenciesToScan, a nested build)
    becomes a seed in turn, and so on."""
    seeds = dict(seeds)
    while True:
        affected = close_dependents(seeds, mods)
        for ga, why in test_only.items():
            affected.setdefault(ga, why)
        more = {}
        for t in test_only:
            for ga, m in mods.items():
                if ga in affected or ga in more:
                    continue
                if any(r.ga == t and r.uses_test_classes() for r in m.all_refs()):
                    more[ga] = f'uses the test classes of {mods[t].artifact_id}'
        if not more:
            return affected
        seeds.update(more)


def read_dependency_list(path):
    """The groupId:artifactId of every artifact listed in a `dependency:list -DoutputFile`
    file (lines like '   g:a:jar:1.0:compile -- module x')."""
    out = set()
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            tok = line.strip().split()
            if not tok:
                continue
            parts = tok[0].split(':')
            if len(parts) >= 4 and parts[0] and parts[1]:
                out.add(f'{parts[0]}:{parts[1]}')
    return out


class ExternalChains:
    """Parent chains and BOM import chains that leave the reactor. The effective POM merges
    what they contribute, but not which poms they went through: a producer pom can sit among
    the ancestors of an external parent, or be imported by an external BOM. Their poms are in
    the local repository once Maven has built the effective POM. A pom that cannot be read, or an
    import version that cannot be resolved, is a doubt."""

    def __init__(self, local_repo, changed):
        self.local_repo = local_repo
        self.changed = changed
        self._poms = {}
        self._props = {}

    def pom(self, g, a, v):
        """{'parent': (g, a, v) | None, 'props': {...}, 'imports': [(g, a, raw version)]}, or
        None when the pom is not in the local repository or does not parse."""
        key = (g, a, v)
        if key not in self._poms:
            path = os.path.join(self.local_repo, *g.split('.'), a, v, f'{a}-{v}.pom')
            try:
                p = ET.parse(path).getroot()
            except (ET.ParseError, OSError):
                self._poms[key] = None
                return None
            parent = child(p, 'parent')
            props_el = child(p, 'properties')
            dm = child(child(p, 'dependencyManagement'), 'dependencies')
            self._poms[key] = {
                'parent': ((text(parent, 'groupId'), text(parent, 'artifactId'), text(parent, 'version'))
                           if parent is not None else None),
                'props': {strip(c.tag): (c.text or '').strip()
                          for c in (list(props_el) if props_el is not None else []) if isinstance(strip(c.tag), str)},
                'imports': [(text(d, 'groupId'), text(d, 'artifactId'), text(d, 'version'))
                            for d in children(dm, 'dependency') if text(d, 'scope') == 'import'],
            }
        return self._poms[key]

    def props(self, g, a, v):
        """The properties a pom sees: its parent chain's, then its own, then project.*."""
        key = (g, a, v)
        if key not in self._props:
            self._props[key] = {}             # cycle guard
            node = self.pom(g, a, v)
            out = {}
            if node and node['parent']:
                out.update(self.props(*node['parent']))
            if node:
                out.update(node['props'])
            out.update({'project.groupId': g, 'project.artifactId': a, 'project.version': v,
                        'groupId': g, 'version': v})
            if node and node['parent']:
                out['project.parent.version'] = node['parent'][2]
            self._props[key] = out
        return self._props[key]

    def walk(self, kind, g, a, v):
        """Reasons the chain that starts at g:a:v makes a module affected (empty: none)."""
        reasons, seen = [], set()

        def label(path):
            return f'{kind} chain ' + ' > '.join(':'.join(x) for x in path)

        def visit(node_gav, path):
            if node_gav in seen:
                return
            seen.add(node_gav)
            path = path + [node_gav]
            if f'{node_gav[0]}:{node_gav[1]}' in self.changed:
                reasons.append(f'{label(path)} reaches the producer')
                return
            if TOKEN.search(':'.join(node_gav)) or not all(node_gav):
                reasons.append(f'{label(path)}: {":".join(node_gav)} cannot be resolved (doubt)')
                return
            node = self.pom(*node_gav)
            if node is None:
                reasons.append(f'{label(path)}: {":".join(node_gav)} cannot be read (doubt)')
                return
            if node['parent']:
                visit(node['parent'], path)
            props = self.props(*node_gav)
            for ig, ia, iv in node['imports']:
                rg, ra, rv = (_interpolate(x, props) for x in (ig, ia, iv))
                if not rg or not ra or not rv:
                    reasons.append(f'{label(path)} names import {ig}:{ia}:{iv}, which cannot be resolved (doubt)')
                    continue
                visit((rg, ra, rv), path)

        visit((g, a, v or ''), [])
        return reasons


def _interpolate(value, props):
    if not value:
        return None
    out = TOKEN.sub(lambda mt: props.get(mt.group(1) or mt.group(2), mt.group(0)), value)
    return None if TOKEN.search(out) else out
