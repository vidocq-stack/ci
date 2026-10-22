# bench-report

Turns raw benchmark output into the files the performance pipeline keeps and publishes
(workspace ADR 0001, *Performance testing of the ecosystem*). Pilot stage: two scripts, run by
hand on Chappe's shootout; the composite action, the `Vidocq/bench-results` push and the Grafana
importer come with P1.

| Script | Input | Output |
|---|---|---|
| `import-wrk2-shootout.py <raw-dir> <out.json>` | The directory the Chappe shootout harness writes (`chappe-bench/target/shootout`: `fingerprint.json`, `_summary.tsv`, `<target>-rate<N>.txt`) | `results.json`, schema 1 |
| `shootout-adoc.py <results.json> <out.adoc>` | A shootout `results.json` | The generated sections of a Performance page: sustained throughput, latency against load, latency spectrum, footprint, run environment |

Both use the Python 3 standard library only.

## `results.json`, schema 1

```json
{
  "schema": 1,
  "fingerprint": { "date": "…", "commit": "…", "dirty": false, "mode": "bridge",
                   "params": { "rates": [50000, 100000, 200000], "slo_p99_ms": 10, "…": "…" },
                   "cpusets": { "server": "0,6,1,7,2,8,3,9", "client": "4,10,5,11" },
                   "host": { "cpu_model": "…", "governor": "performance", "no_turbo": "1", "…": "…" },
                   "jvm": "…", "targets": { "chappe-jvm": "<commit>", "jetty": "Jetty 12.0.21", "…": "…" } },
  "results": [
    { "benchmark": "shootout.plaintext", "target": "jetty", "params": { "offered_rate": 100000 },
      "metric": "p99", "value": 2.46, "unit": "ms" }
  ],
  "series": [
    { "benchmark": "shootout.plaintext", "target": "jetty", "params": { "offered_rate": 100000 },
      "kind": "latency_spectrum", "x": "percentile", "y": "latency_ms", "points": [[0.5, 1.03], [0.9, 1.6]] }
  ]
}
```

* `results` are flat rows, one measured value each, the shape of the `result` table of the ADR.
  Shootout metrics: `p50`, `p75`, `p90`, `p99`, `p99.9`, `p99.99`, `p99.999`, `max` (ms),
  `achieved_rps`, `socket_errors`, `non_2xx` per offered rate; `image_size` and `idle_rss` (MiB)
  per target.
* `series` keep a curve per run: here the HdrHistogram percentile spectrum, downsampled to eight
  points per decade of `1/(1-percentile)` (about 40 points instead of several hundred).

## The generated page

`shootout-adoc.py` writes AsciiDoc meant for
`include::partial$performance/<version>.adoc[leveloffset=+1]`. Its charts are `[vegalite]`
blocks with inline data: the docs build sends them to Kroki (`kroki-fetch-diagram: true`), which
returns static SVG, so the page needs no JavaScript and no Grafana. Every chart has a table with
the same figures next to it. The servers the page is about (`--subject`, default Chappe JVM and
native) are drawn in the accent colour, the others in grey; the latency spectrum shows four
servers at most (`--spectrum`), in the fixed categorical order.

A run that is not a reference run — CPU governor other than `performance`, turbo on, or
uncommitted changes — gets a warning at the top of the generated sections.
