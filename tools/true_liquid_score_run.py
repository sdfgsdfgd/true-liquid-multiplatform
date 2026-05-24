#!/usr/bin/env python3
"""Run or rescore a True Liquid visual benchmark."""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
AV_CAPTURE = ROOT / "tools" / "true_liquid_av_capture_drag.swift"
SCK_CAPTURE = ROOT / "tools" / "true_liquid_sck_capture_drag.swift"
VIDEO_CAPTURE = ROOT / "tools" / "true_liquid_video_capture_drag.py"
PROBE = ROOT / "tools" / "true_liquid_visual_probe.py"
DRAG_ANOMALY = ROOT / "tools" / "true_liquid_drag_anomaly.py"
DEFAULT_PROBE_MS = "30,60,90,120,180,260,360"
CHILDREN: set[subprocess.Popen] = set()


def stage(message: str) -> None:
    print(f"[score-run {time.strftime('%H:%M:%S')}] {message}", flush=True)


def run(cmd: list[str], cwd: Path = ROOT) -> None:
    started = time.monotonic()
    print("+ " + " ".join(str(part) for part in cmd), flush=True)
    proc = track_process(subprocess.Popen(cmd, cwd=cwd, start_new_session=True))
    try:
        returncode = proc.wait()
    except BaseException:
        stage(f"child interrupted after {time.monotonic() - started:.1f}s; terminating pid={proc.pid}")
        terminate_process(proc, timeout=2)
        raise
    finally:
        CHILDREN.discard(proc)
    if returncode != 0:
        stage(f"child failed rc={returncode} elapsed={time.monotonic() - started:.1f}s")
        raise subprocess.CalledProcessError(returncode, cmd)
    stage(f"child done rc=0 elapsed={time.monotonic() - started:.1f}s")


def track_process(proc: subprocess.Popen) -> subprocess.Popen:
    CHILDREN.add(proc)
    return proc


def terminate_process(proc: subprocess.Popen | None, timeout: float = 8) -> None:
    if not proc:
        return
    if proc.poll() is None:
        stage(f"terminate process group pid={proc.pid}")
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except Exception:
            proc.terminate()
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            stage(f"kill process group pid={proc.pid}")
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except Exception:
                proc.kill()
            proc.wait(timeout=timeout)
    CHILDREN.discard(proc)


def cleanup_children(timeout: float = 2) -> None:
    for proc in list(CHILDREN):
        terminate_process(proc, timeout=timeout)


def install_signal_cleanup() -> None:
    def handler(signum: int, _frame: object) -> None:
        cleanup_children()
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGINT, handler)
    signal.signal(signal.SIGTERM, handler)


def latest_run_dir(base: Path) -> Path:
    base.mkdir(parents=True, exist_ok=True)
    existing = sorted(p for p in base.glob("run-*") if p.is_dir())
    next_id = 1
    if existing:
        next_id = max(int(p.name.split("-", 1)[1]) for p in existing if p.name.split("-", 1)[1].isdigit()) + 1
    return base / f"run-{next_id:03d}"


def probe(sequence: Path, events: Path, out_prefix: str, at_ms: float | None, burst: str | None, count: int, width: int) -> Path:
    stage(f"score probe start sequence={sequence.name} probe={out_prefix}")
    out_png = sequence / f"{out_prefix}.png"
    out_json = sequence / f"{out_prefix}.json"
    cmd = [
        sys.executable,
        str(PROBE),
        str(sequence),
        "--events",
        str(events),
        "--out",
        str(out_png),
        "--summary-out",
        str(out_json),
        "--frame-width",
        str(width),
    ]
    if burst:
        cmd += ["--burst", burst]
    else:
        cmd += ["--at-ms", str(at_ms), "--count", str(count)]
    run(cmd)
    stage(f"score probe done sequence={sequence.name} probe={out_prefix}")
    return out_json


def probe_all_metrics(sequence: Path, events: Path) -> Path:
    stage(f"all-frame metrics start sequence={sequence.name}")
    out_json = sequence / "score_all_frames.json"
    run([
        sys.executable,
        str(PROBE),
        str(sequence),
        "--events",
        str(events),
        "--summary-out",
        str(out_json),
        "--all-frames",
        "--metrics-only",
    ])
    stage(f"all-frame metrics done sequence={sequence.name}")
    return out_json


