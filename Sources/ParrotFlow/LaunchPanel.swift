import AppKit
import Combine
import SwiftUI

/// The surface the app puts up while it is getting its models.
///
/// It exists because a launch that has work to do says nothing. `warmModels`
/// starts up to a gigabyte of fetches in the background and reports them into
/// `ModelDownloads`, and the only place those rows are drawn is the setup
/// window — which does not open on a launch where both permissions are already
/// granted. So an upgrade that adds a model downloads it in silence, and the
/// stages that read it stand aside meanwhile with nothing on screen to say so.
///
/// It is deliberately not the setup window. That screen is a list of everything
/// the app needs and a place to fix what is missing; this one asks nothing. It
/// says what the app is doing, in the app's own face, points at the skill that
/// adapts the app, and goes.
///
/// Revision 08 uses the same adaptive Context surface as the pill: a six-point
/// rounded box, one fine outline, and a crisp three-point hard shadow.
final class LaunchPanel {

    private var panel: NSPanel?
    private var watch: AnyCancellable?
    private var model: LaunchModel?
    private var expiry: DispatchWorkItem?
    private var poll: Timer?

    private let downloads: ModelDownloads

    private static let readySeconds: TimeInterval = 30

    /// What the ready line tells you to hold. Nil when nothing bound, and then
    /// the line is left out rather than naming a key that does nothing.
    var hotkey: String?
    /// Updated with config reloads; a visible panel redraws immediately.
    var primaryColor = ContextIdentity.defaultPrimary {
        didSet { model?.primaryColor = primaryColor }
    }
    /// Updated with config reloads; the system choice also follows macOS live.
    var theme: ContextAppearance = .system {
        didSet { model?.theme = theme }
    }

    init(downloads: ModelDownloads = .shared) {
        self.downloads = downloads
    }

    var isShowing: Bool { panel?.isVisible ?? false }

