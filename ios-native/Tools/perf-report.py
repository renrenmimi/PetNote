#!/usr/bin/env python3
"""Turn a run of PERF lines into a distribution, and refuse to overstate it.

Usage:  perf-report.py <metric_key> <logfile> [...]

The reporting rules here are not formatting preferences, they are the stage 7
discipline written down as code:

  * "报告分布与异常值，不只给最好一次" — so the best sample is never printed on
    its own; min, median, max and every sample are printed together.
  * "样本量不足时不得报 p95/p99" — a percentile estimated from ten points has a
    confidence interval wider than the difference anyone is trying to measure.
    This refuses to print p95 below 20 samples and says why instead of quietly
    printing a number that looks like the others.
  * A run with missing samples reports how many are missing. A cold-start
    harness that silently drops the three slowest launches produces a faster
    app on paper.
"""

import statistics
import sys
import re

MIN_SAMPLES_FOR_P95 = 20


def parse(key, paths):
    pattern = re.compile(rf"\b{re.escape(key)}=(\d+)\b")
    values, missing, facts = [], 0, []
    for path in paths:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if line.startswith(("commit=", "metric=", "samples_requested=")):
                    facts.append(line.strip())
                if "result=NO_MARK" in line:
                    missing += 1
                    continue
                match = pattern.search(line)
                if match:
                    values.append(int(match.group(1)))
    return values, missing, facts


def percentile(values, fraction):
    """Nearest-rank. Not interpolated: with samples this few, interpolation
    invents a value between two measurements and presents it as measured."""
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, int(round(fraction * len(ordered) + 0.5)) - 1))
    return ordered[index]


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    key, paths = sys.argv[1], sys.argv[2:]
    values, missing, facts = parse(key, paths)

    print()
    for fact in facts:
        print(f"  {fact}")
    print(f"  metric_key={key}")

    if not values:
        print(f"  NO SAMPLES for {key}.")
        print("  This is [待验证], not zero and not fast. Check that the app was")
        print("  launched with -petnote-perf and that the mark is compiled in.")
        return 1

    print(f"  n={len(values)}" + (f"  MISSING={missing}" if missing else ""))
    if missing:
        print("  WARNING: samples were lost. A lost sample is not a fast sample;")
        print("           the distribution below is of what survived.")

    print(f"  min={min(values)}  median={int(statistics.median(values))}  max={max(values)}")
    if len(values) >= 2:
        print(f"  stdev={statistics.stdev(values):.1f}")

    if len(values) >= MIN_SAMPLES_FOR_P95:
        print(f"  p95={percentile(values, 0.95)}")
    else:
        print(f"  p95=NOT REPORTED — {len(values)} samples, "
              f"{MIN_SAMPLES_FOR_P95} required.")
        print("           A 95th percentile from fewer than 20 points is mostly")
        print("           the single worst sample with a percentile's name on it.")

    print("  all samples: " + " ".join(str(v) for v in values))

    # Outliers, named rather than dropped.
    if len(values) >= 5:
        median = statistics.median(values)
        outliers = [v for v in values if v > median * 1.5 or v < median * 0.5]
        if outliers:
            print("  outliers (>1.5x or <0.5x median): "
                  + " ".join(str(v) for v in outliers))
            print("  These stay in the distribution. Removing them needs a stated")
            print("  reason — a notification arrived, the device was thermally")
            print("  throttled — not the fact that they are inconvenient.")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
