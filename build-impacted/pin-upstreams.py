#!/usr/bin/env python3
"""Pin upstream versions in a consumer checkout, in one pass.

Usage: pin-upstreams.py [--maven-args ARGS] --pin NAME=VERSION [--pin ...] DIR

Rewrites the project property <NAME.version> of every pom of the default Maven reactor of
DIR to VERSION, exactly as one `mvn versions:set-property -Dproperty=NAME.version` per
upstream does, without starting Maven:

- only poms of the reactor: the root pom, its <modules>, recursively, plus the modules of the
  profiles Maven would activate (no activation: only through -P; activeByDefault; property
  activation, env.* read from the environment, -D read from ARGS and .mvn/maven.config);
- only the property itself, a direct child of /project/properties: a plugin configuration
  element or a comment with the same name stays as it is;
- only the text of the element: everything else in the file stays byte for byte.

When the script cannot decide exactly what Maven would do (a profile activated by the JDK,
the OS, a file or a JVM system property, a pinned property defined in a profile, a module path
with an expression, a pom that does not parse...), it touches no file and exits with 3: the
caller then falls back to versions:set-property.
"""
import argparse
import os
import re
import shlex
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

UNDECIDABLE = 3
# Property activations Maven evaluates against JVM system properties the script cannot see.
JVM_PROPERTY_PREFIXES = ("java.", "os.", "user.", "file.", "line.", "path.", "sun.", "jdk.",
                         "maven.", "awt.", "native.", "stdout.", "stderr.")

TOKEN = re.compile(
    r"<!--.*?-->"
    r"|<!\[CDATA\[.*?\]\]>"
    r"|<\?.*?\?>"
    r"|<!DOCTYPE(?:[^>\[]|\[[^\]]*\])*>"
    r"|<(?P<close>/?)(?P<name>[^\s/>!?]+)"
    r"(?:\s+[^\s=/>]+\s*=\s*(?:\"[^\"]*\"|'[^']*'))*\s*(?P<empty>/?)>",
    re.S)


class Undecidable(Exception):
    pass


def local(tag):
    return tag.rsplit("}", 1)[-1].rsplit(":", 1)[-1]


def children(elem, name):
    return [c for c in elem if isinstance(c.tag, str) and local(c.tag) == name]


def child(elem, name):
    found = children(elem, name)
    return found[0] if found else None


def text(elem):
    return (elem.text or "").strip() if elem is not None else ""


def parse_maven_args(args):
    """Return (profiles explicitly activated, profiles deactivated, user properties)."""
    activated, deactivated, props = set(), set(), {}
    tokens = shlex.split(args)
    i = 0
    while i < len(tokens):
        t = tokens[i]
        value = None
        if t in ("-P", "--activate-profiles", "-D", "--define"):
            if i + 1 < len(tokens):
                value = tokens[i + 1]
                i += 1
            kind = "P" if t in ("-P", "--activate-profiles") else "D"
        elif t.startswith("--activate-profiles="):
            kind, value = "P", t.split("=", 1)[1]
        elif t.startswith("--define="):
            kind, value = "D", t.split("=", 1)[1]
        elif t.startswith("-P"):
            kind, value = "P", t[2:]
        elif t.startswith("-D"):
            kind, value = "D", t[2:]
        else:
            kind = None
        if kind == "P" and value is not None:
            for p in value.split(","):
                p = p.strip()
                if p.startswith(("!", "-")):
                    deactivated.add(p[1:])
                elif p.startswith("+"):
                    activated.add(p[1:])
                elif p:
                    activated.add(p)
        elif kind == "D" and value is not None:
            k, _, v = value.partition("=")
            props[k] = v if "=" in value else "true"
        i += 1
    return activated, deactivated, props


def property_value(name, props):
    if name in props:
        return props[name]
    if name.startswith("env."):
        return os.environ.get(name[4:])
    if name.startswith(JVM_PROPERTY_PREFIXES):
        raise Undecidable(f"profile activated by the JVM system property {name}")
    return None


def activation_matches(activation, props, pom):
    """Whether an <activation> holds by its conditions (activeByDefault handled apart)."""
    conditions = [c for c in activation if isinstance(c.tag, str)]
    matched = None
    for c in conditions:
        kind = local(c.tag)
        if kind == "activeByDefault":
            continue
        if kind != "property":
            raise Undecidable(f"{pom}: profile activated by <{kind}>")
        name, value = text(child(c, "name")), text(child(c, "value"))
        negate_name = name.startswith("!")
        name = name.lstrip("!")
        actual = property_value(name, props)
        if value:
            negate_value = value.startswith("!")
            ok = (actual == value.lstrip("!"))
            ok = not ok if negate_value else ok
        else:
            ok = bool(actual)
            ok = not ok if negate_name else ok
        matched = ok if matched is None else (matched and ok)
    return matched


def has_modules(profile):
    mods = child(profile, "modules")
    return mods is not None and bool(children(mods, "module"))


