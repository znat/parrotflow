import AppKit
import ScreenCaptureKit

/// A picture of one window, taken even when other windows cover it: what a
/// run in the background sees of its app. Needs the Screen Recording
/// permission for the process that calls it.
public enum Capture {
    public static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

    /// The window of `app` whose frame matches `window`'s, as an image.
    public static func image(of window: Element, in app: App, timeout: Double = 5) throws -> CGImage {
        guard isAllowed else { throw AXKitError.ax(.apiDisabled, "no Screen Recording permission") }
        guard let frame = window.frame else { throw AXKitError.ax(.failure, "the window has no frame") }
        var result: Result<CGImage, Error>?
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                // Accessibility and ScreenCaptureKit share screen points,
                // top-left origin; a window's frame matches within a point.
                guard let match = content.windows.first(where: {
                    $0.owningApplication?.processID == app.pid
                        && abs($0.frame.minX - frame.minX) <= 1 && abs($0.frame.minY - frame.minY) <= 1
                        && abs($0.frame.width - frame.width) <= 1 && abs($0.frame.height - frame.height) <= 1
                }) else { throw AXKitError.ax(.failure, "no capturable window at \(frame)") }
                let configuration = SCStreamConfiguration()
                configuration.width = Int(match.frame.width) * 2
                configuration.height = Int(match.frame.height) * 2
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: match), configuration: configuration)
                result = .success(image)
            } catch {
                result = .failure(error)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success, let result else {
            throw AXKitError.ax(.cannotComplete, "the capture took more than \(timeout) s")
        }
        return try result.get()
    }
}
