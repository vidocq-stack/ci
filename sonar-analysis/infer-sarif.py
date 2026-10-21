"""Turns Infer's report (infer-out/report.json) into a SARIF report.

Usage: infer-sarif.py <report.json> <out.sarif>

Each issue keeps its bug type as the rule (THREAD_SAFETY_VIOLATION...), its qualifier as the message
and its file and line as the location; Infer's ERROR severity becomes the SARIF level "error", any
other severity "warning". The paths stay as Infer wrote them, relative to the directory javac ran in;
normalize-sarif.py makes them relative to the repository.

Writes the report, even empty, and prints the number of findings.
"""
import json
import sys

src, dst = sys.argv[1:3]
try:
    with open(src, encoding="utf-8") as fh:
        issues = json.load(fh)
except FileNotFoundError:
    issues = []

rules, results = {}, []
for issue in issues:
    rule = issue.get("bug_type") or "INFER"
    rules.setdefault(rule, {
        "id": rule,
        "name": rule,
        "shortDescription": {"text": issue.get("bug_type_hum") or rule},
        "helpUri": "https://fbinfer.com/docs/all-issue-types#%s" % rule.lower(),
    })
    region = {"startLine": max(1, int(issue.get("line") or 1))}
    column = int(issue.get("column") or -1)
    if column > 0:
        region["startColumn"] = column
    results.append({
        "ruleId": rule,
        "level": "error" if issue.get("severity") == "ERROR" else "warning",
        "message": {"text": issue.get("qualifier") or rule},
        "locations": [{"physicalLocation": {"artifactLocation": {"uri": issue.get("file", "")}, "region": region}}],
        "partialFingerprints": {"inferHash": issue.get("hash", "")},
    })

sarif = {
    "version": "2.1.0",
    "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
    "runs": [{
        "tool": {"driver": {
            "name": "Infer",
            "informationUri": "https://fbinfer.com",
            "rules": sorted(rules.values(), key=lambda rule: rule["id"]),
        }},
        "results": results,
    }],
}
with open(dst, "w", encoding="utf-8") as fh:
    json.dump(sarif, fh)
print(len(results))
