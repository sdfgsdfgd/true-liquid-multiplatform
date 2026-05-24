#!/usr/bin/env python3
"""Build annotated burst sheets from True Liquid drag captures."""

from __future__ import annotations

import argparse
import bisect
import json
import math
import statistics as stats
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont, ImageOps, ImageStat


def parse_rect(value: str) -> tuple[float, float, float, float]:
    parts = [p.strip() for p in value.replace("x", ",").split(",") if p.strip()]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError(f"expected x,y,w,h, got {value!r}")
    return tuple(float(p) for p in parts)  # type: ignore[return-value]


def parse_burst(value: str) -> tuple[int, int]:
    parts = value.split(":", 1)
    if len(parts) != 2:
        raise argparse.ArgumentTypeError("expected START:COUNT")
    return int(parts[0]), int(parts[1])


def parse_timestamps(sequence_dir: Path) -> tuple[dict[str, dict], list[dict]]:
    marks: dict[str, dict] = {}
    frames: list[dict] = []
    ts_path = sequence_dir / "timestamps.tsv"
    for raw in ts_path.read_text().splitlines():
        parts = raw.split("\t")
        if len(parts) < 2:
            continue
        if parts[0].isdigit():
            frames.append({
                "i": int(parts[0]),
                "t": int(parts[1]) / 1_000_000.0,
                "file": parts[2],
            })
        elif parts[0].startswith("drag_"):
            marks[parts[0]] = {"t": int(parts[1]) / 1_000_000.0, "raw": parts[2:] if len(parts) > 2 else []}
    return marks, frames


def parse_metadata(sequence_dir: Path) -> dict:
    path = sequence_dir / "capture.json"
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return {}


def metadata_crop(metadata: dict) -> tuple[float, float, float, float] | None:
    crop = metadata.get("crop")
    if isinstance(crop, dict):
        try:
            return float(crop["x"]), float(crop["y"]), float(crop["w"]), float(crop["h"])
        except (KeyError, TypeError, ValueError):
            return None
    if isinstance(crop, list) and len(crop) == 4:
        try:
            return tuple(float(v) for v in crop)  # type: ignore[return-value]
        except (TypeError, ValueError):
            return None
    return None


def metadata_panel_for_time(metadata: dict, marks: dict[str, dict], t: float) -> tuple[float, float, float, float] | None:
    target = metadata.get("targetWindow")
    drag = metadata.get("drag")
    if not isinstance(target, dict):
        return None
    try:
        x = float(target["x"])
        y = float(target["y"])
        w = float(target["w"])
        h = float(target["h"])
    except (KeyError, TypeError, ValueError):
        return None

    if not isinstance(drag, dict) or "drag_start" not in marks or "drag_end" not in marks:
        return x, y, w, h
    try:
        dx = float(drag["toX"]) - float(drag["fromX"])
        dy = float(drag["toY"]) - float(drag["fromY"])
    except (KeyError, TypeError, ValueError):
        return x, y, w, h

    start = float(marks["drag_start"]["t"])
    end = float(marks["drag_end"]["t"])
    if end <= start:
        progress = 1.0 if t >= end else 0.0
    else:
        progress = min(1.0, max(0.0, (t - start) / (end - start)))
    return x + dx * progress, y + dy * progress, w, h


def parse_events(path: Path | None) -> list[dict]:
    if not path:
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
    events.sort(key=lambda e: e["t"])
    return events


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    values = sorted(values)
    idx = min(len(values) - 1, max(0, int(round((pct / 100.0) * (len(values) - 1)))))
    return values[idx]


def compact(values: list[float]) -> str:
    if not values:
        return "n/a"
    return f"min/med/p95/max {min(values):.2f}/{stats.median(values):.2f}/{percentile(values, 95):.2f}/{max(values):.2f}"


def latest_before(events: list[dict], times: list[float], t: float, names: set[str] | None = None) -> dict | None:
    idx = bisect.bisect_right(times, t) - 1
    while idx >= 0:
        event = events[idx]
        if names is None or event.get("event") in names:
            return event
        idx -= 1
    return None


def next_after(events: list[dict], times: list[float], t: float, names: set[str]) -> dict | None:
    idx = bisect.bisect_left(times, t)
    while idx < len(events):
        event = events[idx]
        if event.get("event") in names:
            return event
        idx += 1
    return None


def event_panel(event: dict | None) -> tuple[float, float, float, float] | None:
    if not event or "panel" not in event:
        return None
    try:
        return parse_rect(str(event["panel"]))
    except argparse.ArgumentTypeError:
        return None


def clamp_rect(rect: tuple[int, int, int, int], size: tuple[int, int]) -> tuple[int, int, int, int] | None:
    x0, y0, x1, y1 = rect
    w, h = size
    x0 = max(0, min(w, x0))
    x1 = max(0, min(w, x1))
    y0 = max(0, min(h, y0))
    y1 = max(0, min(h, y1))
    if x1 <= x0 or y1 <= y0:
        return None
    return x0, y0, x1, y1


def map_rect(
    panel: tuple[float, float, float, float],
    capture_crop: tuple[float, float, float, float],
    image_size: tuple[int, int],
) -> tuple[int, int, int, int] | None:
    px, py, pw, ph = panel
    cx, cy, cw, ch = capture_crop
    sx = image_size[0] / cw
    sy = image_size[1] / ch
    rect = (
        round((px - cx) * sx),
        round((py - cy) * sy),
        round((px + pw - cx) * sx),
        round((py + ph - cy) * sy),
    )
    return clamp_rect(rect, image_size)


