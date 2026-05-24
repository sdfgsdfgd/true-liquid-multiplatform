import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 8 || args.count == 9 else {
    fputs("usage: true_liquid_drag_only.swift OUT_DIR FROM_X FROM_Y TO_X TO_Y STEPS STEP_MS [PRE_DELAY_MS]\n", stderr)
    exit(2)
}

let outDir = args[1]
let fromX = Double(args[2])!
let fromY = Double(args[3])!
let toX = Double(args[4])!
let toY = Double(args[5])!
let steps = Int(args[6])!
let stepMs = Double(args[7])!
let preDelayMs = args.count == 9 ? Double(args[8])! : 0.0

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let stampURL = URL(fileURLWithPath: outDir).appendingPathComponent("timestamps.tsv")
if !FileManager.default.fileExists(atPath: stampURL.path) {
    FileManager.default.createFile(atPath: stampURL.path, contents: nil)
}
let stamp = try FileHandle(forWritingTo: stampURL)
try stamp.seekToEnd()
defer { try? stamp.close() }

func nowNs() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

func writeStamp(_ text: String) {
    if let data = (text + "\n").data(using: .utf8) {
        try? stamp.write(contentsOf: data)
    }
}

let source = CGEventSource(stateID: .hidSystemState)

func post(_ type: CGEventType, _ x: Double, _ y: Double) {
    guard let event = CGEvent(
        mouseEventSource: source,
        mouseType: type,
        mouseCursorPosition: CGPoint(x: x, y: y),
        mouseButton: .left
    ) else { return }
    event.post(tap: .cghidEventTap)
}

if preDelayMs > 0 {
    usleep(UInt32(preDelayMs * 1000.0))
}
writeStamp("drag_start\t\(nowNs())\t\(fromX),\(fromY)->\(toX),\(toY)")
post(.mouseMoved, fromX, fromY)
usleep(30_000)
post(.leftMouseDown, fromX, fromY)
for step in 0...steps {
    let t = Double(step) / Double(steps)
    post(.leftMouseDragged, fromX + (toX - fromX) * t, fromY + (toY - fromY) * t)
    usleep(UInt32(stepMs * 1000.0))
}
post(.leftMouseUp, toX, toY)
writeStamp("drag_end\t\(nowNs())\t\(toX),\(toY)")