def drag_anomaly(sequence: Path, events: Path, args: argparse.Namespace) -> Path:
    stage(f"dragback anomaly start sequence={sequence.name}")
    out_json = sequence / "drag_anomaly_metrics.json"
    run([
        sys.executable,
        str(DRAG_ANOMALY),
        str(sequence),
        "--events",
        str(events),
        "--top",
        str(args.drag_anomaly_top),
        "--sheet-radius",
        str(args.drag_anomaly_radius),
        "--tile-width",
        str(args.drag_anomaly_tile_width),
    ])
    stage(f"dragback anomaly done sequence={sequence.name}")
    return out_json


def compact_json_summary(paths: list[Path], out: Path) -> dict:
    payload = {"sequence": str(paths[0].parent) if paths else "", "probes": []}
    for path in paths:
        data = json.loads(path.read_text())
        metrics = list(data.get("metrics", {}).values())
        echo = [m.get("staleEchoScore", 0.0) for m in metrics]
        raw_change = [m.get("rawChangeScore", 0.0) for m in metrics]
        geometry_lag = [m.get("geometryLagPt", 0.0) for m in metrics]
        tracked_lag = [m.get("geometryLagPt", 0.0) for m in metrics if m.get("visualTrackingOk")]
        untracked_lag = [m.get("geometryLagPt", 0.0) for m in metrics if m.get("geometryLagPt", 0.0) > 0 and not m.get("visualTrackingOk")]
        freeze = [m.get("freezeScore", 0.0) for m in metrics if m.get("freezeScore", 0.0) > 0]
        draw_age = [m.get("drawAgeMs") for m in metrics if isinstance(m.get("drawAgeMs"), (int, float)) and m.get("drawAgeMs", -1) >= 0]
        panel_rms = [m.get("panelDiff", {}).get("rms", 0.0) for m in metrics if m.get("panelDiff")]
        active_pct = [m.get("panelDiff", {}).get("activePct", 0.0) for m in metrics if m.get("panelDiff")]
        local_rms = [m.get("panelMotion", {}).get("localRms", 0.0) for m in metrics if m.get("panelMotion")]
        comp_rms = [m.get("panelMotion", {}).get("compRms", 0.0) for m in metrics if m.get("panelMotion")]
        stickiness = [m.get("panelMotion", {}).get("stickiness", 0.0) for m in metrics if m.get("panelMotion")]
        tracking = [m.get("panelMotion", {}).get("trackingAdvantage", 0.0) for m in metrics if m.get("panelMotion")]
        luma_mean = [m.get("luma", {}).get("mean", 0.0) for m in metrics if m.get("luma")]
        luma_hot = [m.get("luma", {}).get("hotPct", 0.0) for m in metrics if m.get("luma")]
        glass = [m.get("optics", {}).get("glassSignature", 0.0) for m in metrics if m.get("optics")]
        rim = [m.get("optics", {}).get("rimContrast", 0.0) for m in metrics if m.get("optics")]
        chroma = [m.get("optics", {}).get("chromaLift", 0.0) for m in metrics if m.get("optics")]
        edge = [m.get("optics", {}).get("edgeLift", 0.0) for m in metrics if m.get("optics")]
        rim_chroma = [m.get("optics", {}).get("rimChroma", 0.0) for m in metrics if m.get("optics")]
        rim_edge = [m.get("optics", {}).get("rimEdge", 0.0) for m in metrics if m.get("optics")]
        detail = [m.get("optics", {}).get("bodyDetail", 0.0) for m in metrics if m.get("optics")]
        edge_err = [abs(m.get("edgeErrPx")) for m in metrics if isinstance(m.get("edgeErrPx"), (int, float))]
        payload["probes"].append({
            "name": path.stem,
            "json": str(path),
            "png": str(path.with_suffix(".png")),
            "selected": data.get("selected", []),
            "summary": data.get("summary", []),
            "staleEchoScore": summarize(echo),
            "rawChangeScore": summarize(raw_change),
            "geometryLagPt": summarize(geometry_lag),
            "trackedGeometryLagPt": summarize(tracked_lag),
            "untrackedGeometryLagPt": summarize(untracked_lag),
            "freezeEvents": {"count": len(freeze), "max": max(freeze) if freeze else 0.0},
            "drawAgeMs": summarize(draw_age),
            "panelDiffRms": summarize(panel_rms),
            "activePct": summarize(active_pct),
            "motionLocalRms": summarize(local_rms),
            "motionCompRms": summarize(comp_rms),
            "motionStickiness": summarize(stickiness),
            "trackingAdvantage": summarize(tracking),
            "lumaMean": summarize(luma_mean),
            "lumaHotPct": summarize(luma_hot),
            "glassSignature": summarize(glass),
            "rimContrast": summarize(rim),
            "chromaLift": summarize(chroma),
            "edgeLift": summarize(edge),
            "rimChroma": summarize(rim_chroma),
            "rimEdge": summarize(rim_edge),
            "bodyDetail": summarize(detail),
            "edgeErrPxAbs": summarize(edge_err),
        })
    out.write_text(json.dumps(payload, indent=2) + "\n")
    print(f"score_summary: {out}")
    for probe_data in payload["probes"]:
        echo = probe_data["staleEchoScore"]
        raw = probe_data["rawChangeScore"]
        lag = probe_data["geometryLagPt"]
        untracked_lag = probe_data["untrackedGeometryLagPt"]
        stick = probe_data["motionStickiness"]
        comp = probe_data["motionCompRms"]
        freeze = probe_data["freezeEvents"]
        luma = probe_data["lumaMean"]
        hot = probe_data["lumaHotPct"]
        glass = probe_data["glassSignature"]
        rim = probe_data["rimContrast"]
        chroma = probe_data["chromaLift"]
        rim_chroma = probe_data["rimChroma"]
        rim_edge = probe_data["rimEdge"]
        print(
            f"{probe_data['name']}: echo med/p95/max "
            f"{echo['median']:.2f}/{echo['p95']:.2f}/{echo['max']:.2f}; "
            f"lag p95/max {lag['p95']:.2f}/{lag['max']:.2f}; "
            f"untracked lag p95/max {untracked_lag['p95']:.2f}/{untracked_lag['max']:.2f}; "
            f"stick p95 {stick['p95']:.2f}; comp p95 {comp['p95']:.2f}; raw p95 {raw['p95']:.2f}; "
            f"freeze count/max {freeze['count']}/{freeze['max']:.2f}; "
            f"luma med/p95 {luma['median']:.1f}/{luma['p95']:.1f}; hot p95 {hot['p95']:.1f}%; "
            f"glass med/p95 {glass['median']:.1f}/{glass['p95']:.1f}; "
            f"rim/chroma p95 {rim['p95']:.1f}/{chroma['p95']:.1f}; "
            f"rimAbs chroma/edge p95 {rim_chroma['p95']:.1f}/{rim_edge['p95']:.1f}"
        )
    return payload


