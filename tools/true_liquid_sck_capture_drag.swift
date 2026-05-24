import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ScreenCaptureKit

final class FrameStore: NSObject, SCStreamOutput, @unchecked Sendable {
    let maxFrames: Int
    let done = DispatchSemaphore(value: 0)
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

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lock.lock()
        if frames.count < maxFrames {
            _ = CVPixelBufferRetain(pixelBuffer)
            frames.append((frames.count, DispatchTime.now().uptimeNanoseconds, pixelBuffer))
            if frames.count == maxFrames {
                done.signal()
            }
        }
        lock.unlock()
    }
}

struct CaptureArgs {
    let outDir: String
    let fromX: Double
    let fromY: Double
    let toX: Double
    let toY: Double
    let frameCount: Int
    let fps: Int
    let requestedCrop: CGRect
    let crop: CGRect
    let steps: Int
    let stepMs: Double
    let waitSeconds: Double
    let targetWindow: CGRect?
}

enum TrueLiquidSckCaptureDrag {
    static func rectPayload(_ rect: CGRect) -> [String: Double] {
        [
            "x": rect.origin.x,
            "y": rect.origin.y,
            "w": rect.width,
            "h": rect.height
        ]
    }

    static func rectNearlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 0.5 &&
            abs(a.origin.y - b.origin.y) < 0.5 &&
            abs(a.width - b.width) < 0.5 &&
            abs(a.height - b.height) < 0.5
    }

    static func clampCropToMainDisplay(_ rect: CGRect) -> CGRect {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let minX = max(bounds.minX, min(rect.minX, bounds.maxX))
        let minY = max(bounds.minY, min(rect.minY, bounds.maxY))
        let maxX = max(minX + 1.0, min(rect.maxX, bounds.maxX))
        let maxY = max(minY + 1.0, min(rect.maxY, bounds.maxY))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func windowScore(owner: String, name: String, matching rawNeedle: String) -> Int? {
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

    static func findWindow(matching needle: String) -> CGRect? {
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

    static func visibleWindowDescriptions(limit: Int = 24) -> String {
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

    static func waitForWindow(matching needle: String, timeoutSeconds: Double) -> CGRect? {
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

    static func run() async throws {
        let args = try parseArgs()
        try FileManager.default.createDirectory(atPath: args.outDir, withIntermediateDirectories: true)
        let outURL = URL(fileURLWithPath: args.outDir)
        let stampURL = outURL.appendingPathComponent("timestamps.tsv")
        FileManager.default.createFile(atPath: stampURL.path, contents: nil)
        let stamp = try FileHandle(forWritingTo: stampURL)
        defer { try? stamp.close() }

        var metadata: [String: Any] = [
            "backend": "sck",
            "crop": rectPayload(args.crop),
            "requestedCrop": rectPayload(args.requestedCrop),
            "displayBounds": rectPayload(CGDisplayBounds(CGMainDisplayID())),
            "cropClamped": !rectNearlyEqual(args.requestedCrop, args.crop),
            "drag": ["fromX": args.fromX, "fromY": args.fromY, "toX": args.toX, "toY": args.toY, "steps": args.steps, "stepMs": args.stepMs, "waitSeconds": args.waitSeconds],
            "frames": ["count": args.frameCount, "fps": args.fps, "intervalMs": 1000.0 / Double(max(1, args.fps))]
        ]
        if let targetWindow = args.targetWindow {
            metadata["targetWindow"] = rectPayload(targetWindow)
        }
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try metadataData.write(to: outURL.appendingPathComponent("capture.json"))

        func writeStamp(_ text: String) {
            if let data = (text + "\n").data(using: .utf8) {
                try? stamp.write(contentsOf: data)
            }
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw NSError(domain: "TrueLiquidSckCaptureDrag", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display found"])
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let config = SCStreamConfiguration()
        config.sourceRect = args.crop
        config.width = max(16, Int(ceil(args.crop.width * scale)))
        config.height = max(16, Int(ceil(args.crop.height * scale)))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, args.fps)))
        config.queueDepth = 8
        config.showsCursor = false
        config.scalesToFit = true
        if #available(macOS 14.0, *) {
            config.preservesAspectRatio = false
            config.shouldBeOpaque = false
            config.ignoreShadowsDisplay = true
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let store = FrameStore(maxFrames: args.frameCount)
        let queue = DispatchQueue(label: "true-liquid-sck-visual-capture")
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(store, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()

        let dragDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            usleep(150_000)
            writeStamp("drag_start\t\(DispatchTime.now().uptimeNanoseconds)\t\(args.fromX),\(args.fromY)->\(args.toX),\(args.toY)")
            post(.mouseMoved, args.fromX, args.fromY)
            usleep(30_000)
            post(.leftMouseDown, args.fromX, args.fromY)
            for step in 0...args.steps {
                let t = Double(step) / Double(args.steps)
                post(.leftMouseDragged, args.fromX + (args.toX - args.fromX) * t, args.fromY + (args.toY - args.fromY) * t)
                usleep(UInt32(args.stepMs * 1000.0))
            }
            post(.leftMouseUp, args.toX, args.toY)
            writeStamp("drag_end\t\(DispatchTime.now().uptimeNanoseconds)\t\(args.toX),\(args.toY)")
            dragDone.signal()
        }

        let timeoutMs = max(2000, Int(Double(args.frameCount) / Double(max(1, args.fps)) * 1000.0) + 3000)
        let deadlineNs = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000
        while store.count < args.frameCount && DispatchTime.now().uptimeNanoseconds < deadlineNs {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        _ = dragDone.wait(timeout: .now() + .seconds(2))
        try await stream.stopCapture()

        let context = CIContext()
        for (index, acquiredNs, pixelBuffer) in store.frames {
            write(index, acquiredNs, pixelBuffer, outURL, stamp, context)
            CVPixelBufferRelease(pixelBuffer)
        }
    }

    static func parseArgs() throws -> CaptureArgs {
        let args = CommandLine.arguments
        guard args.count == 12 || args.count == 14 || args.count == 15 else {
            fputs("usage: true_liquid_sck_capture_drag.swift OUT_DIR FROM_X FROM_Y TO_X TO_Y FRAMES FPS CROP_X CROP_Y CROP_W CROP_H [STEPS STEP_MS]\n", stderr)
            fputs("   or: true_liquid_sck_capture_drag.swift OUT_DIR auto OWNER_MATCH ANCHOR_X ANCHOR_Y DELTA_X DELTA_Y FRAMES FPS PAD_X PAD_Y [STEPS STEP_MS [WAIT_SECONDS]]\n", stderr)
            exit(2)
        }
        if args[2] == "auto" {
            guard let window = waitForWindow(matching: args[3], timeoutSeconds: args.count == 15 ? Double(args[14])! : 0.0) else {
                fputs("could not find window matching \(args[3])\n", stderr)
                fputs("visible candidate windows:\n\(visibleWindowDescriptions())\n", stderr)
                exit(1)
            }
            let anchorX = Double(args[4])!
            let anchorY = Double(args[5])!
            let deltaX = Double(args[6])!
            let deltaY = Double(args[7])!
            let padX = Double(args[10])!
            let padY = Double(args[11])!
            let fromX = window.origin.x + anchorX
            let fromY = window.origin.y + anchorY
            let toX = fromX + deltaX
            let toY = fromY + deltaY
            let minX = min(window.origin.x, window.origin.x + deltaX)
            let maxX = max(window.maxX, window.maxX + deltaX)
            let minY = min(window.origin.y, window.origin.y + deltaY)
            let maxY = max(window.maxY, window.maxY + deltaY)
            let requestedCrop = CGRect(x: max(0, minX - padX), y: max(0, minY - padY), width: maxX - minX + padX * 2, height: maxY - minY + padY * 2)
            let crop = clampCropToMainDisplay(requestedCrop)
            if ProcessInfo.processInfo.environment["TRUE_LIQUID_DRY_TARGET"] == "1" {
                print("targetWindow x=\(window.origin.x) y=\(window.origin.y) w=\(window.width) h=\(window.height)")
                print("drag from=\(fromX),\(fromY) to=\(toX),\(toY) crop=\(crop.origin.x),\(crop.origin.y),\(crop.width),\(crop.height)")
                if !rectNearlyEqual(requestedCrop, crop) {
                    print("requestedCrop=\(requestedCrop.origin.x),\(requestedCrop.origin.y),\(requestedCrop.width),\(requestedCrop.height)")
                }
                exit(0)
            }
            return CaptureArgs(
                outDir: args[1],
                fromX: fromX,
                fromY: fromY,
                toX: toX,
                toY: toY,
                frameCount: Int(args[8])!,
                fps: Int(args[9])!,
                requestedCrop: requestedCrop,
                crop: crop,
                steps: args.count >= 14 ? Int(args[12])! : 80,
                stepMs: args.count >= 14 ? Double(args[13])! : 8.0,
                waitSeconds: args.count == 15 ? Double(args[14])! : 0.0,
                targetWindow: window
            )
        } else {
            let requestedCrop = CGRect(
                x: Double(args[8])!,
                y: Double(args[9])!,
                width: Double(args[10])!,
                height: Double(args[11])!
            )
            let crop = clampCropToMainDisplay(requestedCrop)
            if ProcessInfo.processInfo.environment["TRUE_LIQUID_DRY_TARGET"] == "1" {
                print("drag from=\(args[2]),\(args[3]) to=\(args[4]),\(args[5]) crop=\(crop.origin.x),\(crop.origin.y),\(crop.width),\(crop.height)")
                if !rectNearlyEqual(requestedCrop, crop) {
                    print("requestedCrop=\(requestedCrop.origin.x),\(requestedCrop.origin.y),\(requestedCrop.width),\(requestedCrop.height)")
                }
                exit(0)
            }
            return CaptureArgs(
                outDir: args[1],
                fromX: Double(args[2])!,
                fromY: Double(args[3])!,
                toX: Double(args[4])!,
                toY: Double(args[5])!,
                frameCount: Int(args[6])!,
                fps: Int(args[7])!,
                requestedCrop: requestedCrop,
                crop: crop,
                steps: args.count == 14 ? Int(args[12])! : 80,
                stepMs: args.count == 14 ? Double(args[13])! : 8.0,
                waitSeconds: 0.0,
                targetWindow: nil
            )
        }
    }

    static func post(_ type: CGEventType, _ x: Double, _ y: Double) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: CGPoint(x: x, y: y),
            mouseButton: .left
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    static func write(_ index: Int, _ acquiredNs: UInt64, _ pixelBuffer: CVPixelBuffer, _ outURL: URL, _ stamp: FileHandle, _ context: CIContext) {
        let name = String(format: "frame_%03d.png", index)
        let url = outURL.appendingPathComponent(name)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height)),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            if let data = "\(index)\t\(acquiredNs)\twrite_failed\n".data(using: .utf8) {
                try? stamp.write(contentsOf: data)
            }
            return
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        if let data = "\(index)\t\(acquiredNs)\t\(name)\n".data(using: .utf8) {
            try? stamp.write(contentsOf: data)
        }
    }
}

let finished = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
Task {
    do {
        try await TrueLiquidSckCaptureDrag.run()
    } catch {
        fputs("\(error)\n", stderr)
        exitCode = 1
    }
    finished.signal()
}
finished.wait()
exit(exitCode)
