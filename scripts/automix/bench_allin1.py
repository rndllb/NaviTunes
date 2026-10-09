#!/usr/bin/env python3
"""c2: All-In-One (harmonix-all ensemble) + its Demucs front end. Disk size, params, s/song, memory."""
import argparse, json, resource, time
from pathlib import Path
import numpy as np, torch, soundfile as sf

WORK = Path(__file__).resolve().parent

ap = argparse.ArgumentParser()
ap.add_argument("--device", default="cuda")
ap.add_argument("--threads", type=int, default=12)
ap.add_argument("--files", nargs="+", required=True)
ap.add_argument("--out", required=True)
a = ap.parse_args()
torch.set_num_threads(a.threads)
import allin1
from allin1.models import load_pretrained_model
files = [Path(f) for f in a.files]
durations = [sf.info(str(f)).duration for f in files]
model = load_pretrained_model(model_name="harmonix-all", device=a.device)
params = sum(p.numel() for p in model.parameters())
if params == 0 and hasattr(model, "models"):
    params = sum(p.numel() for m in model.models for p in m.parameters())
if params == 0:
    sd = torch.load(sorted((WORK / "cache/hf").rglob("harmonix-fold0*.pth"))[0], map_location="cpu")
    sd = sd.get("state_dict", sd); params = sum(v.numel() for v in sd.values() if hasattr(v, "numel"))
# demucs (htdemucs) weights live under TORCH_HOME/hub/checkpoints; allin1 weights under HF cache.
hub = WORK / "cache/torch/hub/checkpoints"
demucs_bytes = sum(f.stat().st_size for f in (WORK / "cache/hf").rglob("*.safetensors"))
hf = WORK / "cache/hf"
allin1_bytes = sum(f.stat().st_size for f in hf.rglob("harmonix-*.pth"))
del model
workdir = WORK / "analysis"
def run(f):
    return allin1.analyze(str(f), device=a.device, demix_dir=str(workdir / "demix"), spec_dir=str(workdir / "spec"),
                          keep_byproducts=False, multiprocess=False)
run(files[0])  # warm-up
if a.device == "cuda":
    torch.cuda.reset_peak_memory_stats(); torch.cuda.synchronize()
times = []
for f in files:
    t = time.perf_counter(); run(f)
    if a.device == "cuda": torch.cuda.synchronize()
    times.append(time.perf_counter() - t)
r = {"model": "allin1:harmonix-all(+htdemucs)", "device": a.device, "threads": a.threads,
     "params": params, "disk_bytes": allin1_bytes, "demucs_disk_bytes": demucs_bytes,
     "times": times, "mean_s": float(np.mean(times)), "mean_song_s": float(np.mean(durations)),
     "realtime_factor": float(np.mean(durations) / np.mean(times)),
     "gpu_peak_mb": torch.cuda.max_memory_allocated() / 1e6 if a.device == "cuda" else None,
     "peak_rss_mb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024, "torch": torch.__version__}
Path(a.out).write_text(json.dumps(r, indent=1))
print(f"allin1 {a.device} params={params:,} disk={allin1_bytes}+demucs {demucs_bytes} mean={r['mean_s']:.1f}s/song "
      f"rss={r['peak_rss_mb']:.0f}MB gpu={r['gpu_peak_mb']}")
