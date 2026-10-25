#!/usr/bin/env python3
"""Turn the ordered list of impacted consumers into a job matrix.

Usage: impacted-matrix.py --graph inverted.json --producer OWNER/NAME --impacted impacted.txt

impacted.txt holds one consumer slug per line, in topological order (resolve-consumers.sh).
Prints three `name=value` lines, ready for $GITHUB_OUTPUT, each value compact JSON on one line:

  matrix={"include":[{"repo":"Vidocq/foy"},...]}   for strategy.matrix (fromJSON)
  count=N                                           number of consumers
  With no consumer, the matrix holds one placeholder entry, {"repo":"none"}: Forgejo creates no
  job for an empty matrix, and the jobs that need that job then stay blocked forever. The
  downstream job must skip on count 0; were it to run, build-one-consumer fails on the clone of
  "none", so the placeholder can never pass for a consumer.
  upstreams={"Vidocq/cassini":"Vidocq/foy",...}     for each consumer, the other impacted
                                                    consumers it depends on, directly or not,
                                                    space-separated in topological order

`upstreams` lets build-one-consumer find the intermediate upstreams of its consumer: those that
have a companion branch for the pull request are rebuilt first, in the same job. The producer is
never listed in it (it is always rebuilt and pinned). An edge X -> Y exists when Y consumes an
artifact X produces, both among the producer and the impacted consumers.
"""
import argparse
import json
import sys


def edges(graph, repos):
    """Return {consumer: {direct upstreams}} restricted to repos."""
    preds = {r: set() for r in repos}
    for entry in graph.get("artifacts", {}).values():
        prod = entry.get("produced_by")
        if prod not in preds:
            continue
        for c in entry.get("consumed_by", []):
            cons = c.get("repo")
            if cons in preds and cons != prod:
                preds[cons].add(prod)
    return preds


def matrix(graph, producer, impacted):
    preds = edges(graph, [producer] + impacted)
    position = {r: i for i, r in enumerate(impacted)}
    upstreams = {}
    for repo in impacted:
        seen, stack = set(), list(preds[repo])
        while stack:
            r = stack.pop()
            if r in seen or r == repo:
                continue
            seen.add(r)
            stack.extend(preds.get(r, ()))
        seen.discard(producer)
        upstreams[repo] = " ".join(sorted(seen, key=lambda r: position[r]))
    return {"include": [{"repo": r} for r in impacted] or [{"repo": "none"}]}, upstreams


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--graph", required=True)
    ap.add_argument("--producer", required=True)
    ap.add_argument("--impacted", required=True)
    a = ap.parse_args(argv)
    with open(a.graph, encoding="utf-8") as f:
        graph = json.load(f)
    with open(a.impacted, encoding="utf-8") as f:
        impacted = []
        for line in f:
            slug = line.strip()
            if slug and slug != a.producer and slug not in impacted:
                impacted.append(slug)
    m, up = matrix(graph, a.producer, impacted)
    compact = {"separators": (",", ":")}
    print("matrix=" + json.dumps(m, **compact))
    print(f"count={len(impacted)}")
    print("upstreams=" + json.dumps(up, **compact))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
