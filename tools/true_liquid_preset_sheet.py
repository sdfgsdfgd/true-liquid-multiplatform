#!/usr/bin/env python3
"""Create a side-by-side visual evidence sheet from True Liquid score runs."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


DEFAULT_ROOT = Path("/tmp/true-liquid-zenit1-instrument/score-runs")
DEFAULT_OUT = Path("/tmp/true-liquid-zenit1-instrument/current-preset-comparison.png")
DEFAULT_ITEMS = [
    "Native AppKit fallback:run-065:score_drag180p0.json:11",
    "Spotlight default:run-061:score_drag220p0.json:23",
    "Clear lens no tint:run-063:score_drag300p0.json:26",
    "Prism optical:run-064:score_drag180p0.json:20",
]


@dataclass(frozen=True)
class SheetItem:
    label: str
    run: str
    score: str
    frame: int


def parse_item(raw: str) -> SheetItem:
    parts = raw.split(":")
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("expected LABEL:RUN:SCORE_JSON:FRAME")
    label, run, score, frame = parts
    try:
        frame_id = int(frame)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid frame: {frame}") from exc
    return SheetItem(label, run, score, frame_id)


def load_font(size: int) -> ImageFont.ImageFont:
    for path in (
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


def fit(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    fitted = image.copy()
    fitted.thumbnail(size, Image.Resampling.LANCZOS)
    canvas = Image.new("RGB", size, (12, 17, 22))
    canvas.paste(fitted, ((size[0] - fitted.width) // 2, (size[1] - fitted.height) // 2))
    return canvas


def panel_crop(
    image: Image.Image,
    crop: list[float],
    metric: dict,
    panel_size: tuple[float, float],
    pad: tuple[float, float],
) -> Image.Image:
    scale_x = image.width / float(crop[2])
    scale_y = image.height / float(crop[3])
    panel_x = metric.get("drawX") if isinstance(metric.get("drawX"), (int, float)) else metric.get("slideX", 0)
    panel_y = metric.get("drawY") if isinstance(metric.get("drawY"), (int, float)) else metric.get("slideY", 0)
    panel_w, panel_h = panel_size
    pad_x, pad_y = pad
    rect = (
        round((panel_x - crop[0] - pad_x) * scale_x),
        round((panel_y - crop[1] - pad_y) * scale_y),
        round((panel_x + panel_w - crop[0] + pad_x) * scale_x),
        round((panel_y + panel_h - crop[1] + pad_y) * scale_y),
    )
    x0 = max(0, min(image.width, rect[0]))
    y0 = max(0, min(image.height, rect[1]))
    x1 = max(0, min(image.width, rect[2]))
    y1 = max(0, min(image.height, rect[3]))
    if x1 <= x0 or y1 <= y0:
        return image
    return image.crop((x0, y0, x1, y1))


def load_panel(root: Path, item: SheetItem, panel_size: tuple[float, float], pad: tuple[float, float]) -> tuple[Image.Image, dict]:
    sequence = root / item.run / "frames" / "av-auto"
    score = json.loads((sequence / item.score).read_text())
    metric = score["metrics"][str(item.frame)]
    image = Image.open(sequence / f"frame_{item.frame:03d}.png").convert("RGB")
    return panel_crop(image, score["crop"], metric, panel_size, pad), metric


def metric_line(metric: dict) -> tuple[str, str]:
    optics = metric.get("optics", {})
    luma = metric.get("luma", {})
    motion = (
        f"echo {metric.get('staleEchoScore', 0.0):.1f}  "
        f"lag {metric.get('geometryLagPt', 0.0):.1f}pt  "
        f"freeze {metric.get('freezeScore', 0.0):.1f}  "
        f"luma {luma.get('mean', 0.0):.1f}/{luma.get('p95', 0.0):.0f}"
    )
    optics_line = (
        f"glass {optics.get('glassSignature', 0.0):.1f}  "
        f"rim {optics.get('rimContrast', 0.0):.1f}  "
        f"body detail {optics.get('bodyDetail', 0.0):.1f}  "
        f"chroma {optics.get('rimChroma', 0.0):.1f}"
    )
    return motion, optics_line


def draw_sheet(args: argparse.Namespace) -> None:
    items = [parse_item(raw) for raw in (args.item or DEFAULT_ITEMS)]
    columns = max(1, args.columns)
    rows = (len(items) + columns - 1) // columns
    thumb_size = tuple(args.thumb_size)
    cell_h = thumb_size[1] + 112
    pad = 28
    header = 92
    width = pad * (columns + 1) + thumb_size[0] * columns
    height = header + pad * (rows + 1) + cell_h * rows

    title_font = load_font(28)
    label_font = load_font(22)
    small_font = load_font(16)
    canvas = Image.new("RGB", (width, height), (8, 12, 16))
    draw = ImageDraw.Draw(canvas)
    draw.text((pad, 24), args.title, fill=(235, 244, 250), font=title_font)
    draw.text((pad, 58), args.subtitle, fill=(150, 170, 182), font=small_font)

    for idx, item in enumerate(items):
        panel, metric = load_panel(args.root, item, tuple(args.panel_size), tuple(args.pad))
        thumb = fit(panel, thumb_size)
        col = idx % columns
        row = idx // columns
        x = pad + col * (thumb_size[0] + pad)
        y = header + pad + row * (cell_h + pad)
        draw.rounded_rectangle(
            (x - 10, y - 10, x + thumb_size[0] + 10, y + cell_h - 10),
            radius=12,
            fill=(15, 22, 28),
            outline=(38, 54, 65),
            width=1,
        )
        canvas.paste(thumb, (x, y))
        motion, optics = metric_line(metric)
        ty = y + thumb_size[1] + 14
        draw.text((x, ty), f"{item.label}  |  {item.run} frame {item.frame}", fill=(238, 245, 250), font=label_font)
        draw.text((x, ty + 30), motion, fill=(175, 195, 204), font=small_font)
        draw.text((x, ty + 52), optics, fill=(136, 218, 226), font=small_font)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(args.out)
    print(args.out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--item", action="append", help="LABEL:RUN:SCORE_JSON:FRAME; can be passed multiple times")
    parser.add_argument("--columns", type=int, default=2)
    parser.add_argument("--thumb-size", type=int, nargs=2, default=(790, 540), metavar=("W", "H"))
    parser.add_argument("--panel-size", type=float, nargs=2, default=(780.0, 530.0), metavar=("W", "H"))
    parser.add_argument("--pad", type=float, nargs=2, default=(34.0, 26.0), metavar=("X", "Y"))
    parser.add_argument("--title", default="True Liquid Compose: preset evidence sheet")
    parser.add_argument(
        "--subtitle",
        default="Same desktop, expanded command palette, live drag capture. Metrics are from the displayed frame.",
    )
    draw_sheet(parser.parse_args())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
