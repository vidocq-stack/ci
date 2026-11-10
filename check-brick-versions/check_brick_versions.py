#!/usr/bin/env python3
"""Guard against io.vidocq brick version skew (Vidocq/ci#19). Report mode: findings are
::warning annotations, the exit status is 0 unless --strict.

Usage: check_brick_versions.py --repo OWNER/NAME --pom-dir DIR [--strict]
                               [--forge URL] [--graph-repo OWNER/NAME] [--graph-ref REF]
                               [--central URL] [--token-env VAR]
                               [--graph FILE] [--releases FILE] [--devs FILE]   (offline/test)

For the checked repository NAME and its poms under DIR, with the brick set taken from the
dependency graph (a brick is a producer repository, its property is `<brick>.version`):

  1. every literal `<brick>.version` of another brick must be the latest release of that brick on
     Maven Central, or the brick's current development version (root version of its main). Anything
     else is a stale pin: typically the SNAPSHOT of a line that was released since (0.3.0-SNAPSHOT
     after 0.3.0), which the producer no longer publishes.
  2. the repository's own root version, when it is a SNAPSHOT, must not be superseded by its own
     latest release (a brick left on 0.3.0-SNAPSHOT after 0.3.0 shipped) nor lag the development line
     (the highest development version among the bricks).

--releases / --devs take JSON files {"brick": "version"} instead of querying Central and the forge
(tests). Network failures for one brick skip that brick: a guard must not turn red on an outage.
"""
import argparse
import json
import os
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

NUM = re.compile(r"^(\d+(?:\.\d+)*)")
RELEASE = re.compile(r"^\d+(?:\.\d+)*$")


def vkey(v):
    m = NUM.match(v or "")
    return tuple(int(p) for p in m.group(1).split(".")) if m else None


def is_snapshot(v):
    return (v or "").endswith("-SNAPSHOT")


def base(v):
    return v[: -len("-SNAPSHOT")] if is_snapshot(v) else v


def local(tag):
    return tag.rsplit("}", 1)[-1]


def read_poms(pom_dir):
    """Yield (path, root element) of every pom.xml under pom_dir that parses; target/ is skipped."""
    for p in sorted(Path(pom_dir).rglob("pom.xml")):
        if "target" in p.relative_to(pom_dir).parts:
            continue
        try:
            yield p, ET.parse(p).getroot()
        except ET.ParseError:
            continue


def own_version(pom_dir):
    root = ET.parse(Path(pom_dir) / "pom.xml").getroot()
    for c in root:
        if local(c.tag) == "version":
            return (c.text or "").strip()
    return ""


def property_pins(pom_dir, names):
    """[(pom path, property, literal value)] of the `<name>.version` project properties, direct
    children of /project/properties only."""
    wanted = {f"{n}.version": n for n in names}
    found = []
    for path, root in read_poms(pom_dir):
        for props in (c for c in root if local(c.tag) == "properties"):
            for c in props:
                t = local(c.tag) if isinstance(c.tag, str) else ""
                v = (c.text or "").strip()
                if t in wanted and v and "${" not in v:
                    found.append((str(path.relative_to(pom_dir)), t, v))
    return found


def evaluate(repo_short, own, pins, releases, devs):
    """Pure decision. Returns a list of finding strings."""
    findings = []
    for path, prop, v in pins:
        brick = prop[: -len(".version")]
        if brick == repo_short:
            continue
        rel, dev = releases.get(brick), devs.get(brick)
        if rel is None and dev is None:
            continue  # nothing known about that brick: do not guess
        if v in (rel, dev):
            continue
        known = " or ".join(x for x in (f"the latest release {rel}" if rel else "", f"the development version {dev}" if dev else "") if x)
        why = ""
        if is_snapshot(v) and rel and vkey(v) and vkey(rel) and vkey(v) <= vkey(rel):
            why = f" ({v} is a SNAPSHOT superseded by the release {rel}: nothing publishes it any more)"
        findings.append(f"{path}: <{prop}> is {v}, expected {known}{why}")
    if is_snapshot(own):
        rel = releases.get(repo_short)
        if rel and vkey(own) and vkey(rel) and vkey(own) <= vkey(rel):
            findings.append(f"own version {own} is superseded by its release {rel}: the post-release bump of this repository was missed")
        lines = [vkey(base(d)) for d in devs.values() if is_snapshot(d) and vkey(d)]
        if lines and vkey(own) and vkey(own) < max(lines):
            top = max(d for d in devs.values() if is_snapshot(d) and vkey(d) == max(lines))
            findings.append(f"own version {own} lags the development line ({top})")
    return findings


