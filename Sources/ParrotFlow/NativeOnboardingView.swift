import AppKit
import SwiftUI

/// The approved tour, composed of the same SwiftUI surfaces as the live HUD.
/// Its sole input is a clock, so replay, seeking and still renders agree.
struct NativeOnboardingView: View {
    static let width: CGFloat = 940
    static let height: CGFloat = 700
    static let filmHeight: CGFloat = 620
    let elapsed: TimeInterval
    var showsControls = true
    var progress: Double?
    var fetching: String?
    var paused = false
    var seek: (TimeInterval) -> Void = { _ in }
    var togglePause: () -> Void = {}
    var finish: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.contextPrimaryColor) private var primary
    private var theme: ContextTheme { .init(scheme: .dark, primaryHex: primary) }
    private var position: (index: Int, clock: TimeInterval) { OnboardingTour.at(elapsed) }
    private var example: OnboardingTour.Example { OnboardingTour.examples[position.index] }
    private var frame: OnboardingTour.Frame {
        .init(example: example, clock: reduceMotion ? example.duration : position.clock)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            heading
                .font(.system(size: 28, weight: .medium))
                .padding(.top, 24).padding(.bottom, 22)
            HStack(alignment: .top, spacing: 24) {
                if !example.code.isEmpty {
                    configuration.frame(width: 330, height: 340, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: 16) {
                    composer.frame(height: 340, alignment: .topLeading)
                    speech
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 12)
            if showsControls { footer }
        }
        .padding(28)
        .frame(width: Self.width - ContextIdentity.shadowOffset,
               height: (showsControls ? Self.height : Self.filmHeight) - ContextIdentity.shadowOffset)
        .foregroundStyle(theme.foreground)
        .contextSurface(RoundedRectangle(cornerRadius: 8), border: theme.edge, theme: theme)
        .tourSpotlight(frame.spotlightAmount)
        .padding(.trailing, ContextIdentity.shadowOffset)
        .padding(.bottom, ContextIdentity.shadowOffset)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ContextVoiceMark(color: theme.accent).frame(width: 22, height: 22)
            Text(AppVariant.displayName).font(.system(size: 16, weight: .medium))
            Spacer()
            if let progress {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(progress >= 1 ? "Models downloaded" : "Downloading models")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(Int(min(1, max(0, progress)) * 100))%")
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .foregroundStyle(theme.foreground)
                    ProgressView(value: min(1, max(0, progress)))
                        .tint(theme.accent)
                        .accessibilityLabel("Model download progress")
                    Text(progress >= 1 ? "Ready for local dictation."
                         : "Setup continues while you watch the tour.")
                        .font(.system(size: 11))
                    if progress < 1, let fetching {
                        Text(fetching).font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                .frame(width: 310)
                .foregroundStyle(theme.muted)
                .anchorPreference(key: TourSpot.self, value: .bounds) {
                    [.init(box: $0, soft: false, group: "download-status")]
                }
            }
        }
    }

    private var heading: Text {
        if example.section == 1 {
            let changed = position.index == 0 || OnboardingTour.examples[position.index - 1].headingTerm != example.headingTerm
            let term = example.headingTerm.enumerated().reduce(Text("")) { text, glyph in
                text + Text(String(glyph.element)).foregroundColor(theme.accent.opacity(
                    changed ? frame.revealOpacity(at: glyph.offset, count: example.headingTerm.count) : 1
                ))
            }
            return Text("Enrich your dictation with ")
                + term
        }
        return Text(example.heading)
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(example.file).foregroundStyle(theme.muted)
                .padding(.horizontal, 16).frame(height: 42)
            Rectangle().fill(theme.controlEdge).frame(height: 1)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(example.code.enumerated()), id: \.offset) { index, line in
                    codeText(at: index)
                        .fixedSize(horizontal: false, vertical: true)
                        .tourFocus(frame.mapped || (line.offer && frame.offering), group: "yaml-block")
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(16)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surface)
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.controlEdge))
    }

    private func codeText(at index: Int) -> Text {
        let tokens = TourYAML.highlight(example.code.map(\.text))[index]
        if tokens.isEmpty { return Text(" ") }
        return tokens.reduce(Text("")) { text, token in
            let color: Color
            switch token.tone {
            case .plain: color = theme.foreground
            case .key: color = Color(red: 0.65, green: 0.78, blue: 0.96)
            case .string: color = Color(red: 0.73, green: 0.83, blue: 0.65)
            case .literal: color = Color(red: 0.90, green: 0.72, blue: 0.53)
            case .punctuation: color = theme.muted
            case .comment: color = Color(red: 0.53, green: 0.55, blue: 0.63)
            }
            return text + Text(token.text).foregroundColor(color)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 5) {
                ForEach(0..<3) { _ in Circle().fill(theme.muted.opacity(0.5)).frame(width: 5, height: 5) }
                Text("Message").font(.system(size: 11, design: .monospaced)).padding(.leading, 6)
                Spacer()
            }
            .foregroundStyle(theme.muted)
            ChatComposerFrame(size: 17, contextTheme: theme) {
                message.frame(minHeight: 40, alignment: .topLeading)
            }
            if frame.offering {
                nativePill(.offer(Self.commands, nil, Confidence.Reading(), open: true),
                           pressedKey: frame.pressingKey ? 1 : nil)
                    .environment(\.tourHighlightedCommand, 1)
            } else if example.learned != nil && frame.beatClock >= 6.2 {
                Text("Remembered in context").font(.system(size: 12)).foregroundStyle(theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.controlFill, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.controlEdge))
        .overlay(alignment: .bottomLeading) {
            // Like the live learning dialog, this floats above the destination
            // app. It must not resize the composer or push into the transcript.
            if frame.learning, let learn = example.learned {
                nativePill(
                    .offer(TutorialExample.chips, .learn(.init(term: learn.term, heard: learn.heard,
                        before: learn.before, after: learn.after)), Confidence.Reading(), open: true),
                    pressedKey: frame.pressingKey ? 0 : nil, lit: true
                )
                .padding(.leading, 16).padding(.bottom, 8)
            }
        }
    }

    private var message: some View {
        TourWordFlow(spacing: 4, lineSpacing: 5) {
            ForEach(Array(frame.message.split(separator: " ").enumerated()), id: \.offset) { _, word in
                let highlighted = frame.mapped && example.highlights.contains(String(word))
                Text(word).foregroundStyle(highlighted ? theme.accent : theme.foreground)
                    .tourFocus(highlighted, group: "output")
            }
            Rectangle().fill(theme.accent)
                .frame(width: 2, height: 20)
                .opacity(reduceMotion || position.clock.truncatingRemainder(dividingBy: 1) < 0.55 ? 1 : 0.25)
        }
        .font(.system(size: 17))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(frame.message.isEmpty ? "Empty message composer" : frame.message)
    }

    private var speech: some View {
        HStack(alignment: .top, spacing: 14) {
            nativePill(frame.listening ? .recording(nil) : frame.transcribing ? .working("Transcribing") : .offer(Self.commands, nil, Confidence.Reading(), open: false))
                .frame(width: 108)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(frame.clock < example.listeningEnd && !reduceMotion ? "You’re saying" : "You said")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.muted)
                spokenText
                    .font(.system(size: 19).italic())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("“\(example.spoken)”")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 76, alignment: .topLeading)
    }

    private static let commands = [OfferedCommand(title: "Grammar", key: "G"), OfferedCommand(title: "Slack mentions", key: "S")]

    /// Reserve the complete sentence's wrapping from the first frame; reveal
    /// glyphs with a soft moving edge rather than appending whole-word chunks.
    private var spokenText: some View {
        let replaced = example.replacedSpeechCharacters
        let words = "“\(example.spoken)”".components(separatedBy: " ")
        return TourWordFlow(spacing: 4, lineSpacing: 5) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                let offset = words.prefix(index).reduce(0) { $0 + $1.count + 1 }
                let highlighted = frame.mapped && word.indices.contains { position in
                    replaced.contains(offset + word.distance(from: word.startIndex, to: position) - 1)
                }
                word.enumerated().reduce(Text("")) { text, glyph in
                    let matched = frame.mapped && replaced.contains(offset + glyph.offset - 1)
                    return text + Text(String(glyph.element))
                        .foregroundColor((matched ? Color(white: 0.82) : Color(white: 0.72))
                            .opacity(frame.speechOpacity(at: offset + glyph.offset)))
                }
                .tourFocus(highlighted, group: "speech")
            }
        }
    }

    private func nativePill(_ state: PillState, pressedKey: Int? = nil, lit: Bool = false) -> some View {
        let size = PillMetrics.panelSize(for: state, hasIcon: true, hotkey: Tutorial.hotkey, dock: .below)
        return TourPill(state: state, level: frame.listening ? 0.3 + abs(sin(position.clock * 12)) * 0.65 : 0,
                        clicked: pressedKey, reserved: size, lit: lit)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button("Skip tour", action: finish)
            Spacer()
            Button(paused ? "Play" : "Pause", action: togglePause)
                .accessibilityLabel(paused ? "Play tour" : "Pause tour")
            Button("Replay") { seek(OnboardingTour.starts[position.index]) }
            Button("Back") { seek(OnboardingTour.starts[max(0, position.index - 1)]) }
                .disabled(position.index == 0)
            Button(position.index == OnboardingTour.examples.count - 1 ? "Finish" : "Continue") {
                if position.index == OnboardingTour.examples.count - 1 { finish() }
                else { seek(OnboardingTour.starts[position.index + 1]) }
            }
            .keyboardShortcut(.defaultAction)
        }
        .buttonStyle(.borderless).tint(theme.accent)
        .font(.system(size: 12))
    }
}

/// Per-word layout lets the existing spotlight follow just the changed terms,
/// even when a sentence wraps. No screen coordinates or duplicate text layer.
struct TourWordFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        positions(width: proposal.width ?? 450, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = positions(width: bounds.width, subviews: subviews)
        for (index, point) in layout.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                 proposal: .unspecified)
        }
    }
    private func positions(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        var points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + lineSpacing; row = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            row = max(row, size.height)
        }
        return (CGSize(width: width, height: y + row), points)
    }
}

extension View {
    func tourFocus(_ active: Bool, group: String? = nil) -> some View {
        anchorPreference(key: TourSpot.self, value: .bounds) { active ? [.init(box: $0, soft: false, group: group)] : [] }
    }
}

private struct TourHighlightedCommandKey: EnvironmentKey { static let defaultValue: Int? = nil }
extension EnvironmentValues {
    var tourHighlightedCommand: Int? {
        get { self[TourHighlightedCommandKey.self] }
        set { self[TourHighlightedCommandKey.self] = newValue }
    }
}
