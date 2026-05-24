import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 12 || args.count == 13 else {
    fputs("usage: true_liquid_circle_position_trace.swift OUT_DIR OWNER_MATCH CENTER_ANCHOR_X CENTER_ANCHOR_Y RADIUS_X RADIUS_Y CYCLES STEPS STEP_MS WAIT_SECONDS SAMPLE_HZ [PRE_DELAY_MS]\n", stderr)
    exit(2)
}

let outDir = args[1]
let ownerNeedle = args[2]
let centerAnchorX = Double(args[3])!
let centerAnchorY = Double(args[4])!
let radiusX = Double(args[5])!
let radiusY = Double(args[6])!
let cycles = Double(args[7])!
let steps = Int(args[8])!
let stepMs = Double(args[9])!
let waitSeconds = Double(args[10])!
let sampleHz = Double(args[11])!
let preDelayMs = args.count == 13 ? Double(args[12])! : 0.0

func nowNs() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

func windowScore(owner: String, name: String, matching rawNeedle: String) -> Int? {
    let lowered = rawNeedle.lowercased()
    let ownerLowered = owner.lowercased()
    let nameLowered = name.lowercased()
    if lowered.hasPrefix("owner=") {
        let needle = String(lowered.dropFirst("owner=".count))
        return ownerLowered == needle ? 100 : nil
    }
    if lowered.hasPrefix("name=") || lowered.hasPrefix("title=") {
        let needle = String(lowered.dropFirst(lowered.hasPrefix("name=") ? "name=".count : "title=".count))
        return nameLowered == needle ? 95 : nil
    }
    if ownerLowered == lowered { return 90 }
    if nameLowered == lowered { return 80 }
    if ownerLowered.contains(lowered) { return 60 }
    if lowered.count >= 4 && nameLowered.contains(lowered) { return 40 }
    return nil
}

func findWindow(matching needle: String) -> CGRect? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var best: (score: Int, rect: CGRect)?
    for window in windows {
        let owner = window[kCGWindowOwnerName as String] as? String ?? ""
        let name = window[kCGWindowName as String] as? String ?? ""
        let layer = window[kCGWindowLayer as String] as? Int ?? 0
        guard layer == 0 || layer == 3 else { continue }
        guard let score = windowScore(owner: owner, name: name, matching: needle) else { continue }
        guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? Double,
              let y = bounds["Y"] as? Double,
              let width = bounds["Width"] as? Double,
              let height = bounds["Height"] as? Double else { continue }
        guard width >= 200 && height >= 60 else { continue }
        let rect = CGRect(x: x, y: y, width: width, height: height)
        if best == nil || score > best!.score {
            best = (score, rect)
        }
    }
    return best?.rect
}

func visibleWindowDescriptions(limit: Int = 24) -> String {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var lines: [String] = []
    for window in windows {
        let owner = window[kCGWindowOwnerName as String] as? String ?? ""
        let name = window[kCGWindowName as String] as? String ?? ""
        let layer = window[kCGWindowLayer as String] as? Int ?? 0
        guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double,
              let height = bounds["Height"] as? Double else { continue }
        guard (layer == 0 || layer == 3) && width >= 120 && height >= 40 else { continue }
        lines.append("owner=\(owner) name=\(name) layer=\(layer) size=\(Int(width))x\(Int(height))")
        if lines.count >= limit { break }
    }
    return lines.joined(separator: "\n")
}

func waitForWindow(matching needle: String, timeoutSeconds: Double) -> CGRect? {
    let deadline = Date().addingTimeInterval(max(0.0, timeoutSeconds))
    repeat {
        if let window = findWindow(matching: needle) {
            return window
        }
        if timeoutSeconds <= 0 { return nil }
        usleep(120_000)
    } while Date() < deadline
    return findWindow(matching: needle)
}

func rectString(_ rect: CGRect) -> String {
    String(format: "%.3f,%.3f,%.3f,%.3f", rect.origin.x, rect.origin.y, rect.width, rect.height)
}

guard let initialWindow = waitForWindow(matching: ownerNeedle, timeoutSeconds: waitSeconds) else {
    fputs("could not find window matching \(ownerNeedle)\n", stderr)
    fputs("visible candidate windows:\n\(visibleWindowDescriptions())\n", stderr)
    exit(1)
}

