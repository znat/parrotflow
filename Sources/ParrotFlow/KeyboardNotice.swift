import AppKit
import Carbon.HIToolbox
import Darwin
import SwiftUI

/// Who has Secure Event Input on, if anybody.
///
/// One app turns it on for a password field and macOS stops handing the
/// keyboard to every other process on the machine. There is no permission that
/// exempts an app from that, and there should not be — it is the whole point of
/// it. So this exists to *name* the app, which is the one thing a person needs
/// and cannot get without `ioreg`.
///
/// Costs nothing: two reads, no Accessibility, no Input Monitoring.
enum SecureInput {

    struct Holder {
        /// Nil when the flag is on and the session carries no owner — a screen
        /// lock, loginwindow. Then there is a dead keyboard and nobody to name.
        let pid: pid_t?
        let name: String?

        /// What the notice calls it. "Another app" is not a name and is still
        /// better than a sentence about nothing.
        var described: String { name ?? "Another app" }
    }

    /// Nil when the keyboard is ours to watch.
    static func holder() -> Holder? {
        guard IsSecureEventInputEnabled() else { return nil }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = session["kCGSSessionSecureInputPID"] as? pid_t, pid > 0
        else { return Holder(pid: nil, name: nil) }
        return Holder(pid: pid, name: name(of: pid))
    }

    /// The app's name, and the process's when it is not an app.
    ///
    /// Electron turns secure input on from a helper process, and
    /// `NSRunningApplication` answers nil for one — it is not a GUI app. The
    /// executable name is then what there is, and "Notion Helper" still tells
    /// you what to quit. Measured on 2026-09-06: pid 1002 came back "Notion"
    /// through the first path and pid 1115 "Notion Helper" through the second.
    private static func name(of pid: pid_t) -> String? {
        if let app = NSRunningApplication(processIdentifier: pid) {
            return app.localizedName ?? app.bundleIdentifier
        }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : (path as NSString).lastPathComponent
    }
}

/// Says, once per episode, that another app has taken the keyboard.
///
/// The same shape as `MicNotice` and for the same reason: it is not a status,
/// it is a thing to read, act on, and not be told again. On the pill it would
/// be in the way of the offer, which is the surface it is about.
///
/// The collapsed sentence carries the fix rather than the diagnosis. What you
/// need at that moment is which app to go and quit; what secure input *is* can
/// wait behind the disclosure.
final class KeyboardNotice {

    private var panel: NSPanel?
    private let model = KeyboardNoticeModel()

    /// The holder already spoken about.
    ///
    /// Cleared the moment secure input goes off, so a second episode is said
    /// again. Not kept across launches, unlike `MicNotice.lastDevice`: that one
    /// remembers a decision you made about your own hardware, and this is a
    /// state some other app is in right now. Remembering it would mean staying
    /// quiet the next time the keyboard died.
    private var told: pid_t?

    var isShowing: Bool { panel?.isVisible == true }

    /// After a dictation, if the keyboard is not ours and we have not said so.
    ///
    /// Here rather than at the moment a key is pressed, because by then it is
    /// too late: the letter has already gone into the document instead of
    /// running the command. This is the moment before the offer's keys matter.
    func showIfNeeded() {
        guard let holder = SecureInput.holder() else {
            told = nil
            return
        }
        guard told != holder.pid else { return }
        told = holder.pid
        Log.write("keyboard: \(holder.described) has secure input on; said so once")
        show(app: holder.described)
    }

    /// Put it on screen for a named app, the flag aside.
    ///
    /// Split out so `--panels keyboard` raises the surface the app raises,
    /// rather than a copy of it that can drift — and so it can be looked at on
    /// a machine where nothing is holding the keyboard.
    func show(app: String) {
        model.app = app
        model.expanded = false
        model.onClose = { [weak self] in self?.dismiss() }

        if panel == nil { build() }
        resize()
        reposition()
        panel?.riseIntoView(makeKey: false)
    }

    private func dismiss() {
        panel?.orderOut(nil)
    }

    private func build() {
        let hosting = NSHostingView(rootView: KeyboardNoticeView().environmentObject(model))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: KeyboardNoticeMetrics.width,
                                height: KeyboardNoticeMetrics.height(expanded: false)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.adoptParrotAppearance()
        self.panel = panel

        model.onResize = { [weak self] in self?.resize() }
    }

    private func resize() {
        guard let panel else { return }
        let height = KeyboardNoticeMetrics.height(expanded: model.expanded)
        let origin = panel.frame.origin
        panel.setFrame(
            NSRect(x: origin.x, y: origin.y, width: KeyboardNoticeMetrics.width, height: height),
            display: true, animate: panel.isVisible
        )
        panel.contentView?.frame = NSRect(
            x: 0, y: 0, width: KeyboardNoticeMetrics.width, height: height
        )
    }

    /// Bottom right, where `MicNotice` goes. The two never share the moment —
    /// see the caller.
    private func reposition() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - panel.frame.width - 24,
            y: frame.minY + 24
        ))
    }
}

enum KeyboardNoticeMetrics {
    static let width: CGFloat = 380
    /// Two heights, as in `MicNoticeMetrics`: the sentence is one app name long
    /// and the reasons are fixed text, so there is nothing to measure that is
    /// not known when it is written. Both states are on `--panels keyboard`.
    static func height(expanded: Bool) -> CGFloat { expanded ? 300 : 118 }
}

final class KeyboardNoticeModel: ObservableObject {
    @Published var app = "Another app"
    @Published var expanded = false {
        didSet { onResize?() }
    }
    var onClose: (() -> Void)?
    var onResize: (() -> Void)?
}

struct KeyboardNoticeView: View {
    @EnvironmentObject private var model: KeyboardNoticeModel

    /// Written as the three questions somebody asks in this order: what is
    /// broken, why, and what to do about it. The last one is the reason the
    /// notice exists, so it is the one with the exact steps in it.
    private static let reasons = [
        (
            "What stops working",
            "Escape cannot cancel a dictation, and the offer's letters cannot run its commands. Clicking the pill still works."
        ),
        (
            "Why",
            "An app turns it on for a password field. macOS then hides every key from every other app, this one included."
        ),
        (
            "How to clear it",
            "Click into an ordinary field in that app, or switch away and back. Quitting it always works."
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Parrot.amber)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(model.app) has taken the keyboard")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Quit it, or click out of its password field.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if model.expanded {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Self.reasons, id: \.0) { reason in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(reason.0)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Parrot.amber.opacity(0.9))
                            Text(reason.1)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 21)
            }

            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { model.expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(model.expanded ? 90 : 0))
                        Text(model.expanded ? "Less" : "Why")
                    }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button("Got it") { model.onClose?() }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background {
                        Capsule().fill(Color.white.opacity(0.12))
                    }
            }
        }
        .padding(Parrot.panelPadding)
        .frame(width: KeyboardNoticeMetrics.width, alignment: .leading)
        .parrotSurface(
            RoundedRectangle(cornerRadius: Parrot.panelRadius, style: .continuous),
            solid: true
        )
    }
}
