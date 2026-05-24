import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 13 || args.count == 14 else {
    fputs("usage: true_liquid_circle_drag_only.swift OUT_DIR OWNER_MATCH CENTER_ANCHOR_X CENTER_ANCHOR_Y RADIUS_X RADIUS_Y CYCLES PAD_X PAD_Y STEPS STEP_MS WAIT_SECONDS [PRE_DELAY_MS]\n", stderr)
    exit(2)
}

let outDir = args[1]
let ownerNeedle = args[2]
let centerAnchorX = Double(args[3])!
let centerAnchorY = Double(args[4])!
let radiusX = Double(args[5])!
let radiusY = Double(args[6])!
let cycles = Double(args[7])!
let padX = Double(args[8])!
let padY = Double(args[9])!
let steps = Int(args[10])!
let stepMs = Double(args[11])!
let waitSeconds = Double(args[12])!
let preDelayMs = args.count == 14 ? Double(args[13])! : 0.0
let dry = ProcessInfo.processInfo.environment["TRUE_LIQUID_DRY_TARGET"] == "1"

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
        if timeoutSeconds <= 0 {
            return nil
        }
        usleep(120_000)
    } while Date() < deadline
    return findWindow(matching: needle)
}

func rectPayload(_ rect: CGRect) -> [String: Double] {
    ["x": rect.origin.x, "y": rect.origin.y, "w": rect.width, "h": rect.height]
}

func rectString(_ rect: CGRect) -> String {
    String(format: "%.3f,%.3f,%.3f,%.3f", rect.origin.x, rect.origin.y, rect.width, rect.height)
}

func clampCropToMainDisplay(_ rect: CGRect) -> CGRect {
    let bounds = CGDisplayBounds(CGMainDisplayID())
    let minX = max(bounds.minX, min(rect.minX, bounds.maxX))
    let minY = max(bounds.minY, min(rect.minY, bounds.maxY))
    let maxX = max(minX + 1.0, min(rect.maxX, bounds.maxX))
    let maxY = max(minY + 1.0, min(rect.maxY, bounds.maxY))
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

guard let targetWindow = waitForWindow(matching: ownerNeedle, timeoutSeconds: waitSeconds) else {
    fputs("could not find window matching \(ownerNeedle)\n", stderr)
    fputs("visible candidate windows:\n\(visibleWindowDescriptions())\n", stderr)
    exit(1)
}

let centerX = targetWindow.origin.x + centerAnchorX
let centerY = targetWindow.origin.y + centerAnchorY
let downX = centerX + radiusX
let downY = centerY
let minPanelX = targetWindow.origin.x - 2.0 * radiusX
let maxPanelX = targetWindow.maxX
let minPanelY = targetWindow.origin.y - radiusY
let maxPanelY = targetWindow.maxY + radiusY
let requestedCrop = CGRect(
    x: max(0.0, minPanelX - padX),
    y: max(0.0, minPanelY - padY),
    width: maxPanelX - minPanelX + padX * 2.0,
    height: maxPanelY - minPanelY + padY * 2.0
)
let crop = clampCropToMainDisplay(requestedCrop)

func pathPoint(step: Int) -> CGPoint {
    let t = Double(step) / Double(max(1, steps))
    let theta = t * cycles * 2.0 * Double.pi
    return CGPoint(x: centerX + radiusX * cos(theta), y: centerY + radiusY * sin(theta))
}

func expectedPanel(for cursor: CGPoint) -> CGRect {
    CGRect(
        x: targetWindow.origin.x + cursor.x - downX,
        y: targetWindow.origin.y + cursor.y - downY,
        width: targetWindow.width,
        height: targetWindow.height
    )
}

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let outURL = URL(fileURLWithPath: outDir)
let metadata: [String: Any] = [
    "backend": "video-circle",
    "crop": rectPayload(crop),
    "requestedCrop": rectPayload(requestedCrop),
    "displayBounds": rectPayload(CGDisplayBounds(CGMainDisplayID())),
    "cropClamped": !(abs(requestedCrop.origin.x - crop.origin.x) < 0.5 && abs(requestedCrop.origin.y - crop.origin.y) < 0.5 && abs(requestedCrop.width - crop.width) < 0.5 && abs(requestedCrop.height - crop.height) < 0.5),
    "targetWindow": rectPayload(targetWindow),
    "circle": ["centerAnchorX": centerAnchorX, "centerAnchorY": centerAnchorY, "radiusX": radiusX, "radiusY": radiusY, "cycles": cycles, "steps": steps, "stepMs": stepMs, "waitSeconds": waitSeconds, "downX": downX, "downY": downY],
    "drag": ["fromX": downX, "fromY": downY, "toX": downX, "toY": downY, "steps": steps, "stepMs": stepMs, "waitSeconds": waitSeconds]
]
let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
try metadataData.write(to: outURL.appendingPathComponent("capture.json"))

print("targetWindow=\(rectString(targetWindow))")
print("crop=\(rectString(crop))")
print("requestedCrop=\(rectString(requestedCrop))")
print("down=\(String(format: "%.3f,%.3f", downX, downY))")
if dry { exit(0) }

let source = CGEventSource(stateID: .hidSystemState)
func post(_ type: CGEventType, _ x: Double, _ y: Double) {
    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left) else { return }
    event.post(tap: .cghidEventTap)
}

if preDelayMs > 0 {
    usleep(UInt32(preDelayMs * 1000.0))
}

var eventLines: [String] = []
post(.mouseMoved, downX, downY)
usleep(30_000)
let dragStartNs = nowNs()
post(.leftMouseDown, downX, downY)
for step in 0...steps {
    let point = pathPoint(step: step)
    let stampNs = nowNs()
    post(.leftMouseDragged, Double(point.x), Double(point.y))
    let panel = expectedPanel(for: point)
    let event: [String: Any] = [
        "t": Double(stampNs) / 1_000_000.0,
        "event": "slide",
        "source": "posted-circle",
        "panel": rectString(panel),
        "capture": rectString(crop),
        "postedX": Double(point.x),
        "postedY": Double(point.y),
        "step": step
    ]
    let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
    eventLines.append(String(data: data, encoding: .utf8)!)
    usleep(UInt32(stepMs * 1000.0))
}
post(.leftMouseUp, downX, downY)
let dragEndNs = nowNs()

let timestampLines = [
    "drag_start\t\(dragStartNs)\t\(downX),\(downY)->circle",
    "drag_end\t\(dragEndNs)\t\(downX),\(downY)"
]
try (timestampLines.joined(separator: "\n") + "\n").write(to: outURL.appendingPathComponent("timestamps.tsv"), atomically: true, encoding: .utf8)
try (eventLines.joined(separator: "\n") + "\n").write(to: outURL.appendingPathComponent("expected_events.jsonl"), atomically: true, encoding: .utf8)
