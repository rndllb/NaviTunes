#!/usr/bin/env python3
"""c8(b): try to convert Beat This `small0` to Core ML on this Linux box.

Input: one fixed chunk of log-mel frames (1, 1500, 128) — 30 s at 50 fps — exactly the chunk the
reference inference uses, so the phone runs the same static shape and memory stays bounded.
Output: beat and downbeat logits (1, 1500) each.
"""
import os, sys, time, json
from pathlib import Path
import torch
import numpy as np

WORK = Path(__file__).resolve().parent
os.environ.setdefault("TORCH_HOME", str(WORK / "cache/torch"))
from beat_this.inference import load_model

name = sys.argv[1] if len(sys.argv) > 1 else "small0"
out = WORK / "analysis" / "coreml"
out.mkdir(parents=True, exist_ok=True)
model = load_model(name, device="cpu").eval()


class Wrapped(torch.nn.Module):
    def __init__(self, m):
        super().__init__(); self.m = m
    def forward(self, spect):
        r = self.m(spect)
        return r["beat"], r["downbeat"]


w = Wrapped(model).eval()
x = torch.randn(1, 1500, 128)
with torch.no_grad():
    ref_b, ref_d = w(x)
report = {"model": name, "params": sum(p.numel() for p in model.parameters()),
          "source_ckpt_bytes": (WORK / f"cache/torch/hub/checkpoints/beat_this-{name}.ckpt").stat().st_size}
# Peak host memory for one 30 s chunk on CPU (what the phone would hold at once).
import resource, tracemalloc
t = time.perf_counter()
with torch.no_grad():
    for _ in range(3): w(x)
report["cpu_chunk_seconds_1thread"] = None
torch.set_num_threads(1)
t = time.perf_counter()
with torch.no_grad(): w(x)
report["cpu_chunk_seconds_1thread"] = time.perf_counter() - t
torch.set_num_threads(12)
report["peak_rss_mb"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024

try:
    import coremltools as ct
    traced = torch.jit.trace(w, x)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="spectrogram", shape=(1, 1500, 128), dtype=np.float32)],
        outputs=[ct.TensorType(name="beat"), ct.TensorType(name="downbeat")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
    )
    pkg = out / f"BeatThis-{name}.mlpackage"
    mlmodel.save(str(pkg))
    size = sum(f.stat().st_size for f in pkg.rglob("*") if f.is_file())
    report.update({"coreml": "converted", "mlpackage": str(pkg), "mlpackage_bytes": size})
    # Prediction is macOS-only; on Linux we can only confirm the package was written.
    try:
        pred = mlmodel.predict({"spectrogram": x.numpy()})
        report["linux_predict"] = "ok"
        report["max_abs_diff_beat"] = float(np.abs(pred["beat"] - ref_b.numpy()).max())
    except Exception as e:  # expected on Linux: no Core ML runtime
        report["linux_predict"] = f"unavailable: {type(e).__name__}: {str(e)[:160]}"
except Exception as e:
    import traceback
    report.update({"coreml": "failed", "error": f"{type(e).__name__}: {str(e)[:600]}",
                   "trace_tail": traceback.format_exc()[-1500:]})

(out / f"convert-{name}.json").write_text(json.dumps(report, indent=1))
print(json.dumps({k: v for k, v in report.items() if k != "trace_tail"}, indent=1))
