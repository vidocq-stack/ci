"""Turns the Error Prone warnings of a Maven build log into a SARIF report.

Usage: errorprone-sarif.py <build.log> <out.sarif>

javac prints each Error Prone finding as a compiler warning, which maven-compiler-plugin logs as

    [WARNING] /path/to/File.java:[LINE,COLUMN] [CheckName] message
        (see https://errorprone.info/bugpattern/CheckName)
      Did you mean '...'?

A warning counts as an Error Prone finding when its tag is a check name (UpperCamelCase: javac's
own lint categories are lower case, such as [deprecation]) and a "(see <url>)" line follows it.
The message keeps the suggested fix. Every finding has the level "warning": the analysis build
runs Error Prone in report mode (-XepAllErrorsAsWarnings), which no longer tells its error-level
checks apart. The paths stay as javac wrote them; normalize-sarif.py makes them relative.

Writes the report, even empty, and prints the number of findings.
"""
import json
import re
import sys

src, dst = sys.argv[1:3]

HEAD = re.compile(r"^\[(?:WARNING|ERROR)\] (?P<path>\S.*?\.java):\[(?P<line>\d+),(?P<col>\d+)\] "
                  r"\[(?P<check>[A-Z][A-Za-z0-9]*)\] (?P<message>.*)$")
SEE = re.compile(r"^\s+\(see (?P<url>\S+)\)\s*$")
LOG_LINE = re.compile(r"^\[(?:INFO|WARNING|ERROR|DEBUG)\]")

with open(src, encoding="utf-8", errors="replace") as fh:
    lines = [line.rstrip("\n") for line in fh]

findings, seen = [], set()
i = 0
while i < len(lines):
    head = HEAD.match(lines[i])
    i += 1
    if not head:
        continue
    message, url, suggestion = [head.group("message").strip()], None, []
    # The message may go on over unprefixed lines, up to the "(see ...)" line; a suggested fix may
    # follow it, up to the next log line.
    while i < len(lines) and not LOG_LINE.match(lines[i]):
        see = SEE.match(lines[i])
        if see and url is None:
            url = see.group("url")
        elif url is None:
            message.append(lines[i].strip())
        else:
            suggestion.append(lines[i].strip())
        i += 1
    if url is None:
        continue
    text = " ".join(part for part in message + suggestion if part)
    key = (head.group("path"), head.group("line"), head.group("col"), head.group("check"), text)
    if key in seen:
        continue
    seen.add(key)
    findings.append((head, url, text))

rules = {}
results = []
for head, url, text in findings:
    check = head.group("check")
    rules.setdefault(check, {
        "id": check,
        "name": check,
        "shortDescription": {"text": check},
        "helpUri": url,
    })
    results.append({
        "ruleId": check,
        "level": "warning",
        "message": {"text": text},
        "locations": [{
            "physicalLocation": {
                "artifactLocation": {"uri": head.group("path")},
                "region": {"startLine": int(head.group("line")), "startColumn": int(head.group("col"))},
            }
        }],
    })

sarif = {
    "version": "2.1.0",
    "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
    "runs": [{
        "tool": {"driver": {
            "name": "Error Prone",
            "informationUri": "https://errorprone.info",
            "rules": sorted(rules.values(), key=lambda rule: rule["id"]),
        }},
        "results": results,
    }],
}
with open(dst, "w", encoding="utf-8") as fh:
    json.dump(sarif, fh)
print(len(results))
