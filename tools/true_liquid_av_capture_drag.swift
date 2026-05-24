import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

final class VideoFrameStore: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let maxFrames: Int
    private let lock = NSLock()
    private(set) var frames: [(Int, UInt64, CVPixelBuffer)] = []
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    init(maxFrames: Int) {
        self.maxFrames = maxFrames
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        if frames.count < maxFrames {
            _ = CVPixelBufferRetain(pixelBuffer)
            frames.append((frames.count, DispatchTime.now().uptimeNanoseconds, pixelBuffer))
        }
        lock.unlock()
    }
}

let args = CommandLine.arguments
guard args.count == 12 || args.count == 14 || args.count == 15 else {
    fputs("usage: true_liquid_av_capture_drag.swift OUT_DIR FROM_X FROM_Y TO_X TO_Y FRAMES FPS CROP_X CROP_Y CROP_W CROP_H [STEPS STEP_MS [WAIT_SECONDS]]\n", stderr)
    fputs("   or: true_liquid_av_capture_drag.swift OUT_DIR auto OWNER_MATCH ANCHOR_X ANCHOR_Y DELTA_X DELTA_Y FRAMES FPS PAD_X PAD_Y [STEPS STEP_MS [WAIT_SECONDS]]\n", stderr)
    exit(2)
}

let outDir = args[1]
let autoMode = args[2] == "auto"

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
        if width >= 200 && height >= 60 {
            let rect = CGRect(x: x, y: y, width: width, height: height)
            if best == nil || score > best!.score {
                best = (score, rect)
            }
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

let fromX: Double
let fromY: Double
let toX: Double
let toY: Double
let frameCount: Int
let fps: Int
let requestedCrop: CGRect
let crop: CGRect
let targetWindow: CGRect?
let waitSeconds = args.count == 15 ? Double(args[14])! : 0.0

func rectPayload(_ rect: CGRect) -> [String: Double] {
    [
        "x": rect.origin.x,
        "y": rect.origin.y,
        "w": rect.width,
        "h": rect.height
    ]
}

func clampCropToMainDisplay(_ rect: CGRect) -> CGRect {
    let bounds = CGDisplayBounds(CGMainDisplayID())
    let minX = max(bounds.minX, min(rect.minX, bounds.maxX))
    let minY = max(bounds.minY, min(rect.minY, bounds.maxY))
    let maxX = max(minX + 1.0, min(rect.maxX, bounds.maxX))
    let maxY = max(minY + 1.0, min(rect.maxY, bounds.maxY))
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

func rectNearlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.origin.x - b.origin.x) < 0.5 &&
        abs(a.origin.y - b.origin.y) < 0.5 &&
        abs(a.width - b.width) < 0.5 &&
        abs(a.height - b.height) < 0.5
}

if autoMode {
    guard let window = waitForWindow(matching: args[3], timeoutSeconds: waitSeconds) else {
        fputs("could not find window matching \(args[3])\n", stderr)
        fputs("visible candidate windows:\n\(visibleWindowDescriptions())\n", stderr)
        exit(1)
    }
    let anchorX = Double(args[4])!
    let anchorY = Double(args[5])!
    let deltaX = Double(args[6])!
    let deltaY = Double(args[7])!
    frameCount = Int(args[8])!
    fps = Int(args[9])!
    let padX = Double(args[10])!
    let padY = Double(args[11])!
    fromX = window.origin.x + anchorX
    fromY = window.origin.y + anchorY
    toX = fromX + deltaX
    toY = fromY + deltaY
    let minX = min(window.origin.x, window.origin.x + deltaX)
    let maxX = max(window.maxX, window.maxX + deltaX)
    let minY = min(window.origin.y, window.origin.y + deltaY)
    let maxY = max(window.maxY, window.maxY + deltaY)
    requestedCrop = CGRect(x: max(0, minX - padX), y: max(0, minY - padY), width: maxX - minX + padX * 2, height: maxY - minY + padY * 2)
    crop = clampCropToMainDisplay(requestedCrop)
    targetWindow = window
} else {
    fromX = Double(args[2])!
    fromY = Double(args[3])!
    toX = Double(args[4])!
    toY = Double(args[5])!
    frameCount = Int(args[6])!
    fps = Int(args[7])!
    requestedCrop = CGRect(
        x: Double(args[8])!,
        y: Double(args[9])!,
        width: Double(args[10])!,
        height: Double(args[11])!
    )
    crop = clampCropToMainDisplay(requestedCrop)
    targetWindow = nil
}