def summarize(values: list[float]) -> dict[str, float]:
    if not values:
        return {"min": 0.0, "median": 0.0, "p95": 0.0, "max": 0.0}
    ordered = sorted(values)
    return {
        "min": ordered[0],
        "median": ordered[len(ordered) // 2],
        "p95": ordered[min(len(ordered) - 1, round((len(ordered) - 1) * 0.95))],
        "max": ordered[-1],
    }


def parse_probe_ms(value: str) -> list[float]:
    probes = []
    for raw in value.split(","):
        raw = raw.strip()
        if raw:
            probes.append(float(raw))
    return probes


def probe_label(ms: float) -> str:
    return f"score_drag{ms:05.1f}".replace(".", "p")


def parse_delta_list(value: str) -> list[tuple[float, float]]:
    deltas = []
    for raw in value.replace(";", ":").split(":"):
        raw = raw.strip()
        if not raw:
            continue
        x, y = raw.split(",", 1)
        deltas.append((float(x), float(y)))
    return deltas


def delta_label(delta: tuple[float, float]) -> str:
    dx, dy = delta
    x = "L" if dx < 0 else "R" if dx > 0 else "X"
    y = "U" if dy < 0 else "D" if dy > 0 else "Y"
    return f"{x}{abs(dx):.0f}-{y}{abs(dy):.0f}".lower()


def outlier_score(metric: dict) -> float:
    draw_age = metric.get("drawAgeMs", 0.0)
    if not isinstance(draw_age, (int, float)) or draw_age < 0:
        draw_age = 0.0
    panel_diff = metric.get("panelDiff", {})
    geometry_lag = 0.0 if metric.get("visualTrackingOk") else metric.get("geometryLagPt", 0.0)
    return (
        geometry_lag * 3.0
        + metric.get("staleEchoScore", 0.0) * 1.2
        + metric.get("rawChangeScore", 0.0) * 0.7
        + metric.get("freezeScore", 0.0) * 0.7
        + panel_diff.get("edgeMean", 0.0) * 0.35
        + max(0.0, draw_age - 18.0) * 0.3
    )


def outlier_bursts(metrics_path: Path, limit: int, count: int) -> list[tuple[int, int, float]]:
    data = json.loads(metrics_path.read_text())
    metrics = [(int(i), m) for i, m in data.get("metrics", {}).items()]
    if not metrics or limit <= 0:
        return []
    max_i = max(i for i, _ in metrics)
    scored = sorted(((outlier_score(m), i) for i, m in metrics), reverse=True)
    chosen: list[tuple[int, int, float]] = []
    used: list[int] = []
    for score, frame_i in scored:
        if score < 4.0:
            break
        if any(abs(frame_i - prev) < count for prev in used):
            continue
        start = max(0, min(frame_i - 1, max_i - count + 1))
        chosen.append((start, frame_i, score))
        used.append(frame_i)
        if len(chosen) >= limit:
            break
    return chosen


def capture(sequence: Path, args: argparse.Namespace, delta: tuple[float, float]) -> None:
    stage(f"capture start backend={args.capture_backend} sequence={sequence.name} delta={delta[0]:.0f},{delta[1]:.0f}")
    anchor_x, anchor_y = args.anchor.split(",", 1)
    pad_x, pad_y = args.pad.split(",", 1)
    window_wait = args.window_wait if args.window_wait > 0 else (90.0 if args.launch_app else 0.0)
    owner_match = args.owner if "=" in args.owner else f"owner={args.owner}"
    if args.capture_backend == "video":
        cmd = [
            sys.executable,
            str(VIDEO_CAPTURE),
            str(sequence),
            owner_match,
            anchor_x,
            anchor_y,
            str(delta[0]),
            str(delta[1]),
            str(args.frames),
            str(args.fps),
            pad_x,
            pad_y,
            str(args.steps),
            str(args.step_ms),
            str(window_wait),
            "--pre-delay-ms",
            str(args.video_pre_delay_ms),
            "--post-delay-ms",
            str(args.video_post_delay_ms),
        ]
        run(cmd)
        stage(f"capture done sequence={sequence.name}")
        return
    capture_tool = SCK_CAPTURE if args.capture_backend == "sck" else AV_CAPTURE
    cmd = [
        "swift",
        "-Xfrontend",
        "-disable-availability-checking",
        str(capture_tool),
        str(sequence),
        "auto",
        owner_match,
        anchor_x,
        anchor_y,
        str(delta[0]),
        str(delta[1]),
        str(args.frames),
        str(args.fps),
        pad_x,
        pad_y,
        str(args.steps),
        str(args.step_ms),
        str(window_wait),
    ]
    run(["env", "TRUE_LIQUID_DRY_TARGET=1", *cmd])
    run(cmd)
    stage(f"capture done sequence={sequence.name}")


def score_sequence(sequence: Path, events: Path, args: argparse.Namespace) -> dict:
    started = time.monotonic()
    stage(f"offline scoring start sequence={sequence.name}")
    generated = [probe(sequence, events, "score_predrag", None, f"0:{args.predrag_count}", args.predrag_count, args.probe_width)]
    for ms in parse_probe_ms(args.probe_ms):
        generated.append(probe(sequence, events, probe_label(ms), ms, None, args.probe_count, args.probe_width))
    if args.outlier_probes > 0:
        metrics_path = probe_all_metrics(sequence, events)
        generated.append(metrics_path)
        for i, (start, frame_i, score) in enumerate(outlier_bursts(metrics_path, args.outlier_probes, args.outlier_count), 1):
            label = f"score_outlier{i:02d}_f{frame_i:03d}_s{score:.0f}"
            generated.append(probe(sequence, events, label, None, f"{start}:{args.outlier_count}", args.outlier_count, args.probe_width))
    if args.drag_anomalies:
        drag_anomaly(sequence, events, args)
    summary = compact_json_summary(generated, sequence / "score_summary.json")
    stage(f"offline scoring done sequence={sequence.name} elapsed={time.monotonic() - started:.1f}s")
    return summary


def launch_app(events: Path, run_dir: Path, args: argparse.Namespace) -> tuple[subprocess.Popen, object]:
    log = (run_dir / "app.log").open("w")
    cmd = [
        "gradle",
        "--no-daemon",
        "-DtrueLiquid.instrument=true",
        f"-DtrueLiquid.instrument.path={events}",
        f"-DtrueLiquid.instrument.captureWindow={str(not args.hide_app_from_capture).lower()}",
        f"-DtrueLiquid.defaultExpanded={str(args.default_expanded).lower()}",
        f"-DtrueLiquid.edgeDiagnostic={str(args.edge_diagnostic).lower()}",
    ]
    if args.title:
        cmd.append(f"-DtrueLiquid.title={args.title}")
    if args.preset:
        cmd.append(f"-DtrueLiquid.preset={args.preset}")
    cmd.append(args.app_task)
    stage(f"app launch title={args.title or '(default)'} log={log.name}")
    print("+ " + " ".join(cmd), flush=True)
    proc = track_process(subprocess.Popen(cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True))
    return proc, log


def stop_app(proc: subprocess.Popen | None, log: object | None) -> None:
    stage("app stop start")
    terminate_process(proc)
    if log:
        log.close()
    stage("app stop done")


def wait_for_event(path: Path, event_name: str, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists():
            for raw in path.read_text(errors="replace").splitlines():
                if f'"event":"{event_name}"' in raw:
                    return True
        time.sleep(0.12)
    return False


def wait_for_text(path: Path, needle: str, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists() and needle in path.read_text(errors="replace"):
            return True
        time.sleep(0.20)
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sequence", type=Path, help="existing capture sequence to rescore")
    parser.add_argument("--events", type=Path, help="events.jsonl for an existing capture")
    parser.add_argument("--run-root", type=Path, default=Path("/tmp/true-liquid-zenit1-instrument/score-runs"))
    parser.add_argument("--owner", default="name=True Liquid Compose")
    parser.add_argument("--anchor", default="55,55")
    parser.add_argument("--delta", default="-300,0")
    parser.add_argument("--deltas", help="colon-separated drag deltas, for example '-300,0:300,0:0,-220:0,220'")
    parser.add_argument("--capture-backend", choices=["av", "sck", "video"], default="av")
    parser.add_argument("--video-pre-delay-ms", type=float, default=900.0)
    parser.add_argument("--video-post-delay-ms", type=float, default=900.0)
    parser.add_argument("--frames", type=int, default=120)
    parser.add_argument("--fps", type=int, default=60)
    parser.add_argument("--pad", default="120,15")
    parser.add_argument("--steps", type=int, default=60)
    parser.add_argument("--step-ms", type=float, default=6.0)
    parser.add_argument("--probe-width", type=int, default=1500)
    parser.add_argument("--probe-ms", default=DEFAULT_PROBE_MS, help="comma-separated drag offsets in ms")
    parser.add_argument("--probe-count", type=int, default=5)
    parser.add_argument("--predrag-count", type=int, default=7)
    parser.add_argument("--outlier-probes", type=int, default=0, help="extra burst sheets around highest-scoring raw-frame anomalies")
    parser.add_argument("--outlier-count", type=int, default=5)
    parser.add_argument("--drag-anomalies", action="store_true", help="score per-frame backdrop dragback and write anomaly sheets")
    parser.add_argument("--drag-anomaly-top", type=int, default=5)
    parser.add_argument("--drag-anomaly-radius", type=int, default=3)
    parser.add_argument("--drag-anomaly-tile-width", type=int, default=330)
    parser.add_argument("--launch-app", action="store_true")
    parser.add_argument("--app-task", default=":demo:run")
    parser.add_argument("--app-wait", type=float, default=7.0)
    parser.add_argument("--run-task-wait", type=float, default=90.0)
    parser.add_argument("--window-wait", type=float, default=0.0)
    parser.add_argument("--native-wait", type=float, default=45.0)
    parser.add_argument("--allow-missing-native", action="store_true")
    parser.add_argument("--keep-app", action="store_true")
    parser.add_argument("--hide-app-from-capture", action="store_true", help="hide the app from external validation screenshots")
    parser.add_argument("--edge-diagnostic", action="store_true", help="false-color and boost the native edge refraction field")
    parser.add_argument("--default-expanded", action="store_true")
    parser.add_argument("--preset", default="", help="demo preset: spotlight, clear, prism, native")
    parser.add_argument("--title", default="", help="window title for launched demo; defaults to a unique score-run title")
    parser.add_argument("--skip-capture", action="store_true")
    args = parser.parse_args()

    app_proc = None
    app_log = None
    if args.sequence:
        if not args.events:
            raise SystemExit("--events is required with --sequence")
        sequence = args.sequence
        events = args.events
        run_dir = sequence
        sequences = [sequence]
    else:
        run_dir = latest_run_dir(args.run_root)
        events = run_dir / "events.jsonl"
        run_dir.mkdir(parents=True, exist_ok=True)
        stage(f"run-dir {run_dir}")
        deltas = parse_delta_list(args.deltas or args.delta)
        if args.launch_app and not args.title:
            args.title = f"True Liquid Compose {run_dir.name}"
        if args.launch_app and args.owner == parser.get_default("owner") and args.title:
            args.owner = f"name={args.title}"
        if args.launch_app:
            app_proc, app_log = launch_app(events, run_dir, args)
            time.sleep(args.app_wait)
            app_log_path = run_dir / "app.log"
            task_marker = f"> Task {args.app_task}" if args.app_task.startswith(":") else f"> Task :{args.app_task}"
            if not wait_for_text(app_log_path, task_marker, args.run_task_wait):
                if not args.keep_app:
                    stop_app(app_proc, app_log)
                raise SystemExit(f"Gradle did not reach {args.app_task} within {args.run_task_wait:.1f}s: {app_log_path}")
            if not args.allow_missing_native and not wait_for_event(events, "stream-start", args.native_wait):
                if not args.keep_app:
                    stop_app(app_proc, app_log)
                raise SystemExit(f"native instrumentation did not reach stream-start within {args.native_wait:.1f}s: {events}")
            stage("app ready; native stream-start observed")
        sequences = []
        try:
            for i, delta in enumerate(deltas, 1):
                sequence = run_dir / "frames" / ("av-auto" if len(deltas) == 1 else f"av-auto-{i:02d}-{delta_label(delta)}")
                if not args.skip_capture:
                    capture(sequence, args, delta)
                sequences.append(sequence)
        finally:
            if args.launch_app and not args.keep_app:
                stop_app(app_proc, app_log)

    if not events.exists():
        print(f"warning: {events} does not exist; native metrics will be absent")
        events.write_text("")

    suite = []
    stage(f"offline scoring phase start sequences={len(sequences)}")
    for sequence in sequences:
        suite.append(score_sequence(sequence, events, args))
    stage("offline scoring phase done")
    if len(suite) > 1:
        suite_path = run_dir / "suite_summary.json"
        suite_path.write_text(json.dumps({"runDir": str(run_dir), "events": str(events), "sequences": suite}, indent=2) + "\n")
        print(f"suite_summary: {suite_path}")
    print(f"run_dir: {run_dir}")
    return 0


if __name__ == "__main__":
    install_signal_cleanup()
    try:
        raise SystemExit(main())
    finally:
        if CHILDREN:
            stage(f"final cleanup children={len(CHILDREN)}")
        cleanup_children()
