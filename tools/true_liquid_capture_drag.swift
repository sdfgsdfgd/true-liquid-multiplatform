import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count == 12 || args.count == 14 else {
    fputs("usage: true_liquid_capture_drag.swift OUT_DIR FROM_X FROM_Y TO_X TO_Y FRAMES INTERVAL_MS CROP_X CROP_Y CROP_W CROP_H [STEPS STEP_MS]\n", stderr)
    exit(2)
}

let outDir = args[1]
let fromX = Double(args[2])!
let fromY = Double(args[3])!
let toX = Double(args[4])!
let toY = Double(args[5])!
let frameCount = Int(args[6])!
let intervalMs = Double(args[7])!
let intervalUs = UInt32(intervalMs * 1000.0)
let crop = CGRect(
    x: Double(args[8])!,
    y: Double(args[9])!,
    width: Double(args[10])!,
    height: Double(args[11])!
)
let steps = args.count == 14 ? Int(args[12])! : 80
let stepMs = args.count == 14 ? Double(args[13])! : 8.0
let stepUs = UInt32(stepMs * 1000.0)

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let outURL = URL(fileURLWithPath: outDir)
let stampURL = outURL.appendingPathComponent("timestamps.tsv")
FileManager.default.createFile(atPath: stampURL.path, contents: nil)
let stamp = try FileHandle(forWritingTo: stampURL)
defer { try? stamp.close() }

let metadata: [String: Any] = [
    "crop": ["x": crop.origin.x, "y": crop.origin.y, "w": crop.width, "h": crop.height],
    "drag": ["fromX": fromX, "fromY": fromY, "toX": toX, "toY": toY, "steps": steps, "stepMs": stepMs],
    "frames": ["count": frameCount, "intervalMs": intervalMs]
]
let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
try metadataData.write(to: outURL.appendingPathComponent("capture.json"))

func nowNs() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

func writeStamp(_ text: String) {
    if let data = (text + "\n").data(using: .utf8) {
        try? stamp.write(contentsOf: data)
    }
}

func write(_ index: Int, _ acquiredNs: UInt64, _ image: CGImage) {
    let name = String(format: "frame_%03d.png", index)
    let url = outURL.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        writeStamp("\(index)\t\(acquiredNs)\tdestination_failed")
        return
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    writeStamp("\(index)\t\(acquiredNs)\t\(name)")
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

let captureQueue = DispatchQueue(label: "true-liquid-capture")
let captureDone = DispatchSemaphore(value: 0)
let display = CGMainDisplayID()
var captured: [(Int, UInt64, CGImage)] = []

_ = CGDisplayCreateImage(display, rect: crop)

captureQueue.async {
    for index in 0..<frameCount {
        let acquiredNs = nowNs()
        if let image = CGDisplayCreateImage(display, rect: crop) {
            captured.append((index, acquiredNs, image))
        } else {
            writeStamp("\(index)\t\(acquiredNs)\tcapture_failed")
        }
        usleep(intervalUs)
    }
    captureDone.signal()
}

usleep(150_000)
writeStamp("drag_start\t\(nowNs())\t\(fromX),\(fromY)->\(toX),\(toY)")
post(.mouseMoved, fromX, fromY)
usleep(30_000)
post(.leftMouseDown, fromX, fromY)
for step in 0...steps {
    let t = Double(step) / Double(steps)
    post(.leftMouseDragged, fromX + (toX - fromX) * t, fromY + (toY - fromY) * t)
    usleep(stepUs)
}
post(.leftMouseUp, toX, toY)
writeStamp("drag_end\t\(nowNs())\t\(toX),\(toY)")

captureDone.wait()
for (index, acquiredNs, image) in captured {
    write(index, acquiredNs, image)
}
