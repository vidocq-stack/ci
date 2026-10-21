"""Turns a normalised SARIF report into SonarQube's generic issue format (sonar.externalIssuesReportPaths).

Usage: sarif-to-generic.py <in.sarif> <out.json> <repository-root> <engine-id> <software-quality> <severity> <clean-code-attribute>

SonarQube imports every SARIF result as a vulnerability. That suits the security scans, not a code
checker: Error Prone's bug patterns or Infer's data races would show as 147 vulnerabilities. The
generic format says what the issues are instead: one software quality (RELIABILITY, MAINTAINABILITY,
SECURITY) and its severity (LOW, MEDIUM, HIGH) for every rule of the report. Issues are kept at line
level: the format counts columns from 0, SARIF from 1, and a column past the line would lose the issue.
The paths become absolute: SonarQube imports a generic report module by module, each module resolving
a relative path against its own directory, so a path relative to the repository matches no module.

Prints the number of issues written.
"""
import json
import os
import sys

src, dst, root, engine, quality, severity, attribute = sys.argv[1:8]
root = os.path.realpath(root)
with open(src, encoding="utf-8") as fh:
    sarif = json.load(fh)

rules, issues = {}, []
for run in sarif.get("runs", []):
    described = {r.get("id"): r for r in run.get("tool", {}).get("driver", {}).get("rules", []) or []}
    for result in run.get("results", []) or []:
        rid = result.get("ruleId") or engine
        if rid not in rules:
            rule = described.get(rid, {})
            name = (rule.get("shortDescription") or {}).get("text") or rule.get("name") or rid
            rules[rid] = {
                "id": rid,
                "name": name,
                "description": "See %s" % rule["helpUri"] if rule.get("helpUri") else name,
                "engineId": engine,
                "cleanCodeAttribute": attribute,
                "impacts": [{"softwareQuality": quality, "severity": severity}],
            }
        location = (result.get("locations") or [{}])[0].get("physicalLocation", {})
        path = location.get("artifactLocation", {}).get("uri")
        if not path:
            continue
        issues.append({
            "ruleId": rid,
            "primaryLocation": {
                "message": (result.get("message") or {}).get("text") or rid,
                "filePath": path if os.path.isabs(path) else os.path.join(root, path),
                "textRange": {"startLine": max(1, int(location.get("region", {}).get("startLine") or 1))},
            },
        })

with open(dst, "w", encoding="utf-8") as fh:
    json.dump({"rules": sorted(rules.values(), key=lambda r: r["id"]), "issues": issues}, fh)
print(len(issues))
