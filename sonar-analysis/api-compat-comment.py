"""Reports the API compatibility that japicmp measured during the build.

Usage: api-compat-comment.py <repository-root>
Environment: BOT_TOKEN, SERVER_URL, REPOSITORY, PR_NUMBER, HEAD_SHA (pull requests only).

Reads every target/japicmp/*.xml of the repository, written by a module whose build runs japicmp (as
Chappe's quality profile does, Vidocq/vidocq#288): per module, the release it was compared with and the
types with a binary- or source-incompatible change, then the changes themselves. Prints the summary,
and on a pull request with a bot token keeps one comment up to date with it. Report mode: never fails.
"""
import json
import os
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

root = os.path.realpath(sys.argv[1])
MARKER = "<!-- vidocq-japicmp -->"
MAX_LINES = 60


def reports():
    for directory, subdirs, files in os.walk(root):
        subdirs[:] = [d for d in subdirs if not d.startswith(".") and d != "node_modules"]
        if os.path.basename(directory) == "japicmp" and os.path.basename(os.path.dirname(directory)) == "target":
            module = os.path.relpath(os.path.dirname(os.path.dirname(directory)), root)
            for name in sorted(files):
                if name.endswith(".xml"):
                    yield ("." if module == "." else module), os.path.join(directory, name)


def incompatible(element):
    return element.get("binaryCompatible") == "false" or element.get("sourceCompatible") == "false"


def short(type_name):
    return (type_name or "?").rsplit(".", 1)[-1].replace("$", ".")


def readable(type_name):
    return (type_name or "?").replace("$", ".")


def words(change_type):
    return change_type.lower().replace("_", " ")


def changes(cls):
    """The incompatible changes of a class, as text lines."""
    out = []
    source_only = lambda e: " (source only)" if e.get("binaryCompatible") != "false" else ""
    for cc in cls.findall("compatibilityChanges/compatibilityChange"):
        if incompatible(cc):
            out.append(words(cc.get("type", "?")) + source_only(cc))
    for kind, label in (("constructors/constructor", "constructor"), ("methods/method", "method"), ("fields/field", "field")):
        for member in cls.findall(kind):
            bad = [cc for cc in member.findall("compatibilityChanges/compatibilityChange") if incompatible(cc)]
            if not bad:
                continue
            name = member.get("name") or short(cls.get("fullyQualifiedName"))
            if label != "field":
                name += "(" + ", ".join(short(p.get("type")) for p in member.findall("parameters/parameter")) + ")"
            out.append("%s: `%s`" % (", ".join(words(cc.get("type", "?")) + source_only(cc) for cc in bad), name))
    if not out and cls.get("changeStatus") == "REMOVED":
        out.append("type removed")
    return out or ["incompatible"]


modules, details = [], []
for module, path in sorted(reports()):
    try:
        report = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as err:
        print("::warning::Cannot read the japicmp report %s: %s" % (path, err))
        continue
    broken = [c for c in report.findall("classes/class") if incompatible(c)]
    binary = sum(1 for c in broken if c.get("binaryCompatible") == "false")
    modules.append((module, report.get("oldVersion", "?"), report.get("newVersion", "?"), binary, len(broken)))
    for cls in sorted(broken, key=lambda c: c.get("fullyQualifiedName", "")):
        for change in changes(cls):
            details.append("- `%s` (%s): %s" % (readable(cls.get("fullyQualifiedName")), module, change))

if not modules:
    print("No japicmp report in the build: no API compatibility report.")
    sys.exit(0)

total = sum(m[4] for m in modules)
verdict = ("✅ no incompatible change" if total == 0
           else "⚠️ %d type%s with incompatible changes" % (total, "" if total == 1 else "s"))
lines = [MARKER, "### API compatibility with the last release (japicmp): " + verdict, "",
         "| Module | Compared with | Binary-incompatible types | Incompatible types (binary or source) |",
         "|---|---|---:|---:|"]
lines += ["| `%s` | %s | %d | %d |" % (module, old, binary, count) for module, old, _, binary, count in modules]
if details:
    shown = details[:MAX_LINES]
    if len(details) > MAX_LINES:
        shown.append("- … and %d more, in the module's `target/japicmp/` report" % (len(details) - MAX_LINES))
    lines += ["", "<details><summary>Incompatible changes</summary>", ""] + shown + ["", "</details>"]
sha = os.environ.get("HEAD_SHA", "")[:8]
lines += ["", "Report mode: the packages each `module-info.java` exports, compared with the latest release; "
              "nothing blocks before 1.0.0-RC1 (Vidocq/vidocq#288)" + (" · commit `%s`" % sha if sha else "")]
body = "\n".join(lines)
print(body)

pr, token = os.environ.get("PR_NUMBER", ""), os.environ.get("BOT_TOKEN", "")
if not pr or not token:
    sys.exit(0)


def forge(method, path, payload=None):
    req = urllib.request.Request(
        os.environ["SERVER_URL"].rstrip("/") + "/api/v1" + path,
        data=None if payload is None else json.dumps(payload).encode(),
        method=method,
        headers={"Authorization": "token " + token, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None


repo = os.environ["REPOSITORY"]
try:
    comments = forge("GET", "/repos/%s/issues/%s/comments" % (repo, pr)) or []
    mine = next((c for c in comments if MARKER in (c.get("body") or "")), None)
    if mine:
        forge("PATCH", "/repos/%s/issues/comments/%s" % (repo, mine["id"]), {"body": body})
    else:
        forge("POST", "/repos/%s/issues/%s/comments" % (repo, pr), {"body": body})
except urllib.error.URLError as err:
    print("::warning::Could not post the API compatibility comment: %s" % err)
