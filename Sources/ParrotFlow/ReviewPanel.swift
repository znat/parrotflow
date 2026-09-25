import AppKit
import Combine
import SwiftUI

/// The action key's words, to edit before the run starts. Return runs,
/// Shift+Return adds a line, Escape cancels. It sits where the run panel
/// will: beside the target app's window.
///
/// It takes keyboard focus. Run and Cancel both give focus back to the app
/// that was in front at the press, and Run starts only once that app is in
/// front again: the runner stops when another app is.
final class ReviewPanel {

    enum Key: Equatable { case run, newline, cancel, other }

    /// What a text view command does in the field.
    static func key(_ command: Selector, shift: Bool) -> Key {
        switch command {
        case #selector(NSResponder.insertNewline(_:)): return shift ? .newline : .run
        case #selector(NSResponder.cancelOperation(_:)): return .cancel
        default: return .other
        }
    }

    /// The text to run, or nil when there is nothing to run.
    static func runnable(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What the recorder keeps as heard: only when it differs from the run.
    static func heard(_ heard: String, ran: String) -> String? {
        heard == ran ? nil : heard
    }

    var primaryColor = ContextIdentity.defaultPrimary {
        didSet { model.primaryColor = primaryColor }
    }
    var theme: ContextAppearance = .system {
        didSet { model.theme = theme }
    }

    private(set) var isOpen = false
    private let model = ReviewModel()
    private var panel: ReviewWindow?
    private var hosting: NSView?
    private var watch: AnyCancellable?
    private var target: NSRunningApplication?
    private var onRun: ((String) -> Void)?
    private var onCancel: (() -> Void)?

    /// `window` is the target app's window, in accessibility coordinates.
    func show(
        _ text: String, target: NSRunningApplication?, window: CGRect?,
        run: @escaping (String) -> Void, cancel: @escaping () -> Void
    ) {
        if panel == nil { build() }
        guard let panel else { return }
        // The one it replaces is cancelled; focus stays here for the new one.
        if isOpen, let replaced = onCancel {
            onCancel = nil
            replaced()
        }
        self.target = target
        onRun = run
        onCancel = cancel
        model.text = text
        isOpen = true
        place(window: window.map(QuestionPlacement.flipped))
        panel.riseIntoView(makeKey: true)
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, self.isOpen else { return }
            if !panel.isKeyWindow {
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
            }
            self.model.focus?()
        }
    }

    /// Dictation while the panel is open goes into its field.
    func dictate(_ words: String) -> Bool {
        guard isOpen else { return false }
        model.text += (model.text.isEmpty || model.text.hasSuffix(" ") ? "" : " ") + words
        return true
    }

    /// Closes it as Escape would. Returns the app focus goes back to.
    @discardableResult
    func cancel() -> NSRunningApplication? {
        guard isOpen else { return nil }
        let back = target
        let done = onCancel
        close { done?() }
        return back
    }

    private func run() {
        guard isOpen, let text = Self.runnable(model.text) else { return }
        let done = onRun
        close { done?(text) }
    }

    private func close(then next: @escaping () -> Void) {
        isOpen = false
        onRun = nil
        onCancel = nil
        let back = target
        target = nil
        let wasKey = panel?.isKeyWindow == true || NSApp.isActive
        panel?.orderOut(nil)
        guard let back, wasKey else { return next() }
        // Only an active app can hand activation on; see `QuestionPanel.handBack`.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            back.activate()
            Self.waitForFront(back, until: Date().addingTimeInterval(1), then: next)
        }
    }

    private static func waitForFront(
        _ app: NSRunningApplication, until: Date, then next: @escaping () -> Void
    ) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if front == app.processIdentifier || Date() >= until {
            if front != app.processIdentifier {
                Log.write("action: \(app.localizedName ?? "the app") did not come back to the front")
            }
            // The window takes key a moment after the app is in front.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: next)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            waitForFront(app, until: until, then: next)
        }
    }

    // MARK: - The window

    private var placedScreen: CGRect = .zero

    private func place(window: CGRect?) {
        guard let panel, let hosting else { return }
        placedScreen = QuestionPlacement.screen(for: window)
        let size = hosting.fittingSize
        let gap = QuestionPlacement.gap - QuestionMetrics.bleed
        let frame = QuestionPlacement.aside(size, window: window, on: placedScreen, gap: gap).frame
        panel.setFrame(frame, display: true)
        hosting.frame = NSRect(origin: .zero, size: size)
    }

    /// A new height keeps the top edge where it is.
    private func resize() {
        guard let panel, let hosting, isOpen else { return }
        let size = hosting.fittingSize
        guard size.height != panel.frame.height else { return }
        let top = min(panel.frame.maxY, placedScreen.maxY)
        let y = max(placedScreen.minY, top - size.height)
        panel.setFrame(
            CGRect(x: panel.frame.minX, y: y, width: size.width, height: size.height),
            display: true
        )
        hosting.frame = NSRect(origin: .zero, size: size)
    }

    private func build() {
        let hosting = ReviewHostingView(rootView: ReviewView().environmentObject(model))
        let panel = ReviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: QuestionMetrics.windowWidth, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = nil
        panel.onCancel = { [weak self] in self?.cancel() }
        model.primaryColor = primaryColor
        model.theme = theme
        model.onRun = { [weak self] in self?.run() }
        model.onCancel = { [weak self] in self?.cancel() }
        watch = model.$text
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resize() }
        self.panel = panel
        self.hosting = hosting
    }
}