let centerX = initialWindow.origin.x + centerAnchorX
let centerY = initialWindow.origin.y + centerAnchorY
let downX = centerX + radiusX
let downY = centerY

func pathPoint(step: Int) -> CGPoint {
    let t = Double(step) / Double(max(1, steps))
    let theta = t * cycles * 2.0 * Double.pi
    return CGPoint(x: centerX + radiusX * cos(theta), y: centerY + radiusY * sin(theta))
}

func expectedPanel(for cursor: CGPoint) -> CGRect {
    CGRect(
        x: initialWindow.origin.x + cursor.x - downX,
        y: initialWindow.origin.y + cursor.y - downY,
        width: initialWindow.width,
        height: initialWindow.height
    )
}

let lock = NSLock()
var actualSamples: [[String: Any]] = []
func appendActual(_ rect: CGRect) {
    lock.lock()
    actualSamples.append([
        "t": Double(nowNs()) / 1_000_000.0,
        "event": "actual-window",
        "panel": rectString(rect)
    ])
    lock.unlock()
}

let queue = DispatchQueue(label: "true-liquid-circle-position-sampler")
let timer = DispatchSource.makeTimerSource(queue: queue)
let intervalNs = UInt64(max(1.0, 1_000_000_000.0 / max(1.0, sampleHz)))
timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(intervalNs)), leeway: .milliseconds(1))
timer.setEventHandler {
    if let rect = findWindow(matching: ownerNeedle) {
        appendActual(rect)
    }
}
timer.resume()

let source = CGEventSource(stateID: .hidSystemState)
func post(_ type: CGEventType, _ x: Double, _ y: Double) {
    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left) else { return }
    event.post(tap: .cghidEventTap)
}

if preDelayMs > 0 {
    usleep(UInt32(preDelayMs * 1000.0))
}

var expectedEvents: [[String: Any]] = []
post(.mouseMoved, downX, downY)
usleep(30_000)
let dragStartNs = nowNs()
post(.leftMouseDown, downX, downY)
for step in 0...steps {
    let point = pathPoint(step: step)
    let stampNs = nowNs()
    post(.leftMouseDragged, Double(point.x), Double(point.y))
    let panel = expectedPanel(for: point)
    expectedEvents.append([
        "t": Double(stampNs) / 1_000_000.0,
        "event": "posted-circle",
        "panel": rectString(panel),
        "postedX": Double(point.x),
        "postedY": Double(point.y),
        "step": step
    ])
    usleep(UInt32(stepMs * 1000.0))
}
post(.leftMouseUp, downX, downY)
let dragEndNs = nowNs()
usleep(250_000)
timer.cancel()
usleep(50_000)

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let outURL = URL(fileURLWithPath: outDir)
func jsonLine(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

let metadata: [String: Any] = [
    "targetWindow": rectString(initialWindow),
    "down": "\(downX),\(downY)",
    "circle": ["centerAnchorX": centerAnchorX, "centerAnchorY": centerAnchorY, "radiusX": radiusX, "radiusY": radiusY, "cycles": cycles, "steps": steps, "stepMs": stepMs, "sampleHz": sampleHz],
    "dragStartMs": Double(dragStartNs) / 1_000_000.0,
    "dragEndMs": Double(dragEndNs) / 1_000_000.0
]
try jsonLine(metadata).write(to: outURL.appendingPathComponent("position_meta.json"), atomically: true, encoding: .utf8)
try (expectedEvents.map(jsonLine).joined(separator: "\n") + "\n").write(to: outURL.appendingPathComponent("expected_events.jsonl"), atomically: true, encoding: .utf8)
lock.lock()
let actual = actualSamples
lock.unlock()
try (actual.map(jsonLine).joined(separator: "\n") + "\n").write(to: outURL.appendingPathComponent("actual_window_events.jsonl"), atomically: true, encoding: .utf8)

print("position_trace=\(outDir)")
print("expected=\(expectedEvents.count)")
print("actual=\(actual.count)")
print("drag_ms=\(Double(dragEndNs - dragStartNs) / 1_000_000.0)")
