import AppKit
import SwiftUI

/// The window a new release is offered in.
///
/// An NSAlert until it could not do the job. Two things it will not do: it lays
/// its own text out at whatever height that text needs, so a release with ten
/// bullets on it grew past the bottom of the screen; and it puts at most two
/// buttons in a row — measured, on macOS 26 — so three answers came out stacked
/// in a column. This is the app's own surface instead, the same dark ground and
/// plumage rim as the correction and preview panels.
///
/// The notes go in a scroll view with a ground of their own. They are the one
/// piece of text in the app written somewhere else, by whoever wrote the
/// release, and a panel of it reads as quoted rather than as the app talking.
final class UpdatePanel {

    private var panel: NSPanel?
    private let model = UpdateModel()

    /// The three answers, plus the one the window itself gives when it is
    /// closed without an answer: nothing.
    struct Answers {
        let install: (() -> Void)?
        let copyCommand: () -> Void
        let skip: () -> Void
        let later: () -> Void
    }

    func show(
        release: Updates.Release, current: String?, blocker: String?, answers: Answers
    ) {
        model.version = release.version
        model.current = current
        model.blocker = blocker
        // The notes view is built here rather than in the SwiftUI body: it
        // measures itself, and the panel needs that height to size itself
        // before anything is on screen.
        model.notes = ReleaseNotes.scrollingView(
            ReleaseNotes.attributed(release.notes.isEmpty ? "No release notes." : release.notes),
            maxHeight: notesCeiling()
        )
        model.canInstall = answers.install != nil
        model.onPrimary = { [weak self] in
            self?.dismiss()
            if let install = answers.install { install() } else { answers.copyCommand() }
        }
        model.onSkip = { [weak self] in
            self?.dismiss()
            answers.skip()
        }
        model.onLater = { [weak self] in
            self?.dismiss()
            answers.later()
        }

        if panel == nil { build() }
        resize()
        centre()
        NSApp.activate(ignoringOtherApps: true)
        panel?.riseIntoView(makeKey: true)
    }

    private func dismiss() {
        panel?.orderOut(nil)
    }

    /// How tall the notes may get on the screen they are about to appear on.
    /// The rest of the panel is about 200 points, and a window taller than the
    /// screen has its buttons under the dock.
    private func notesCeiling() -> CGFloat {
        let room = (NSScreen.main?.visibleFrame.height ?? 900) - 260
        return max(120, min(380, room))
    }

    private func build() {
        let hosting = NSHostingView(rootView: UpdateView().environmentObject(model))
        let panel = UpdateKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: UpdateMetrics.width, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.adoptParrotAppearance()
        panel.onCancel = { [weak self] in self?.model.onLater?() }
        self.panel = panel
    }

    /// The height SwiftUI works out for itself, rather than a number kept in
    /// step by hand: the notes are as tall as the release is long, and the
    /// blocker line is there or it is not.
    private func resize() {
        guard let panel, let hosting = panel.contentView else { return }
        hosting.layoutSubtreeIfNeeded()
        let height = hosting.fittingSize.height
        panel.setFrame(
            NSRect(x: panel.frame.origin.x, y: panel.frame.origin.y,
                   width: UpdateMetrics.width, height: height),
            display: false
        )
    }

    private func centre() {
        guard let panel, let screen = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: screen.midX - panel.frame.width / 2,
            // A little above centre. A dialog placed dead centre sits low,
            // because the eye reads the middle of a screen as higher than it is.
            y: screen.midY - panel.frame.height / 2 + 40
        ))
    }
}

enum UpdateMetrics {
    /// The notes are the widest thing in the app, and deliberately: a release
    /// bullet carries a sentence and two links, and at 500 points every one of
    /// them wrapped.
    static let notesWidth: CGFloat = 700
    static var width: CGFloat { notesWidth + Parrot.panelPadding * 2 }
}

final class UpdateModel: ObservableObject {
    @Published var version = "0.0.0"
    @Published var current: String?
    @Published var blocker: String?
    @Published var notes: NSScrollView?
    @Published var canInstall = true
    var onPrimary: (() -> Void)?
    var onSkip: (() -> Void)?
    var onLater: (() -> Void)?
}

struct UpdateView: View {
    @EnvironmentObject private var model: UpdateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 11) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(AppVariant.displayName) \(model.version) is available")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("You are running \(model.current ?? "an unknown version").")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if let notes = model.notes {
                NotesBox(scroll: notes)
                    .frame(width: UpdateMetrics.notesWidth, height: notes.frame.height)
            }

            if let blocker = model.blocker {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Parrot.amber)
                        .padding(.top, 1)
                    Text(blocker)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Spacer(minLength: 12)

                ActionButton(title: "Later", key: "esc", filled: false, quiet: true) {
                    model.onLater?()
                }
                .keyboardShortcut(.cancelAction)

                ActionButton(title: "Skip this version", key: "", filled: false, quiet: true) {
                    model.onSkip?()
                }

                ActionButton(
                    title: model.canInstall ? "Update and restart" : "Copy the upgrade command",
                    key: "↩", filled: true
                ) {
                    model.onPrimary?()
                }
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(Parrot.panelPadding)
        .frame(width: UpdateMetrics.width, alignment: .leading)
        .parrotSurface(
            RoundedRectangle(cornerRadius: Parrot.panelRadius, style: .continuous),
            solid: true
        )
    }
}

/// The measured scroll view, handed to SwiftUI as it is. Rebuilding it in
/// `makeNSView` would measure it a second time, and the panel has already been
/// sized from the first answer.
private struct NotesBox: NSViewRepresentable {
    typealias NSViewType = NSScrollView
    // Spelled out rather than as `Context`: this module has a `Context` of its
    // own — the screen-capture stage — and it shadows the protocol's typealias.
    typealias Ctx = NSViewRepresentableContext<NotesBox>

    let scroll: NSScrollView

    func makeNSView(context: Ctx) -> NSScrollView { scroll }
    func updateNSView(_ view: NSScrollView, context: Ctx) {}
}

/// Borderless panels refuse key status, and this one has a default button and
/// an escape.
private final class UpdateKeyPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
