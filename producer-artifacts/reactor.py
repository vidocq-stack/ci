"""The producer reactor's modules from its effective POM: version and install skip of each one.

read(EFF.xml) -> {groupId:artifactId: Module(version, install_skipped)}, with the same module
naming as build-one-consumer/targeted/producer-artifacts.py (groupId inherited from the parent).

A module skips install by design when its effective POM says so: maven-install-plugin's `skip`
configured to true in its build plugins (the plugin's configuration or its default-install
execution, which wins), else the `maven.install.skip` property set to true (the parameter's
property, read only when the configuration leaves `skip` unset). Such a module installs nothing in
the rebuild either (`mvn install` honours the same POM), so no consumer can depend on it at the PR
version. Anything else, such as a skip in pluginManagement only, counts as installing: the module
must then have installed files, else the artifacts are not shared and the consumers rebuild
(fail closed).
"""
from collections import namedtuple
import xml.etree.ElementTree as ET

Module = namedtuple('Module', 'version install_skipped')


def _strip(tag):
    return tag.split('}', 1)[1] if isinstance(tag, str) and tag.startswith('{') else tag


def _child(el, name):
    for c in (el if el is not None else []):
        if _strip(c.tag) == name:
            return c
    return None


def _children(el, name):
    return [c for c in (el if el is not None else []) if _strip(c.tag) == name]


def _text(el, name):
    c = _child(el, name)
    return (c.text or '').strip() if c is not None else ''


def _skip_value(config):
    skip = _child(config, 'skip')
    return None if skip is None else (skip.text or '').strip().lower() == 'true'


def _install_skipped(project):
    configured = None
    for plugin in _children(_child(_child(project, 'build'), 'plugins'), 'plugin'):
        if _text(plugin, 'artifactId') != 'maven-install-plugin' \
                or _text(plugin, 'groupId') not in ('', 'org.apache.maven.plugins'):
            continue
        value = _skip_value(_child(plugin, 'configuration'))
        if value is not None:
            configured = value
        for execution in _children(_child(plugin, 'executions'), 'execution'):
            if _text(execution, 'id') == 'default-install':
                value = _skip_value(_child(execution, 'configuration'))
                if value is not None:
                    configured = value
    if configured is not None:
        return configured
    return _text(_child(project, 'properties'), 'maven.install.skip').lower() == 'true'


def read(path):
    """Raise ET.ParseError or OSError when the file cannot be read."""
    root = ET.parse(path).getroot()
    projects = [root] if _strip(root.tag) == 'project' else _children(root, 'project')
    modules = {}
    for p in projects:
        parent = _child(p, 'parent')
        g = _text(p, 'groupId') or _text(parent, 'groupId')
        a = _text(p, 'artifactId')
        if g and a:
            modules[f'{g}:{a}'] = Module(_text(p, 'version') or _text(parent, 'version'), _install_skipped(p))
    return modules