def estimate_right_edge(image: Image.Image, panel_px: tuple[int, int, int, int] | None) -> float | None:
    if not panel_px:
        return None
    x0, y0, x1, y1 = panel_px
    search_left = max(2, x1 - 120)
    search_right = min(image.width - 3, x1 + 120)
    band_top = max(0, y0 + 8)
    band_bottom = min(image.height, y1 - 8)
    if search_right <= search_left or band_bottom <= band_top:
        return None

    gray = image.convert("L")
    best_x = None
    best_score = -1.0
    for x in range(search_left, search_right + 1):
        left = gray.crop((x - 2, band_top, x - 1, band_bottom))
        right = gray.crop((x + 1, band_top, x + 2, band_bottom))
        diff = ImageChops.difference(left, right)
        score = ImageStat.Stat(diff).mean[0]
        center_bias = 1.0 - min(1.0, abs(x - x1) / 120.0) * 0.18
        score *= center_bias
        if score > best_score:
            best_score = score
            best_x = x
    return float(best_x) if best_x is not None and best_score > 2.0 else None


def diff_metrics(a: Image.Image, b: Image.Image, rect: tuple[int, int, int, int] | None = None) -> dict[str, float]:
    if rect:
        a = a.crop(rect)
        b = b.crop(rect)
    diff = ImageChops.difference(a.convert("RGB"), b.convert("RGB")).convert("L")
    return gray_diff_metrics(diff)


def gray_diff_metrics(diff: Image.Image) -> dict[str, float]:
    hist = diff.histogram()
    count = max(1, sum(hist))
    rms = math.sqrt(sum((i * i) * c for i, c in enumerate(hist)) / count)
    p95 = hist_percentile(hist, 95)
    active_pct = sum(hist[32:]) * 100.0 / count
    edge_mean = ImageStat.Stat(diff.filter(ImageFilter.FIND_EDGES)).mean[0]
    return {
        "mean": ImageStat.Stat(diff).mean[0],
        "rms": rms,
        "p95": p95,
        "activePct": active_pct,
        "edgeMean": edge_mean,
    }


def panel_diff_metrics(prev: Image.Image | None, cur: Image.Image, rect: tuple[int, int, int, int] | None) -> dict[str, float]:
    if prev is None or rect is None:
        return {}
    diff = ImageChops.difference(prev.convert("RGB"), cur.convert("RGB")).convert("L").crop(rect)
    return gray_diff_metrics(diff)


def shifted_overlap_metrics(prev: Image.Image, cur: Image.Image, shift_x: int, shift_y: int) -> dict[str, float]:
    w = min(prev.width, cur.width)
    h = min(prev.height, cur.height)
    if w < 20 or h < 20:
        return {}
    prev = prev.crop((0, 0, w, h))
    cur = cur.crop((0, 0, w, h))
    x0_cur = max(0, shift_x)
    y0_cur = max(0, shift_y)
    x1_cur = min(w, w + shift_x)
    y1_cur = min(h, h + shift_y)
    if x1_cur <= x0_cur or y1_cur <= y0_cur:
        return {}
    x0_prev = x0_cur - shift_x
    y0_prev = y0_cur - shift_y
    x1_prev = x1_cur - shift_x
    y1_prev = y1_cur - shift_y
    coverage = ((x1_cur - x0_cur) * (y1_cur - y0_cur)) * 100.0 / (w * h)
    if coverage < 35.0:
        return {}
    diff = ImageChops.difference(
        prev.crop((x0_prev, y0_prev, x1_prev, y1_prev)).convert("RGB"),
        cur.crop((x0_cur, y0_cur, x1_cur, y1_cur)).convert("RGB"),
    ).convert("L")
    metrics = gray_diff_metrics(diff)
    metrics["coveragePct"] = coverage
    return metrics


