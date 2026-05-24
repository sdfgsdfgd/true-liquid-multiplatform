#!/usr/bin/env python3
from __future__ import annotations

import bisect
import json
import math
import statistics as st
import sys
from pathlib import Path


def parse_rect(value: str) -> tuple[float, float, float, float]:
    x, y, w, h = [float(p) for p in value.split(",")]
    return x, y, w, h


def pct(xs: list[float], p: float) -> float:
    if not xs:
        return 0.0
    xs = sorted(xs)
    i = min(len(xs) - 1, max(0, round((len(xs) - 1) * p / 100.0)))
    return xs[i]


def compact(xs: list[float]) -> dict[str, float]:
    if not xs:
        return {"min": 0.0, "median": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
    return {"min": min(xs), "median": st.median(xs), "p95": pct(xs, 95), "p99": pct(xs, 99), "max": max(xs)}


def load(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def interp_expected(expected: list[dict], times: list[float], t: float) -> tuple[float, float] | None:
    i = bisect.bisect_right(times, t)
    if i <= 0:
        e = expected[0]
        x, y, _, _ = parse_rect(e["panel"])
        return x, y
    if i >= len(expected):
        e = expected[-1]
        x, y, _, _ = parse_rect(e["panel"])
        return x, y
    a = expected[i - 1]
    b = expected[i]
    ta = float(a["t"])
    tb = float(b["t"])
    ax, ay, _, _ = parse_rect(a["panel"])
    bx, by, _, _ = parse_rect(b["panel"])
    if tb <= ta:
        return ax, ay
    u = max(0.0, min(1.0, (t - ta) / (tb - ta)))
    return ax + (bx - ax) * u, ay + (by - ay) * u


def main() -> int:
    root = Path(sys.argv[1])
    expected = load(root / "expected_events.jsonl")
    actual = load(root / "actual_window_events.jsonl")
    meta = json.loads((root / "position_meta.json").read_text())
    start = float(meta["dragStartMs"])
    end = float(meta["dragEndMs"])
    expected_times = [float(e["t"]) for e in expected]
    rows = []
    for sample in actual:
        t = float(sample["t"])
        if not (start <= t <= end):
            continue
        ex = interp_expected(expected, expected_times, t)
        if ex is None:
            continue
        ax, ay, _, _ = parse_rect(sample["panel"])
        dx = ax - ex[0]
        dy = ay - ex[1]
        rows.append({"t": t, "dragMs": t - start, "actualX": ax, "actualY": ay, "expectedX": ex[0], "expectedY": ex[1], "dx": dx, "dy": dy, "dist": math.hypot(dx, dy)})

    jump_rows = []
    for a, b in zip(rows, rows[1:]):
        dt = b["t"] - a["t"]
        actual_move = math.hypot(b["actualX"] - a["actualX"], b["actualY"] - a["actualY"])
        expected_move = math.hypot(b["expectedX"] - a["expectedX"], b["expectedY"] - a["expectedY"])
        jump_rows.append({
            "t": b["t"],
            "dragMs": b["dragMs"],
            "dt": dt,
            "actualMove": actual_move,
            "expectedMove": expected_move,
            "moveDelta": actual_move - expected_move,
            "stuck": expected_move >= 3.0 and actual_move < expected_move * 0.25,
            "catchup": actual_move > max(8.0, expected_move * 1.8),
        })

    dist = [r["dist"] for r in rows]
    abs_dx = [abs(r["dx"]) for r in rows]
    abs_dy = [abs(r["dy"]) for r in rows]
    dt = [r["dt"] for r in jump_rows]
    actual_move = [r["actualMove"] for r in jump_rows]
    expected_move = [r["expectedMove"] for r in jump_rows]
    stuck = [r for r in jump_rows if r["stuck"]]
    catchup = [r for r in jump_rows if r["catchup"]]
    top_err = sorted(rows, key=lambda r: r["dist"], reverse=True)[:16]
    top_jump = sorted(jump_rows, key=lambda r: abs(r["moveDelta"]), reverse=True)[:16]
    payload = {
        "root": str(root),
        "samples": len(rows),
        "dragMs": end - start,
        "errorPt": compact(dist),
        "absDxPt": compact(abs_dx),
        "absDyPt": compact(abs_dy),
        "sampleDtMs": compact(dt),
        "actualMovePt": compact(actual_move),
        "expectedMovePt": compact(expected_move),
        "stuckCount": len(stuck),
        "catchupCount": len(catchup),
        "topError": top_err,
        "topMoveDelta": top_jump,
    }
    (root / "position_analysis.json").write_text(json.dumps(payload, indent=2) + "\n")
    print(f"samples={payload['samples']} dragMs={payload['dragMs']:.1f}")
    print("errorPt min/med/p95/p99/max "
          f"{payload['errorPt']['min']:.1f}/{payload['errorPt']['median']:.1f}/{payload['errorPt']['p95']:.1f}/{payload['errorPt']['p99']:.1f}/{payload['errorPt']['max']:.1f}")
    print("sampleDtMs min/med/p95/p99/max "
          f"{payload['sampleDtMs']['min']:.1f}/{payload['sampleDtMs']['median']:.1f}/{payload['sampleDtMs']['p95']:.1f}/{payload['sampleDtMs']['p99']:.1f}/{payload['sampleDtMs']['max']:.1f}")
    print(f"stuck={len(stuck)} catchup={len(catchup)}")
    print("top errors:")
    for r in top_err[:8]:
        print(f"  t={r['dragMs']:.1f}ms err={r['dist']:.1f} dx={r['dx']:.1f} dy={r['dy']:.1f} actual={r['actualX']:.1f},{r['actualY']:.1f} expected={r['expectedX']:.1f},{r['expectedY']:.1f}")
    print("top movement deltas:")
    for r in top_jump[:8]:
        print(f"  t={r['dragMs']:.1f}ms dt={r['dt']:.1f} actualMove={r['actualMove']:.1f} expectedMove={r['expectedMove']:.1f} delta={r['moveDelta']:.1f} stuck={r['stuck']} catchup={r['catchup']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
