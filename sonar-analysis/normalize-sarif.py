"""Prepares a SARIF report for SonarQube's import (sonar.sarifReportPaths).

Usage: normalize-sarif.py <repository-root> <in.sarif> <out.sarif> <tool>

- Paths become relative to the repository root: OSV-Scanner and OpenGrep may write absolute
  paths, and SonarQube matches the files of an external issue against the paths it indexed.
- OSV-Scanner reads the build's SBOM (target/bom.json), a file SonarQube does not index: its
  findings move to the root pom.xml, which it does.
- OpenGrep rule ids are cut down to the rule's own id (java.lang.security...): OpenGrep prefixes
  them with the path of the rules directory, which differs from one runner to the next, and a
  changing id would make every finding look new.
- Findings whose file belongs to a module SonarQube does not analyse are dropped: a module with
  sonar.skip (benchmarks, test vehicles), or a directory with a pom.xml outside the reactor
  (out-of-reactor TCK runners). SonarQube would otherwise attach them to the whole project.
  The reactor is read from the root pom.xml: its modules plus those of its quality profile, the
  one the analysis build activates.
- Results outside the repository are dropped too.

Prints the number of results kept.
"""
import json
import os
import re
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

root, src, dst, tool = sys.argv[1:5]
root = os.path.realpath(root)


def tag(element):
    return element.tag.rsplit("}", 1)[-1]


def child(element, name):
    return next((c for c in element if tag(c) == name), None)


def children(element, name):
    return [c for c in element if tag(c) == name] if element is not None else []


def read_pom(directory):
    try:
        return ET.parse(os.path.join(directory, "pom.xml")).getroot()
    except (OSError, ET.ParseError):
        return None


def reactor():
    """Module directories (relative, "" for the root) -> analysed (True) or skipped (False)."""
    modules, stack = {}, [("", False)]
    while stack:
        rel, parent_skipped = stack.pop()
        if rel in modules:
            continue
        project = read_pom(os.path.join(root, rel))
        if project is None:
            continue
        properties = child(project, "properties")
        skip = child(properties, "sonar.skip") if properties is not None else None
        skipped = parent_skipped if skip is None else (skip.text or "").strip() == "true"
        modules[rel] = not skipped
        names = [m.text for m in children(child(project, "modules"), "module")]
        for profile in children(child(project, "profiles"), "profile"):
            pid = child(profile, "id")
            if pid is not None and (pid.text or "").strip() == "quality":
                names += [m.text for m in children(child(profile, "modules"), "module")]
        for name in names:
            name = (name or "").strip()
            if not name:
                continue
            if name.endswith(".xml"):
                name = os.path.dirname(name)
            sub = os.path.normpath(os.path.join(rel, name))
            stack.append(("" if sub == "." else sub, skipped))
    return modules


MODULES = reactor()


def analysed(path):
    """Whether the nearest directory holding a pom.xml is a module SonarQube analyses."""
    directory = os.path.dirname(path)
    while True:
        if os.path.isfile(os.path.join(root, directory, "pom.xml")):
            return MODULES.get(directory, False)
        if not directory:
            return MODULES.get("", True)
        directory = os.path.dirname(directory)


def relative(uri):
    """The repository-relative path of a SARIF artifact URI, or None when it lies outside."""
    if uri.startswith("file:"):
        path = urllib.request.url2pathname(urllib.parse.urlparse(uri).path)
    else:
        path = urllib.parse.unquote(uri)
    if os.path.isabs(path):
        path = os.path.realpath(path)
        if path != root and not path.startswith(root + os.sep):
            return None
        path = os.path.relpath(path, root)
    path = path[2:] if path.startswith("./") else path
    if path.startswith(".."):
        return None
    path = path.replace(os.sep, "/")
    if tool == "osv-scanner" and os.path.basename(path) == "bom.json":
        path = "pom.xml"
    return path


def rule_id(rid):
    if tool != "opengrep" or not rid:
        return rid
    m = re.search(r"(?:^|\.)(java\..+)$", rid)
    return m.group(1) if m else rid


def keep_location(location):
    art = location.get("physicalLocation", {}).get("artifactLocation", {})
    path = relative(art.get("uri", ""))
    if not path or not analysed(path):
        return False
    art["uri"] = path
    art.pop("uriBaseId", None)
    return True


with open(src, encoding="utf-8") as fh:
    sarif = json.load(fh)

kept = 0
for run in sarif.get("runs", []):
    run.pop("originalUriBaseIds", None)
    for rule in run.get("tool", {}).get("driver", {}).get("rules", []) or []:
        if "id" in rule:
            rule["id"] = rule_id(rule["id"])
    results = []
    for result in run.get("results", []) or []:
        result["ruleId"] = rule_id(result.get("ruleId"))
        locations = [loc for loc in result.get("locations", []) or [] if keep_location(loc)]
        if locations:
            result["locations"] = locations
            related = [loc for loc in result.get("relatedLocations", []) or [] if keep_location(loc)]
            if related:
                result["relatedLocations"] = related
            else:
                result.pop("relatedLocations", None)
            results.append(result)
    run["results"] = results
    kept += len(results)

with open(dst, "w", encoding="utf-8") as fh:
    json.dump(sarif, fh)
print(kept)