def panel_motion_metrics(
    prev: Image.Image | None,
    cur: Image.Image,
    prev_rect: tuple[int, int, int, int] | None,
    cur_rect: tuple[int, int, int, int] | None,
) -> dict[str, float]:
    if prev is None or prev_rect is None or cur_rect is None:
        return {}
    prev_crop = prev.crop(prev_rect)
    cur_crop = cur.crop(cur_rect)
    w = min(prev_crop.width, cur_crop.width)
    h = min(prev_crop.height, cur_crop.height)
    if w < 80 or h < 40:
        return {}
    prev_crop = prev_crop.crop((0, 0, w, h))
    cur_crop = cur_crop.crop((0, 0, w, h))
    inset_x = min(max(12, round(w * 0.07)), max(12, w // 4))
    inset_y = min(max(10, round(h * 0.10)), max(10, h // 4))
    inner = (inset_x, inset_y, w - inset_x, h - inset_y)
    if inner[2] <= inner[0] or inner[3] <= inner[1]:
        return {}
    prev_backdrop = prev_crop.crop(inner).filter(ImageFilter.GaussianBlur(5))
    cur_backdrop = cur_crop.crop(inner).filter(ImageFilter.GaussianBlur(5))
    dx = cur_rect[0] - prev_rect[0]
    dy = cur_rect[1] - prev_rect[1]
    local = diff_metrics(prev_backdrop, cur_backdrop)
    compensated = shifted_overlap_metrics(prev_backdrop, cur_backdrop, -dx, -dy)
    if not compensated:
        return {}
    local_rms = local["rms"]
    comp_rms = compensated["rms"]
    return {
        "dxPx": float(dx),
        "dyPx": float(dy),
        "motionPx": math.hypot(dx, dy),
        "localRms": local_rms,
        "localP95": local["p95"],
        "compRms": comp_rms,
        "compP95": compensated["p95"],
        "compCoveragePct": compensated["coveragePct"],
        "trackingAdvantage": local_rms - comp_rms,
        "stickiness": max(0.0, comp_rms - local_rms),
    }


def panel_luma_metrics(cur: Image.Image, rect: tuple[int, int, int, int] | None) -> dict[str, float]:
    if rect is None:
        return {}
    luma = cur.crop(rect).convert("L")
    hist = luma.histogram()
    total = max(1, sum(hist))
    stat = ImageStat.Stat(luma)
    return {
        "mean": stat.mean[0],
        "stdev": stat.stddev[0],
        "p50": hist_percentile(hist, 50),
        "p95": hist_percentile(hist, 95),
        "p99": hist_percentile(hist, 99),
        "brightPct": sum(hist[220:]) * 100.0 / total,
        "hotPct": sum(hist[245:]) * 100.0 / total,
        "darkPct": sum(hist[:24]) * 100.0 / total,
    }


def stitch_bands(bands: list[Image.Image]) -> Image.Image | None:
    bands = [band.convert("RGB") for band in bands if band.width > 0 and band.height > 0]
    if not bands:
        return None
    width = max(band.width for band in bands)
    height = sum(band.height for band in bands)
    out = Image.new("RGB", (width, height))
    y = 0
    for band in bands:
        out.paste(band, (0, y))
        y += band.height
    return out


def image_hot_pct(luma: Image.Image, threshold: int) -> float:
    hist = luma.histogram()
    total = max(1, sum(hist))
    return sum(hist[threshold:]) * 100.0 / total


def chroma_split_score(image: Image.Image) -> float:
    r, g, b = image.convert("RGB").split()
    rb = ImageChops.difference(r, b)
    rg = ImageChops.difference(r, g)
    gb = ImageChops.difference(g, b)
    return (
        ImageStat.Stat(rb).mean[0] * 0.55 +
        ImageStat.Stat(rg).mean[0] * 0.25 +
        ImageStat.Stat(gb).mean[0] * 0.20
    )


def panel_optics_metrics(cur: Image.Image, rect: tuple[int, int, int, int] | None) -> dict[str, float]:
    if rect is None:
        return {}
    panel = cur.crop(rect).convert("RGB")
    w, h = panel.size
    if w < 120 or h < 64:
        return {}
    x_band = min(max(10, round(w * 0.055)), max(10, w // 5))
    y_band = min(max(8, round(h * 0.115)), max(8, h // 4))
    inner_rect = (x_band * 2, y_band * 2, w - x_band * 2, h - y_band * 2)
    if inner_rect[2] <= inner_rect[0] or inner_rect[3] <= inner_rect[1]:
        return {}

    rim = stitch_bands([
        panel.crop((0, 0, w, y_band)),
        panel.crop((0, h - y_band, w, h)),
        panel.crop((0, y_band, x_band, h - y_band)),
        panel.crop((w - x_band, y_band, w, h - y_band)),
    ])
    if rim is None:
        return {}
    body = panel.crop(inner_rect)
    rim_luma = rim.convert("L")
    body_luma = body.convert("L")
    rim_stat = ImageStat.Stat(rim_luma)
    body_stat = ImageStat.Stat(body_luma)
    rim_edge = ImageStat.Stat(rim_luma.filter(ImageFilter.FIND_EDGES)).mean[0]
    body_edge = ImageStat.Stat(body_luma.filter(ImageFilter.FIND_EDGES)).mean[0]
    rim_chroma = chroma_split_score(rim)
    body_chroma = chroma_split_score(body)
    rim_contrast = abs(rim_stat.mean[0] - body_stat.mean[0])
    chroma_lift = max(0.0, rim_chroma - body_chroma * 0.72)
    edge_lift = max(0.0, rim_edge - body_edge * 0.82)
    detail = body_stat.stddev[0]
    hot_pct = image_hot_pct(panel.convert("L"), 245)
    bright_pct = image_hot_pct(panel.convert("L"), 220)
    signature = (
        min(28.0, rim_contrast) * 1.15 +
        min(34.0, edge_lift) * 1.05 +
        min(42.0, chroma_lift) * 1.35 +
        min(55.0, detail) * 0.38 -
        hot_pct * 1.8 -
        max(0.0, body_stat.mean[0] - 170.0) * 0.22
    )
    return {
        "rimLumaMean": rim_stat.mean[0],
        "bodyLumaMean": body_stat.mean[0],
        "rimContrast": rim_contrast,
        "rimEdge": rim_edge,
        "bodyEdge": body_edge,
        "edgeLift": edge_lift,
        "rimChroma": rim_chroma,
        "bodyChroma": body_chroma,
        "chromaLift": chroma_lift,
        "bodyDetail": detail,
        "brightPct": bright_pct,
        "hotPct": hot_pct,
        "glassSignature": max(0.0, min(100.0, signature)),
    }


def hist_percentile(hist: list[int], pct: float) -> float:
    total = sum(hist)
    if total <= 0:
        return 0.0
    threshold = total * pct / 100.0
    acc = 0
    for i, count in enumerate(hist):
        acc += count
        if acc >= threshold:
            return float(i)
    return 255.0


def resize_to_width(image: Image.Image, width: int) -> Image.Image:
    if image.width == width:
        return image.copy()
    height = max(1, round(image.height * (width / image.width)))
    return image.resize((width, height), Image.Resampling.LANCZOS)


def diff_strip(prev: Image.Image | None, cur: Image.Image, rect: tuple[int, int, int, int] | None, width: int) -> Image.Image | None:
    if prev is None or rect is None:
        return None
    diff = ImageChops.difference(prev.convert("RGB"), cur.convert("RGB")).convert("L")
    diff = diff.crop(rect)
    diff = ImageOps.autocontrast(diff)
    color = ImageOps.colorize(diff, black="#101820", white="#ff3b30")
    return resize_to_width(color, width)


def draw_text(draw: ImageDraw.ImageDraw, xy: tuple[int, int], text: str, fill: str, font: ImageFont.ImageFont) -> None:
    draw.text((xy[0] + 1, xy[1] + 1), text, fill="#000000", font=font)
    draw.text(xy, text, fill=fill, font=font)


def event_counts(events: list[dict], start: float | None, end: float | None) -> dict[str, int]:
    counts: dict[str, int] = {}
    for event in events:
        if start is not None and event["t"] < start:
            continue
        if end is not None and event["t"] > end:
            continue
        key = str(event.get("event"))
        counts[key] = counts.get(key, 0) + 1
    return counts


def current_drag_latest(
    events: list[dict],
    times: list[float],
    t: float,
    names: set[str],
    start: float | None,
) -> dict | None:
    event = latest_before(events, times, t, names)
    if event and start is not None and event["t"] < start:
        return None
    return event


def summarize_native(events: list[dict], marks: dict[str, dict]) -> list[str]:
    if not events:
        return ["native: no events provided"]
    times = [e["t"] for e in events]
    start = marks.get("drag_start", {}).get("t")
    end = marks.get("drag_end", {}).get("t")
    in_drag = [e for e in events if (start is None or e["t"] >= start) and (end is None or e["t"] <= end)]
    counts = event_counts(events, start, end)
    slides = [e for e in in_drag if e.get("event") == "slide"]
    draws = [e for e in in_drag if e.get("event") == "draw"]
    frames = [e for e in in_drag if e.get("event") == "frame"]
    slide_to_draw = []
    for slide in slides:
        draw = next_after(events, times, slide["t"], {"draw"})
        if draw:
            slide_to_draw.append(draw["t"] - slide["t"])
    draw_after_slide = []
    draw_x_error = []
    draw_y_error = []
    draw_point_error = []
    for draw in draws:
        slide = current_drag_latest(events, times, draw["t"], {"slide"}, start)
        if slide:
            draw_after_slide.append(draw["t"] - slide["t"])
            dp = event_panel(draw)
            sp = event_panel(slide)
            if dp and sp:
                dx = dp[0] - sp[0]
                dy = dp[1] - sp[1]
                draw_x_error.append(dx)
                draw_y_error.append(dy)
                draw_point_error.append(math.hypot(dx, dy))
    frame_age = [float(e.get("ageMs", 0.0)) for e in frames if "ageMs" in e]
    draw_age = [float(e.get("frameAgeMs", 0.0)) for e in draws if "frameAgeMs" in e]
    drawable_wait = [float(e.get("drawableWaitMs", 0.0)) for e in draws if "drawableWaitMs" in e]
    frame_dt = [b["t"] - a["t"] for a, b in zip(frames, frames[1:])]
    lines = [
        f"native drag counts: " + ", ".join(f"{k}={counts[k]}" for k in sorted(counts)),
        f"slide_to_next_draw_ms: {compact(slide_to_draw)}",
        f"draw_after_latest_slide_ms: {compact(draw_after_slide)}",
        f"draw_x_minus_slide_x_pt: {compact(draw_x_error)}",
        f"draw_y_minus_slide_y_pt: {compact(draw_y_error)}",
        f"draw_minus_slide_pt: {compact(draw_point_error)}",
        f"stream_frame_dt_ms: {compact(frame_dt)}",
        f"frame_age_ms: {compact(frame_age)}",
        f"draw_frame_age_ms: {compact(draw_age)}",
        f"drawable_wait_ms: {compact(drawable_wait)}",
    ]
    for name in ("filter", "stream-start"):
        event = latest_before(events, times, start or events[-1]["t"], {name})
        if event:
            payload = {k: v for k, v in event.items() if k not in {"t", "event"}}
            lines.append(f"{name}: {payload}")
    return lines


def diagnose_native(events: list[dict], marks: dict[str, dict]) -> list[str]:
    if not events:
        return []
    times = [e["t"] for e in events]
    start = marks.get("drag_start", {}).get("t")
    end = marks.get("drag_end", {}).get("t")
    in_drag = [e for e in events if (start is None or e["t"] >= start) and (end is None or e["t"] <= end)]
    draws = [e for e in in_drag if e.get("event") == "draw"]
    draw_age = [float(e.get("frameAgeMs", 0.0)) for e in draws if "frameAgeMs" in e]
    draw_point_error = []
    for draw in draws:
        slide = current_drag_latest(events, times, draw["t"], {"slide"}, start)
        dp = event_panel(draw)
        sp = event_panel(slide)
        if dp and sp:
            draw_point_error.append(math.hypot(dp[0] - sp[0], dp[1] - sp[1]))

    lines: list[str] = []
    filter_event = latest_before(events, times, start or events[-1]["t"], {"filter"})
    excluded_count = 0
    if filter_event:
        excluded_count = int(filter_event.get("excludedApps", 0)) + int(filter_event.get("excludedWindows", 0))
    if filter_event and excluded_count == 0:
        lines.append("diagnosis: self-capture risk: filter excluded zero apps/windows")
    if draw_age and percentile(draw_age, 95) > 100:
        lines.append(f"diagnosis: stale capture: draw frame age p95 {percentile(draw_age, 95):.1f}ms")
    if draw_point_error and max(draw_point_error) <= 1.0:
        lines.append("diagnosis: geometry ok: draw panel tracks latest slide within 1pt")
    if not lines:
        lines.append("diagnosis: no obvious native timing fault in selected drag window")
    return lines


def summarize_capture(all_frames: list[dict], selected: list[dict], marks: dict[str, dict], metadata: dict) -> list[str]:
    all_dt = [b["t"] - a["t"] for a, b in zip(all_frames, all_frames[1:])]
    selected_dt = [b["t"] - a["t"] for a, b in zip(selected, selected[1:])]
    start = marks.get("drag_start", {}).get("t")
    end = marks.get("drag_end", {}).get("t")
    in_drag = [frame for frame in all_frames if (start is None or frame["t"] >= start) and (end is None or frame["t"] <= end)]
    in_drag_dt = [b["t"] - a["t"] for a, b in zip(in_drag, in_drag[1:])]
    requested = None
    frame_meta = metadata.get("frames") if isinstance(metadata.get("frames"), dict) else {}
    if "intervalMs" in frame_meta:
        requested = float(frame_meta["intervalMs"])
    elif "fps" in frame_meta and float(frame_meta["fps"]) > 0:
        requested = 1000.0 / float(frame_meta["fps"])

    lines = [
        f"capture frames: total={len(all_frames)} inDrag={len(in_drag)}",
        f"capture_all_dt_ms: {compact(all_dt)}",
        f"capture_drag_dt_ms: {compact(in_drag_dt)}",
        f"capture_selected_dt_ms: {compact(selected_dt)}",
    ]
    if requested is not None:
        lines.append(f"capture_requested_dt_ms: {requested:.2f}")
        if selected_dt and stats.median(selected_dt) > requested * 1.35:
            lines.append(f"diagnosis: observer cadence limited: selected median {stats.median(selected_dt):.1f}ms")
    return lines


def selected_frames(
    frames: list[dict],
    marks: dict[str, dict],
    burst: tuple[int, int] | None,
    indices: str | None,
    at_ms: float | None,
    count: int,
) -> list[dict]:
    by_index = {f["i"]: f for f in frames}
    if indices:
        wanted = [int(v.strip()) for v in indices.split(",") if v.strip()]
    elif burst:
        start, count = burst
        wanted = list(range(start, start + count))
    elif at_ms is not None and "drag_start" in marks:
        target = marks["drag_start"]["t"] + at_ms
        start = next((i for i, frame in enumerate(frames) if frame["t"] >= target), len(frames) - 1)
        return frames[start:start + count]
    else:
        wanted = [f["i"] for f in frames[:5]]
    return [by_index[i] for i in wanted if i in by_index]


def collect_frame_metrics(
    sequence_dir: Path,
    frames: list[dict],
    marks: dict[str, dict],
    events: list[dict],
    metadata: dict,
    capture_crop: tuple[float, float, float, float] | None,
) -> tuple[dict[int, dict], list[str]]:
    event_times = [e["t"] for e in events]
    drag_start = marks.get("drag_start", {}).get("t")
    metrics: dict[int, dict] = {}
    prev_image: Image.Image | None = None
    prev_t: float | None = None
    prev_slide_x: float | None = None
    prev_slide_y: float | None = None
    prev_draw_x: float | None = None
    prev_draw_y: float | None = None
    prev_panel_px: tuple[int, int, int, int] | None = None

    for frame in frames:
        image = Image.open(sequence_dir / frame["file"]).convert("RGB")
        panel_event = latest_before(events, event_times, frame["t"], {"draw", "slide", "stream-start", "resize"})
        latest_slide = latest_before(events, event_times, frame["t"], {"slide"})
        latest_draw = latest_before(events, event_times, frame["t"], {"draw"})
        panel = event_panel(panel_event)
        panel_source = "native" if panel else "metadata"
        panel = panel or metadata_panel_for_time(metadata, marks, frame["t"])
        panel_px = map_rect(panel, capture_crop, image.size) if panel and capture_crop else None
        slide_panel = event_panel(latest_slide)
        draw_panel = event_panel(latest_draw)
        slide_x = slide_panel[0] if slide_panel else (panel[0] if panel and panel_source == "metadata" else None)
        slide_y = slide_panel[1] if slide_panel else (panel[1] if panel and panel_source == "metadata" else None)
        draw_x = draw_panel[0] if draw_panel else None
        draw_y = draw_panel[1] if draw_panel else None
        draw_age = float(latest_draw.get("frameAgeMs")) if latest_draw and "frameAgeMs" in latest_draw else None
        geometry_lag_x = (draw_x - slide_x) if draw_x is not None and slide_x is not None else 0.0
        geometry_lag_y = (draw_y - slide_y) if draw_y is not None and slide_y is not None else 0.0
        geometry_lag = math.hypot(geometry_lag_x, geometry_lag_y)
        diff = panel_diff_metrics(prev_image, image, panel_px)
        motion_diff = panel_motion_metrics(prev_image, image, prev_panel_px, panel_px)
        luma = panel_luma_metrics(image, panel_px)
        optics = panel_optics_metrics(image, panel_px)
        edge_x = estimate_right_edge(image, panel_px)
        edge_error = edge_x - panel_px[2] if edge_x is not None and panel_px else None
        slide_delta = (
            math.hypot(slide_x - prev_slide_x, slide_y - prev_slide_y)
            if slide_x is not None and slide_y is not None and prev_slide_x is not None and prev_slide_y is not None
            else 0.0
        )
        draw_delta = (
            math.hypot(draw_x - prev_draw_x, draw_y - prev_draw_y)
            if draw_x is not None and draw_y is not None and prev_draw_x is not None and prev_draw_y is not None
            else 0.0
        )
        motion = max(slide_delta, draw_delta, motion_diff.get("motionPx", 0.0))
        rms = diff.get("rms", 0.0)
        active_pct = diff.get("activePct", 0.0)
        edge_mean = diff.get("edgeMean", 0.0)
        valid_draw_age = draw_age is not None and draw_age >= 0
        age = draw_age if valid_draw_age else 0.0
        local_motion = motion_diff.get("localRms", rms)
        freeze_score = motion if motion >= 3.0 and local_motion < 2.0 and rms < 2.0 else 0.0
        age_factor = 1.0 + min(3.0, max(0.0, age - 16.0) / 90.0)
        raw_change_score = (rms * 0.30 + active_pct * 1.15 + edge_mean * 0.18) * age_factor
        visual_tracking_ok = (
            geometry_lag > 8.0
            and bool(motion_diff)
            and motion_diff.get("compRms", 999.0) <= 3.0
            and motion_diff.get("trackingAdvantage", 0.0) >= 8.0
            and motion_diff.get("stickiness", 999.0) <= 2.0
            and raw_change_score <= 5.0
        )
        if motion_diff and valid_draw_age:
            stale_echo_score = max(0.0, motion_diff["stickiness"] - 1.2) * (1.0 + min(2.0, motion / 28.0)) * age_factor
        else:
            stale_echo_score = 0.0
        metrics[frame["i"]] = {
            "dtMs": 0.0 if prev_t is None else frame["t"] - prev_t,
            "dragMs": 0.0 if drag_start is None else frame["t"] - drag_start,
            "slideX": slide_x,
            "slideY": slide_y,
            "drawX": draw_x,
            "drawY": draw_y,
            "drawAgeMs": draw_age,
            "geometryLagXPt": geometry_lag_x,
            "geometryLagYPt": geometry_lag_y,
            "geometryLagPt": geometry_lag,
            "panelDiff": diff,
            "panelMotion": motion_diff,
            "luma": luma,
            "optics": optics,
            "edgeErrPx": edge_error,
            "panelSource": panel_source if panel else None,
            "motionPt": motion,
            "visualTrackingOk": visual_tracking_ok,
            "freezeScore": freeze_score,
            "staleEchoScore": stale_echo_score,
            "rawChangeScore": raw_change_score,
        }
        prev_image = image
        prev_t = frame["t"]
        prev_slide_x = slide_x
        prev_slide_y = slide_y
        prev_draw_x = draw_x
        prev_draw_y = draw_y
        prev_panel_px = panel_px

    freeze_scores = [m["freezeScore"] for m in metrics.values() if m["freezeScore"] > 0]
    echo_scores = [m["staleEchoScore"] for m in metrics.values()]
    raw_change_scores = [m["rawChangeScore"] for m in metrics.values()]
    geometry_lag_values = [m["geometryLagPt"] for m in metrics.values()]
    tracked_lag_values = [m["geometryLagPt"] for m in metrics.values() if m.get("visualTrackingOk")]
    untracked_lag_values = [m["geometryLagPt"] for m in metrics.values() if m["geometryLagPt"] > 0 and not m.get("visualTrackingOk")]
    rms_values = [m["panelDiff"]["rms"] for m in metrics.values() if m["panelDiff"]]
    active_values = [m["panelDiff"]["activePct"] for m in metrics.values() if m["panelDiff"]]
    local_values = [m["panelMotion"]["localRms"] for m in metrics.values() if m["panelMotion"]]
    comp_values = [m["panelMotion"]["compRms"] for m in metrics.values() if m["panelMotion"]]
    stick_values = [m["panelMotion"]["stickiness"] for m in metrics.values() if m["panelMotion"]]
    tracking_values = [m["panelMotion"]["trackingAdvantage"] for m in metrics.values() if m["panelMotion"]]
    luma_mean = [m["luma"]["mean"] for m in metrics.values() if m["luma"]]
    luma_p95 = [m["luma"]["p95"] for m in metrics.values() if m["luma"]]
    luma_hot = [m["luma"]["hotPct"] for m in metrics.values() if m["luma"]]
    glass_signature = [m["optics"]["glassSignature"] for m in metrics.values() if m["optics"]]
    rim_contrast = [m["optics"]["rimContrast"] for m in metrics.values() if m["optics"]]
    chroma_lift = [m["optics"]["chromaLift"] for m in metrics.values() if m["optics"]]
    edge_lift = [m["optics"]["edgeLift"] for m in metrics.values() if m["optics"]]
    rim_chroma = [m["optics"]["rimChroma"] for m in metrics.values() if m["optics"]]
    rim_edge = [m["optics"]["rimEdge"] for m in metrics.values() if m["optics"]]
    body_detail = [m["optics"]["bodyDetail"] for m in metrics.values() if m["optics"]]
    lines = [
        f"visual_screen_diff_rms: {compact(rms_values)}",
        f"visual_active_diff_pct: {compact(active_values)}",
        f"visual_raw_change_score: {compact(raw_change_scores)}",
        f"visual_geometry_lag_pt: {compact(geometry_lag_values)}",
        f"visual_tracking_ok_lag_pt: {compact(tracked_lag_values)}",
        f"visual_panel_local_rms: {compact(local_values)}",
        f"visual_motion_comp_rms: {compact(comp_values)}",
        f"visual_tracking_advantage: {compact(tracking_values)}",
        f"visual_echo_stickiness: {compact(stick_values)}",
        f"visual_stale_echo_score: {compact(echo_scores)}",
        f"visual_freeze_events: count={len(freeze_scores)} max={max(freeze_scores) if freeze_scores else 0.0:.2f}",
        f"visual_luma_mean: {compact(luma_mean)}",
        f"visual_luma_p95: {compact(luma_p95)}",
        f"visual_luma_hot_pct: {compact(luma_hot)}",
        f"glass_signature: {compact(glass_signature)}",
        f"glass_rim_contrast: {compact(rim_contrast)}",
        f"glass_chroma_lift: {compact(chroma_lift)}",
        f"glass_edge_lift: {compact(edge_lift)}",
        f"glass_rim_chroma: {compact(rim_chroma)}",
        f"glass_rim_edge: {compact(rim_edge)}",
        f"glass_body_detail: {compact(body_detail)}",
    ]
    if freeze_scores:
        lines.append("diagnosis: visual freeze risk: native motion with near-zero panel diff")
    if stick_values and percentile(stick_values, 95) <= 2.0 and raw_change_scores and percentile(raw_change_scores, 95) > 30:
        lines.append("diagnosis: raw diff is high, but motion-compensated backdrop tracks correctly")
    if geometry_lag_values and percentile(geometry_lag_values, 95) > 8:
        if not untracked_lag_values:
            lines.append("diagnosis: event geometry drift, but visual backdrop motion-compensates cleanly")
        else:
            lines.append(f"diagnosis: render geometry lag risk: slide/draw drift p95 {percentile(untracked_lag_values, 95):.1f}pt")
    elif echo_scores and percentile(echo_scores, 95) > 12:
        lines.append(f"diagnosis: visual echo risk: staleEchoScore p95 {percentile(echo_scores, 95):.1f}")
    if luma_mean and (percentile(luma_mean, 95) > 190 or percentile(luma_hot, 95) > 8):
        lines.append(
            f"diagnosis: brightness blowout risk: lumaMean p95 {percentile(luma_mean, 95):.1f}, "
            f"hotPct p95 {percentile(luma_hot, 95):.1f}"
        )
    if glass_signature and percentile(glass_signature, 50) < 18:
        lines.append(
            f"diagnosis: weak glass signature: median {percentile(glass_signature, 50):.1f}, "
            f"rim/chroma/depth may be too subtle"
        )
    return metrics, lines


def build_sheet(
    sequence_dir: Path,
    frames: list[dict],
    marks: dict[str, dict],
    events: list[dict],
    metadata: dict,
    capture_crop: tuple[float, float, float, float] | None,
    out: Path,
    frame_width: int,
    summary_lines: list[str],
    metrics: dict[int, dict],
) -> list[str]:
    event_times = [e["t"] for e in events]
    font = ImageFont.load_default()
    rows: list[Image.Image] = []
    report: list[str] = []
    prev_image: Image.Image | None = None
    prev_t: float | None = None
    drag_start = marks.get("drag_start", {}).get("t")

    for frame in frames:
        image = Image.open(sequence_dir / frame["file"]).convert("RGB")
        panel_event = latest_before(events, event_times, frame["t"], {"draw", "slide", "stream-start", "resize"})
        latest_slide = latest_before(events, event_times, frame["t"], {"slide"})
        latest_draw = latest_before(events, event_times, frame["t"], {"draw"})
        panel = event_panel(panel_event)
        panel = panel or metadata_panel_for_time(metadata, marks, frame["t"])
        panel_px = map_rect(panel, capture_crop, image.size) if panel and capture_crop else None
        full = resize_to_width(image, frame_width)
        panel_zoom = resize_to_width(image.crop(panel_px), frame_width) if panel_px else None
        heat = diff_strip(prev_image, image, panel_px, frame_width)
        metric = metrics.get(frame["i"], {})
        diff = metric.get("panelDiff", {})
        motion_diff = metric.get("panelMotion", {})
        dt = metric.get("dtMs", 0.0 if prev_t is None else frame["t"] - prev_t)
        rel = metric.get("dragMs", 0.0 if drag_start is None else frame["t"] - drag_start)
        slide_x = metric.get("slideX")
        slide_y = metric.get("slideY")
        draw_x = metric.get("drawX")
        draw_y = metric.get("drawY")
        draw_age = metric.get("drawAgeMs")
        geometry_lag = metric.get("geometryLagPt", 0.0)
        edge_error = metric.get("edgeErrPx")
        luma = metric.get("luma", {})
        metric_text = ""
        if diff:
            metric_text = f" screen={diff['rms']:.1f}"
        if motion_diff:
            metric_text += (
                f" mc={motion_diff['compRms']:.1f}"
                f" local={motion_diff['localRms']:.1f}"
                f" stick={motion_diff['stickiness']:.1f}"
            )
        if luma:
            metric_text += f" luma={luma['mean']:.0f}/{luma['p95']:.0f} hot={luma['hotPct']:.1f}%"
        optics = metric.get("optics", {})
        if optics:
            metric_text += (
                f" glass={optics['glassSignature']:.0f}"
                f" rim={optics['rimContrast']:.0f}"
                f" chr={optics['chromaLift']:.0f}"
                f" edge={optics['edgeLift']:.0f}"
            )
        if edge_error is not None:
            metric_text += f" edgeErrPx={edge_error:.1f}"
        metric_text += (
            f" freeze={metric.get('freezeScore', 0.0):.1f}"
            f" echo={metric.get('staleEchoScore', 0.0):.1f}"
            f" raw={metric.get('rawChangeScore', 0.0):.1f}"
        )
        slide_label = f"{float(slide_x):.0f},{float(slide_y):.0f}" if slide_x is not None and slide_y is not None else "n/a"
        draw_label = f"{float(draw_x):.0f},{float(draw_y):.0f}" if draw_x is not None and draw_y is not None else "n/a"
        label = (
            f"frame {frame['i']:03d}  dt={dt:.1f}ms  drag+{rel:.1f}ms"
            f"  slide={slide_label}"
            f"  draw={draw_label}"
        )
        if draw_age is not None:
            label += f"  drawAge={float(draw_age):.1f}ms"
        if geometry_lag:
            label += f"  lag={float(geometry_lag):.1f}pt"
        label += metric_text
        report.append(label)

        parts = [full]
        if panel_zoom:
            parts.append(panel_zoom)
        if heat:
            parts.append(heat)
        label_h = 38
        row_h = label_h + sum(part.height for part in parts)
        row = Image.new("RGB", (frame_width, row_h), "#12161d")
        draw = ImageDraw.Draw(row)
        draw_text(draw, (10, 12), label, "#e9f2ff", font)
        y = label_h
        for part in parts:
            row.paste(part, (0, y))
            y += part.height
        rows.append(row)
        prev_image = image
        prev_t = frame["t"]

    gap = 12
    header_lines = summary_lines[:12]
    header_h = 18 + len(header_lines) * 18
    total_h = header_h + sum(r.height for r in rows) + gap * max(0, len(rows) - 1)
    sheet = Image.new("RGB", (frame_width, total_h), "#090b0f")
    draw = ImageDraw.Draw(sheet)
    for i, line in enumerate(header_lines):
        draw_text(draw, (10, 10 + i * 18), line[:220], "#e9f2ff", font)
    y = header_h
    for row in rows:
        sheet.paste(row, (0, y))
        y += row.height + gap
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sequence_dir", type=Path)
    parser.add_argument("--events", type=Path)
    parser.add_argument("--crop", type=parse_rect, help="capture crop in display points: x,y,w,h")
    parser.add_argument("--burst", type=parse_burst, help="frame START:COUNT")
    parser.add_argument("--indices", help="comma-separated frame indices")
    parser.add_argument("--at-ms", type=float, help="select the first burst frame at drag_start plus this many ms")
    parser.add_argument("--count", type=int, default=5, help="frame count for --at-ms")
    parser.add_argument("--all-frames", action="store_true", help="score every captured frame")
    parser.add_argument("--metrics-only", action="store_true", help="write JSON metrics without rendering a sheet")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--summary-out", type=Path)
    parser.add_argument("--frame-width", type=int, default=1400)
    args = parser.parse_args()

    marks, all_frames = parse_timestamps(args.sequence_dir)
    metadata = parse_metadata(args.sequence_dir)
    events = parse_events(args.events)
    capture_crop = args.crop or metadata_crop(metadata)
    frames = all_frames if args.all_frames else selected_frames(all_frames, marks, args.burst, args.indices, args.at_ms, args.count)
    if not frames:
        raise SystemExit("no selected frames found")
    if not args.metrics_only and not args.out:
        raise SystemExit("--out is required unless --metrics-only is set")

    summary = [
        f"sequence: {args.sequence_dir}",
        f"selected: {[f['i'] for f in frames]}",
        f"crop: {capture_crop if capture_crop else 'n/a'}",
    ]
    summary.extend(summarize_capture(all_frames, frames, marks, metadata))
    frame_metrics, visual_summary = collect_frame_metrics(args.sequence_dir, frames, marks, events, metadata, capture_crop)
    summary.extend(visual_summary)
    summary.extend(summarize_native(events, marks))
    summary.extend(diagnose_native(events, marks))
    for line in summary:
        print(line)
    frame_report = []
    if not args.metrics_only:
        frame_report = build_sheet(args.sequence_dir, frames, marks, events, metadata, capture_crop, args.out, args.frame_width, summary, frame_metrics)
    for line in frame_report:
        print(line)
    if args.summary_out:
        payload = {
            "sequence": str(args.sequence_dir),
            "selected": [f["i"] for f in frames],
            "crop": capture_crop,
            "summary": summary,
            "frames": frame_report,
            "metrics": frame_metrics,
        }
        args.summary_out.parent.mkdir(parents=True, exist_ok=True)
        args.summary_out.write_text(json.dumps(payload, indent=2) + "\n")
    if args.out:
        print(f"wrote: {args.out}")
    elif args.summary_out:
        print(f"wrote: {args.summary_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
