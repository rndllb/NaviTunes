#!/usr/bin/env python3
"""T630 c2: measure beat/downbeat analysis models on this box.

For each model: on-disk size, parameter count, seconds per song on CPU (12 threads and 2 threads)
and on GPU, peak host RSS and peak GPU memory. Output: JSON + a markdown table.
"""
import argparse
import json
import os
import resource
import sys
import time
from pathlib import Path

import numpy as np
import torch

WORK = Path(__file__).resolve().parent


def rss_mb():
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024


def bench_beat_this(name, files, device, threads):
    from beat_this.inference import File2Beats
    torch.set_num_threads(threads)
    f2b = File2Beats(checkpoint_path=name, device=device, dbn=False)
    model = f2b.model
    params = sum(p.numel() for p in model.parameters())
    ckpt = WORK / "cache/torch/hub/checkpoints" / f"beat_this-{name}.ckpt"
    size = ckpt.stat().st_size if ckpt.exists() else None
    # warm-up on the first file (CUDA context, kernels)
    f2b(str(files[0]))
    if device == "cuda":
        torch.cuda.reset_peak_memory_stats(); torch.cuda.synchronize()
    times = []
    for f in files:
        t = time.perf_counter(); f2b(str(f))
        if device == "cuda": torch.cuda.synchronize()
        times.append(time.perf_counter() - t)
    gpu_peak = torch.cuda.max_memory_allocated() / 1e6 if device == "cuda" else None
    return {"params": params, "disk_bytes": size, "times": times, "gpu_peak_mb": gpu_peak}


def bench_madmom(files, threads):
    """RNNDownBeatProcessor (3 BLSTMs, numpy) + DBN. CPU only; it has no GPU path."""
    os.environ["OMP_NUM_THREADS"] = str(threads)
    from madmom.features.downbeats import RNNDownBeatProcessor, DBNDownBeatTrackingProcessor
    import madmom
    rnn = RNNDownBeatProcessor(num_threads=threads)
    dbn = DBNDownBeatTrackingProcessor(beats_per_bar=[3, 4], fps=100, num_threads=threads)
    model_dir = Path(madmom.__file__).parent / "models" / "downbeats"
    model_files = sorted(model_dir.glob("downbeats_blstm_*.pkl"))
    size = sum(f.stat().st_size for f in model_files)
    # parameter count: load the pickled ensemble members directly and count every ndarray weight
    from madmom.ml.nn import NeuralNetwork
    params = 0
    for f in model_files:
        nn = NeuralNetwork.load(str(f))
        for layer in nn.layers:
            for attr in vars(layer).values():
                if isinstance(attr, np.ndarray):
                    params += attr.size
                elif hasattr(attr, "__dict__"):
                    for v in vars(attr).values():
                        if isinstance(v, np.ndarray):
                            params += v.size
    rnn(str(files[0]))
    times = []
    for f in files:
        t = time.perf_counter(); act = rnn(str(f)); dbn(act); times.append(time.perf_counter() - t)
    return {"params": params, "disk_bytes": size, "times": times, "gpu_peak_mb": None,
            "model_files": [f.name for f in model_files]}


def bench_librosa(files, threads):
    import librosa, soundfile as sf
    times = []
    for f in files:
        y, sr = sf.read(str(f), dtype="float32"); y = y.mean(axis=1) if y.ndim == 2 else y
        t = time.perf_counter(); librosa.beat.beat_track(y=y, sr=sr, units="time"); times.append(time.perf_counter() - t)
    return {"params": 0, "disk_bytes": 0, "times": times, "gpu_peak_mb": None}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, help="final0 | small0 | madmom | librosa")
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--threads", type=int, default=12)
    ap.add_argument("--files", nargs="+", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    files = [Path(f) for f in a.files]
    import soundfile as sf
    durations = [sf.info(str(f)).duration for f in files]
    if a.model in ("final0", "small0", "final1", "small1"):
        r = bench_beat_this(a.model, files, a.device, a.threads)
    elif a.model == "madmom":
        r = bench_madmom(files, a.threads)
    elif a.model == "librosa":
        r = bench_librosa(files, a.threads)
    else:
        sys.exit("unknown model")
    r.update({"model": a.model, "device": a.device, "threads": a.threads, "files": [f.name for f in files],
              "durations": durations, "mean_s": float(np.mean(r["times"])),
              "mean_song_s": float(np.mean(durations)),
              "realtime_factor": float(np.mean(durations) / np.mean(r["times"])),
              "peak_rss_mb": rss_mb(), "torch": torch.__version__})
    Path(a.out).write_text(json.dumps(r, indent=1))
    print(f"{a.model:8s} {a.device:4s} thr={a.threads:2d} params={r['params']:,} disk={r['disk_bytes']} "
          f"mean={r['mean_s']:.2f}s/song ({r['realtime_factor']:.0f}x realtime) rss={r['peak_rss_mb']:.0f}MB gpu={r['gpu_peak_mb']}")


if __name__ == "__main__":
    main()
