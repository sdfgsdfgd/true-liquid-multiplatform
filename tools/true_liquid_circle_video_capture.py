#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DRAG_ONLY = ROOT / "tools" / "true_liquid_circle_drag_only.swift"
CROP_RE = re.compile(r"crop=(?P<x>-?\d+(?:\.\d+)?),(?P<y>-?\d+(?:\.\d+)?),(?P<w>-?\d+(?:\.\d+)?),(?P<h>-?\d+(?:\.\d+)?)")


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    print("+ " + " ".join(str(part) for part in cmd), flush=True)
    return subprocess.run(cmd, cwd=ROOT, check=True, text=True, **kwargs)


def swift_cmd(args: argparse.Namespace, dry: bool) -> list[str]:
    cmd = [
        "swift",
        "-Xfrontend",
        "-disable-availability-checking",
        str(DRAG_ONLY),
        str(args.out_dir),
        args.owner_match,
        str(args.center_anchor_x),
        str(args.center_anchor_y),
        str(args.radius_x),
        str(args.radius_y),
        str(args.cycles),
        str(args.pad_x),
        str(args.pad_y),
        str(args.steps),
        str(args.step_ms),
        str(args.wait_seconds),
    ]
    if not dry:
        cmd.append(str(args.pre_delay_ms))
    return cmd


def dry_target(args: argparse.Namespace) -> tuple[float, float, float, float]:
    env = os.environ.copy()
    env["TRUE_LIQUID_DRY_TARGET"] = "1"
    result = run(swift_cmd(args, dry=True), env=env, capture_output=True)
    print(result.stdout, end="")
    match = CROP_RE.search(result.stdout)
    if not match:
        raise SystemExit(f"could not parse crop from dry output:\n{result.stdout}")
    return tuple(float(match.group(k)) for k in ("x", "y", "w", "h"))  # type: ignore[return-value]


def append_frame_timestamps(sequence: Path, capture_start_ns: int, fps: int) -> int:
    frames = sorted(sequence.glob("frame_*.png"))
    with (sequence / "timestamps.tsv").open("a") as handle:
        for index, frame in enumerate(frames):
            t_ns = capture_start_ns + round(index * 1_000_000_000 / max(1, fps))
            handle.write(f"{index}\t{t_ns}\t{frame.name}\n")
    return len(frames)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("out_dir", type=Path)
    parser.add_argument("owner_match")
    parser.add_argument("center_anchor_x", type=float)
    parser.add_argument("center_anchor_y", type=float)
    parser.add_argument("radius_x", type=float)
    parser.add_argument("radius_y", type=float)
    parser.add_argument("cycles", type=float)
    parser.add_argument("frames", type=int)
    parser.add_argument("fps", type=int)
    parser.add_argument("pad_x", type=float)
    parser.add_argument("pad_y", type=float)
    parser.add_argument("steps", type=int)
    parser.add_argument("step_ms", type=float)
    parser.add_argument("wait_seconds", type=float)
    parser.add_argument("--pre-delay-ms", type=float, default=700.0)
    parser.add_argument("--post-delay-ms", type=float, default=1000.0)
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    crop = dry_target(args)
    drag_duration = (args.steps + 1) * args.step_ms / 1000.0 + 0.05
    duration = max(
        args.frames / max(1, args.fps),
        args.pre_delay_ms / 1000.0 + drag_duration + args.post_delay_ms / 1000.0,
    )
    duration = min(duration + 0.35, 12.0)
    mov_path = args.out_dir / "capture.mov"
    capture_start_ns = time.monotonic_ns()
    screencapture = subprocess.Popen(
        [
            "screencapture",
            "-x",
            "-v",
            "-V",
            f"{duration:.3f}",
            "-R",
            f"{crop[0]:.0f},{crop[1]:.0f},{crop[2]:.0f},{crop[3]:.0f}",
            str(mov_path),
        ],
        cwd=ROOT,
    )
    try:
        time.sleep(0.35)
        run(swift_cmd(args, dry=False))
        screencapture.wait(timeout=duration + 8.0)
    finally:
        if screencapture.poll() is None:
            screencapture.terminate()
            try:
                screencapture.wait(timeout=3)
            except subprocess.TimeoutExpired:
                screencapture.kill()
                screencapture.wait(timeout=3)

    run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(mov_path),
            "-vf",
            f"fps={args.fps}",
            "-start_number",
            "0",
            str(args.out_dir / "frame_%03d.png"),
        ]
    )
    count = append_frame_timestamps(args.out_dir, capture_start_ns, args.fps)
    meta_path = args.out_dir / "capture.json"
    if meta_path.exists():
        meta = json.loads(meta_path.read_text())
        meta["frames"] = {"count": count, "fps": args.fps, "intervalMs": 1000.0 / max(1, args.fps)}
        meta["video"] = {"captureStartNs": capture_start_ns, "durationSeconds": duration, "preDelayMs": args.pre_delay_ms}
        meta_path.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n")
    print(f"video_frames={count}")
    if count < 3:
        raise SystemExit("video extraction produced too few frames")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
