import AppKit
import SwiftUI

final class SettingsModel: ObservableObject {
    @Published var micStatus: Permissions.Status = .notDetermined
    @Published var axStatus: Permissions.Status = .notGranted
    @Published var axBlocker: String?
    @Published var hotkeyDisplay: String = ""
    @Published var hotkeyMode: String = ""
    @Published var hotkeyError: String?
    @Published var outputDir: String = ""
    @Published var lastRecording: String?
    @Published var lastTranscript: String?

    func refreshPermissions() {
        micStatus = Permissions.microphone
        axStatus = Permissions.accessibility
        axBlocker = Permissions.accessibilityBlocker
    }
}

/// Single plain window — no preferences tabs, no toolbar. It exists to answer
/// "is this thing actually allowed to hear me, and what key starts it?".
final class SettingsWindowController {
    let model = SettingsModel()
    private var window: NSWindow?
    private var timer: Timer?
    private var accessibilityObserver: NSObjectProtocol?

    init() {
        accessibilityObserver = Permissions.observeAccessibilityChanges { [weak self] in
            self?.model.refreshPermissions()
        }
    }

    deinit {
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
        }
    }

    func show() {
        model.refreshPermissions()

        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.model.refreshPermissions()
        }
    }

    private func build() {
        let view = SettingsView().environmentObject(model)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "ParrotFlow"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 460, height: 460))
        self.window = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.timer?.invalidate()
            self?.timer = nil
        }
    }
}

// MARK: - View

private struct SettingsView: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                Section(title: "Permissions") {
                    PermissionRow(
                        icon: "mic.fill",
                        title: "Microphone",
                        detail: "Required to record.",
                        status: model.micStatus,
                        actionTitle: model.micStatus == .notDetermined ? "Request" : "Open Settings",
                        action: {
                            if model.micStatus == .notDetermined {
                                Permissions.requestMicrophone { _ in model.refreshPermissions() }
                            } else {
                                Permissions.openMicrophoneSettings()
                            }
                        }
                    )

                    PermissionRow(
                        icon: "keyboard.fill",
                        title: "Accessibility",
                        detail: "Not needed yet — it's what will let ParrotFlow type the transcript into the app you're using.",
                        status: model.axStatus,
                        // "Request" must come first: AXIsProcessTrustedWithOptions
                        // is what registers this binary with TCC. Merely opening
                        // Settings shows a list this app may not be in yet.
                        actionTitle: "Request",
                        action: { Permissions.requestAccessibility() },
                        secondaryTitle: "Open Settings",
                        secondaryAction: { Permissions.openAccessibilitySettings() },
                        footnote: model.axBlocker
                            ?? "Ticked the box already? Relaunch so the running process picks it up."
                    )
                }

                Section(title: "Hotkey") {
                    if let error = model.hotkeyError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack(spacing: 10) {
                            Text(model.hotkeyDisplay)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                            Text(model.hotkeyMode)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Text("Configured in `~/.config/parrotflow/config.yaml`")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Edit Config") {
                            NSWorkspace.shared.open(ConfigStore.fileURL)
                        }
                    }
                }

                Section(title: "Recordings") {
                    Text(model.outputDir)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if let last = model.lastRecording {
                        Text("Last: \(last)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Open Folder") {
                        let dir = URL(fileURLWithPath: (model.outputDir as NSString).expandingTildeInPath)
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 460, minHeight: 460)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("ParrotFlow")
                    .font(.system(size: 19, weight: .semibold))
                Text("Local dictation. Nothing leaves this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.6)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let status: Permissions.Status
    let actionTitle: String
    let action: () -> Void
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil
    /// Shown only while the permission is still missing.
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(title).font(.system(size: 13, weight: .medium))
                        StatusBadge(status: status)
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if status != .granted {
                    VStack(alignment: .trailing, spacing: 6) {
                        Button(actionTitle, action: action)
                        if let secondaryTitle, let secondaryAction {
                            Button(secondaryTitle, action: secondaryAction)
                        }
                    }
                }
            }

            if status != .granted, let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 30)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct StatusBadge: View {
    let status: Permissions.Status

    var body: some View {
        Text(status.label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined, .notGranted: return .orange
        }
    }
}
