#!/usr/bin/env python3
"""Find frame-level dragback/texture-delay episodes in True Liquid captures."""

from __future__ import annotations

import argparse
import bisect
import csv
import json
import math
import statistics as stats
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont


Rect = tuple[float, float, float, float]
PixelRect = tuple[int, int, int, int]


def parse_rect(value: str) -> Rect:
    parts = [p.strip() for p in value.replace("x", ",").split(",") if p.strip()]
    if len(parts) != 4:
        raise ValueError(f"expected rect x,y,w,h, got {value!r}")
    return tuple(float(p) for p in parts)  # type: ignore[return-value]


def parse_timestamps(sequence_dir: Path) -> tuple[dict[str, dict], list[dict]]:
    marks: dict[str, dict] = {}
    frames: list[dict] = []
    for raw in (sequence_dir / "timestamps.tsv").read_text().splitlines():
        parts = raw.split("\t")
        if len(parts) < 2:
            continue
        if parts[0].isdigit():
            frames.append({"i": int(parts[0]), "t": int(parts[1]) / 1_000_000.0, "file": parts[2]})
        elif parts[0].startswith("drag_"):
            marks[parts[0]] = {"t": int(parts[1]) / 1_000_000.0, "raw": parts[2:] if len(parts) > 2 else []}
    frames.sort(key=lambda f: f["i"])
    return marks, frames


def parse_metadata(sequence_dir: Path) -> dict:
    path = sequence_dir / "capture.json"
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return {}


def metadata_rect(metadata: dict, key: str) -> Rect | None:
    value = metadata.get(key)
    if isinstance(value, dict):
        try:
            return float(value["x"]), float(value["y"]), float(value["w"]), float(value["h"])
        except (KeyError, TypeError, ValueError):
            return None
    if isinstance(value, list) and len(value) == 4:
        try:
            return tuple(float(v) for v in value)  # type: ignore[return-value]
        except (TypeError, ValueError):
            return None
    return None


def parse_events(path: Path | None) -> list[dict]:
    if not path or not path.exists():
        return []
    events: list[dict] = []
    for raw in path.read_text(errors="replace").splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            event = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if "t" in event and "event" in event:
            events.append(event)
    events.sort(key=lambda e: float(e["t"]))
    return events


def latest_before(events: list[dict], times: list[float], t: float, names: set[str] | None = None) -> dict | None:
    idx = bisect.bisect_right(times, t) - 1
    while idx >= 0:
        event = events[idx]
        if names is None or event.get("event") in names:
            return event
        idx -= 1
    return None


def events_between(events: list[dict], start: float, end: float, margin: float = 0.0) -> list[dict]:
    lo = start - margin
    hi = end + margin
    return [event for event in events if lo <= float(event["t"]) <= hi]


def event_panel(event: dict | None) -> Rect | None:
    if not event or "panel" not in event:
        return None
    try:
        return parse_rect(str(event["panel"]))
    except ValueError:
        return None


def metadata_panel_for_time(metadata: dict, marks: dict[str, dict], t: float) -> Rect | None:
    target = metadata_rect(metadata, "targetWindow")
    drag = metadata.get("drag")
    if not target:
        return None
    x, y, w, h = target
    if not isinstance(drag, dict) or "drag_start" not in marks or "drag_end" not in marks:
        return target
    try:
        dx = float(drag["toX"]) - float(drag["fromX"])
        dy = float(drag["toY"]) - float(drag["fromY"])
    except (KeyError, TypeError, ValueError):
        return target
    start = float(marks["drag_start"]["t"])
    end = float(marks["drag_end"]["t"])
    progress = 1.0 if end <= start and t >= end else 0.0 if end <= start else min(1.0, max(0.0, (t - start) / (end - start)))
    return x + dx * progress, y + dy * progress, w, h