private final class ReviewWindow: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// A click on a button works the first time, while another app is active.
private final class ReviewHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ReviewModel: ObservableObject {
    @Published var text = ""
    @Published var primaryColor = ContextIdentity.defaultPrimary
    @Published var theme: ContextAppearance = .system
    var onRun: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Set by the field: puts the caret at the end of the text.
    var focus: (() -> Void)?
}

enum ReviewMetrics {
    static let padding: CGFloat = 12
    static let fontSize: CGFloat = 14
    static let inset = NSSize(width: 6, height: 7)
    static let maxLines: CGFloat = 8
    static var fieldWidth: CGFloat { QuestionMetrics.surfaceWidth - padding * 2 }

    /// The field's height for `text`: every line of it, up to `maxLines`.
    static func fieldHeight(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        let line = ceil(font.ascender - font.descender + font.leading)
        // A trailing newline is a line the bounding rect does not count.
        let measured = text.hasSuffix("\n") || text.isEmpty ? text + " " : text
        let width = fieldWidth - inset.width * 2 - 10
        let rect = NSAttributedString(string: measured, attributes: [.font: font])
            .boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        let lines = max(1, min(maxLines, ceil(rect.height / line)))
        return lines * line + inset.height * 2
    }
}

struct ReviewView: View {
    @EnvironmentObject private var model: ReviewModel
    @Environment(\.colorScheme) private var colorScheme

    private var effectiveColorScheme: ColorScheme {
        model.theme.resolved(against: colorScheme)
    }

    private var theme: ContextTheme {
        ContextTheme(scheme: effectiveColorScheme, primaryHex: model.primaryColor)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            ReviewField(model: model, theme: theme)
                .frame(width: ReviewMetrics.fieldWidth,
                       height: ReviewMetrics.fieldHeight(model.text))
                .background(
                    theme.dark ? theme.controlFill : Color.white,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(theme.controlEdge, lineWidth: 1)
                }
            HStack(spacing: 8) {
                Button { model.onCancel?() } label: { label("Cancel", key: "esc") }
                    .buttonStyle(ReviewButton(primary: false, theme: theme))
                Button { model.onRun?() } label: { label("Run", key: "↩") }
                    .buttonStyle(ReviewButton(primary: true, theme: theme))
                    .disabled(ReviewPanel.runnable(model.text) == nil)
            }
        }
        .padding(ReviewMetrics.padding)
        .frame(width: QuestionMetrics.surfaceWidth)
        .foregroundStyle(theme.foreground)
        .contextSurface(
            RoundedRectangle(cornerRadius: ContextIdentity.radius, style: .continuous),
            border: theme.edge, theme: theme
        )
        .padding(QuestionMetrics.bleed)
        .environment(\.colorScheme, effectiveColorScheme)
    }

    private func label(_ title: String, key: String) -> some View {
        HStack(spacing: 7) {
            Text(title)
            Text(key)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(theme.muted)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(theme.muted.opacity(0.4), lineWidth: 0.5)
                }
        }
    }
}

private struct ReviewButton: ButtonStyle {
    let primary: Bool
    let theme: ContextTheme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: primary ? .medium : .regular))
            .foregroundStyle(theme.foreground.opacity(configuration.isPressed ? 0.65 : 1))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                primary ? theme.accent.opacity(configuration.isPressed ? 0.12 : 0.18)
                    : theme.controlFill,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4).strokeBorder(
                    primary ? theme.accent.opacity(0.7) : theme.controlEdge,
                    lineWidth: primary ? 1 : 0.5
                )
            }
            .opacity(enabled ? 1 : 0.45)
    }
}

/// A plain-text view: SwiftUI's fields cannot tell Return from Shift+Return.
private struct ReviewField: NSViewRepresentable {
    @ObservedObject var model: ReviewModel
    let theme: ContextTheme

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: NSViewRepresentableContext<Self>) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.delegate = context.coordinator
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.drawsBackground = false
        text.font = .systemFont(ofSize: ReviewMetrics.fontSize)
        text.textContainerInset = ReviewMetrics.inset
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.string = model.text
        model.focus = { [weak text] in
            guard let text else { return }
            text.window?.makeFirstResponder(text)
            text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
            text.scrollRangeToVisible(text.selectedRange())
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: NSViewRepresentableContext<Self>) {
        guard let text = scroll.documentView as? NSTextView else { return }
        if text.string != model.text {
            text.string = model.text
            text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        }
        let color = NSColor(theme.foreground)
        text.textColor = color
        text.insertionPointColor = color
        scroll.appearance = NSAppearance(named: theme.dark ? .darkAqua : .aqua)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: ReviewModel

        init(model: ReviewModel) { self.model = model }

        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else { return }
            model.text = text.string
        }

        func textView(_ textView: NSTextView, doCommandBy command: Selector) -> Bool {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            switch ReviewPanel.key(command, shift: shift) {
            case .run:
                model.onRun?()
                return true
            case .newline:
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case .cancel:
                model.onCancel?()
                return true
            case .other:
                return false
            }
        }
    }
}