    /// Asked, not remembered from the last hover: SwiftUI's `onHover` can miss
    /// the exit. Same reasoning as `PillHUD.pointerIsOver`.
    var pointerIsOver: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: LaunchMetrics.bleed, dy: LaunchMetrics.bleed)
            .contains(NSEvent.mouseLocation)
    }

    /// Shows it only if this launch has something to wait for.
    ///
    /// Asked after `warmModels` has declared its rows. A launch with everything
    /// on disk and in memory has nothing to say and says nothing: no flash, no
    /// panel that appears and leaves before it can be read.
    func showIfNeeded(hotkey: String?) {
        self.hotkey = hotkey
        guard LaunchModel.moment(of: downloads.rows) != .ready else { return }
        show()
    }

    func show() {
        if panel == nil { build() }
        // Sized before the rise: `riseIntoView` animates the origin, and a
        // resize during it re-centres on a frame that is still moving.
        panel?.setContentSize(LaunchMetrics.windowSize(for: LaunchModel.moment(of: downloads.rows)))
        position()
        // Never key, and never `NSApp.activate`. This opens on its own at
        // login, while somebody is typing into something else.
        panel?.riseIntoView(makeKey: false)

        // Debounced: a fetch reports every percent, and a layout pass per
        // percent to find the height has not changed is the trap
        // `PermissionsWindowController.resizeToContent` fell into first.
        watch = downloads.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.follow() }
        follow()
    }

    /// Takes the height of the moment, and starts or drops the ready countdown.
    private func follow() {
        guard let model, isShowing else { return }
        resize()
        let ready = model.moment == .ready
        if ready, model.countdown == nil {
            // Not paused when it opens under a still pointer: at login nobody
            // may be there, and a paused panel would stay up until they were.
            apply(Countdown(duration: Self.readySeconds, start: Date()))
        } else if !ready, model.countdown != nil {
            apply(nil)
        }
    }

    /// Takes the height this state needs, keeping the panel where it is.
    ///
    /// `setContentSize` holds the bottom-left corner, so a panel that grew
    /// would climb up the screen and one that shrank would sink. Re-centring on
    /// the old centre keeps it still.
    private func resize() {
        guard let panel, panel.isVisible else { return }
        let size = LaunchMetrics.windowSize(for: LaunchModel.moment(of: downloads.rows))
        guard panel.frame.size != size else { return }
        let centre = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(
            x: centre.x - size.width / 2, y: centre.y - size.height / 2
        ))
    }

    /// Publishes the countdown and arms what its state needs: the expiry while
    /// it runs, the pointer poll while a hover holds it.
    private func apply(_ countdown: Countdown?) {
        disarm()
        model?.countdown = countdown
        switch countdown?.state {
        case .running?:
            guard let deadline = countdown?.deadline else { return }
            let expiry = DispatchWorkItem { [weak self] in self?.dismiss() }
            self.expiry = expiry
            // Wall time, like the bar: uptime stops while the Mac sleeps.
            DispatchQueue.main.asyncAfter(
                wallDeadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: expiry
            )
        case .paused?:
            poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, !self.pointerIsOver else { return }
                self.hovering(false)
            }
        case .expired?:
            dismiss()
        case nil:
            break
        }
    }

    private func disarm() {
        expiry?.cancel()
        expiry = nil
        poll?.invalidate()
        poll = nil
    }

    /// Nothing armed means no countdown, or a panel already fading out.
    private func hovering(_ inside: Bool) {
        guard expiry != nil || poll != nil, var countdown = model?.countdown else { return }
        let before = countdown
        if inside {
            countdown.pause(at: Date())
        } else {
            countdown.resume(at: Date())
        }
        guard countdown != before else { return }
        apply(countdown)
    }

    /// The ready line stays up for 30 seconds, for as long as the pointer is
    /// over the panel, or until the cross closes it.
    ///
    /// The models land when nobody may be looking. A hover says somebody is,
    /// so it holds the panel while they read or copy.
    func dismiss() {
        watch = nil
        disarm()
        guard let panel, panel.isVisible else {
            model?.countdown = nil
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? 0 : 0.22
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            panel.orderOut(nil)
            panel.alphaValue = 1
            // Cleared after the fade: a nil countdown draws the bar full.
            self?.model?.countdown = nil
        }
    }

    private func build() {
        let model = LaunchModel(
            downloads: downloads, hotkey: hotkey, primaryColor: primaryColor,
            theme: theme
        )
        self.model = model
        let hosting = NSHostingView(rootView: LaunchView(
            onHide: { [weak self] in self?.dismiss() },
            onHover: { [weak self] in self?.hovering($0) }
        ).environmentObject(model))
        hosting.frame = NSRect(
            origin: .zero, size: LaunchMetrics.windowSize(for: model.moment)
        )
        hosting.autoresizingMask = [.width, .height]

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The Context shadow is part of the SwiftUI surface and resizes with it.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = nil
        self.panel = panel
    }

    /// Centred, and a little above the middle.
    ///
    /// Dead centre puts it over whatever somebody is reading. The optical
    /// centre is higher than the geometric one anyway, which is where a thing
    /// that introduces itself belongs.
    private func position() {
        guard let panel, let frame = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2 + frame.height * 0.08
        ))
    }
}

enum LaunchMetrics {
    /// The surface, margin included — the same number the window is built at.
    /// Taking these as the content's size instead put the view 60 points
    /// outside its own window, which drew the edge around the margin rather
    /// than around the glass.
    ///
    /// 500 because the ready line's skill command is 347 points at 11-point
    /// monospaced, and its block with the Copy button is about 428.
    static let width: CGFloat = 500
    static let padding: CGFloat = 30

    /// A height per moment, and the window is resized between them. The list
    /// is capped at three rows (see `LaunchModel.shown`), the ready line
    /// carries the skill command, and the short states would sit in a mostly
    /// empty panel at either of those heights.
    static func height(for moment: LaunchModel.Moment) -> CGFloat {
        switch moment {
        case .downloading: return 440
        case .ready: return 380
        case .loading, .stuck: return 280
        }
    }

    /// The window: the surface, plus the margin the material's shadow lands in.
    static func windowSize(for moment: LaunchModel.Moment) -> NSSize {
        NSSize(width: width + bleed * 2, height: height(for: moment) + bleed * 2)
    }
    /// Transparent room for the three-point shadow and one-point outline.
    static let bleed: CGFloat = 7
    static let mark: CGFloat = 54
}

