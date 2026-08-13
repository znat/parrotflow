import AVFoundation
import AppKit
import ApplicationServices
import Security

enum Permissions {
    enum Status {
        case granted
        case denied
        case notDetermined
        /// Accessibility has no "not yet asked" state — the process either is
        /// trusted or it isn't.
        case notGranted

        var label: String {
            switch self {
            case .granted: return "Granted"
            case .denied: return "Denied"
            case .notDetermined: return "Not requested"
            case .notGranted: return "Not granted"
            }
        }
    }

    // MARK: Code signature

    /// True when the bundle carries an ad-hoc signature.
    ///
    /// This matters because TCC pins high-risk grants (Accessibility, Input
    /// Monitoring) to the binary's cdhash. An ad-hoc signature produces a new
    /// cdhash on every build, so the grant silently stops applying and the
    /// entry left behind in System Settings refers to a binary that no longer
    /// exists — ticking it again just re-uses the dead entry.
    static var isAdHocSigned: Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let signatureFlags = dictionary[kSecCodeInfoFlags as String] as? UInt32
        else { return false }

        // kSecCodeSignatureAdhoc — not bridged into Swift, value from cs_blobs.h.
        let adhocFlag: UInt32 = 0x0000_0002
        return signatureFlags & adhocFlag != 0
    }

    /// Where the running bundle lives — a copy in /Applications keeps a stable
    /// signature, a freshly rebuilt one in .build does not.
    static var isRunningFromBuildDirectory: Bool {
        Bundle.main.bundleURL.path.contains("/.build/")
    }

    // MARK: Microphone

    /// Requires `NSMicrophoneUsageDescription` in Info.plist, otherwise macOS
    /// kills the process the moment the prompt would appear.
    static var microphone: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        switch microphone {
        case .granted:
            completion(true)
        case .denied:
            // The system only ever prompts once; from here it's a trip to Settings.
            openMicrophoneSettings()
            completion(false)
        case .notDetermined, .notGranted:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    // MARK: Accessibility
    //
    // Not needed to record — only to type the transcript into the frontmost app
    // later on. Surfaced now so the permission is already sorted by then.

    /// `AXIsProcessTrustedWithOptions(nil)` rather than `AXIsProcessTrusted()`:
    /// the latter can serve a value cached from process start, which shows up as
    /// a status that never flips after you tick the box in System Settings.
    static var accessibility: Status {
        AXIsProcessTrustedWithOptions(nil) ? .granted : .notGranted
    }

    /// Why a grant isn't sticking, when we can tell. nil once it has stuck.
    static var accessibilityBlocker: String? {
        guard accessibility != .granted else { return nil }
        guard isAdHocSigned else { return nil }

        if isRunningFromBuildDirectory {
            return "This build is ad-hoc signed and running from .build, which is rebuilt from scratch each time. "
                + "macOS pins this permission to the exact binary, so a grant is void the moment you rebuild — and the "
                + "leftover entry in System Settings points at a binary that's gone, which is why re-ticking it does nothing. "
                + "Run `make install` and grant the permission to the copy in /Applications instead."
        }
        return "This build is ad-hoc signed, so macOS pins the permission to the exact binary and forgets it whenever "
            + "the app is rebuilt. If it won't stick, run `make reset-permissions` and grant it again."
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Fires when the system's accessibility trust database changes — lets the
    /// UI react the moment the box is ticked instead of waiting for a poll.
    /// Undocumented, so it's a supplement to polling, not a replacement.
    static func observeAccessibilityChanges(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { _ in
            // The database write and the trust check aren't atomic; a beat of
            // delay avoids reading the old value.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: handler)
        }
    }

    /// Relaunches the app. macOS often won't extend a fresh Accessibility grant
    /// to an already-running process — System Settings offers "Quit & Reopen"
    /// for exactly this reason, and an ad-hoc signed build hits it more often
    /// because its signature changes on every build.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
