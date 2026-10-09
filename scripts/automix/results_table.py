#!/usr/bin/env python3
"""Render results JSON (heuristic sections and All-In-One sections) into the markdown tables for
docs/automix.md and the report."""
import json, sys
from pathlib import Path
import numpy as np

W = Path(__file__).resolve().parent
heur = json.load(open(W / "analysis/results-heuristic.json"))
allin = json.load(open(W / "analysis/results-allin1.json")) if (W / "analysis/results-allin1.json").exists() else None

def f(x, d=1):
    return "—" if x is None or (isinstance(x, float) and np.isnan(x)) else f"{x:.{d}f}"

lines = []
lines.append("### Per pair (heuristic sections = the shipping rule)\n")
lines.append("| # | Pair | Style chosen | Baseline: beat err / jump | Beat-matched: beat err / stretch / jump | Section + bass swap: beat err / stretch / jump | Crossfade: jump (max step) |")
lines.append("|---|---|---|---|---|---|---|")
for i, r in enumerate(heur, 1):
    s = r["strategies"]
    b = s["baseline"]
    base = f"{f(b['beat_error_ms'],0)} ms / {f(b['loudness_jump_lu'])} LU"
    bm = sec = cf = "—"
    if "beat" in s:
        x = s["beat"]; bm = f"{f(x['beat_error_ms'],0)} ms / {f(x['stretch_pct'])} % / {f(x['loudness_jump_lu'])} LU"
    if "section" in s:
        x = s["section"]; sec = f"{f(x['beat_error_ms'],0)} ms / {f(x['stretch_pct'])} % / {f(x['loudness_jump_lu'])} LU ({x['bars']} bars)"
    if "crossfade" in s:
        x = s["crossfade"]; cf = f"{f(x['loudness_jump_lu'])} LU ({f(x['max_step_lu'])})"
    style = r["style"].replace("crossfade:", "crossfade · ")
    ok = "✓" if (r["expect"] == "blend") == (r["style"] == "beat-matched") else "✗"
    lines.append(f"| {i} | {r['pair']} | {style} {ok} | {base} | {bm} | {sec} | {cf} |")

def agg(rows, key, field):
    v = [r["strategies"][key][field] for r in rows if key in r["strategies"] and not (isinstance(r["strategies"][key][field], float) and np.isnan(r["strategies"][key][field]))]
    return (np.median(v), np.mean(v), len(v)) if v else (float("nan"), float("nan"), 0)

lines.append("\n### Aggregate over the beat-matched pairs (median / mean)\n")
lines.append("| Strategy | Beat error ms | Stretch % | Loudness jump LU | Max 1 s step LU | n |")
lines.append("|---|---|---|---|---|---|")
blends = [r for r in heur if r["style"] == "beat-matched"]
for key, label in (("baseline", "plain crossfade (no analysis)"), ("beat", "beat-matched"), ("section", "beat + section-aligned + bass swap + loudness match")):
    be = agg(blends, key, "beat_error_ms"); st = agg(blends, key, "stretch_pct"); lj = agg(blends, key, "loudness_jump_lu"); ms = agg(blends, key, "max_step_lu")
    lines.append(f"| {label} | {f(be[0],0)} / {f(be[1],0)} | {f(st[0])} / {f(st[1])} | {f(lj[0])} / {f(lj[1])} | {f(ms[0])} / {f(ms[1])} | {be[2]} |")
cross = [r for r in heur if r["style"] != "beat-matched"]
lines.append("\n### Incompatible pairs: smooth crossfade vs the plain baseline (median / mean)\n")
lines.append("| Strategy | Loudness jump LU | Max 1 s step LU | n |")
lines.append("|---|---|---|---|")
for key, label in (("baseline", "plain crossfade, last 8 s of A over first 8 s of B"), ("crossfade", "smooth crossfade: cue-timed, loudness-matched, filter sweep")):
    lj = agg(cross, key, "loudness_jump_lu"); ms = agg(cross, key, "max_step_lu")
    lines.append(f"| {label} | {f(lj[0])} / {f(lj[1])} | {f(ms[0])} / {f(ms[1])} | {lj[2]} |")

if allin:
    lines.append("\n### c8(e): heuristic sections vs All-In-One sections, same pairs, section strategy\n")
    lines.append("| # | Pair | Heuristic: mixOut→mixIn, beat err, jump | All-In-One: mixOut→mixIn, beat err, jump | Cue delta (A / B) |")
    lines.append("|---|---|---|---|---|")
    deltas_a, deltas_b, lj_h, lj_a = [], [], [], []
    for i, (h, a) in enumerate(zip(heur, allin), 1):
        hs, as_ = h["strategies"].get("section"), a["strategies"].get("section")
        if not hs or not as_:
            hk = "section" if hs else "crossfade"; ak = "section" if as_ else "crossfade"
            lines.append(f"| {i} | {h['pair']} | {h['style']} | {a['style']} | — |")
            continue
        da, db = hs["mixOut"] - as_["mixOut"], hs["mixIn"] - as_["mixIn"]
        deltas_a.append(abs(da)); deltas_b.append(abs(db)); lj_h.append(hs["loudness_jump_lu"]); lj_a.append(as_["loudness_jump_lu"])
        lines.append(f"| {i} | {h['pair']} | {hs['mixOut']:.1f}→{hs['mixIn']:.1f}, {f(hs['beat_error_ms'],0)} ms, {f(hs['loudness_jump_lu'])} LU | {as_['mixOut']:.1f}→{as_['mixIn']:.1f}, {f(as_['beat_error_ms'],0)} ms, {f(as_['loudness_jump_lu'])} LU | {da:+.1f} s / {db:+.1f} s |")
    if deltas_a:
        lines.append(f"\nMedian |cue delta|: mix-out {np.median(deltas_a):.1f} s, mix-in {np.median(deltas_b):.1f} s over {len(deltas_a)} blended pairs. "
                     f"Median loudness jump: heuristic {np.median(lj_h):.1f} LU vs All-In-One {np.median(lj_a):.1f} LU.")
print("\n".join(lines))
