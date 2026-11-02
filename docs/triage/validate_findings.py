#!/usr/bin/env python3
"""Validate T344 finding JSONs against the vellum triage data contract.

The contract (amended 2026-09-16, md5 32c56d39c6254d7d69f938f99f6cce2e) is the
interface between this run and the swipe app, whose author cannot talk to us.
Drift here fails at the join, when it is most expensive — so every file is
checked before handoff rather than after.

    python3 docs/triage/validate_findings.py

Exits non-zero if any file violates the contract.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent
FINDINGS = ROOT / "findings"

REQUIRED = [
    "id", "source", "source_verdict", "title", "claim", "class", "status",
    "video", "description", "issue", "proposed_fix", "steps", "tested_at", "notes",
]
OPTIONAL = {"image", "no_video_reason", "surviving_defect"}

CLASSES = {"visual", "systemic", "taste", "untestable"}
STATUSES = {"confirmed", "already_fixed", "not_reproduced", "cannot_test", "needs_decision"}
VERDICTS = {"CONFIRMED", "REINFORCED", "DENIED", None}
SEVERITIES = {"low", "medium", "high"}
SURVIVING_KEYS = {"title", "severity", "description", "proposed_fix"}

# The contract PINS the evidence field names because producer and consumer once
# guessed them in opposite directions. The app tolerates a few aliases as a
# kindness; this producer must never need them, so a near-miss is an error here.
NEAR_MISSES = {
    "screenshot": "image", "still": "image", "img": "image",
    "no_video": "no_video_reason", "video_reason": "no_video_reason",
    "novideo_reason": "no_video_reason", "videoReason": "no_video_reason",
    "noVideoReason": "no_video_reason",
    "survivingDefect": "surviving_defect", "surviving": "surviving_defect",
    "residual_defect": "surviving_defect",
}


def nonempty_str(v):
    return isinstance(v, str) and v.strip() != ""


def validate(path):
    errs = []
    try:
        d = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        return [f"{path.name}: not valid JSON — {e}"]

    for key in REQUIRED:
        if key not in d:
            errs.append(f"{path.name}: missing required key '{key}'")
    for key in d:
        if key in NEAR_MISSES:
            errs.append(f"{path.name}: '{key}' is a near-miss; the pinned name is '{NEAR_MISSES[key]}'")
        elif key not in REQUIRED and key not in OPTIONAL:
            errs.append(f"{path.name}: unknown key '{key}' is not in the contract")
    if errs:
        return errs

    if d["id"] != path.stem:
        errs.append(f"{path.name}: id '{d['id']}' does not match filename")
    if d["class"] not in CLASSES:
        errs.append(f"{path.name}: class '{d['class']}' not in {sorted(CLASSES)}")
    if d["status"] not in STATUSES:
        errs.append(f"{path.name}: status '{d['status']}' not in {sorted(STATUSES)}")
    if d["source_verdict"] not in VERDICTS:
        errs.append(f"{path.name}: source_verdict '{d['source_verdict']}' invalid")
    if not isinstance(d["steps"], list) or not d["steps"]:
        errs.append(f"{path.name}: steps must be a non-empty list")

    # Evidence: exactly one of video / image carries it, never both. When neither
    # does, no_video_reason must say why, so "nothing to film" is distinguishable
    # from "the recording failed" — which a bare null is not.
    video, image = d.get("video"), d.get("image")
    reason = d.get("no_video_reason")
    if video and image:
        errs.append(f"{path.name}: both 'video' and 'image' set; exactly one carries the evidence")
    for field, value in (("video", video), ("image", image)):
        if value is None:
            continue
        if not nonempty_str(value):
            errs.append(f"{path.name}: '{field}' must be a relative path string or null")
        elif not (ROOT / value).is_file():
            errs.append(f"{path.name}: {field} '{value}' does not exist on disk")
    if not video and not image and not nonempty_str(reason):
        errs.append(f"{path.name}: 'video' is null and no 'image' given, so 'no_video_reason' is required")
    if reason is not None and not nonempty_str(reason):
        errs.append(f"{path.name}: 'no_video_reason' must be a non-empty string when present")

    sd = d.get("surviving_defect")
    if sd is not None:
        if not isinstance(sd, dict):
            errs.append(f"{path.name}: 'surviving_defect' must be an object")
        else:
            missing = SURVIVING_KEYS - sd.keys()
            extra = sd.keys() - SURVIVING_KEYS
            if missing:
                errs.append(f"{path.name}: surviving_defect missing {sorted(missing)}")
            if extra:
                errs.append(f"{path.name}: surviving_defect has unknown keys {sorted(extra)}")
            if sd.get("severity") not in SEVERITIES:
                errs.append(f"{path.name}: surviving_defect.severity '{sd.get('severity')}' not in {sorted(SEVERITIES)}")
            for k in SURVIVING_KEYS - {"severity"}:
                if k in sd and not nonempty_str(sd[k]):
                    errs.append(f"{path.name}: surviving_defect.{k} must be a non-empty string")

    return errs


# Other tasks write probe files into this directory (T348 writes ZZ-T348-PROBE to
# prove its scheduler carries a finding to the phone unattended). Those are not this
# run's findings: counting them would misreport the batch size and the status
# distribution. They are skipped, never deleted — deleting one would break another
# task's in-flight test.
FOREIGN_PREFIXES = ("ZZ-",)


def is_foreign(path):
    return path.stem.startswith(FOREIGN_PREFIXES)


def main():
    if not FINDINGS.is_dir():
        print(f"no findings directory at {FINDINGS}", file=sys.stderr)
        return 1

    skipped = [p.stem for p in sorted(FINDINGS.glob("*.json")) if is_foreign(p)]
    if skipped:
        print(f"skipping {len(skipped)} foreign file(s), not this run's: {', '.join(skipped)}")

    files = [p for p in sorted(FINDINGS.glob("*.json")) if not is_foreign(p)]
    if not files:
        print("no finding files found", file=sys.stderr)
        return 1

    all_errs, statuses, evidence, surviving = [], {}, {}, []
    for f in files:
        errs = validate(f)
        all_errs += errs
        if not errs:
            d = json.loads(f.read_text())
            statuses.setdefault(d["status"], []).append(f.stem)
            kind = "video" if d.get("video") else "image" if d.get("image") else "no_video_reason"
            evidence.setdefault(kind, []).append(f.stem)
            if d.get("surviving_defect"):
                surviving.append(f"{f.stem} ({d['surviving_defect']['severity']})")

    print(f"checked {len(files)} finding(s)")
    print("status:")
    for status in sorted(statuses):
        ids = statuses[status]
        print(f"  {status:16s} {len(ids):3d}  {', '.join(ids)}")
    print("evidence:")
    for kind in sorted(evidence):
        ids = evidence[kind]
        print(f"  {kind:16s} {len(ids):3d}  {', '.join(ids)}")
    if surviving:
        print(f"surviving_defect: {', '.join(surviving)}")

    if all_errs:
        print(f"\n{len(all_errs)} contract violation(s):", file=sys.stderr)
        for e in all_errs:
            print(f"  - {e}", file=sys.stderr)
        return 1

    print("\nall files conform to the contract")
    return 0


if __name__ == "__main__":
    sys.exit(main())
