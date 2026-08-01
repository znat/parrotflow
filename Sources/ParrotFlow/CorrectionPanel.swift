import AppKit
import SwiftUI

/// The teach-a-word panel: one row per selected word, each mapping what
/// ParrotFlow wrote to what it should have written.
///
/// Selecting a phrase gives you a row per word rather than one row for the
/// whole string, because rules are per-word — "Tasmin and Mick" should teach
/// two rules, not one rule for a phrase that will never recur verbatim. Rows
/// left blank are skipped, so the words you did not come to fix cost nothing.
///
/// Visually a sibling of the recording pill and the notice: same material,
/// same plumage rim, same footer as the preview panel. The words are set in
/// monospace — they are literal strings being mapped to other literal strings,
/// and each row is a line that lands in config.yaml.
final class CorrectionPanel {

    private var panel: KeyPanel?
    private let model = CorrectionModel()

    /// (rules to save, the full corrected text to put back).
    var onSave: (([(heard: String, corrected: String)], String) -> Void)?
    var onCancel: (() -> Void)?

    func show(selection: String) {
        model.load(selection: selection)
        model.onSubmit = { [weak self] in self?.commit() }
        model.onCancel = { [weak self] in self?.dismiss(cancelled: true) }

        if panel == nil { build() }
        resize()
        reposition()

        NSApp.activate(ignoringOtherApps: true)
        panel?.riseIntoView(makeKey: true)
    }

    /// Opens with a rule already filled in — the model proposed it, the user
    /// confirms it. One keystroke, and nothing is written on a guess.
    func show(rule: (heard: String, corrected: String)) {
        model.loadRule(heard: rule.heard, corrected: rule.corrected)
        model.onSubmit = { [weak self] in self?.commit() }
        model.onCancel = { [weak self] in self?.dismiss(cancelled: true) }

        if panel == nil { build() }
        resize()
        reposition()
        NSApp.activate(ignoringOtherApps: true)
        panel?.riseIntoView(makeKey: true)
    }

    private func commit() {
        let rules = model.rules()
        let corrected = model.correctedText()
        dismiss(cancelled: false)
        onSave?(rules, corrected)
    }

    /// Escape reaches here twice — once through the button that advertises it,
    /// once through the panel's own `cancelOperation` for when nothing inside
    /// holds focus. Whichever arrives first closes the panel; the other finds
    /// it already gone.
    private func dismiss(cancelled: Bool) {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
        if cancelled { onCancel?() }
    }

    private func build() {
        let hosting = NSHostingView(rootView: CorrectionView().environmentObject(model))
        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: CorrectionMetrics.width, height: 200),
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
        panel.onCancel = { [weak self] in self?.dismiss(cancelled: true) }
        self.panel = panel
    }

    /// Grows with the number of words, up to a scrolling cap.
    private func resize() {
        guard let panel else { return }
        let height = CorrectionMetrics.height(forRows: model.visibleTokens.count)
        panel.setContentSize(NSSize(width: CorrectionMetrics.width, height: height))
        panel.contentView?.frame = NSRect(
            x: 0, y: 0, width: CorrectionMetrics.width, height: height
        )
    }

    private func reposition() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        ))
    }
}

enum CorrectionMetrics {
    static let width: CGFloat = 500
    static let rowHeight: CGFloat = 38
    static let maxRows = 7
    /// Title, column labels, and the footer the preview panel also carries.
    private static let chrome: CGFloat = 126

    static func height(forRows rows: Int) -> CGFloat {
        chrome + rowHeight * CGFloat(max(1, min(rows, maxRows)))
    }
}

/// Borderless panels refuse key status, which would leave every field unable
/// to take a keystroke.
private final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// SwiftUI's `onExitCommand` only fires when something inside holds focus.
    /// Handling it on the panel means Escape always closes, even if the view
    /// somehow renders with nothing focusable.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: - Model

/// One selected word, plus the punctuation and spacing around it so the
/// phrase can be put back together exactly as it was found.
struct CorrectionToken: Identifiable {
    let id = UUID()
    /// Punctuation before the word — an opening quote or bracket.
    var prefix: String = ""
    /// The bare word. This is what becomes a rule.
    var word: String
    /// Trailing punctuation and whitespace.
    var suffix: String = ""
    var replacement: String = ""
    var isRemoved: Bool = false
    /// Typed by hand rather than taken from a selection, so the word itself is
    /// editable and it contributes nothing to reassembly.
    var isManual: Bool = false

    var resolved: String {
        guard !isManual else { return "" }
        let body = isRemoved || replacement.isEmpty ? word : replacement
        return prefix + body + suffix
    }
}

final class CorrectionModel: ObservableObject {
    @Published var tokens: [CorrectionToken] = []
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    var visibleTokens: [CorrectionToken] {
        tokens.filter { !$0.isRemoved && (!$0.word.isEmpty || $0.isManual) }
    }

    var pendingRuleCount: Int { rules().count }

    func load(selection: String) {
        tokens = Self.tokenize(selection).filter { !$0.word.isEmpty || !$0.prefix.isEmpty }
        // Nothing selected (or nothing readable): give a row you can type both
        // halves into, rather than a panel with no fields at all.
        if !tokens.contains(where: { !$0.word.isEmpty }) {
            tokens.append(CorrectionToken(word: "", isManual: true))
        }
    }