def panel_for_time(metadata: dict, marks: dict[str, dict], events: list[dict], times: list[float], t: float) -> tuple[Rect | None, str]:
    slide = latest_before(events, times, t, {"slide"})
    panel = event_panel(slide)
    if panel:
        return panel, "slide"
    draw = latest_before(events, times, t, {"draw"})
    panel = event_panel(draw)
    if panel:
        return panel, "draw"
    panel = metadata_panel_for_time(metadata, marks, t)
    return panel, "metadata" if panel else "none"


def clamp_pixel_rect(rect: PixelRect, size: tuple[int, int]) -> PixelRect | None:
    x0, y0, x1, y1 = rect
    w, h = size
    x0 = max(0, min(w, x0))
    x1 = max(0, min(w, x1))
    y0 = max(0, min(h, y0))
    y1 = max(0, min(h, y1))
    if x1 <= x0 or y1 <= y0:
        return None
    return x0, y0, x1, y1


def map_rect(panel: Rect, capture_crop: Rect, image_size: tuple[int, int]) -> PixelRect | None:
    px, py, pw, ph = panel
    cx, cy, cw, ch = capture_crop
    if cw <= 0 or ch <= 0:
        return None
    sx = image_size[0] / cw
    sy = image_size[1] / ch
    return clamp_pixel_rect(
        (
            round((px - cx) * sx),
            round((py - cy) * sy),
            round((px + pw - cx) * sx),
            round((py + ph - cy) * sy),
        ),
        image_size,
    )


def relative_rect(rect: PixelRect, rel: tuple[float, float, float, float]) -> PixelRect | None:
    x0, y0, x1, y1 = rect
    w = x1 - x0
    h = y1 - y0
    out = (
        round(x0 + w * rel[0]),
        round(y0 + h * rel[1]),
        round(x0 + w * rel[2]),
        round(y0 + h * rel[3]),
    )
    return out if out[2] > out[0] and out[3] > out[1] else None


def prep_array(image: Image.Image, rect: PixelRect, scale: float) -> np.ndarray | None:
    crop = image.crop(rect).convert("RGB")
    w = max(24, round(crop.width * scale))
    h = max(16, round(crop.height * scale))
    if w < 24 or h < 16:
        return None
    crop = crop.resize((w, h), Image.Resampling.BICUBIC).filter(ImageFilter.GaussianBlur(1.2))
    arr = np.asarray(crop).astype(np.float32)
    luma = arr[:, :, 0] * 0.299 + arr[:, :, 1] * 0.587 + arr[:, :, 2] * 0.114
    chroma = arr.max(axis=2) - arr.min(axis=2)
    mask = (luma < 236.0) & (chroma < 96.0)
    if mask.mean() < 0.35:
        mask = luma < 244.0
    mean = float(luma[mask].mean()) if mask.any() else float(luma.mean())
    std = float(luma[mask].std()) if mask.any() else float(luma.std())
    norm = (luma - mean) / max(6.0, std)
    norm[~mask] *= 0.18
    return norm


def overlap_views(a: np.ndarray, b: np.ndarray, sx: int, sy: int) -> tuple[np.ndarray, np.ndarray] | None:
    h, w = a.shape
    x0_b = max(0, sx)
    y0_b = max(0, sy)
    x1_b = min(w, w + sx)
    y1_b = min(h, h + sy)
    if x1_b <= x0_b or y1_b <= y0_b:
        return None
    x0_a = x0_b - sx
    y0_a = y0_b - sy
    x1_a = x1_b - sx
    y1_a = y1_b - sy
    coverage = ((x1_b - x0_b) * (y1_b - y0_b)) / float(w * h)
    if coverage < 0.45:
        return None
    return a[y0_a:y1_a, x0_a:x1_a], b[y0_b:y1_b, x0_b:x1_b]


def mse_for_shift(a: np.ndarray, b: np.ndarray, sx: int, sy: int) -> float | None:
    views = overlap_views(a, b, sx, sy)
    if views is None:
        return None
    av, bv = views
    diff = av - bv
    return float(np.mean(diff * diff))


