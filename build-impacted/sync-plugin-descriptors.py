#!/usr/bin/env python3
"""Make the plugin.xml of every maven-plugin module follow the root pom version.

Usage: sync-plugin-descriptors.py DIR

versions:set does not touch resources, and a maven-plugin module that ships a hand-written
src/main/resources/META-INF/maven/plugin.xml has a hardcoded <version> in it. Without this sync
the plugin jar carries a stale descriptor and every consumer fails with "Plugin's descriptor
contains the wrong version".
"""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def sync(repo):
    rp = ET.parse(repo / "pom.xml").getroot()
    ns = rp.tag[1:].split("}", 1)[0] if rp.tag.startswith("{") else ""
    v = rp.find(f"{{{ns}}}version") if ns else rp.find("version")
    version = v.text.strip()
    n = 0
    for pom in repo.rglob("pom.xml"):
        if "target" in pom.parts:
            continue
        try:
            r = ET.parse(pom).getroot()
        except ET.ParseError:
            continue
        pns = r.tag[1:].split("}", 1)[0] if r.tag.startswith("{") else ""
        pkg = r.find(f"{{{pns}}}packaging") if pns else r.find("packaging")
        if pkg is None or (pkg.text or "").strip() != "maven-plugin":
            continue
        px = pom.parent / "src/main/resources/META-INF/maven/plugin.xml"
        if not px.is_file():
            continue
        content = px.read_text(encoding="utf-8")
        new = re.sub(r"(<artifactId>[^<]+</artifactId>\s*\n\s*<version>)[^<]+(</version>)",
                     rf"\g<1>{version}\g<2>", content, count=1)
        if new != content:
            px.write_text(new, encoding="utf-8")
            n += 1
    return n


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write(__doc__)
        sys.exit(2)
    print(f"  plugin.xml synced: {sync(Path(sys.argv[1]))}")