# ---------------------------------------------------------------- network (skipped under test)

def http_get(url, token=None, timeout=20):
    req = urllib.request.Request(url, headers={"Authorization": f"token {token}"} if token else {})
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 - fixed https endpoints
        return r.read().decode("utf-8", "replace")


def latest_release(central, artifacts):
    """Highest purely numeric release of the first of the artifacts that Central knows."""
    for g, a in artifacts[:3]:
        try:
            xml = http_get(f"{central}/{g.replace('.', '/')}/{a}/maven-metadata.xml")
        except Exception:  # noqa: BLE001
            continue
        vs = [vkey(v) and v for v in re.findall(r"<version>([^<]+)</version>", xml) if RELEASE.match(v)]
        vs = [v for v in vs if v]
        if vs:
            return max(vs, key=vkey)
    return None


def dev_version(forge, slug, token):
    try:
        xml = http_get(f"{forge}/{slug}/raw/branch/main/pom.xml", token)
        root = ET.fromstring(xml)
    except Exception:  # noqa: BLE001
        return None
    for c in root:
        if local(c.tag) == "version":
            return (c.text or "").strip()
    return None


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--pom-dir", required=True)
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--forge", default="https://codefloe.com")
    ap.add_argument("--graph-repo", default="Vidocq/dep-graph")
    ap.add_argument("--graph-ref", default="main")
    ap.add_argument("--central", default="https://repo1.maven.org/maven2")
    ap.add_argument("--token-env", default="BOT_TOKEN")
    ap.add_argument("--graph")
    ap.add_argument("--releases")
    ap.add_argument("--devs")
    a = ap.parse_args(argv)
    token = os.environ.get(a.token_env) or None
    short = a.repo.rsplit("/", 1)[-1]

    try:
        if a.graph:
            graph = json.load(open(a.graph))
        else:
            graph = json.loads(http_get(f"{a.forge}/{a.graph_repo}/raw/branch/{a.graph_ref}/graph/inverted.json", token))
    except Exception as e:  # noqa: BLE001
        print(f"::notice title=brick versions::dependency graph unreadable ({e}): check skipped")
        return 0
    by_brick = {}
    for coord, meta in (graph.get("artifacts") or {}).items():
        slug = (meta or {}).get("produced_by")
        if slug and ":" in coord:
            by_brick.setdefault(slug.rsplit("/", 1)[-1], (slug, []))[1].append(tuple(coord.split(":", 1)))
    bricks = sorted(by_brick)

    own = own_version(a.pom_dir) if (Path(a.pom_dir) / "pom.xml").exists() else ""
    pins = property_pins(a.pom_dir, bricks)
    needed = {p[1][: -len(".version")] for p in pins} | ({short} if short in by_brick else set())

    if a.releases:
        releases = json.load(open(a.releases))
    else:
        releases = {b: r for b in needed if (r := latest_release(a.central, sorted(by_brick[b][1])))}
    if a.devs:
        devs = json.load(open(a.devs))
    else:
        devs = {b: d for b in bricks if (d := dev_version(a.forge, by_brick[b][0], token))}

    findings = evaluate(short, own, pins, releases, devs)
    for f in findings:
        print(f"::warning title=Brick version skew::{f}")
    if findings:
        print(f"{len(findings)} brick version finding(s) in {a.repo} (Vidocq/ci#19). Fix: set the property to the "
              "producer's development SNAPSHOT (the release automation opens that pull request after each release).")
    else:
        print(f"brick versions of {a.repo}: aligned")
    return 1 if (findings and a.strict) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
