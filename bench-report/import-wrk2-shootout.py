"""Turns the raw output of a wrk2 shootout into one results.json (schema 1, see README.md).

Usage: import-wrk2-shootout.py <raw-dir> <out.json>

<raw-dir> is what the Chappe shootout harness leaves in chappe-bench/target/shootout:
  fingerprint.json         machine, settings and versions of the run
  _summary.tsv             one line per target: image size (MB) and idle RSS in its first columns
  <target>-rate<N>.txt     the `wrk --latency` output of <target> at the offered rate N

The results are flat rows (benchmark, target, parameters, metric, value, unit), the shape the
PostgreSQL importer of Grafana and the report generators read. The HdrHistogram percentile
spectrum of every run is kept, downsampled, as a series: it is what the latency charts draw.

Prints the number of result rows written.
"""
import json
import math
import os
import re
import sys

BENCHMARK = "shootout.plaintext"
UNIT_TO_MS = {"us": 0.001, "ms": 1.0, "s": 1000.0, "m": 60000.0}
SUMMARY_PERCENTILES = {"50.000%": "p50", "75.000%": "p75", "90.000%": "p90", "99.000%": "p99",
                       "99.900%": "p99.9", "99.990%": "p99.99", "99.999%": "p99.999", "100.000%": "max"}
SPECTRUM_POINTS_PER_DECADE = 8


def to_ms(text):
    match = re.fullmatch(r"([0-9.]+)(us|ms|s|m)", text)
    if not match:
        raise ValueError("not a wrk2 duration: %r" % text)
    return float(match.group(1)) * UNIT_TO_MS[match.group(2)]


def parse_run(text):
    """Returns (metrics, spectrum) of one `wrk --latency` output; spectrum is [[percentile, ms], ...]."""
    metrics, spectrum, in_spectrum = {}, [], False
    for line in text.splitlines():
        fields = line.split()
        if not fields:
            continue
        if fields[0] in SUMMARY_PERCENTILES and len(fields) == 2:
            metrics[SUMMARY_PERCENTILES[fields[0]]] = to_ms(fields[1])
        elif line.strip().startswith("Value") and "Percentile" in line:
            in_spectrum = True
        elif in_spectrum and fields[0].startswith("#["):
            in_spectrum = False
        elif in_spectrum and len(fields) == 4:
            # Detailed spectrum lines are in milliseconds: Value Percentile TotalCount 1/(1-Percentile)
            spectrum.append([float(fields[1]), float(fields[0])])
        elif fields[0] == "Requests/sec:":
            metrics["achieved_rps"] = float(fields[1])
        elif line.strip().startswith("Socket errors:"):
            metrics["socket_errors"] = sum(int(n) for n in re.findall(r"\d+", line))
        elif line.strip().startswith("Non-2xx or 3xx responses:"):
            metrics["non_2xx"] = int(fields[-1])
    metrics.setdefault("socket_errors", 0)
    metrics.setdefault("non_2xx", 0)
    return metrics, downsample(spectrum)


def downsample(spectrum):
    """Keeps the first point past each step of 1/(1-percentile) on a log scale, and the last one.

    The 100th percentile is dropped: it sits at infinity on that scale, and the max is a metric.
    """
    below_max = [point for point in spectrum if point[0] < 1.0]
    kept, next_step = [], 0.0
    for percentile, value in below_max:
        position = -math.log10(1.0 - percentile)
        if position >= next_step:
            kept.append([percentile, value])
            next_step = math.floor(position * SPECTRUM_POINTS_PER_DECADE + 1) / SPECTRUM_POINTS_PER_DECADE
    if below_max and kept[-1] != below_max[-1]:
        kept.append(below_max[-1])
    return kept


def mebibytes(text):
    """docker stats memory ("38.5MiB", "1.2GiB", "812KiB") in MiB, or None."""
    match = re.fullmatch(r"([0-9.]+)\s*([KMG]i?B)", text or "")
    if not match:
        return None
    factor = {"KiB": 1 / 1024, "KB": 1 / 1024, "MiB": 1, "MB": 1, "GiB": 1024, "GB": 1024}[match.group(2)]
    return round(float(match.group(1)) * factor, 1)


def main(raw_dir, out_path):
    with open(os.path.join(raw_dir, "fingerprint.json"), encoding="utf-8") as fh:
        fingerprint = json.load(fh)
    rows, series = [], []

    def row(target, params, metric, value, unit):
        rows.append({"benchmark": BENCHMARK, "target": target, "params": params,
                     "metric": metric, "value": value, "unit": unit})

    summary = os.path.join(raw_dir, "_summary.tsv")
    if os.path.exists(summary):
        with open(summary, encoding="utf-8") as fh:
            for line in fh:
                cols = line.rstrip("\n").split("\t")
                if len(cols) < 3:
                    continue
                target, image_mb, rss = cols[0], cols[1], cols[2]
                if image_mb not in ("", "?"):
                    row(target, {}, "image_size", float(image_mb), "MiB")
                if mebibytes(rss) is not None:
                    row(target, {}, "idle_rss", mebibytes(rss), "MiB")

    for name in sorted(os.listdir(raw_dir)):
        match = re.fullmatch(r"(.+)-rate(\d+)\.txt", name)
        if not match:
            continue
        target, rate = match.group(1), int(match.group(2))
        with open(os.path.join(raw_dir, name), encoding="utf-8") as fh:
            metrics, spectrum = parse_run(fh.read())
        if "p99" not in metrics:
            print("warning: no latency distribution in %s, skipped" % name, file=sys.stderr)
            continue
        params = {"offered_rate": rate}
        for metric, value in metrics.items():
            unit = "req/s" if metric == "achieved_rps" else "count" if metric in ("socket_errors", "non_2xx") else "ms"
            row(target, params, metric, value, unit)
        series.append({"benchmark": BENCHMARK, "target": target, "params": params,
                       "kind": "latency_spectrum", "x": "percentile", "y": "latency_ms", "points": spectrum})

    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump({"schema": 1, "fingerprint": fingerprint, "results": rows, "series": series},
                  fh, indent=1)
        fh.write("\n")
    print(len(rows))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
