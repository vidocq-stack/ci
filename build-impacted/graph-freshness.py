#!/usr/bin/env python3
"""Check that the dependency graph is not older than the producer's data.

Usage: graph-freshness.py INVERTED_JSON DATA_JSON REQUIRE_FRESH

graph/inverted.json (its "generated_at") is built from the data/*.json files of the
dependency-graph repository. When it is older than the producer's data file (its
"updated_at"), the graph may not know every consumer: the downstream rebuild would then
check fewer repositories than it should, and say nothing. With REQUIRE_FRESH=true that is an
error (exit 1); otherwise a warning (exit 0).
"""
import json
import sys
from datetime import datetime

TITLE = "Stale dependency graph"


def instant(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def load(path, key):
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return None, None
    if not isinstance(doc, dict):
        return None, None
    return doc.get(key), doc.get("repo")


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    graph_path, data_path, require = argv
    strict = require.strip().lower() == "true"
    level = "error" if strict else "warning"

    generated, _ = load(graph_path, "generated_at")
    updated, repo = load(data_path, "updated_at")
    g, d = instant(generated), instant(updated)
    problem = None
    if g is None:
        problem = "cannot tell whether the dependency graph is fresh: graph/inverted.json has no valid generated_at."
    elif d is None:
        problem = "cannot tell whether the dependency graph is fresh: the producer data has no valid updated_at."
    elif g < d:
        problem = (f"graph/inverted.json was generated at {generated}, before the producer data"
                   f"{f' ({repo})' if repo else ''} was updated at {updated}. The list of consumers "
                   "to rebuild may miss repositories. Rebuild the graph in the dependency-graph "
                   "repository, then run this job again.")
    if problem is None:
        print(f"dep-graph is fresh: graph generated {generated}, producer data updated {updated}")
        return 0
    print(f"::{level} title={TITLE}::{problem}")
    if not strict:
        print("(require-fresh-graph is false: going on with this graph.)")
    return 1 if strict else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
