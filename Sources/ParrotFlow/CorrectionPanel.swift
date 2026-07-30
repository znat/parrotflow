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
/// Visually a sibling of the recording pill: same translucent material, same
/// hairline border, same place on screen. The words are set in monospace —
/// they are literal strings being mapped to other literal strings, and each
/// row is a line that lands in config.yaml.
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
        panel?.makeKeyAndOrderFront(nil)
    }

    private func commit() {
        let rules = model.rules()
        let corrected = model.correctedText()
        dismiss(cancelled: false)
        onSave?(rules, corrected)
    }

    private func dismiss(cancelled: Bool) {
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
    static let width: CGFloat = 480
    static let rowHeight: CGFloat = 38
    static let maxRows = 7
    private static let chrome: CGFloat = 96

    static func height(forRows rows: Int) -> CGFloat {
        chrome + rowHeight * CGFloat(max(1, min(rows, maxRows)))
    }
}

/// Borderless panels refuse key status, which would leave every field unable
/// to take a keystroke.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
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

    var resolved: String {
        let body = isRemoved || replacement.isEmpty ? word : replacement
        return prefix + body + suffix
    }
}

final class CorrectionModel: ObservableObject {
    @Published var tokens: [CorrectionToken] = []
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    var visibleTokens: [CorrectionToken] {
        tokens.filter { !$0.isRemoved && !$0.word.isEmpty }
    }

    var pendingRuleCount: Int { rules().count }

    func load(selection: String) {
        tokens = Self.tokenize(selection)
        if tokens.isEmpty {
            tokens = [CorrectionToken(word: "")]
        }
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

private struct CorrectionView: View {
    @EnvironmentObject private var model: CorrectionModel
    @FocusState private var focused: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 0) {
                    ForEach($model.tokens) { $token in
                        if !token.isRemoved, !token.word.isEmpty {
                            row($token)
                        }
                    }
                }
            }
            .frame(maxHeight: CorrectionMetrics.rowHeight * CGFloat(CorrectionMetrics.maxRows))

            footer
        }
        .padding(16)
        .frame(width: CorrectionMetrics.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
        .onAppear { focused = model.visibleTokens.first?.id }
        .onExitCommand { model.onCancel?() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("HEARD AS")
                .frame(width: 150, alignment: .leading)
            Text("SHOULD BE")
            Spacer()
        }
        .font(.system(size: 9, weight: .semibold))
        .kerning(0.8)
        .foregroundStyle(.tertiary)
        .padding(.bottom, 8)
    }

    private func row(_ token: Binding<CorrectionToken>) -> some View {
        HStack(spacing: 12) {
            Text(token.wrappedValue.word)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 150, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(
                    token.wrappedValue.replacement.isEmpty
                        ? AnyShapeStyle(.tertiary)
                        : AnyShapeStyle(Color.accentColor)
                )

            TextField("leave blank to skip", text: token.replacement)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .focused($focused, equals: token.wrappedValue.id)
                .onSubmit { model.onSubmit?() }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6).strokeBorder(
                        Color.accentColor.opacity(focused == token.wrappedValue.id ? 0.8 : 0),
                        lineWidth: 1.5
                    )
                )

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

    private var footer: some View {
        HStack(spacing: 14) {
            hint("return", "Save")
            hint("esc", "Cancel")
            Spacer()
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 10)
    }

    private var summary: String {
        switch model.pendingRuleCount {
        case 0: return "Fill in a word to save a rule"
        case 1: return "1 rule"
        case let count: return "\(count) rules"
        }
    }

    private func hint(_ key: String, _ meaning: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 4))
            Text(meaning)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