def match_shift(
    prev_image: Image.Image,
    cur_image: Image.Image,
    prev_rect: PixelRect,
    cur_rect: PixelRect,
    expected_shift: tuple[float, float],
    scale: float,
    search_px: float,
) -> dict | None:
    rois = [
        ("body", (0.10, 0.22, 0.90, 0.76)),
        ("center", (0.22, 0.26, 0.80, 0.62)),
        ("wide", (0.08, 0.14, 0.92, 0.84)),
    ]
    best_result: dict | None = None
    expected_x = int(round(expected_shift[0] * scale))
    expected_y = int(round(expected_shift[1] * scale))
    radius_x = max(6, int(round(search_px * scale)))
    radius_y = max(3, int(round(min(search_px * 0.25, 28.0) * scale)))

    for name, rel in rois:
        prev_roi = relative_rect(prev_rect, rel)
        cur_roi = relative_rect(cur_rect, rel)
        if not prev_roi or not cur_roi:
            continue
        prev_arr = prep_array(prev_image, prev_roi, scale)
        cur_arr = prep_array(cur_image, cur_roi, scale)
        if prev_arr is None or cur_arr is None or prev_arr.shape != cur_arr.shape:
            continue

        candidates: list[tuple[float, int, int]] = []
        for sy in range(expected_y - radius_y, expected_y + radius_y + 1):
            for sx in range(expected_x - radius_x, expected_x + radius_x + 1):
                score = mse_for_shift(prev_arr, cur_arr, sx, sy)
                if score is not None:
                    candidates.append((score, sx, sy))
        if not candidates:
            continue
        candidates.sort(key=lambda item: item[0])
        best = candidates[0]
        second = candidates[min(len(candidates) - 1, max(1, len(candidates) // 12))]
        expected_score = mse_for_shift(prev_arr, cur_arr, expected_x, expected_y)
        zero_score = mse_for_shift(prev_arr, cur_arr, 0, 0)
        margin = max(0.0, second[0] - best[0]) / max(0.0001, best[0])
        expected_penalty = max(0.0, (expected_score if expected_score is not None else best[0]) - best[0]) / max(0.0001, best[0])
        quality = min(1.0, margin * 4.0 + expected_penalty * 0.35)
        result = {
            "roi": name,
            "observedShiftXPx": best[1] / scale,
            "observedShiftYPx": best[2] / scale,
            "expectedShiftXPx": expected_x / scale,
            "expectedShiftYPx": expected_y / scale,
            "bestMse": best[0],
            "expectedMse": expected_score,
            "zeroMse": zero_score,
            "confidence": quality,
            "bestMargin": margin,
            "expectedPenalty": expected_penalty,
        }
        if best_result is None or result["confidence"] > best_result["confidence"] or (
            result["confidence"] == best_result["confidence"] and result["bestMse"] < best_result["bestMse"]
        ):
            best_result = result
    return best_result


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * pct / 100.0)))
    return ordered[idx]


def compact(values: list[float]) -> dict[str, float]:
    if not values:
        return {"min": 0.0, "median": 0.0, "p95": 0.0, "max": 0.0}
    return {
        "min": min(values),
        "median": stats.median(values),
        "p95": percentile(values, 95),
        "max": max(values),
    }


