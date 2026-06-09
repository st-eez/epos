#!/usr/bin/env python3
"""Honest post-hoc scoring for the local polish model sweep.

The Swift harness's `residual+` count is triage only: `out != det` fires for
under-performance (model left um/uh that det removes) and for empty-output collapse,
so the raw counts over-credit. This re-scores each cell directionally from the stored
canon/det/out, and emits ONLY the genuinely ambiguous cells (changed-disfluent,
content-defect-bait) to a judge-input file for the skeptical Claude judge pass.

  python3 scripts/score-polish-sweep.py            # scores .build/evals/sweep.jsonl
  python3 scripts/score-polish-sweep.py FILE...     # specific files
"""
import sys
import re
import glob
import json
from pathlib import Path
from collections import defaultdict

HARD_FILLERS = {"um", "uh", "er", "hmm"}
EVALS = Path(__file__).resolve().parent.parent / ".build" / "evals"


def tokens(s):
    return re.findall(r"[a-z0-9']+", s.lower())


def has_hard_filler(s):
    return any(t in HARD_FILLERS for t in tokens(s))


def classify_disfluent(canon, out):
    if out.strip() == "":
        return "empty"            # catastrophic data loss
    if out == canon:
        return "noop"             # model did nothing
    if has_hard_filler(out):
        return "left-fillers"     # worse than the deterministic floor
    return "changed"              # candidate clean — judge decides good vs mangled


def classify_bait(canon, out):
    if out == canon:
        return "identical"        # the only fully-safe outcome
    if tokens(out) == tokens(canon):
        return "cosmetic"         # punctuation/casing only — guard-fixable
    return "content-defect"       # content tokens changed — disqualifying-ish, judge confirms


def main():
    files = sys.argv[1:] or sorted(glob.glob(str(EVALS / "sweep.jsonl")))
    if not files:
        print("no sweep files found", file=sys.stderr)
        return 1
    cells = []
    for f in files:
        for line in open(f):
            line = line.strip()
            if line:
                cells.append(json.loads(line))

    # config -> bucket -> count
    stats = defaultdict(lambda: defaultdict(int))
    latency = defaultdict(list)
    judge_input = []
    for c in cells:
        key = (c["model"], c["prompt"], c["kt"])
        latency[key].append(c.get("latencyMs", 0))
        if c["set"] == "disfluent":
            verdict = classify_disfluent(c["canon"], c["out"])
            stats[key]["d:" + verdict] += 1
            if verdict == "changed":
                judge_input.append({**slim(c), "axis": "disfluent-quality"})
        else:
            verdict = classify_bait(c["canon"], c["out"])
            stats[key]["b:" + verdict] += 1
            if verdict == "content-defect":
                judge_input.append({**slim(c), "axis": "bait-content"})

    print("\n════════ Honest sweep scoring ════════")
    print("disfluent (8): noop=did-nothing empty=DATA-LOSS left-fillers=worse-than-floor changed=candidate")
    print("bait (13): identical=safe cosmetic=punct/case content-defect=meaning\n")
    header = f"{'model':<12} {'prompt':<13} {'kt':<9} | {'noop':>4} {'empty':>5} {'leftF':>5} {'chg':>4} | {'ident':>5} {'cosm':>4} {'cDef':>4} | {'ms':>5}"
    print(header)
    print("-" * len(header))
    for key in sorted(stats):
        s = stats[key]
        avg = int(sum(latency[key]) / len(latency[key])) if latency[key] else 0
        m, p, k = key
        print(f"{m:<12} {p:<13} {k:<9} | {s['d:noop']:>4} {s['d:empty']:>5} {s['d:left-fillers']:>5} {s['d:changed']:>4} | "
              f"{s['b:identical']:>5} {s['b:cosmetic']:>4} {s['b:content-defect']:>4} | {avg:>5}")

    out_path = EVALS / "judge-input.jsonl"
    out_path.write_text("\n".join(json.dumps(j) for j in judge_input) + "\n")
    print(f"\nwrote {out_path} ({len(judge_input)} cells need judging)")
    return 0


def slim(c):
    return {k: c[k] for k in ("model", "prompt", "kt", "set", "canon", "det", "out")}


if __name__ == "__main__":
    sys.exit(main())
