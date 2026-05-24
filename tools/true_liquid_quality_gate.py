#!/usr/bin/env python3
"""Summarize True Liquid smoothness and optical-quality readiness from score summaries."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path


DEFAULT_ROOT = Path("/tmp/true-liquid-zenit1-instrument/score-runs")


@dataclass(frozen=True)
class SummaryInput:
    label: str
    path: Path


def clamp(value: float, lo: float = 0.0, hi: float = 100.0) -> float:
    return max(lo, min(hi, value))


def parse_summary(raw: str) -> SummaryInput:
    if ":" in raw:
        label, path = raw.split(":", 1)
        return SummaryInput(label.strip(), Path(path).expanduser())
    path = Path(raw).expanduser()
    return SummaryInput(path.parent.parent.parent.name or path.stem, path)


def latest_summary(root: Path) -> Path:
    candidates = sorted(root.glob("run-*/frames/*/score_summary.json"))
    if not candidates:
        raise SystemExit(f"no score_summary.json found under {root}")
    return candidates[-1]


def stat(probe: dict, name: str, key: str, default: float = 0.0) -> float:
    value = probe.get(name, {})
    if isinstance(value, dict) and isinstance(value.get(key), (int, float)):
        return float(value[key])
    return default


def edge_diagnostic_enabled(summary_path: Path) -> bool:
    events = summary_path.parents[2] / "events.jsonl"
    if not events.exists():
        return False
    for raw in events.read_text(errors="replace").splitlines():
        if '"event":"draw"' in raw and '"edgeDiagnostic":true' in raw:
            return True
    return False


def summarize_summary(item: SummaryInput) -> dict:
    payload = json.loads(item.path.read_text())
    probes = [p for p in payload.get("probes", []) if p.get("name") != "score_predrag"]
    if not probes:
        probes = payload.get("probes", [])
    if not probes:
        raise SystemExit(f"no probes in {item.path}")

    freeze_count = sum(int(p.get("freezeEvents", {}).get("count", 0)) for p in probes)
    freeze_max = max((float(p.get("freezeEvents", {}).get("max", 0.0)) for p in probes), default=0.0)
    edge_diagnostic = edge_diagnostic_enabled(item.path)

    metrics = {
        "echoMax": max(stat(p, "staleEchoScore", "max") for p in probes),
        "echoP95": max(stat(p, "staleEchoScore", "p95") for p in probes),
        "lagP95": max(stat(p, "geometryLagPt", "p95") for p in probes),
        "untrackedLagP95": max(stat(p, "untrackedGeometryLagPt", "p95") for p in probes),
        "stickP95": max(stat(p, "motionStickiness", "p95") for p in probes),
        "drawAgeP95": max(stat(p, "drawAgeMs", "p95") for p in probes),
        "compP95": max(stat(p, "motionCompRms", "p95") for p in probes),
        "rawP95": max(stat(p, "rawChangeScore", "p95") for p in probes),
        "lumaMeanP95": max(stat(p, "lumaMean", "p95") for p in probes),
        "lumaHotP95": max(stat(p, "lumaHotPct", "p95") for p in probes),
        "glassMedian": min(stat(p, "glassSignature", "median") for p in probes),
        "glassP95": max(stat(p, "glassSignature", "p95") for p in probes),
        "rimContrastP95": max(stat(p, "rimContrast", "p95") for p in probes),
        "chromaLiftP95": max(stat(p, "chromaLift", "p95") for p in probes),
        "edgeLiftP95": max(stat(p, "edgeLift", "p95") for p in probes),
        "rimChromaP95": max(stat(p, "rimChroma", "p95") for p in probes),
        "rimEdgeP95": max(stat(p, "rimEdge", "p95") for p in probes),
        "bodyDetailP95": max(stat(p, "bodyDetail", "p95") for p in probes),
        "edgeDiagnostic": 1.0 if edge_diagnostic else 0.0,
        "freezeCount": float(freeze_count),
        "freezeMax": freeze_max,
    }

    smoothness = clamp(
        100.0
        - metrics["echoMax"] * 10.0
        - freeze_count * 30.0
        - metrics["untrackedLagP95"] * 5.0
        - max(0.0, metrics["drawAgeP95"] - 18.0) * 3.0
        - max(0.0, metrics["lumaHotP95"] - 5.0) * 4.0
    )
    chroma_quality = min(metrics["chromaLiftP95"], 10.0) * 3.0 + min(metrics["edgeLiftP95"], 10.0) * 3.6
    optics = clamp(
        metrics["glassMedian"] * 0.72
        + metrics["bodyDetailP95"] * 0.34
        + metrics["rimContrastP95"] * 0.20
        + chroma_quality
        + min(metrics["rimChromaP95"], 8.0) * 0.55
        - metrics["lumaHotP95"] * 2.0
        - max(0.0, metrics["lumaMeanP95"] - 145.0) * 0.45
        - (100.0 if edge_diagnostic else 0.0)
    )

    gates = {
        "edgeDiagnostic==false": not edge_diagnostic,
        "echoMax<=1": metrics["echoMax"] <= 1.0,
        "freezeCount==0": freeze_count == 0,
        "untrackedLagP95<=2pt": metrics["untrackedLagP95"] <= 2.0,
        "drawAgeP95<=18.5ms": metrics["drawAgeP95"] <= 18.5,
        "lumaMeanP95<=145": metrics["lumaMeanP95"] <= 145.0,
        "lumaHotP95<=5%": metrics["lumaHotP95"] <= 5.0,
        "glassMedian>=35": metrics["glassMedian"] >= 35.0,
        "rimContrastP95>=32": metrics["rimContrastP95"] >= 32.0,
        "chromaLiftP95>=0.8": metrics["chromaLiftP95"] >= 0.8,
        "edgeLiftP95>=0.8": metrics["edgeLiftP95"] >= 0.8,
        "rimChromaP95>=1.2": metrics["rimChromaP95"] >= 1.2,
        "rimChromaP95<=12": metrics["rimChromaP95"] <= 12.0,
        "bodyDetailP95>=32": metrics["bodyDetailP95"] >= 32.0,
    }
    failed = [name for name, ok in gates.items() if not ok]
    return {
        "label": item.label,
        "path": str(item.path),
        "probeCount": len(probes),
        "metrics": metrics,
        "smoothnessScore": smoothness,
        "opticsScore": optics,
        "readinessScore": min(smoothness, optics),
        "gates": gates,
        "failed": failed,
        "pass": not failed,
    }


def compare_to_baseline(reports: list[dict], baseline_label: str | None) -> list[dict]:
    if len(reports) < 2:
        return []
    baseline = None
    if baseline_label:
        baseline = next((r for r in reports if r["label"] == baseline_label), None)
    if baseline is None:
        baseline = next((r for r in reports if "native" in r["label"].lower()), None)
    if baseline is None:
        return []
    base = baseline["metrics"]
    comparisons = []
    for report in reports:
        if report is baseline:
            continue
        metrics = report["metrics"]
        body_base = max(0.001, base["bodyDetailP95"])
        glass_base = max(0.001, base["glassMedian"])
        comparisons.append({
            "label": report["label"],
            "baseline": baseline["label"],
            "bodyDetailLift": metrics["bodyDetailP95"] / body_base,
            "glassMedianLift": metrics["glassMedian"] / glass_base,
            "lumaMeanDelta": metrics["lumaMeanP95"] - base["lumaMeanP95"],
            "readinessDelta": report["readinessScore"] - baseline["readinessScore"],
        })
    return comparisons


def print_report(report: dict) -> None:
    metrics = report["metrics"]
    status = "PASS" if report["pass"] else "FAIL"
    print(
        f"{status} {report['label']}: readiness={report['readinessScore']:.1f} "
        f"smooth={report['smoothnessScore']:.1f} optics={report['opticsScore']:.1f}"
    )
    print(
        "  motion "
        f"echoMax={metrics['echoMax']:.2f} "
        f"untrackedLagP95={metrics['untrackedLagP95']:.2f}pt "
        f"drawAgeP95={metrics['drawAgeP95']:.2f}ms "
        f"freeze={int(metrics['freezeCount'])}"
    )
    print(
        "  optics "
        f"glassMed={metrics['glassMedian']:.1f} "
        f"bodyP95={metrics['bodyDetailP95']:.1f} "
        f"rimP95={metrics['rimContrastP95']:.1f} "
        f"chromaLiftP95={metrics['chromaLiftP95']:.1f} "
        f"edgeLiftP95={metrics['edgeLiftP95']:.1f} "
        f"rimChromaP95={metrics['rimChromaP95']:.1f} "
        f"diag={int(metrics['edgeDiagnostic'])} "
        f"lumaP95={metrics['lumaMeanP95']:.1f} "
        f"hotP95={metrics['lumaHotP95']:.1f}%"
    )
    if report["failed"]:
        print("  failed gates: " + ", ".join(report["failed"]))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", action="append", type=parse_summary, help="LABEL:PATH or PATH; can repeat")
    parser.add_argument("--run-root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--baseline", help="label to use as comparison baseline; defaults to first label containing 'native'")
    parser.add_argument("--out", type=Path, help="write JSON report")
    args = parser.parse_args()

    inputs = args.summary or [SummaryInput("latest", latest_summary(args.run_root))]
    reports = [summarize_summary(item) for item in inputs]
    comparisons = compare_to_baseline(reports, args.baseline)

    for report in reports:
        print_report(report)
    for comparison in comparisons:
        print(
            f"COMPARE {comparison['label']} vs {comparison['baseline']}: "
            f"bodyDetail x{comparison['bodyDetailLift']:.2f}, "
            f"glassMed x{comparison['glassMedianLift']:.2f}, "
            f"lumaDelta {comparison['lumaMeanDelta']:+.1f}, "
            f"readinessDelta {comparison['readinessDelta']:+.1f}"
        )

    payload = {"reports": reports, "comparisons": comparisons}
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(payload, indent=2) + "\n")
        print(f"quality_report: {args.out}")
    return 0 if all(report["pass"] for report in reports) else 2


if __name__ == "__main__":
    raise SystemExit(main())