if ProcessInfo.processInfo.environment["TRUE_LIQUID_DRY_TARGET"] == "1" {
    if let targetWindow {
        print("targetWindow x=\(targetWindow.origin.x) y=\(targetWindow.origin.y) w=\(targetWindow.width) h=\(targetWindow.height)")
    }
    print("drag from=\(fromX),\(fromY) to=\(toX),\(toY) crop=\(crop.origin.x),\(crop.origin.y),\(crop.width),\(crop.height)")
    if !rectNearlyEqual(requestedCrop, crop) {
        print("requestedCrop=\(requestedCrop.origin.x),\(requestedCrop.origin.y),\(requestedCrop.width),\(requestedCrop.height)")
    }
    exit(0)
}

let hasDragTuning = args.count == 14 || args.count == 15
let steps = hasDragTuning ? Int(args[12])! : 80
let stepMs = hasDragTuning ? Double(args[13])! : 8.0

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let outURL = URL(fileURLWithPath: outDir)
let stampURL = outURL.appendingPathComponent("timestamps.tsv")
FileManager.default.createFile(atPath: stampURL.path, contents: nil)
let stamp = try FileHandle(forWritingTo: stampURL)
defer { try? stamp.close() }

var metadata: [String: Any] = [
    "backend": "av",
    "crop": rectPayload(crop),
    "requestedCrop": rectPayload(requestedCrop),
    "displayBounds": rectPayload(CGDisplayBounds(CGMainDisplayID())),
    "cropClamped": !rectNearlyEqual(requestedCrop, crop),
    "drag": ["fromX": fromX, "fromY": fromY, "toX": toX, "toY": toY, "steps": steps, "stepMs": stepMs, "waitSeconds": waitSeconds],
    "frames": ["count": frameCount, "fps": fps, "intervalMs": 1000.0 / Double(max(1, fps))]
]
if let targetWindow {
    metadata["targetWindow"] = rectPayload(targetWindow)
}
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

func write(_ index: Int, _ acquiredNs: UInt64, _ pixelBuffer: CVPixelBuffer, _ context: CIContext) {
    let name = String(format: "frame_%03d.png", index)
    let url = outURL.appendingPathComponent(name)
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    guard let cgImage = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height)),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        writeStamp("\(index)\t\(acquiredNs)\twrite_failed")
        return
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    CGImageDestinationFinalize(destination)
    writeStamp("\(index)\t\(acquiredNs)\t\(name)")
}

let session = AVCaptureSession()
session.beginConfiguration()
guard let input = AVCaptureScreenInput(displayID: CGMainDisplayID()) else {
    fputs("failed to create AVCaptureScreenInput\n", stderr)
    exit(1)
}
input.cropRect = crop
input.minFrameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
input.capturesCursor = false
input.capturesMouseClicks = false
guard session.canAddInput(input) else {
    fputs("cannot add screen input\n", stderr)
    exit(1)
}
session.addInput(input)

let output = AVCaptureVideoDataOutput()
output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
output.alwaysDiscardsLateVideoFrames = false
let queue = DispatchQueue(label: "true-liquid-av-visual-capture")
let store = VideoFrameStore(maxFrames: frameCount)
output.setSampleBufferDelegate(store, queue: queue)
guard session.canAddOutput(output) else {
    fputs("cannot add video output\n", stderr)
    exit(1)
}
session.addOutput(output)
session.commitConfiguration()
session.startRunning()

usleep(150_000)
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

let timeoutMs = max(2000, Int(Double(frameCount) / Double(max(1, fps)) * 1000.0) + 3000)
let deadline = nowNs() + UInt64(timeoutMs) * 1_000_000
while store.count < frameCount && nowNs() < deadline {
    usleep(5_000)
}
session.stopRunning()

let context = CIContext()
for (index, acquiredNs, pixelBuffer) in store.frames {
    write(index, acquiredNs, pixelBuffer, context)
    CVPixelBufferRelease(pixelBuffer)
}