/// What the panel is saying, worked out from the rows the fetches report into.
///
/// A class rather than a computed property on the view because the view has to
/// be handed something that publishes, and `ModelDownloads` publishes rows for
/// a screen that lists all of them. This is the same rows read as one sentence.
final class LaunchModel: ObservableObject {

    enum Moment: Equatable {
        /// Bytes are still arriving. The only state that names anything.
        case downloading
        /// They are all here and going into memory.
        case loading
        /// Nothing a dictation needs is still coming.
        case ready
        /// A model a dictation waits on did not arrive. Named, because the app
        /// cannot transcribe and a panel that kept saying "getting ready" would
        /// be lying.
        case stuck(String)
    }

    let downloads: ModelDownloads
    let hotkey: String?
    @Published var primaryColor: String
    @Published var theme: ContextAppearance
    /// Set by `LaunchPanel` while the ready line is up. Nil on the panel sheet.
    @Published var countdown: Countdown?
    private var watch: AnyCancellable?

    init(
        downloads: ModelDownloads, hotkey: String? = nil,
        primaryColor: String = ContextIdentity.defaultPrimary,
        theme: ContextAppearance = .system
    ) {
        self.downloads = downloads
        self.hotkey = hotkey
        self.primaryColor = primaryColor
        self.theme = theme
        watch = downloads.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var moment: Moment { Self.moment(of: downloads.rows) }

    /// Pinned to the tag of the running build, so the skill matches the app
    /// it configures. Outside a bundle there is no version, and the default
    /// branch is the closest thing.
    static func skillCommand(version: String?) -> String {
        guard let version else { return "npx skills add znat/parrotflow --skill parrotflow" }
        return "npx skills add 'znat/parrotflow#v\(version)@parrotflow'"
    }

    var skillCommand: String { Self.skillCommand(version: Updates.current) }

    static func moment(of rows: [ModelDownload]) -> Moment {
        if let stuck = rows.first(where: { $0.blocking && $0.state.hasFailed }) {
            return .stuck(stuck.name)
        }
        if rows.contains(where: { if case .downloading = $0.state { return true }
                                  if case .waiting = $0.state { return true }
                                  return false }) {
            return .downloading
        }
        if rows.contains(where: { $0.state == .loading }) { return .loading }
        return .ready
    }

    /// The rows worth naming: the ones that are not here yet.
    ///
    /// Installed rows are left out rather than ticked. This is not the setup
    /// screen's inventory — a row that has arrived is not news, and a list that
    /// only ever grows shorter is easier to read than one that never changes
    /// length.
    var coming: [ModelDownload] {
        downloads.rows.filter(\.state.isPending)
    }

    /// At most three rows, in the order the launch declared them.
    ///
    /// A first install has six models to fetch and this is a splash, not the
    /// setup screen's inventory. Three is what the panel is tall enough to
    /// hold, and the heading above them already carries the total. Declaration
    /// order rather than most-advanced-first, so a row never overtakes another
    /// and the list only ever shortens.
    static let listLimit = 3

    var shown: [ModelDownload] { Array(coming.prefix(Self.listLimit)) }

    /// "937 MB", counting only what has not landed.
    var remaining: String? {
        let left = coming.reduce(0.0) { total, row in
            switch row.state {
            case .downloading(let percent):
                return total + Double(row.megabytes) * (1 - Double(percent ?? 0) / 100)
            // The bytes are already here; what is left is a load, not a
            // download. Counted whole, a row that had finished downloading kept
            // its full size in the figure.
            case .loading, .installed:
                return total
            case .waiting, .off, .failed:
                return total + Double(row.megabytes)
            }
        }
        guard left >= 1 else { return nil }
        return ModelDownloads.size(megabytes: Int(left.rounded()))
    }
}

// MARK: - The panel

struct LaunchView: View {
    @EnvironmentObject private var model: LaunchModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var scale
    let onHide: () -> Void
    var onHover: (Bool) -> Void = { _ in }

