import AppKit
import ScreenCaptureKit
import Vision

/// The text in a part of the screen, read from its pixels. For what the
/// accessibility tree does not hold: Teams' attendee suggestions were on
/// screen and not in the tree.
enum ScreenText {
    struct Line {
        let text: String
        let confidence: Float
        /// Screen points, top-left origin, as items carry them.
        let frame: CGRect

        var encoded: [String: Any] {
            ["text": text, "p": (Double(confidence) * 100).rounded() / 100,
             "x": Int(frame.midX.rounded()), "y": Int(frame.midY.rounded()),
             "w": Int(frame.width.rounded()), "h": Int(frame.height.rounded())]
        }
    }

    enum Failure: LocalizedError {
        case notGranted
        case noDisplay
        case capture(String)

        var errorDescription: String? {
            switch self {
            case .notGranted: return "screen recording is not granted"
            case .noDisplay: return "no display holds that region"
            case .capture(let why): return "could not capture the screen: \(why)"
            }
        }
    }

    private static var asked = false

    /// `region` in screen points, top-left origin.
    static func read(_ region: CGRect) async throws -> [Line] {
        let (image, shown) = try await capture(region)
        return try recognize(image, as: shown)
    }

    /// The lines in `image`, which shows `region` of the screen. Measured on
    /// a 3448×1998 screenshot: 42-48 ms whole, 32-34 ms for one dialog.
    static func recognize(_ image: CGImage, as region: CGRect) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["en-US", "fr-FR"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let top = observation.topCandidates(1).first else { return nil }
            // Normalised, with the origin at the bottom left.
            let box = observation.boundingBox
            return Line(
                text: top.string, confidence: top.confidence,
                frame: CGRect(
                    x: region.minX + box.minX * region.width,
                    y: region.minY + (1 - box.maxY) * region.height,
                    width: box.width * region.width, height: box.height * region.height
                )
            )
        }
    }

    /// The region at the display's pixel scale, cut to the display that holds
    /// its centre, and the part of it shown. ParrotFlow's own panels are left out.
    static func capture(_ region: CGRect) async throws -> (CGImage, CGRect) {
        guard CGPreflightScreenCaptureAccess() else {
            if !asked {
                asked = true
                // Puts the app in System Settings' list, so it can be switched on.
                _ = CGRequestScreenCaptureAccess()
            }
            throw Failure.notGranted
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Failure.capture(error.localizedDescription)
        }
        let centre = CGPoint(x: region.midX, y: region.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(centre) })
            ?? content.displays.first(where: { $0.frame.intersects(region) })
        else { throw Failure.noDisplay }
        let shown = region.intersection(display.frame)
        guard !shown.isNull, shown.width >= 1, shown.height >= 1 else { throw Failure.noDisplay }
        let own = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.sourceRect = shown.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Int((shown.width * scale).rounded())
        config.height = Int((shown.height * scale).rounded())
        config.showsCursor = false
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return (image, shown)
        } catch {
            throw Failure.capture(error.localizedDescription)
        }
    }

    /// A JPEG of `region` at `path`, for the run recorder. Its frame is the
    /// part of the region on the display, top-left and size in points. Never
    /// asks for the permission: a recording must not raise a dialog.
    static func shot(_ region: CGRect, to path: String) async throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else { throw Failure.notGranted }
        let start = Date()
        let (image, shown) = try await capture(region)
        return try save(image, shown: shown, to: path, since: start)
    }

    /// A read of the window for the runner, from one capture: the JPEG at
    /// `path` for the recorder, and with `see` the lines in it. Adds `shot` or
    /// `shot_error`, and `seen` and `seen_ms`, to `reply`. Without the
    /// permission there is no `seen`. Never asks for it.
    static func window(_ region: CGRect, shot path: String?, see: Bool,
                       into reply: inout [String: Any]) async {
        guard path != nil || see else { return }
        let start = Date()
        let image: CGImage, shown: CGRect
        do {
            guard CGPreflightScreenCaptureAccess() else { throw Failure.notGranted }
            (image, shown) = try await capture(region)
        } catch {
            if path != nil {
                reply["shot"] = NSNull()
                reply["shot_error"] = error.localizedDescription
            }
            return
        }
        if let path {
            do {
                reply["shot"] = try save(image, shown: shown, to: path, since: start)
            } catch {
                reply["shot"] = NSNull()
                reply["shot_error"] = error.localizedDescription
            }
        }
        guard see else { return }
        let reading = Date()
        do {
            let lines = try recognize(image, as: shown)
            reply["seen"] = lines.map(\.encoded)
            reply["seen_ms"] = Int(Date().timeIntervalSince(reading) * 1000)
        } catch {
            reply["seen_error"] = error.localizedDescription
        }
    }

    private static func save(_ image: CGImage, shown: CGRect, to path: String,
                             since start: Date) throws -> [String: Any] {
        guard let data = NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        else { throw Failure.capture("the JPEG could not be made") }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return ["file": path,
                "frame": ["x": shown.minX, "y": shown.minY, "w": shown.width, "h": shown.height],
                "scale": Double(image.width) / Double(shown.width),
                "w": image.width, "h": image.height,
                "ms": Int(Date().timeIntervalSince(start) * 1000)]
    }

    /// `--look-image <png> [x y w h]`: the same reading on a saved image. The
    /// region is centre and size in the image's pixels; lines come out in
    /// points at `scale` pixels per point. `--json` prints the warm time and
    /// the lines as the runner gets them.
    static func lookImage(_ arguments: [String]) -> Int32 {
        guard let path = arguments.first else {
            print("usage: ParrotFlow --look-image <png> [x y w h] [--scale 2] [--json]")
            return 2
        }
        guard let whole = NSImage(contentsOfFile: path)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("could not read \(path)")
            return 1
        }
        let scale = arguments.firstIndex(of: "--scale").flatMap {
            arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil
        } ?? 2
        let numbers = arguments.dropFirst().prefix(4).compactMap(Double.init)
        var pixels = CGRect(x: 0, y: 0, width: whole.width, height: whole.height)
        if numbers.count == 4 {
            pixels = CGRect(x: numbers[0] - numbers[2] / 2, y: numbers[1] - numbers[3] / 2,
                            width: numbers[2], height: numbers[3]).integral
        }
        guard let image = whole.cropping(to: pixels) else {
            print("the region is not in the image")
            return 1
        }
        let region = CGRect(x: pixels.minX / scale, y: pixels.minY / scale,
                            width: pixels.width / scale, height: pixels.height / scale)
        do {
            _ = try recognize(image, as: region)
            let start = Date()
            let lines = try recognize(image, as: region)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if arguments.contains("--json") {
                let out: [String: Any] = ["ms": ms, "lines": lines.map(\.encoded),
                                          "w": image.width, "h": image.height]
                let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                return 0
            }
            print("\(lines.count) lines in \(ms) ms, warm, from \(image.width)×\(image.height) px")
            for line in lines.sorted(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }) {
                print(String(format: "%5.0f,%5.0f %4.0fx%-3.0f %.2f  %@",
                             line.frame.midX, line.frame.midY, line.frame.width, line.frame.height,
                             line.confidence, line.text))
            }
            return 0
        } catch {
            print("could not read the text: \(error.localizedDescription)")
            return 1
        }
    }
}
