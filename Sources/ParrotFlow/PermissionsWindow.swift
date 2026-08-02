import AppKit
import SwiftUI

final class PermissionsModel: ObservableObject {
    @Published var micStatus: Permissions.Status = .notDetermined
    @Published var axStatus: Permissions.Status = .notGranted
    @Published var axBlocker: String?

    func refresh() {
        micStatus = Permissions.microphone
        axStatus = Permissions.accessibility
        axBlocker = Permissions.accessibilityBlocker
    }
}

/// Single plain window — no preferences tabs, no toolbar. It exists to answer
/// "is this thing actually allowed to hear me, and to type what it hears?".
/// Everything else the app can be told lives in config.yaml, which the Settings
/// menu item opens.
final class PermissionsWindowController {
    let model = PermissionsModel()
    private var window: NSWindow?
    private var timer: Timer?
    private var accessibilityObserver: NSObjectProtocol?

    init() {
        accessibilityObserver = Permissions.observeAccessibilityChanges { [weak self] in
            self?.model.refresh()
        }
    }

    deinit {
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
        }
    }

    func show() {
        model.refresh()

        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.model.refresh()
        }
    }

    private func build() {
        let view = PermissionsView().environmentObject(model)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "\(AppVariant.displayName) Permissions"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 460, height: 320))
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

private struct PermissionsView: View {
    @EnvironmentObject private var model: PermissionsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    detail: "Required to record.",
                    status: model.micStatus,
                    actionTitle: model.micStatus == .notDetermined ? "Request" : "Open Settings",
                    action: {
                        if model.micStatus == .notDetermined {
                            Permissions.requestMicrophone { _ in model.refresh() }
                        } else {
                            Permissions.openMicrophoneSettings()
                        }
                    }
                )

                PermissionRow(
                    icon: "keyboard.fill",
                    title: "Accessibility",
                    detail: "Not needed to record — it's what lets ParrotFlow type the transcript into the app you're using.",
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
            .padding(24)
        }
        .frame(minWidth: 460, minHeight: 320)
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