    func loadRule(heard: String, corrected: String) {
        tokens = [CorrectionToken(word: heard, replacement: corrected, isManual: true)]
    }

    func remove(_ id: UUID) {
        guard let index = tokens.firstIndex(where: { $0.id == id }) else { return }
        tokens[index].isRemoved = true
        tokens[index].replacement = ""
        objectWillChange.send()
    }

    /// Only rows that were actually changed become rules.
    func rules() -> [(heard: String, corrected: String)] {
        tokens.compactMap { token in
            guard !token.isRemoved else { return nil }
            let corrected = token.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            let heard = token.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !corrected.isEmpty, !heard.isEmpty, corrected != heard else { return nil }
            return (heard, corrected)
        }
    }

    /// The whole selection with corrections applied, ready to go back into the
    /// field it came from.
    func correctedText() -> String {
        tokens.map(\.resolved).joined()
    }

    /// Splits on whitespace, keeping punctuation attached to its word so
    /// "Mick." teaches a rule for "Mick" but comes back with its full stop.
    static func tokenize(_ text: String) -> [CorrectionToken] {
        let punctuation = CharacterSet.punctuationCharacters
            .union(.symbols)
            .subtracting(CharacterSet(charactersIn: "'-"))

        var tokens: [CorrectionToken] = []
        var index = text.startIndex

        while index < text.endIndex {
            // Whitespace belongs to the previous token's suffix.
            while index < text.endIndex, text[index].isWhitespace {
                if tokens.isEmpty {
                    tokens.append(CorrectionToken(word: ""))
                }
                tokens[tokens.count - 1].suffix.append(text[index])
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }

            var token = CorrectionToken(word: "")
            while index < text.endIndex,
                  let scalar = text[index].unicodeScalars.first,
                  punctuation.contains(scalar), !text[index].isWhitespace {
                token.prefix.append(text[index])
                index = text.index(after: index)
            }
            while index < text.endIndex, !text[index].isWhitespace {
                if let scalar = text[index].unicodeScalars.first, punctuation.contains(scalar) {
                    break
                }
                token.word.append(text[index])
                index = text.index(after: index)
            }
            while index < text.endIndex, !text[index].isWhitespace {
                guard let scalar = text[index].unicodeScalars.first,
                      punctuation.contains(scalar) else { break }
                token.suffix.append(text[index])
                index = text.index(after: index)
            }

            if token.word.isEmpty && token.prefix.isEmpty && token.suffix.isEmpty { break }
            tokens.append(token)
        }

        return tokens.filter { !($0.word.isEmpty && $0.prefix.isEmpty) }
    }
}

// MARK: - View

struct CorrectionView: View {
    @EnvironmentObject private var model: CorrectionModel
    @FocusState private var focused: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Vocabulary", note: "teach a word")
            columns

            ScrollView {
                VStack(spacing: 0) {
                    ForEach($model.tokens) { $token in
                        if !token.isRemoved, !token.word.isEmpty || token.isManual {
                            row($token)
                        }
                    }
                }
            }
            .frame(maxHeight: CorrectionMetrics.rowHeight * CGFloat(CorrectionMetrics.maxRows))

            PanelActions(
                status: summary,
                cancelTitle: "Cancel",
                confirmTitle: "Save",
                onCancel: { model.onCancel?() },
                onConfirm: { model.onSubmit?() }
            )
        }
        .padding(Parrot.panelPadding)
        .frame(width: CorrectionMetrics.width)
        .parrotSurface(RoundedRectangle(cornerRadius: Parrot.panelRadius, style: .continuous))
        .onAppear {
            focused = model.visibleTokens.first(where: { $0.isManual })?.id
                ?? model.visibleTokens.first?.id
        }
        .onExitCommand { model.onCancel?() }
    }

    private var columns: some View {
        HStack(spacing: 12) {
            Text("HEARD AS")
                .frame(width: 150, alignment: .leading)
            Text("SHOULD BE")
            Spacer()
        }
        .font(.system(size: 9, weight: .semibold, design: .rounded))
        .kerning(0.9)
        .foregroundStyle(.quaternary)
        .padding(.bottom, 6)
    }

    private func row(_ token: Binding<CorrectionToken>) -> some View {
        HStack(spacing: 12) {
            Group {
                if token.wrappedValue.isManual {
                    TextField("wrong word", text: token.word)
                        .textFieldStyle(.plain)
                        .focused($focused, equals: token.wrappedValue.id)
                        .onSubmit { model.onSubmit?() }
                        .parrotField(focused: focused == token.wrappedValue.id)
                } else {
                    Text(token.wrappedValue.word)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 150, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(
                    token.wrappedValue.replacement.isEmpty
                        ? AnyShapeStyle(.quaternary)
                        : AnyShapeStyle(Parrot.leaf)
                )

            TextField("leave blank to skip", text: token.replacement)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .focused($focused, equals: token.wrappedValue.id)
                .onSubmit { model.onSubmit?() }
                .parrotField(focused: focused == token.wrappedValue.id)

            Button {
                model.remove(token.wrappedValue.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Leave this word alone")
        }
        .frame(height: CorrectionMetrics.rowHeight)
    }

    private var summary: String {
        switch model.pendingRuleCount {
        case 0: return "Fill in a word to save a rule"
        case 1: return "1 rule to save"
        case let count: return "\(count) rules to save"
        }
    }
}