def nearby_native(events: list[dict], start: float, end: float) -> dict:
    interesting = {
        "drag-latch",
        "drag-latch-refresh",
        "drag-unlatch",
        "recenter-explicit",
        "recenter-request",
        "recenter-configured",
        "draw-obsolete",
        "draw-latched-late",
        "draw-late-resubmit",
        "drawable-miss",
        "render-defer",
        "render-frame-throttle",
        "frame",
        "draw",
        "slide",
    }
    near = [e for e in events_between(events, start, end, 40.0) if e.get("event") in interesting]
    counts: dict[str, int] = {}
    for event in near:
        key = str(event.get("event"))
        counts[key] = counts.get(key, 0) + 1
    draws = [e for e in near if e.get("event") == "draw"]
    draw_age = [float(e.get("frameAgeMs", 0.0)) for e in draws if isinstance(e.get("frameAgeMs"), (int, float))]
    drawable_wait = [float(e.get("drawableWaitMs", 0.0)) for e in draws if isinstance(e.get("drawableWaitMs"), (int, float))]
    return {
        "counts": counts,
        "drawAgeMs": compact(draw_age),
        "drawableWaitMs": compact(drawable_wait),
        "latestEvents": [
            {k: v for k, v in event.items() if k in {"t", "event", "source", "reason", "frameAgeMs", "drawableWaitMs", "latched"}}
            for event in near[-8:]
        ],
    }


