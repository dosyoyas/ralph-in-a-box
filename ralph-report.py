#!/usr/bin/env python3
"""Summarise ralph metrics (one JSON line per agent run) to show where cost goes.

Usage: ralph-report.py [metrics.jsonl ...]   (default: /tmp/ralph_logs/claude_metrics_*.jsonl)
"""
import glob
import json
import sys
from collections import defaultdict

paths = sys.argv[1:] or sorted(glob.glob("/tmp/ralph_logs/claude_metrics_*.jsonl"))
rows = [json.loads(l) for p in paths for l in open(p) if l.strip()]
if not rows:
    sys.exit("no metrics found: " + " ".join(paths))

total = sum(r["cost_usd"] for r in rows) or 1e-9


def table(title, keyfn):
    g = defaultdict(lambda: defaultdict(float))
    for r in rows:
        a = g[keyfn(r)]
        a["runs"] += 1
        a["cost"] += r["cost_usd"]
        a["turns"] += r["num_turns"]
        a["wall"] += r["wall_s"]
        a["cache_read"] += r["tokens"]["cache_read"]
        a["cache_create"] += r["tokens"]["cache_creation"]
        a["output"] += r["tokens"]["output"]
        a["first_ctx"] += r["first_turn_ctx"]
    print(f"\n== {title}")
    print(f"{'':16}{'runs':>5}{'$':>8}{'%':>6}{'turns':>7}{'wall_s':>8}{'first_ctx':>10}{'cacheR_k':>10}{'cacheW_k':>10}{'out_k':>7}")
    for k, a in sorted(g.items(), key=lambda kv: -kv[1]["cost"]):
        n = a["runs"]
        print(f"{str(k):16}{n:5.0f}{a['cost']:8.2f}{100 * a['cost'] / total:6.0f}{a['turns']:7.0f}{a['wall']:8.0f}"
              f"{a['first_ctx'] / n:10.0f}{a['cache_read'] / 1e3:10.0f}{a['cache_create'] / 1e3:10.0f}{a['output'] / 1e3:7.1f}")


table("by phase", lambda r: r["phase"])
table("by iteration", lambda r: f"{r['iteration']:>3} {r['phase']}")

tools = defaultdict(lambda: [0, 0])
for r in rows:
    for k, v in r["tools"].items():
        tools[k][0] += v["n"]
        tools[k][1] += v["result_bytes"]
print("\n== tool calls (n) and result bytes fed back into context")
for k, (n, b) in sorted(tools.items(), key=lambda kv: -kv[1][1]):
    print(f"{k:16}{n:6d} calls{b / 1024:10.1f} KiB")

print(f"\nTOTAL ${sum(r['cost_usd'] for r in rows):.2f}, {len(rows)} runs, "
      f"{sum(r['num_turns'] for r in rows):.0f} turns, {sum(r['wall_s'] for r in rows) / 60:.1f} min")
print("first_ctx = tokens in the first turn (system + CLAUDE.md + prompt): fixed overhead paid by EVERY run.")