    private var theme: ContextTheme {
        ContextTheme(scheme: effectiveColorScheme, primaryHex: model.primaryColor)
    }

    private var effectiveColorScheme: ColorScheme {
        model.theme.resolved(against: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            ContextVoiceMark(color: theme.accent)
                .frame(width: LaunchMetrics.mark, height: LaunchMetrics.mark)

            Text(AppVariant.displayName)
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(theme.foreground)
                .padding(.top, 14)

            switch model.moment {
            case .loading:
                Breath(text: "Loading models")
            case .ready:
                ready
            case .stuck(let name):
                VStack(spacing: 18) {
                    Text("\(name) did not arrive. Open Setup… from the menu bar.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.failure)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                    Button("Got it", action: onHide)
                        .buttonStyle(ContextLaunchButton(primary: true))
                }
                .padding(.top, 14)
            case .downloading:
                downloading
            }
        }
        .frame(
            width: LaunchMetrics.width - LaunchMetrics.padding * 2,
            height: LaunchMetrics.height(for: model.moment) - LaunchMetrics.padding * 2
        )
        .padding(LaunchMetrics.padding)
        .background {
            surfaceShape.fill(theme.hardShadow)
                .offset(x: ContextIdentity.shadowOffset, y: ContextIdentity.shadowOffset)
            surfaceShape.fill(theme.surface)
        }
        .overlay {
            if model.moment == .ready {
                countdownBar.clipShape(surfaceShape)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.moment == .ready {
                LaunchClose(theme: theme, action: onHide).padding(10)
            }
        }
        .overlay {
            surfaceShape.strokeBorder(theme.edge, lineWidth: 1 / scale)
        }
        .onHover(perform: onHover)
        .padding(LaunchMetrics.bleed)
        .foregroundStyle(theme.foreground)
        .environment(\.contextPrimaryColor, model.primaryColor)
        .environment(\.colorScheme, effectiveColorScheme)
    }

    private var surfaceShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ContextIdentity.radius, style: .continuous)
    }

    /// How long the ready line has left, draining toward the right edge.
    private var countdownBar: some View {
        let countdown = model.countdown
        let paused = countdown?.isPaused ?? true
        return TimelineView(.animation(minimumInterval: nil, paused: paused)) { context in
            GeometryReader { geometry in
                theme.accent
                    .frame(
                        width: geometry.size.width * (countdown?.fraction(at: context.date) ?? 1),
                        height: 3
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .opacity(countdown?.isPaused == true ? 0.45 : 1)
        .allowsHitTesting(false)
    }

    private var ready: some View {
        VStack(spacing: 0) {
            readyLine
            Rectangle()
                .fill(theme.controlEdge)
                .frame(height: 1 / scale)
                .padding(.vertical, 20)
            skillOffer
        }
        .padding(.top, 15)
    }

    /// Without a bound key there is nothing to hold, so the line goes rather
    /// than naming one that does nothing. See `SetupPane.unregisteredHotkey`.
    @ViewBuilder
    private var readyLine: some View {
        if let hotkey = model.hotkey {
            HStack(spacing: 7) {
                Text("Hold")
                Text(hotkey)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.foreground)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 2)
                    .background(theme.accent.opacity(0.13), in: RoundedRectangle(
                        cornerRadius: 4, style: .continuous
                    ))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(theme.accent.opacity(0.65), lineWidth: 1)
                    }
                Text("to dictate")
            }
            .font(.system(size: 14))
            .foregroundStyle(theme.muted)
        } else {
            Text("Ready")
                .font(.system(size: 14))
                .foregroundStyle(theme.muted)
        }
    }

    private var skillOffer: some View {
        VStack(spacing: 12) {
            (Text("Adapt ParrotFlow to your work in minutes")
                .fontWeight(.medium)
                .foregroundStyle(theme.foreground)
             + Text(" with the skill:").foregroundStyle(theme.muted))
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            SkillCommandBlock(command: model.skillCommand, theme: theme)
        }
    }