def analyze(sequence_dir: Path, events_path: Path | None, args: argparse.Namespace) -> dict:
    marks, frames = parse_timestamps(sequence_dir)
    metadata = parse_metadata(sequence_dir)
    events = parse_events(events_path)
    event_times = [float(e["t"]) for e in events]
    capture_crop = args.crop or metadata_rect(metadata, "crop")
    if capture_crop is None:
        raise SystemExit("capture crop missing; pass --crop or include capture.json")

    drag_start = marks.get("drag_start", {}).get("t", frames[0]["t"] if frames else 0.0)
    drag_end = marks.get("drag_end", {}).get("t", frames[-1]["t"] if frames else drag_start)
    in_drag_frames = [frame for frame in frames if drag_start - 40.0 <= frame["t"] <= drag_end + 120.0]
    if len(in_drag_frames) < 3:
        raise SystemExit("not enough in-drag frames for anomaly analysis")

    records: list[dict] = []
    previous: dict | None = None
    prev_image: Image.Image | None = None
    image_cache: dict[int, Image.Image] = {}

    for frame in in_drag_frames:
        image = Image.open(sequence_dir / frame["file"]).convert("RGB")
        image_cache[frame["i"]] = image
        panel, panel_source = panel_for_time(metadata, marks, events, event_times, frame["t"])
        panel_px = map_rect(panel, capture_crop, image.size) if panel else None
        latest_draw = latest_before(events, event_times, frame["t"], {"draw"})
        latest_slide = latest_before(events, event_times, frame["t"], {"slide"})
        base_record = {
            "frame": frame["i"],
            "file": frame["file"],
            "tMs": frame["t"],
            "dragMs": frame["t"] - drag_start,
            "panel": panel,
            "panelSource": panel_source,
            "panelPx": panel_px,
            "draw": {k: latest_draw.get(k) for k in ("t", "frameAgeMs", "drawableWaitMs", "latched", "uv", "panel", "capture") if latest_draw and k in latest_draw} if latest_draw else {},
            "slide": {k: latest_slide.get(k) for k in ("t", "source", "panel", "capture") if latest_slide and k in latest_slide} if latest_slide else {},
        }
        if previous is not None and prev_image is not None and previous.get("panelPx") and panel_px:
            dt = frame["t"] - float(previous["tMs"])
            dx = panel_px[0] - previous["panelPx"][0]
            dy = panel_px[1] - previous["panelPx"][1]
            expected = (-float(dx), -float(dy))
            search_px = max(args.search_px, abs(dx) * 1.5, abs(dy) * 1.5)
            match = match_shift(prev_image, image, previous["panelPx"], panel_px, expected, args.match_scale, search_px)
            if match:
                lag_x = float(match["observedShiftXPx"]) - float(match["expectedShiftXPx"])
                lag_y = float(match["observedShiftYPx"]) - float(match["expectedShiftYPx"])
                lag_px = math.hypot(lag_x, lag_y)
                panel_speed = math.hypot(dx, dy) / max(0.001, dt)
                delay_ms = 0.0 if panel_speed < 0.05 else lag_px / panel_speed
                confidence = float(match["confidence"])
                draw_age = float(latest_draw.get("frameAgeMs", 0.0)) if latest_draw and isinstance(latest_draw.get("frameAgeMs"), (int, float)) else 0.0
                drawable_wait = float(latest_draw.get("drawableWaitMs", 0.0)) if latest_draw and isinstance(latest_draw.get("drawableWaitMs"), (int, float)) else 0.0
                score = (
                    lag_px * (0.45 + confidence) * (0.15 if panel_speed < 0.05 else 1.0)
                    + max(0.0, delay_ms - 18.0) * 0.28
                    + max(0.0, dt - 22.0) * 1.4
                    + max(0.0, drawable_wait - 2.0) * 1.2
                    + max(0.0, draw_age - 22.0) * 0.55
                )
                native = nearby_native(events, float(previous["tMs"]), frame["t"])
                base_record.update(
                    {
                        "dtMs": dt,
                        "panelDxPx": dx,
                        "panelDyPx": dy,
                        "panelSpeedPxMs": panel_speed,
                        "observedShiftXPx": match["observedShiftXPx"],
                        "observedShiftYPx": match["observedShiftYPx"],
                        "expectedShiftXPx": match["expectedShiftXPx"],
                        "expectedShiftYPx": match["expectedShiftYPx"],
                        "lagXPx": lag_x,
                        "lagYPx": lag_y,
                        "lagPx": lag_px,
                        "delayMs": delay_ms,
                        "match": match,
                        "nativeWindow": native,
                        "dragbackScore": score,
                    }
                )
            else:
                base_record.update({"dtMs": dt, "panelDxPx": dx, "panelDyPx": dy, "dragbackScore": max(0.0, dt - 22.0) * 1.4})
        records.append(base_record)
        previous = base_record
        prev_image = image

    scored = [r for r in records if r.get("dragbackScore", 0.0) > 0 and r.get("dragMs", 0.0) >= 0]
    scored.sort(key=lambda r: float(r.get("dragbackScore", 0.0)), reverse=True)
    chosen: list[dict] = []
    used_frames: list[int] = []
    for record in scored:
        frame_i = int(record["frame"])
        if any(abs(frame_i - used) <= args.sheet_radius * 2 for used in used_frames):
            continue
        chosen.append(record)
        used_frames.append(frame_i)
        if len(chosen) >= args.top:
            break

    lag_values = [float(r.get("lagPx", 0.0)) for r in records if "lagPx" in r]
    delay_values = [float(r.get("delayMs", 0.0)) for r in records if "delayMs" in r]
    dt_values = [float(r.get("dtMs", 0.0)) for r in records if "dtMs" in r]
    summary = {
        "sequence": str(sequence_dir),
        "events": str(events_path) if events_path else "",
        "frameCount": len(frames),
        "analyzedFrames": len(records),
        "dragStartMs": drag_start,
        "dragEndMs": drag_end,
        "captureCrop": capture_crop,
        "requestedCrop": metadata_rect(metadata, "requestedCrop"),
        "cropClamped": bool(metadata.get("cropClamped", False)),
        "lagPx": compact(lag_values),
        "delayMs": compact(delay_values),
        "frameDtMs": compact(dt_values),
        "top": chosen,
    }
    payload = {"summary": summary, "records": records}
    return payload


def resize_to_width(image: Image.Image, width: int) -> Image.Image:
    if image.width <= width:
        return image.copy()
    height = max(1, round(image.height * width / image.width))
    return image.resize((width, height), Image.Resampling.LANCZOS)


def draw_label(draw: ImageDraw.ImageDraw, xy: tuple[int, int], text: str, font: ImageFont.ImageFont, fill: str = "#f4fbff") -> None:
    draw.text((xy[0] + 1, xy[1] + 1), text, fill="#000000", font=font)
    draw.text(xy, text, fill=fill, font=font)


