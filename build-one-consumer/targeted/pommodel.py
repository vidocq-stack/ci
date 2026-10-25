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
    __slots__ = ('ga', 'version', 'kind', 'scope')

    def __init__(self, ga, version, kind, scope=''):
        self.ga, self.version, self.kind, self.scope = ga, version or None, kind, scope

    def label(self):
        return f'{self.kind}({self.scope})' if self.scope else self.kind


class Module:
    def __init__(self):
        self.group_id = self.artifact_id = self.version = ''
        self.packaging = 'jar'
        self.basedir = ''
        self.parent = None            # GA of the parent, or None
        self.properties = {}
        self.refs = []                # [Ref] from the effective model
        self.config_text = []         # text of plugin configurations ("g:a" strings)
        self.dm_xml = None            # <dependencyManagement> as plain XML, or None
        self.dm_versions = {}         # GA -> managed version
        self.repositories_xml = ''    # <repositories> + <pluginRepositories>, plain XML
        self.nested_refs = []         # [Ref] named by nested builds under src/
        self.nested_local = set()     # GA declared by those nested poms themselves
        self.nested_unreadable = []   # nested poms that do not parse
        self.imports = []             # GA of BOM imports in the raw pom (dependencyManagement)

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

    def interpolate(self, value):
        """Resolve @prop@ and ${prop} from the module's effective properties; None if a token
        is left (filtering tokens a nested build would resolve some other way)."""
        if not value:
            return None
        builtins = {'project.version': self.version, 'project.groupId': self.group_id,
                    'project.artifactId': self.artifact_id, 'version': self.version,
                    'groupId': self.group_id, 'artifactId': self.artifact_id}

        def sub(m):
            key = m.group(1) or m.group(2)
            return self.properties.get(key, builtins.get(key, m.group(0)))
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
    props = child(p, 'properties')
    for prop in (list(props) if props is not None else []):
        if isinstance(strip(prop.tag), str):
            m.properties[strip(prop.tag)] = (prop.text or '').strip()
    for d in children(child(p, 'dependencies'), 'dependency'):
        m.refs.append(Ref(f"{text(d, 'groupId')}:{text(d, 'artifactId')}", text(d, 'version'),
                          'dependency', text(d, 'scope', 'compile')))
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
                              'plugin dependency'))
        _scan_config(child(pl, 'configuration'), m, 'plugin configuration')
        for ex in children(child(pl, 'executions'), 'execution'):
            _scan_config(child(ex, 'configuration'), m, 'plugin configuration')
    return m


NESTED_ELEMENTS = ('dependency', 'plugin', 'path', 'artifactItem', 'extension')


def scan_nested(m):
    """Nested builds (maven-invoker-plugin ITs, test projects run by a test) resolve artifacts
    their module never declares. Every pom.xml under the module's src/ is read as plain XML and
    its references are recorded, with versions resolved from the module's properties where they
    are filtering tokens (@x.version@, ${project.version}). Any module is scanned, with or
    without the invoker plugin."""
    src = os.path.join(m.basedir, 'src')
    if not os.path.isdir(src):
        return
    for d, dirs, files in os.walk(src):
        dirs[:] = sorted(x for x in dirs if x != 'target' and not x.startswith('.'))
        if 'pom.xml' not in files:
            continue
        path = os.path.join(d, 'pom.xml')
        try:
            p = ET.parse(path).getroot()
        except (ET.ParseError, OSError):
            m.nested_unreadable.append(os.path.relpath(path, m.basedir))
            continue
        parent = child(p, 'parent')
        own_group = text(p, 'groupId') or text(parent, 'groupId')
        if text(p, 'artifactId'):
            m.nested_local.add(f"{own_group}:{text(p, 'artifactId')}")
        if parent is not None:
            m.nested_refs.append(Ref(f"{text(parent, 'groupId')}:{text(parent, 'artifactId')}",
                                     m.interpolate(text(parent, 'version')), 'nested build'))
        for el in p.iter():
            tag = strip(el.tag)
            if tag not in NESTED_ELEMENTS:
                continue
            a = text(el, 'artifactId')
            g = text(el, 'groupId') or (DEFAULT_PLUGIN_GROUP if tag == 'plugin' else '')
            g = g.replace('${project.groupId}', own_group).replace('${project.parent.groupId}',
                                                                  text(parent, 'groupId'))
            if a and g:
                m.nested_refs.append(Ref(f'{g}:{a}', m.interpolate(text(el, 'version')), 'nested build'))


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
        scan_nested(m)
        mods[m.ga] = m
    return mods


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