    /// The one state that names the models.
    ///
    /// It names them because it is the one that takes minutes, and a wait you
    /// are given no reason for is longer than the same wait explained. Loading
    /// takes seconds and says nothing but its own name.
    private var downloading: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heading)
                .font(.system(size: 13))
                .foregroundStyle(theme.muted)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 16)

            ForEach(model.shown) { row in
                LaunchRow(row: row, theme: theme)
            }

            Text("These models improve your dictation by understanding what you meant.")
                .font(.system(size: 12.5))
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            HStack {
                Spacer()
                Button("Hide", action: onHide)
                    .buttonStyle(ContextLaunchButton())
            }
            .padding(.top, 15)
        }
        .padding(.top, 22)
    }

    private var heading: String {
        let count = model.coming.count
        let models = count == 1 ? "one model" : "\(count) models"
        guard let remaining = model.remaining else { return "Downloading \(models)" }
        return "Downloading \(models) · \(remaining) left"
    }
}

/// One model on its way, and how far it has got.
private struct LaunchRow: View {
    let row: ModelDownload
    let theme: ContextTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(row.name)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.foreground)
                Spacer(minLength: 8)
                if let note {
                    Text(note)
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(theme.muted.opacity(row.state == .loading ? 0.7 : 1))
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.foreground.opacity(0.12))
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 2)
        }
        .padding(.bottom, 11)
    }

    private var note: String? {
        switch row.state {
        case .downloading(let percent): return percent.map { "\($0)%" }
        case .loading: return "loading"
        case .waiting, .installed, .off, .failed: return nil
        }
    }

    /// A bar that is full but not ticked is what loading looks like: the bytes
    /// are all here and the model is not.
    private var fraction: CGFloat {
        switch row.state {
        case .downloading(let percent): return CGFloat(percent ?? 0) / 100
        case .loading, .installed: return 1
        case .waiting, .off, .failed: return 0
        }
    }
}

/// The skill command on one line, and a button that copies it.
private struct SkillCommandBlock: View {
    let command: String
    let theme: ContextTheme
    @State private var copiedAt: Date?

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .fixedSize()
            Button(action: copy) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                    // Held at the width of "Copied" so the block does not
                    // reflow on a click.
                    ZStack(alignment: .leading) {
                        Text("Copied").hidden()
                        Text(copiedAt == nil ? "Copy" : "Copied")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(copiedAt == nil ? theme.muted : theme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.controlFill, in: RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4).strokeBorder(theme.controlEdge, lineWidth: 1)
        }
        .task(id: copiedAt) {
            guard copiedAt != nil else { return }
            guard (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            copiedAt = nil
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copiedAt = Date()
    }
}

/// The way out of the ready line before its countdown ends.
private struct LaunchClose: View {
    let theme: ContextTheme
    let action: () -> Void
    @State private var hot = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(hot ? theme.foreground : theme.muted)
                .frame(width: 20, height: 20)
                .background(
                    hot ? theme.foreground.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hot = $0 }
        .accessibilityLabel("Close")
    }
}

/// A line that breathes, for a wait with no number on it.
private struct Breath: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.contextPrimaryColor) private var primaryColor
    @State private var lit = false

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(theme.muted.opacity(lit || reduceMotion ? 1 : 0.65))
            .padding(.top, 14)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    lit = true
                }
            }
    }

    private var theme: ContextTheme {
        ContextTheme(scheme: colorScheme, primaryHex: primaryColor)
    }
}

private struct ContextLaunchButton: ButtonStyle {
    var primary = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.contextPrimaryColor) private var primaryColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: primary ? 13 : 12, weight: primary ? .medium : .regular))
            .foregroundStyle(theme.foreground.opacity(configuration.isPressed ? 0.65 : 1))
            .padding(.horizontal, primary ? 20 : 13)
            .padding(.vertical, primary ? 7 : 5)
            .background(
                primary ? theme.accent.opacity(configuration.isPressed ? 0.12 : 0.18)
                    : theme.controlFill,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4).strokeBorder(
                    primary ? theme.accent : theme.controlEdge,
                    lineWidth: primary ? 1 : 0.5
                )
            }
    }

    private var theme: ContextTheme {
        ContextTheme(scheme: colorScheme, primaryHex: primaryColor)
    }
}