def record_label(record: dict) -> str:
    return (
        f"f{int(record['frame']):03d} t={record.get('dragMs', 0.0):.0f}ms "
        f"dt={record.get('dtMs', 0.0):.1f} "
        f"lag={record.get('lagPx', 0.0):.1f}px "
        f"delay={record.get('delayMs', 0.0):.1f}ms "
        f"dx={record.get('panelDxPx', 0.0):.1f} "
        f"obs={record.get('observedShiftXPx', 0.0):.1f} "
        f"exp={record.get('expectedShiftXPx', 0.0):.1f}"
    )


def write_timeline(payload: dict, out: Path) -> None:
    records = payload["records"]
    width = 1500
    height = 620
    pad_l = 70
    pad_r = 30
    pad_t = 30
    chart_h = 135
    gap = 28
    image = Image.new("RGB", (width, height), "#0a0d12")
    draw = ImageDraw.Draw(image)
    font = ImageFont.load_default()

    if not records:
        image.save(out)
        return
    xs = [float(r.get("dragMs", 0.0)) for r in records]
    min_x = min(xs)
    max_x = max(xs) if max(xs) > min_x else min_x + 1.0

    series = [
        ("lagPx", "#ff5d73", 1.0),
        ("delayMs", "#ffd166", 0.7),
        ("dtMs", "#6ecbff", 2.0),
        ("dragbackScore", "#b28dff", 0.6),
    ]

    def x_to_px(x: float) -> int:
        return round(pad_l + (x - min_x) / (max_x - min_x) * (width - pad_l - pad_r))

    for row, (key, color, scale_hint) in enumerate(series):
        y0 = pad_t + row * (chart_h + gap)
        values = [float(r.get(key, 0.0)) for r in records]
        max_v = max(max(values), 1.0) * scale_hint
        draw.rectangle((pad_l, y0, width - pad_r, y0 + chart_h), outline="#2a3340")
        draw_label(draw, (10, y0 + 8), key, font, color)
        points = []
        for record, value in zip(records, values):
            x = x_to_px(float(record.get("dragMs", 0.0)))
            y = round(y0 + chart_h - min(1.0, value / max_v) * chart_h)
            points.append((x, y))
        if len(points) >= 2:
            draw.line(points, fill=color, width=2)
        for chosen in payload["summary"].get("top", []):
            x = x_to_px(float(chosen.get("dragMs", 0.0)))
            draw.line((x, y0, x, y0 + chart_h), fill="#ffffff", width=1)
    image.save(out)


def write_csv(payload: dict, out: Path) -> None:
    rows = payload["records"]
    fields = [
        "frame",
        "dragMs",
        "dtMs",
        "panelDxPx",
        "panelDyPx",
        "observedShiftXPx",
        "expectedShiftXPx",
        "lagXPx",
        "lagPx",
        "delayMs",
        "dragbackScore",
        "panelSource",
    ]
    with out.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def write_report(payload: dict, out: Path) -> None:
    summary = payload["summary"]
    lines = [
        f"sequence: {summary['sequence']}",
        f"frames: total={summary['frameCount']} analyzed={summary['analyzedFrames']}",
        f"cropClamped: {summary['cropClamped']} crop={summary['captureCrop']} requested={summary['requestedCrop']}",
        f"lagPx min/med/p95/max: {summary['lagPx']['min']:.1f}/{summary['lagPx']['median']:.1f}/{summary['lagPx']['p95']:.1f}/{summary['lagPx']['max']:.1f}",
        f"delayMs min/med/p95/max: {summary['delayMs']['min']:.1f}/{summary['delayMs']['median']:.1f}/{summary['delayMs']['p95']:.1f}/{summary['delayMs']['max']:.1f}",
        f"frameDtMs min/med/p95/max: {summary['frameDtMs']['min']:.1f}/{summary['frameDtMs']['median']:.1f}/{summary['frameDtMs']['p95']:.1f}/{summary['frameDtMs']['max']:.1f}",
        "",
        "top anomaly frames:",
    ]
    for i, record in enumerate(summary.get("top", []), 1):
        native_counts = record.get("nativeWindow", {}).get("counts", {})
        draw_age = record.get("nativeWindow", {}).get("drawAgeMs", {})
        drawable = record.get("nativeWindow", {}).get("drawableWaitMs", {})
        lines.append(
            f"{i}. {record_label(record)} score={record.get('dragbackScore', 0.0):.1f} "
            f"conf={record.get('match', {}).get('confidence', 0.0):.2f} roi={record.get('match', {}).get('roi', 'n/a')} "
            f"native={native_counts} drawAgeP95={draw_age.get('p95', 0.0):.1f} drawableP95={drawable.get('p95', 0.0):.2f}"
        )
    out.write_text("\n".join(lines) + "\n")


