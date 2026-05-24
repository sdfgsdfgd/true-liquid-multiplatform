#!/usr/bin/env python3
"""Record a fixed-duration macOS screen video while performing a drag, then extract PNG frames."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
AV_CAPTURE = ROOT / "tools" / "true_liquid_av_capture_drag.swift"
DRAG_ONLY = ROOT / "tools" / "true_liquid_drag_only.swift"


RECT_RE = re.compile(r"(?P<key>targetWindow|crop|requestedCrop) x=(?P<x>-?\d+(?:\.\d+)?) y=(?P<y>-?\d+(?:\.\d+)?) w=(?P<w>-?\d+(?:\.\d+)?) h=(?P<h>-?\d+(?:\.\d+)?)")
DRAG_RE = re.compile(
    r"drag from=(?P<fx>-?\d+(?:\.\d+)?),(?P<fy>-?\d+(?:\.\d+)?) "
    r"to=(?P<tx>-?\d+(?:\.\d+)?),(?P<ty>-?\d+(?:\.\d+)?) "
    r"crop=(?P<x>-?\d+(?:\.\d+)?),(?P<y>-?\d+(?:\.\d+)?),(?P<w>-?\d+(?:\.\d+)?),(?P<h>-?\d+(?:\.\d+)?)"
)
REQUESTED_RE = re.compile(r"requestedCrop=(?P<x>-?\d+(?:\.\d+)?),(?P<y>-?\d+(?:\.\d+)?),(?P<w>-?\d+(?:\.\d+)?),(?P<h>-?\d+(?:\.\d+)?)")


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    print("+ " + " ".join(str(part) for part in cmd), flush=True)
    return subprocess.run(cmd, check=True, text=True, **kwargs)


def rect_payload(rect: tuple[float, float, float, float]) -> dict[str, float]:
    return {"x": rect[0], "y": rect[1], "w": rect[2], "h": rect[3]}


def parse_probe(stdout: str) -> dict:
    data: dict = {}
    for line in stdout.splitlines():
        if line.startswith("targetWindow "):
            values = dict(re.findall(r"([xywh])=(-?\d+(?:\.\d+)?)", line))
            data["targetWindow"] = tuple(float(values[k]) for k in ("x", "y", "w", "h"))
        drag = DRAG_RE.search(line)
        if drag:
            data["from"] = (float(drag.group("fx")), float(drag.group("fy")))
            data["to"] = (float(drag.group("tx")), float(drag.group("ty")))
            data["crop"] = tuple(float(drag.group(k)) for k in ("x", "y", "w", "h"))
        requested = REQUESTED_RE.search(line)
        if requested:
            data["requestedCrop"] = tuple(float(requested.group(k)) for k in ("x", "y", "w", "h"))
    if "from" not in data or "to" not in data or "crop" not in data:
        raise SystemExit(f"could not parse dry target output:\n{stdout}")
    data.setdefault("requestedCrop", data["crop"])
    return data


def dry_target(args: argparse.Namespace) -> dict:
    cmd = [
        "env",
        "TRUE_LIQUID_DRY_TARGET=1",
        "swift",
        "-Xfrontend",
        "-disable-availability-checking",
        str(AV_CAPTURE),
        str(args.out_dir),
        "auto",
        args.owner_match,
        str(args.anchor_x),
        str(args.anchor_y),
        str(args.delta_x),
        str(args.delta_y),
        str(args.frames),
        str(args.fps),
        str(args.pad_x),
        str(args.pad_y),
        str(args.steps),
        str(args.step_ms),
        str(args.wait_seconds),
    ]
    result = run(cmd, cwd=ROOT, capture_output=True)
    print(result.stdout, end="")
    return parse_probe(result.stdout)


def write_metadata(args: argparse.Namespace, probe: dict, capture_started_ns: int, duration: float) -> None:
    args.out_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        "backend": "video",
        "crop": rect_payload(probe["crop"]),
        "requestedCrop": rect_payload(probe["requestedCrop"]),
        "cropClamped": probe["crop"] != probe["requestedCrop"],
        "drag": {
            "fromX": probe["from"][0],
            "fromY": probe["from"][1],
            "toX": probe["to"][0],
            "toY": probe["to"][1],
            "steps": args.steps,
            "stepMs": args.step_ms,
            "waitSeconds": args.wait_seconds,
        },
        "frames": {"count": args.frames, "fps": args.fps, "intervalMs": 1000.0 / max(1, args.fps)},
        "video": {"captureStartNs": capture_started_ns, "durationSeconds": duration, "preDelayMs": args.pre_delay_ms},
    }
    if "targetWindow" in probe:
        payload["targetWindow"] = rect_payload(probe["targetWindow"])
    (args.out_dir / "capture.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def append_frame_timestamps(sequence: Path, capture_start_ns: int, fps: int) -> int:
    frames = sorted(sequence.glob("frame_*.png"))
    with (sequence / "timestamps.tsv").open("a") as handle:
        for index, frame in enumerate(frames):
            t_ns = capture_start_ns + round(index * 1_000_000_000 / max(1, fps))
            handle.write(f"{index}\t{t_ns}\t{frame.name}\n")
    return len(frames)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("out_dir", type=Path)
    parser.add_argument("owner_match")
    parser.add_argument("anchor_x", type=float)
    parser.add_argument("anchor_y", type=float)
    parser.add_argument("delta_x", type=float)
    parser.add_argument("delta_y", type=float)
    parser.add_argument("frames", type=int)
    parser.add_argument("fps", type=int)
    parser.add_argument("pad_x", type=float)
    parser.add_argument("pad_y", type=float)
    parser.add_argument("steps", type=int)
    parser.add_argument("step_ms", type=float)
    parser.add_argument("wait_seconds", type=float)
    parser.add_argument("--pre-delay-ms", type=float, default=900.0)
    parser.add_argument("--post-delay-ms", type=float, default=900.0)
    args = parser.parse_args()

    probe = dry_target(args)
    drag_duration = (args.steps + 1) * args.step_ms / 1000.0 + 0.05
    duration = max(float(args.frames) / max(1, args.fps), args.pre_delay_ms / 1000.0 + drag_duration + args.post_delay_ms / 1000.0)
    duration = min(duration + 0.25, 12.0)
    crop = probe["crop"]
    args.out_dir.mkdir(parents=True, exist_ok=True)
    timestamp_path = args.out_dir / "timestamps.tsv"
    timestamp_path.write_text("")
    mov_path = args.out_dir / "capture.mov"
    capture_start_ns = time.monotonic_ns()
    write_metadata(args, probe, capture_start_ns, duration)

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
        run(
            [
                "swift",
                "-Xfrontend",
                "-disable-availability-checking",
                str(DRAG_ONLY),
                str(args.out_dir),
                str(probe["from"][0]),
                str(probe["from"][1]),
                str(probe["to"][0]),
                str(probe["to"][1]),
                str(args.steps),
                str(args.step_ms),
                str(args.pre_delay_ms),
            ],
            cwd=ROOT,
        )
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
        ],
        cwd=ROOT,
    )
    count = append_frame_timestamps(args.out_dir, capture_start_ns, args.fps)
    print(f"video_frames={count}")
    if count < 3:
        raise SystemExit("video extraction produced too few frames")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
