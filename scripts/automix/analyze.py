#!/usr/bin/env python3
"""Server-side AutoMix analysis for one or more audio files.

Writes one JSON per track in the schema `TransitionMetadata` (Swift) decodes:
beats, downbeats, tempo, key, loudness, sections, cue points.

Beat/downbeat tracking: Beat This (CPJKU) by default. Sections: All-In-One when
`--sections allin1` and the allin1 venv is given, otherwise a librosa
self-similarity segmentation with energy-based intro/outro labelling.
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf
import librosa
import pyloudnorm as pyln

SCHEMA_VERSION = 1

KEY_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
# Krumhansl-Schmuckler profiles
MAJOR = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
MINOR = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
CAMELOT_MAJOR = {"C": "8B", "C#": "3B", "D": "10B", "D#": "5B", "E": "12B", "F": "7B", "F#": "2B",
                 "G": "9B", "G#": "4B", "A": "11B", "A#": "6B", "B": "1B"}
CAMELOT_MINOR = {"C": "5A", "C#": "12A", "D": "7A", "D#": "2A", "E": "9A", "F": "4A", "F#": "11A",
                 "G": "6A", "G#": "1A", "A": "8A", "A#": "3A", "B": "10A"}


def estimate_key(y, sr):
    chroma = librosa.feature.chroma_cqt(y=y, sr=sr)
    prof = chroma.mean(axis=1)
    best = None
    for i in range(12):
        for mode, template in (("major", MAJOR), ("minor", MINOR)):
            score = np.corrcoef(np.roll(template, i), prof)[0, 1]
            if best is None or score > best[0]:
                best = (score, KEY_NAMES[i], mode)
    _, tonic, mode = best
    camelot = (CAMELOT_MAJOR if mode == "major" else CAMELOT_MINOR)[tonic]
    return {"tonic": tonic, "mode": mode, "camelot": camelot}


def loudness_block(meter, y, sr, start, end):
    a, b = int(max(0, start) * sr), int(min(len(y) / sr, end) * sr)
    seg = y[a:b]
    if len(seg) < sr * 0.5:
        return -70.0
    v = meter.integrated_loudness(seg)
    return float(v) if np.isfinite(v) else -70.0


def loudness_range(meter, y, sr):
    # Short-term (3 s) loudness distribution, 10th..95th percentile (EBU R128 style approximation).
    win, hop = int(3 * sr), int(1 * sr)
    vals = []
    for s in range(0, max(1, len(y) - win), hop):
        v = meter.integrated_loudness(y[s:s + win])
        if np.isfinite(v) and v > -70:
            vals.append(v)
    if len(vals) < 3:
        return 0.0
    vals = np.array(vals)
    vals = vals[vals > vals.max() - 20]
    return float(np.percentile(vals, 95) - np.percentile(vals, 10))


def heuristic_sections(y, sr, downbeats, duration, bar):
    """The phone-runnable intro/outro heuristic (ported 1:1 to Swift `IntroOutroHeuristic`).

    RMS envelope per bar (downbeat to downbeat). Reference level = 90th percentile of bar RMS.
    intro = leading run of bars under 70 % of the reference (at least 1 bar, at most 32);
    outro = trailing run of bars under 70 % of the reference (same limits). Everything between
    is 'body'. No chroma, no self-similarity, no model: O(n) over the envelope."""
    if len(downbeats) < 4:
        return [{"start": 0.0, "end": duration, "label": "body"}]
    edges = list(map(float, downbeats))
    if edges[0] > 0.5: edges = [0.0] + edges
    if duration - edges[-1] > 0.5: edges.append(duration)
    rms = []
    for s, e in zip(edges[:-1], edges[1:]):
        seg = y[int(s * sr):int(e * sr)]
        rms.append(float(np.sqrt(np.mean(seg ** 2))) if len(seg) else 0.0)
    rms = np.array(rms)
    ref = float(np.percentile(rms, 90)) if len(rms) else 1.0
    thr = 0.7 * ref
    n = len(rms)
    intro_bars = 0
    while intro_bars < min(32, n - 1) and rms[intro_bars] < thr:
        intro_bars += 1
    outro_bars = 0
    while outro_bars < min(32, n - 1 - intro_bars) and rms[n - 1 - outro_bars] < thr:
        outro_bars += 1
    sections = []
    if intro_bars > 0:
        sections.append({"start": 0.0, "end": round(edges[intro_bars], 3), "label": "intro"})
    body_end = edges[n - outro_bars] if outro_bars > 0 else duration
    sections.append({"start": round(edges[intro_bars], 3), "end": round(body_end, 3), "label": "body"})
    if outro_bars > 0:
        sections.append({"start": round(body_end, 3), "end": duration, "label": "outro"})
    return sections


def allin1_sections(path, venv_python, workdir):
    """Run All-In-One in its own venv (different torch) and read back segments + its beats."""
    import subprocess
    code = (
        "import allin1, json, sys\n"
        f"r = allin1.analyze({str(path)!r}, device='cuda', demix_dir={str(workdir / 'demix')!r}, "
        f"spec_dir={str(workdir / 'spec')!r}, keep_byproducts=False)\n"
        "print(json.dumps({'bpm': r.bpm, 'beats': list(map(float, r.beats)), 'downbeats': list(map(float, r.downbeats)), "
        "'segments': [{'start': float(s.start), 'end': float(s.end), 'label': s.label} for s in r.segments]}))\n"
    )
    out = subprocess.run([venv_python, "-c", code], capture_output=True, text=True, env=os.environ)
    if out.returncode != 0:
        sys.stderr.write(out.stderr[-2000:])
        return None
    return json.loads(out.stdout.strip().splitlines()[-1])


def beat_confidence(beats, duration):
    """1.0 for a steady grid, low for rubato/no beats: 1 - normalized MAD of beat intervals."""
    if len(beats) < 8 or duration <= 0:
        return 0.0
    iv = np.diff(beats)
    med = np.median(iv)
    if med <= 0:
        return 0.0
    mad = np.median(np.abs(iv - med)) / med
    coverage = min(1.0, (beats[-1] - beats[0]) / max(1.0, duration - 2))
    return float(max(0.0, min(1.0, (1.0 - 8.0 * mad))) * coverage)


def pick_cues(beats, downbeats, sections, duration, bar):
    """mixIn: the downbeat 8 bars before the intro ends (so the song's body starts as the outgoing
    song finishes), or the first downbeat. mixOut: the outro's first downbeat, else 8 bars before
    the last downbeat. An 'intro' or 'outro' longer than 32 bars is not one."""
    intro = next((s for s in sections if s["label"] == "intro"), None)
    outro = next((s for s in sections if s["label"] == "outro"), None)
    if intro is not None and (intro["end"] - intro["start"]) > 32 * bar:
        intro["label"] = "verse"; intro = None
    if outro is not None and (outro["end"] - outro["start"]) > 32 * bar:
        outro["label"] = "verse"; outro = None
    first_db = float(downbeats[0]) if len(downbeats) else 0.0
    last_db = float(downbeats[-1]) if len(downbeats) else duration
    mix_in = first_db
    if intro is not None and len(downbeats):
        target = intro["end"] - 8 * bar
        if target > first_db:
            mix_in = float(downbeats[np.argmin(np.abs(downbeats - target))])
    if outro is not None and len(downbeats):
        cands = downbeats[downbeats >= outro["start"] - 0.01]
        mix_out = float(cands[0]) if len(cands) else last_db - 8 * bar
    else:
        mix_out = last_db - 8 * bar
    mix_out = max(mix_in + bar, min(mix_out, duration - 2 * bar))
    if len(downbeats):
        earlier = downbeats[downbeats <= mix_out + 0.01]
        if len(earlier):
            mix_out = float(earlier[-1])
    return {"mixIn": round(mix_in, 3), "mixOut": round(mix_out, 3)}


def analyze_one(path, model, out_dir, f2b, allin1_python, workdir, sections_mode):
    t0 = time.time()
    y, sr = sf.read(str(path), dtype="float32", always_2d=True)
    stereo = y
    mono = y.mean(axis=1)
    duration = len(mono) / sr

    analyzer = None
    allin1_result = None
    if sections_mode == "allin1" and allin1_python:
        allin1_result = allin1_sections(path, allin1_python, workdir)

    if model == "allin1" and allin1_result:
        beats = np.array(allin1_result["beats"]); downbeats = np.array(allin1_result["downbeats"])
        analyzer = "allin1:harmonix-all"
    else:
        beats, downbeats = f2b(str(path))
        beats, downbeats = np.asarray(beats, dtype=float), np.asarray(downbeats, dtype=float)
        analyzer = f"beat_this:{model}"

    tempo = float(60.0 / np.median(np.diff(beats))) if len(beats) > 2 else 0.0
    beat_dur = 60.0 / tempo if tempo > 0 else 0.5
    bpb = 4
    if len(downbeats) > 2 and beat_dur > 0:
        n = int(round(np.median(np.diff(downbeats)) / beat_dur))
        bpb = n if 2 <= n <= 7 else 4
    bar = beat_dur * bpb

    meter = pyln.Meter(sr)
    integrated = float(meter.integrated_loudness(stereo))
    if allin1_result:
        sections = [{"start": round(s["start"], 3), "end": round(s["end"], 3), "label": s["label"]}
                    for s in allin1_result["segments"]]
    else:
        sections = heuristic_sections(mono, sr, downbeats, duration, bar)
    cues = pick_cues(beats, downbeats, sections, duration, bar)
    y22 = librosa.resample(mono, orig_sr=sr, target_sr=22050) if sr != 22050 else mono
    key = estimate_key(y22, 22050)

    meta = {
        "version": SCHEMA_VERSION,
        "trackId": path.stem,
        "duration": round(duration, 3),
        "tempo": round(tempo, 3),
        "beats": [round(float(b), 3) for b in beats],
        "downbeats": [round(float(d), 3) for d in downbeats],
        "beatConfidence": round(beat_confidence(beats, duration), 3),
        "key": key,
        "loudness": {
            "integrated": round(integrated, 2),
            "range": round(loudness_range(meter, stereo, sr), 2),
            "intro": round(loudness_block(meter, stereo, sr, cues["mixIn"], cues["mixIn"] + 10), 2),
            "outro": round(loudness_block(meter, stereo, sr, cues["mixOut"] - 10, cues["mixOut"]), 2),
        },
        "sections": sections,
        "cues": cues,
        "analyzer": analyzer,
        "beatsPerBar": bpb,
        "analysisSeconds": round(time.time() - t0, 2),
    }
    out = out_dir / f"{path.stem}.json"
    out.write_text(json.dumps(meta))
    return meta


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--out", required=True)
    ap.add_argument("--model", default="final0", help="beat_this checkpoint name, or 'allin1'")
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--sections", default="heuristic", choices=["heuristic", "allin1"])
    ap.add_argument("--allin1-python", default=None)
    ap.add_argument("--workdir", default=".")
    args = ap.parse_args()
    out_dir = Path(args.out); out_dir.mkdir(parents=True, exist_ok=True)
    f2b = None
    if args.model != "allin1":
        from beat_this.inference import File2Beats
        f2b = File2Beats(checkpoint_path=args.model, device=args.device, dbn=False)
    for f in args.files:
        p = Path(f)
        m = analyze_one(p, args.model, out_dir, f2b, args.allin1_python, Path(args.workdir), args.sections)
        print(f"{p.stem:45s} {m['tempo']:7.2f} bpm  conf {m['beatConfidence']:.2f}  "
              f"{m['loudness']['integrated']:6.1f} LUFS  key {m['key']['camelot']:>3s}  "
              f"mixIn {m['cues']['mixIn']:6.1f} mixOut {m['cues']['mixOut']:6.1f}  "
              f"sections {[s['label'] for s in m['sections']]}  {m['analysisSeconds']}s", flush=True)


if __name__ == "__main__":
    main()