def write_anomaly_sheets(sequence_dir: Path, payload: dict, out_dir: Path, radius: int, tile_width: int) -> None:
    records = {int(r["frame"]): r for r in payload["records"]}
    font = ImageFont.load_default()
    for sheet_index, peak in enumerate(payload["summary"].get("top", []), 1):
        peak_i = int(peak["frame"])
        frame_indices = [i for i in range(peak_i - radius, peak_i + radius + 1) if i in records]
        tiles: list[Image.Image] = []
        for frame_i in frame_indices:
            record = records[frame_i]
            image = Image.open(sequence_dir / str(record["file"])).convert("RGB")
            panel_px = record.get("panelPx")
            if panel_px:
                crop = image.crop(tuple(panel_px))
            else:
                crop = image
            tile = resize_to_width(crop, tile_width)
            label_h = 48
            labeled = Image.new("RGB", (tile.width, tile.height + label_h), "#10151c")
            labeled.paste(tile, (0, label_h))
            draw = ImageDraw.Draw(labeled)
            draw_label(draw, (8, 8), record_label(record), font)
            draw_label(
                draw,
                (8, 25),
                f"score={record.get('dragbackScore', 0.0):.1f} conf={record.get('match', {}).get('confidence', 0.0):.2f} roi={record.get('match', {}).get('roi', 'n/a')}",
                font,
                "#c8ddff",
            )
            tiles.append(labeled)
        if not tiles:
            continue
        gap = 8
        width = sum(t.width for t in tiles) + gap * (len(tiles) - 1)
        height = max(t.height for t in tiles)
        sheet = Image.new("RGB", (width, height), "#05070a")
        x = 0
        for tile in tiles:
            sheet.paste(tile, (x, 0))
            x += tile.width + gap
        sheet.save(out_dir / f"drag_anomaly_sheet_{sheet_index:02d}_f{peak_i:03d}.png")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sequence_dir", type=Path)
    parser.add_argument("--events", type=Path)
    parser.add_argument("--crop", type=parse_rect)
    parser.add_argument("--out-dir", type=Path)
    parser.add_argument("--top", type=int, default=5)
    parser.add_argument("--sheet-radius", type=int, default=3)
    parser.add_argument("--tile-width", type=int, default=330)
    parser.add_argument("--match-scale", type=float, default=0.22)
    parser.add_argument("--search-px", type=float, default=70.0)
    args = parser.parse_args()

    out_dir = args.out_dir or args.sequence_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    payload = analyze(args.sequence_dir, args.events, args)
    json_path = out_dir / "drag_anomaly_metrics.json"
    json_path.write_text(json.dumps(payload, indent=2) + "\n")
    write_csv(payload, out_dir / "drag_anomaly_timeline.csv")
    write_report(payload, out_dir / "drag_anomaly_report.txt")
    write_timeline(payload, out_dir / "drag_anomaly_timeline.png")
    write_anomaly_sheets(args.sequence_dir, payload, out_dir, args.sheet_radius, args.tile_width)
    print(f"wrote: {json_path}")
    print(f"wrote: {out_dir / 'drag_anomaly_report.txt'}")
    print(f"wrote: {out_dir / 'drag_anomaly_timeline.png'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
