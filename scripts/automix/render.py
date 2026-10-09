#!/usr/bin/env python3
"""T630 c3/c4: render song-pair transitions three ways and score them.

Strategies
  baseline : plain equal-power crossfade, fixed 8 s overlap at the end of A, B from 0. No analysis.
  beat     : beat-matched. B stretched to A's tempo (pitch-preserving, ±8 % cap), B's first downbeat
             landed on an A downbeat 8 bars before A's last downbeat. Equal-power crossfade.
  section  : beat + section-aligned + bass swap + loudness match. Mix-out at A's outro downbeat
             (cues.mixOut), mix-in at B's cues.mixIn, low-shelf handover at the midpoint, B trimmed
             to A's integrated loudness (±6 dB cap). Same guard as the Swift TransitionPlanner.

The guard picks the STYLE (never refuses): compatible pairs get `beat` + `section`; incompatible
pairs (tempo mismatch, quiet into loud, rubato) get `crossfade`: a loudness-matched equal-power
fade with no time-stretch and a gentle low-pass sweep, timed to A's mixOut and B's mixIn cues.

Scores per rendered transition
  beat_error_ms : median |nearest A beat − B beat| over the overlap, in the output timeline.
  stretch_pct   : |rate − 1| × 100 applied to B.
  loudness_jump : |short-term LUFS of the 3 s just after the overlap − 3 s just before it| (LU),
                  plus the largest step between consecutive 1 s short-term readings across it.
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
import librosa
import pyloudnorm as pyln
from scipy.signal import butter, sosfilt

WORK = Path(__file__).resolve().parent
META = WORK / "analysis/meta"  # overridden by --meta
CLIPS = WORK / "clips"
SAMPLES = WORK / "samples"

# Mirror of TransitionGuardThresholds in Swift.
MAX_TEMPO_DEV = 0.08
MAX_LOUDNESS_DELTA = 8.0
MIN_BEAT_CONF = 0.5
PREFERRED_BARS = 8
MIN_BARS = 2
MAX_GAIN_DB = 6.0
MIN_DURATION = 45.0


def load(name):
    y, sr = sf.read(str(CLIPS / f"{name}.flac"), dtype="float32", always_2d=True)
    return y, sr


def meta(name):
    return json.loads((META / f"{name}.json").read_text())



def tempo_match_rate(ta, tb):
    cands = [tb / 2, tb, tb * 2]
    best = min(cands, key=lambda c: abs(ta / c - 1))
    return ta / best


def bar_of(m):
    beats = np.array(m["beats"])
    bd = float(np.median(np.diff(beats))) if len(beats) > 2 else 60 / max(m["tempo"], 1)
    return bd * m.get("beatsPerBar", 4), bd


def downbeat_at_or_before(m, t):
    d = np.array(m["downbeats"]); d = d[d <= t + 1e-3]
    return float(d[-1]) if len(d) else t


def downbeat_at_or_after(m, t):
    d = np.array(m["downbeats"]); d = d[d >= t - 1e-3]
    return float(d[0]) if len(d) else t


def guard(a, b):
    """Returns (plan dict) or (None, reason) — same rules and order as TransitionPlanner.plan."""
    if a["duration"] < MIN_DURATION or b["duration"] < MIN_DURATION:
        return None, "trackTooShort"
    if a["beatConfidence"] < MIN_BEAT_CONF or b["beatConfidence"] < MIN_BEAT_CONF:
        return None, "lowBeatConfidence"
    rate = tempo_match_rate(a["tempo"], b["tempo"])
    if abs(rate - 1) > MAX_TEMPO_DEV:
        return None, "tempoMismatch"
    if abs(a["loudness"]["integrated"] - b["loudness"]["integrated"]) > MAX_LOUDNESS_DELTA:
        return None, "energyMismatch"
    bar_a, _ = bar_of(a)
    # The overlap must end where A still has beats: no later than the last downbeat. The outro
    # cue can only pull the mix-out earlier (mirrors TransitionPlanner).
    last_db_a = a["downbeats"][-1] if a["downbeats"] else a["duration"]
    mix_out = downbeat_at_or_before(a, min(a["cues"]["mixOut"], last_db_a - PREFERRED_BARS * bar_a))
    mix_in = downbeat_at_or_after(b, b["cues"]["mixIn"])
    avail_a = a["duration"] - mix_out
    avail_b = (b["duration"] - mix_in) / rate
    bars = min(PREFERRED_BARS, int(np.floor(min(avail_a, avail_b) / bar_a + 1e-6)))
    if bars < MIN_BARS:
        return None, "insufficientMaterial"
    gain = float(np.clip(a["loudness"]["integrated"] - b["loudness"]["integrated"], -MAX_GAIN_DB, MAX_GAIN_DB))
    return {"mixOut": mix_out, "mixIn": mix_in, "bars": bars, "overlap": bars * bar_a, "rate": rate,
            "gainDB": gain, "glide": min(8.0, 4 * bar_of(b)[0]), "bpb": a.get("beatsPerBar", 4)}, None


def bar_lock_schedule(a, b, mix_out, mix_in, bars, bpb, fallback_rate, cap=MAX_TEMPO_DEV):
    """Per-bar rates so each of B's bars lands on A's: rate_k = (B bar length) / (A bar length),
    clamped to the stretch cap. Returns [(out_seconds, rate)] or None when a grid is too sparse.
    Mirrors TransitionPlanner.rateSchedule."""
    ab, bb = np.array(a["beats"]), np.array(b["beats"])
    ia = int(np.searchsorted(ab, mix_out - 1e-3)); ib = int(np.searchsorted(bb, mix_in - 1e-3))
    if ia >= len(ab) or ib >= len(bb) or abs(ab[ia] - mix_out) > 0.05 or abs(bb[ib] - mix_in) > 0.05:
        return None
    # B's grid may be read at half/double time: pick the beat step that matches the rate.
    step_b = {0.5: 2, 1.0: 1, 2.0: 1}.get(round(fallback_rate * b["tempo"] / a["tempo"] * 2) / 2, 1)
    sched = []
    for k in range(bars):
        a0, a1 = ia + k * bpb, ia + (k + 1) * bpb
        b0, b1 = ib + k * bpb * step_b, ib + (k + 1) * bpb * step_b
        if a1 >= len(ab) or b1 >= len(bb):
            return None
        la, lb = ab[a1] - ab[a0], bb[b1] - bb[b0]
        if la <= 0 or lb <= 0:
            return None
        r = lb / la
        if abs(r - 1) > cap * 1.5:  # a skipped beat in one grid: do not chase it
            r = fallback_rate
        sched.append((float(la), float(np.clip(r, 1 - cap, 1 + cap))))
    return sched


def stretch(y, rate):
    """Pitch-preserving time stretch per channel (librosa phase vocoder; the phone uses
    AVAudioUnitTimePitch, same class of algorithm)."""
    if abs(rate - 1) < 1e-4:
        return y
    chans = [librosa.effects.time_stretch(y[:, c], rate=rate) for c in range(y.shape[1])]
    n = min(len(c) for c in chans)
    return np.stack([c[:n] for c in chans], axis=1)


def low_shelf(y, sr, gain_db, fc=150.0):
    """Approximate a low-shelf by splitting lows and scaling them (linear-phase enough for a swap)."""
    if gain_db == 0:
        return y
    sos = butter(2, fc, btype="low", fs=sr, output="sos")
    lows = sosfilt(sos, y, axis=0)
    g = 10 ** (gain_db / 20)
    return y - lows + lows * g


def equal_power(n):
    p = np.linspace(0, 1, n)
    return np.cos(p * np.pi / 2)[:, None], np.sin(p * np.pi / 2)[:, None]


def render_crossfade(ya, yb, sr, a, b, duration=8.0, sweep=True, tail_after=20.0):
    """Smooth crossfade for incompatible pairs: no stretch, equal-power, loudness-matched (±6 dB),
    low-pass sweep closing on A (20 kHz→800 Hz) and opening on B (800 Hz→20 kHz), timed to A's
    mixOut and B's mixIn cues. Mirrors TransitionPlanner.crossfade + AutoMixAutomation."""
    mix_out = downbeat_at_or_before(a, a["cues"]["mixOut"])
    mix_in = downbeat_at_or_after(b, b["cues"]["mixIn"])
    if b["duration"] - mix_in < duration:  # slide the incoming cue back so a full fade fits
        mix_in = downbeat_at_or_before(b, min(mix_in, max(0.0, b["duration"] - duration)))
    if a["duration"] - mix_out < 3.0:
        mix_out = downbeat_at_or_before(a, max(0.0, a["duration"] - duration))
    dur = max(0.5, min(duration, a["duration"] - mix_out, b["duration"] - mix_in))
    gain = float(np.clip(a["loudness"]["integrated"] - b["loudness"]["integrated"], -MAX_GAIN_DB, MAX_GAIN_DB))
    trim = 10 ** (gain / 20)
    n = int(dur * sr)
    a0 = int(mix_out * sr); b0 = int(mix_in * sr)
    ya_tail = ya[a0:a0 + n]; ya_tail = np.pad(ya_tail, ((0, n - len(ya_tail)), (0, 0)))
    yb_head = yb[b0:b0 + n]; yb_head = np.pad(yb_head, ((0, n - len(yb_head)), (0, 0)))
    fo, fi = equal_power(n)
    if sweep:
        # Piecewise sweep in 8 steps (log-frequency), applied with a 2nd-order low-pass per step.
        steps = 8
        lo, hi = np.log2(800.0), np.log2(20000.0)
        outs_a, outs_b = [], []
        for k in range(steps):
            s0, s1 = k * n // steps, (k + 1) * n // steps
            p = (k + 0.5) / steps
            fa = 2 ** (hi - (hi - lo) * p); fb = 2 ** (lo + (hi - lo) * p)
            sa = butter(2, min(fa, sr / 2 * 0.99), btype="low", fs=sr, output="sos")
            sb = butter(2, min(fb, sr / 2 * 0.99), btype="low", fs=sr, output="sos")
            outs_a.append(sosfilt(sa, ya_tail[s0:s1], axis=0)); outs_b.append(sosfilt(sb, yb_head[s0:s1], axis=0))
        ya_tail = np.concatenate(outs_a); yb_head = np.concatenate(outs_b)
    mixed = ya_tail * fo + yb_head * fi * trim
    rest = yb[b0 + n:b0 + n + int(tail_after * sr)] * trim
    out = np.concatenate([ya[:a0], mixed, rest]).astype(np.float32)
    peak = np.abs(out).max()
    if peak > 0.99:
        out = out / peak * 0.99
    return out, {"overlap_start": mix_out, "overlap_end": mix_out + dur, "b_file_at_overlap": mix_in,
                 "rate": 1.0, "gain_db": gain, "n_ov": n}