def active_profiles(root, activated, deactivated, props, pom):
    profiles = children(child(root, "profiles"), "profile") if child(root, "profiles") is not None else []
    default_with_modules = any(
        has_modules(p) and child(p, "activation") is not None
        and text(child(child(p, "activation"), "activeByDefault")) == "true"
        for p in profiles)
    active, by_default = [], []
    for p in profiles:
        pid = text(child(p, "id"))
        if pid in deactivated:
            continue
        if pid in activated:
            active.append(p)
            continue
        activation = child(p, "activation")
        if activation is None:
            continue
        try:
            matches = activation_matches(activation, props, pom)
        except Undecidable:
            # A profile that adds no module only matters when it could switch off an
            # activeByDefault profile that does.
            if has_modules(p) or default_with_modules:
                raise
            continue
        if matches:
            active.append(p)
        elif text(child(activation, "activeByDefault")) == "true":
            by_default.append(p)
    return active if active else by_default


def reactor(top, activated, deactivated, props):
    """The pom files of the default reactor, root first."""
    seen, order, todo = set(), [], [top / "pom.xml"]
    while todo:
        pom = todo.pop(0).resolve()
        if pom in seen:
            continue
        if not pom.is_file():
            raise Undecidable(f"module pom not found: {pom}")
        seen.add(pom)
        order.append(pom)
        try:
            root = ET.parse(pom).getroot()
        except ET.ParseError as e:
            raise Undecidable(f"{pom}: {e}")
        holders = [root] + active_profiles(root, activated, deactivated, props, pom)
        for h in holders:
            mods = child(h, "modules")
            for m in children(mods, "module") if mods is not None else []:
                path = text(m)
                if "${" in path:
                    raise Undecidable(f"{pom}: module path with an expression: {path}")
                target = pom.parent / path
                todo.append(target if target.is_file() else target / "pom.xml")
    return order


def rewrite(pom, pins):
    """Return (new text, names pinned) for one pom; raise Undecidable on any doubt."""
    raw = pom.read_bytes()
    content = raw.decode("utf-8")
    root = ET.fromstring(raw)
    wanted = {f"{n}.version": n for n in pins}
    for prof in children(child(root, "profiles"), "profile") if child(root, "profiles") is not None else []:
        pprops = child(prof, "properties")
        for c in pprops if pprops is not None else []:
            if isinstance(c.tag, str) and local(c.tag) in wanted:
                raise Undecidable(f"{pom}: {local(c.tag)} defined in profile {text(child(prof, 'id'))}")

    stack, edits, names = [], [], []
    tokens = list(TOKEN.finditer(content))
    for i, tok in enumerate(tokens):
        name = tok.group("name")
        if name is None:
            continue
        lname = local(name)
        if tok.group("close"):
            if stack:
                stack.pop()
            continue
        is_target = lname in wanted and [local(s) for s in stack] == ["project", "properties"]
        if tok.group("empty"):
            if is_target:
                raise Undecidable(f"{pom}: <{lname}/> is empty")
            continue
        if is_target:
            nxt = tokens[i + 1] if i + 1 < len(tokens) else None
            if nxt is None or nxt.group("close") != "/" or local(nxt.group("name") or "") != lname:
                raise Undecidable(f"{pom}: <{lname}> does not hold plain text")
            if lname in [n + ".version" for n in names]:
                raise Undecidable(f"{pom}: <{lname}> defined twice")
            edits.append((tok.end(), nxt.start(), pins[wanted[lname]]))
            names.append(wanted[lname])
        stack.append(name)
    new = content
    for start, end, value in reversed(edits):
        new = new[:start] + value + new[end:]
    return new, names


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--maven-args", default="")
    ap.add_argument("--pin", action="append", default=[], metavar="NAME=VERSION")
    ap.add_argument("dir")
    a = ap.parse_args(argv)
    pins = dict(p.split("=", 1) for p in a.pin)
    top = Path(a.dir)
    try:
        args = a.maven_args
        config = top / ".mvn" / "maven.config"
        if config.is_file():
            args = config.read_text(encoding="utf-8") + " " + args
        # -D in MAVEN_OPTS are JVM system properties, which profile activation reads too.
        args = os.environ.get("MAVEN_OPTS", "") + " " + args
        activated, deactivated, props = parse_maven_args(args)
        poms = reactor(top, activated, deactivated, props)
        results = [(pom, *rewrite(pom, pins)) for pom in poms]
    except Undecidable as e:
        print(f"pin-upstreams: cannot decide without Maven: {e}", file=sys.stderr)
        return UNDECIDABLE
    except (OSError, UnicodeDecodeError, ET.ParseError, ValueError) as e:
        print(f"pin-upstreams: cannot decide without Maven: {e}", file=sys.stderr)
        return UNDECIDABLE

    pinned, changed = set(), 0
    for pom, new, names in results:
        pinned.update(names)
        if names:
            pom.write_bytes(new.encode("utf-8"))
            changed += 1
    for n in sorted(pinned):
        print(f"  set {n}.version={pins[n]}")
    print(f"  pinned {len(pinned)} upstream version(s) in {changed} pom(s) of {len(poms)} in the reactor")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