def render_blend(ya, yb, sr, mix_out, mix_in, overlap, rate, gain_db=0.0, bass_swap=False, glide=0.0,
                 tail_after=20.0, schedule=None):
    """Output timeline = A's clock. B enters at mix_out (A time) with its file at mix_in, stretched by
    `rate` for the overlap (then glides to 1 over `glide` s). Returns (audio, info)."""
    a_out = int(mix_out * sr)
    n_ov = int(overlap * sr)
    ya_pre = ya[:a_out]
    ya_tail = ya[a_out:a_out + n_ov]
    if len(ya_tail) < n_ov:
        ya_tail = np.pad(ya_tail, ((0, n_ov - len(ya_tail)), (0, 0)))
    b_start = int(mix_in * sr)
    # B material needed: overlap at `rate` + glide + a tail, in B-file seconds.
    need_b = int(((overlap) * rate + glide * (rate + 1) / 2 + tail_after) * sr) + sr
    yb_seg = yb[b_start:b_start + need_b]
    # Stretch the overlap part and the glide separately (piecewise-constant rate is what the
    # phone's time-pitch does between automation ticks; a 4-step ramp approximates the glide).
    if schedule:
        pieces, pos = [], 0
        for seg_out, r in schedule:
            src_len = int(seg_out * r * sr)
            pieces.append(stretch(yb_seg[pos:pos + src_len], r)[:int(seg_out * sr)]); pos += src_len
        yb_ov = np.concatenate(pieces)[:n_ov]
        if len(yb_ov) < n_ov:
            yb_ov = np.pad(yb_ov, ((0, n_ov - len(yb_ov)), (0, 0)))
        b_ov_src = pos
        rate = schedule[-1][1]  # the glide starts from the last bar's rate
    else:
        b_ov_src = int(overlap * rate * sr)
        yb_ov = stretch(yb_seg[:b_ov_src], rate)[:n_ov]
    if len(yb_ov) < n_ov:
        yb_ov = np.pad(yb_ov, ((0, n_ov - len(yb_ov)), (0, 0)))
    rest_src = yb_seg[b_ov_src:]
    if glide > 0 and abs(rate - 1) > 1e-4:
        steps = 4
        pieces, pos = [], 0
        for k in range(steps):
            r = rate + (1 - rate) * (k + 0.5) / steps
            src_len = int(glide / steps * r * sr)
            pieces.append(stretch(rest_src[pos:pos + src_len], r)); pos += src_len
        yb_rest = np.concatenate(pieces + [rest_src[pos:]])
    else:
        yb_rest = rest_src
    trim = 10 ** (gain_db / 20)
    fo, fi = equal_power(n_ov)
    if bass_swap:
        # Outgoing keeps the lows for the first half, then a 1-bar (1/8 overlap) ramp hands over.
        ramp = max(1, n_ov // 8)
        half = n_ov // 2
        a_low = np.ones((n_ov, 1), np.float32); b_low = np.zeros((n_ov, 1), np.float32)
        s0 = half - ramp // 2
        a_low[s0:s0 + ramp, 0] = np.linspace(1, 0, ramp); a_low[s0 + ramp:] = 0
        b_low[s0:s0 + ramp, 0] = np.linspace(0, 1, ramp); b_low[s0 + ramp:] = 1
        cut = 10 ** (-18 / 20)
        sos = butter(2, 150.0, btype="low", fs=sr, output="sos")
        a_lows = sosfilt(sos, ya_tail, axis=0); b_lows = sosfilt(sos, yb_ov, axis=0)
        ya_tail = ya_tail - a_lows + a_lows * (cut + (1 - cut) * a_low)
        yb_ov = yb_ov - b_lows + b_lows * (cut + (1 - cut) * b_low)
    mixed = ya_tail * fo + yb_ov * fi * trim
    out = np.concatenate([ya_pre, mixed, yb_rest * trim]).astype(np.float32)
    peak = np.abs(out).max()
    if peak > 0.99:
        out = out / peak * 0.99
    return out, {"overlap_start": mix_out, "overlap_end": mix_out + overlap, "b_file_at_overlap": mix_in,
                 "rate": rate, "gain_db": gain_db, "n_ov": n_ov, "schedule": schedule}


def beat_error_ms(a, b, info):
    """In the output timeline, A beats are at their file times. B beats land at
    overlap_start + (t_b − mix_in) / rate. Median nearest-neighbour distance over the overlap."""
    ab = np.array(a["beats"]); bb = np.array(b["beats"])
    s, e = info["overlap_start"], info["overlap_end"]
    a_in = ab[(ab >= s) & (ab <= e)]
    bb_in = bb[bb >= info["b_file_at_overlap"]] - info["b_file_at_overlap"]
    if info.get("schedule"):
        # piecewise map: B-file offset -> output offset through the per-bar rates
        edges_out, edges_src = [0.0], [0.0]
        for seg_out, r in info["schedule"]:
            edges_out.append(edges_out[-1] + seg_out); edges_src.append(edges_src[-1] + seg_out * r)
        b_out = s + np.interp(bb_in, edges_src, edges_out, right=np.nan)
        b_out = b_out[~np.isnan(b_out)]
    else:
        b_out = s + bb_in / info["rate"]
    b_in = b_out[(b_out >= s) & (b_out <= e)]
    if len(a_in) == 0 or len(b_in) == 0:
        return float("nan")
    d = np.array([np.min(np.abs(a_in - t)) for t in b_in])
    return float(np.median(d) * 1000)


def loudness_jump(out, sr, s, e):
    meter = pyln.Meter(sr)
    def st(t0, t1):
        seg = out[int(max(0, t0) * sr):int(t1 * sr)]
        if len(seg) < sr: return -70.0
        v = meter.integrated_loudness(seg); return float(v) if np.isfinite(v) else -70.0
    before = st(s - 3, s); after = st(e, e + 3)
    # largest 1 s step of 3 s short-term loudness across [s-5, e+5]
    vals = [st(t - 3, t) for t in np.arange(max(3, s - 5), min(len(out) / sr, e + 5), 1.0)]
    steps = [abs(x - y) for x, y in zip(vals[1:], vals[:-1]) if x > -60 and y > -60]
    return abs(after - before), (max(steps) if steps else 0.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pairs", required=True, help="JSON list of [A, B, expectation]")
    ap.add_argument("--out", default=str(SAMPLES))
    ap.add_argument("--results", required=True)
    ap.add_argument("--meta", default=None)
    args = ap.parse_args()
    global META
    if args.meta:
        META = Path(args.meta)
    pairs = json.loads(Path(args.pairs).read_text())
    out_dir = Path(args.out); out_dir.mkdir(parents=True, exist_ok=True)
    results = []
    for a_name, b_name, expect in pairs:
        a, b = meta(a_name), meta(b_name)
        ya, sr = load(a_name); yb, sr_b = load(b_name)
        if sr_b != sr:
            yb = np.stack([librosa.resample(yb[:, c], orig_sr=sr_b, target_sr=sr) for c in range(2)], 1)
        plan, reason = guard(a, b)
        row = {"pair": f"{a_name} -> {b_name}", "expect": expect, "style": "beat-matched" if plan else f"crossfade:{reason}",
               "tempoA": a["tempo"], "tempoB": b["tempo"], "lufsA": a["loudness"]["integrated"],
               "lufsB": a and b["loudness"]["integrated"], "confA": a["beatConfidence"], "confB": b["beatConfidence"],
               "strategies": {}}
        base = f"{a_name}__{b_name}"
        # ---- baseline: last 8 s of A over first 8 s of B, no analysis.
        ov = 8.0
        out, info = render_blend(ya, yb, sr, mix_out=a["duration"] - ov, mix_in=0.0, overlap=ov, rate=1.0)
        s, e = info["overlap_start"], info["overlap_end"]
        lj, step = loudness_jump(out, sr, s, e)
        clip = out[int(max(0, s - 20) * sr):int((e + 20) * sr)]
        sf.write(out_dir / f"{base}__1-baseline-crossfade.flac", clip, sr)
        row["strategies"]["baseline"] = {"beat_error_ms": beat_error_ms(a, b, info), "stretch_pct": 0.0,
                                         "loudness_jump_lu": lj, "max_step_lu": step, "overlap_s": ov}
        # ---- beat-matched (guard applies)
        if plan:
            bar_a, _ = bar_of(a)
            last_db = a["downbeats"][-1]
            mix_out_beat = downbeat_at_or_before(a, last_db - 8 * bar_a)
            mix_in_beat = float(a and b["downbeats"][0])
            out, info = render_blend(ya, yb, sr, mix_out_beat, mix_in_beat, 8 * bar_a, plan["rate"], glide=plan["glide"])
            s, e = info["overlap_start"], info["overlap_end"]
            lj, step = loudness_jump(out, sr, s, e)
            clip = out[int(max(0, s - 20) * sr):int((e + 20) * sr)]
            sf.write(out_dir / f"{base}__2-beat-matched.flac", clip, sr)
            row["strategies"]["beat"] = {"beat_error_ms": beat_error_ms(a, b, info),
                                         "stretch_pct": abs(plan["rate"] - 1) * 100,
                                         "loudness_jump_lu": lj, "max_step_lu": step, "overlap_s": 8 * bar_a}
            # ---- section-aligned + bass swap + loudness match
            sched = bar_lock_schedule(a, b, plan["mixOut"], plan["mixIn"], plan["bars"], plan["bpb"], plan["rate"])
            out, info = render_blend(ya, yb, sr, plan["mixOut"], plan["mixIn"], plan["overlap"], plan["rate"],
                                     gain_db=plan["gainDB"], bass_swap=True, glide=plan["glide"], schedule=sched)
            s, e = info["overlap_start"], info["overlap_end"]
            lj, step = loudness_jump(out, sr, s, e)
            clip = out[int(max(0, s - 20) * sr):int((e + 20) * sr)]
            sf.write(out_dir / f"{base}__3-section-bass-swap.flac", clip, sr)
            row["strategies"]["section"] = {"beat_error_ms": beat_error_ms(a, b, info),
                                            "stretch_pct": abs(plan["rate"] - 1) * 100,
                                            "loudness_jump_lu": lj, "max_step_lu": step,
                                            "overlap_s": plan["overlap"], "bars": plan["bars"],
                                            "gain_db": plan["gainDB"], "mixOut": plan["mixOut"], "mixIn": plan["mixIn"],
                                            "bar_locked": sched is not None,
                                            "rate_range_pct": [round((min(r for _, r in sched) - 1) * 100, 2), round((max(r for _, r in sched) - 1) * 100, 2)] if sched else None}
        else:
            out, info = render_crossfade(ya, yb, sr, a, b)
            s, e = info["overlap_start"], info["overlap_end"]
            lj, step = loudness_jump(out, sr, s, e)
            clip = out[int(max(0, s - 20) * sr):int((e + 20) * sr)]
            sf.write(out_dir / f"{base}__4-smooth-crossfade-{reason}.flac", clip, sr)
            row["strategies"]["crossfade"] = {"reason": reason, "beat_error_ms": beat_error_ms(a, b, info),
                                              "stretch_pct": 0.0, "loudness_jump_lu": lj, "max_step_lu": step,
                                              "overlap_s": e - s, "gain_db": info["gain_db"]}
        results.append(row)
        print(json.dumps(row), flush=True)
    Path(args.results).write_text(json.dumps(results, indent=1))


if __name__ == "__main__":
    main()
