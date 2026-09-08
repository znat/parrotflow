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
/// the app needs and a place to fix what is missing; this one asks nothing and
/// offers nothing but the door. It says what the app is doing, in the app's own
/// face, and goes.
///
/// Glass rather than the near-black ground the other panels take. Every Mac
/// that runs ParrotFlow is Apple silicon and every Apple silicon Mac runs
/// macOS 26, so `ParrotGlass` is the platform material here rather than a
/// fallback anybody sees. See `ParrotGlass.isPlatform`.
final class LaunchPanel {

    private var panel: NSPanel?
    private var watch: AnyCancellable?
    /// Which of the two heights the window is currently built at.
    private var listing = false

    private let downloads: ModelDownloads

    /// What the ready line tells you to hold. Nil when nothing bound, and then
    /// the line is left out rather than naming a key that does nothing.
    var hotkey: String?

    init(downloads: ModelDownloads = .shared) {
        self.downloads = downloads
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
        position()
        // Never key, and never `NSApp.activate`. This opens on its own at
        // login, while somebody is typing into something else.
        panel?.riseIntoView(makeKey: false)

        // The rows come and go, so the panel is two heights and has to be
        // resized between them. Debounced: a fetch reports every percent, and
        // a layout pass per percent to find the height has not changed is the
        // trap `PermissionsWindowController.resizeToContent` fell into first.
        watch = downloads.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.resize() }
    }

    /// Takes the height this state needs, keeping the panel where it is.
    ///
    /// `setContentSize` holds the bottom-left corner, so a panel that grew
    /// would climb up the screen and one that shrank would sink. Re-centring on
    /// the old centre keeps it still.
    private func resize() {
        guard let panel, panel.isVisible else { return }
        let wanted = LaunchModel.moment(of: downloads.rows) == .downloading
        guard wanted != listing else { return }
        listing = wanted
        let centre = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let size = LaunchMetrics.windowSize(listing: wanted)
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(
            x: centre.x - size.width / 2, y: centre.y - size.height / 2
        ))
    }

    /// It waits to be dismissed. Nothing takes it down on a timer.
    ///
    /// The last thing it says is which key to hold, and that is the one
    /// sentence a first launch exists to deliver. A panel that reached it and
    /// then faded on its own would deliver it to an empty chair — the moment
    /// the models land is not the moment somebody is looking. So the end of
    /// this panel is a person pressing a button, and the button is the receipt
    /// that they read the line above it.
    func dismiss() {
        watch = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    private func build() {
        let model = LaunchModel(downloads: downloads, hotkey: hotkey)
        let hosting = NSHostingView(rootView: LaunchView(onHide: { [weak self] in
            self?.dismiss()
        }).environmentObject(model))
        listing = LaunchModel.moment(of: downloads.rows) == .downloading
        hosting.frame = NSRect(origin: .zero, size: LaunchMetrics.windowSize(listing: listing))
        hosting.autoresizingMask = [.width, .height]

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = ParrotGlass.container(
            hosting, radius: Parrot.panelRadius, inset: LaunchMetrics.bleed,
            // Lighter than the preview panel's. Nothing here is selected or
            // read word by word — it is a name, a sentence and three numbers,
            // and the material's own legibility pass carries them.
            tint: NSColor.black.withAlphaComponent(0.12)
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The bloom bleeds into the margin, so a window shadow would trace the
        // blur rather than the panel. Same reason as every other surface here.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.adoptParrotAppearance()
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
    static let width: CGFloat = 440
    static let padding: CGFloat = 30

    /// A list, and a line. The panel is two heights, and the window is resized
    /// between them.
    ///
    /// One fixed height does not work. It was fixed, at what three rows need,
    /// and a first install declares six: the sentence and the button were
    /// pushed out of the panel. The list is capped now — see `LaunchModel.shown`
    /// — and the short states would sit in a mostly empty panel if they were
    /// held at the tall one.
    static let listed: CGFloat = 440
    static let plain: CGFloat = 280

    static func height(listing: Bool) -> CGFloat { listing ? listed : plain }

    /// The window: the surface, plus the margin the material's shadow lands in.
    static func windowSize(listing: Bool) -> NSSize {
        NSSize(width: width + bleed * 2, height: height(listing: listing) + bleed * 2)
    }
    /// Transparent room around the panel. It held the bloom, which has gone;
    /// it is kept because the material casts its own shadow and a window with
    /// no margin clips it square at the edge.
    static let bleed: CGFloat = 34
    static let bird: CGFloat = 76
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
    private var watch: AnyCancellable?

    init(downloads: ModelDownloads, hotkey: String? = nil) {
        self.downloads = downloads
        self.hotkey = hotkey
        watch = downloads.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var moment: Moment { Self.moment(of: downloads.rows) }

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

private struct LaunchView: View {
    @EnvironmentObject private var model: LaunchModel
    let onHide: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PlumageBird(size: LaunchMetrics.bird)

            // New York. The three the design pass left open were serif,
            // rounded and wide caps; this is the one surface in the app that is
            // only the app saying its own name, and nothing else here is set in
            // a serif.
            Text(AppVariant.displayName)
                .font(.system(size: 31, weight: .medium, design: .serif))
                .foregroundStyle(.white.opacity(0.96))
                .padding(.top, 16)

            switch model.moment {
            case .loading:
                Breath(text: "Loading models")
            case .ready:
                ready
            case .stuck(let name):
                VStack(spacing: 18) {
                    Text("\(name) did not arrive. Open Setup… from the menu bar.")
                        .font(.system(size: 13))
                        .foregroundStyle(Parrot.scarlet)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                    Button("Got it", action: onHide)
                        .buttonStyle(GlassPill(tinted: true))
                }
                .padding(.top, 14)
            case .downloading:
                downloading
            }
        }
        .frame(
            width: LaunchMetrics.width - LaunchMetrics.padding * 2,
            height: LaunchMetrics.height(listing: model.moment == .downloading)
                - LaunchMetrics.padding * 2
        )
        .padding(LaunchMetrics.padding)
        // Nothing is painted over the material: `parrotSurface` skips its own
        // scrim and sheen where the platform has Liquid Glass.
        //
        // `rim: false`, which is the one place this surface parts company with
        // the pill and the dialogs. The plumage rim is how a hand-drawn dark
        // panel says where it ends and that it is the app's; Liquid Glass draws
        // its own edge and lights it, so a turning rim on top is a second
        // border arguing with the first. What is left is the plain hairline the
        // rim carried on its inside anyway.
        // `edge: .clear` as well, so nothing of ours is drawn on the boundary
        // at all. The material has its own lit edge; a hairline of ours beside
        // it is a second line a fraction away from the first, which is what a
        // rendering glitch looks like.
        //
        // No bloom either. It is the rim's colours blurred and thrown past the
        // edge, so with no rim it was a coloured fringe with nothing making it
        // — warm on one corner, cool on the other, and reading as a halo the
        // compositor had got wrong.
        .parrotSurface(
            RoundedRectangle(cornerRadius: Parrot.panelRadius, style: .continuous),
            glass: true,
            rim: false,
            edge: .clear
        )
        .padding(LaunchMetrics.bleed)
    }

    /// Without a bound key there is nothing to hold, so the line goes rather
    /// than naming one that does nothing. See `SetupPane.unregisteredHotkey`.
    @ViewBuilder
    private var ready: some View {
        if let hotkey = model.hotkey {
            VStack(spacing: 18) {
                HStack(spacing: 7) {
                    Text("Hold")
                Text(hotkey)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.96))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.14), in: RoundedRectangle(
                        cornerRadius: Parrot.fieldRadius, style: .continuous
                    ))
                    .overlay {
                        RoundedRectangle(cornerRadius: Parrot.fieldRadius, style: .continuous)
                            .strokeBorder(Parrot.action.opacity(0.6), lineWidth: 1.5)
                    }
                    Text("to dictate")
                }
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.72))

                Button("Got it", action: onHide)
                    .buttonStyle(GlassPill(tinted: true))
            }
            .padding(.top, 15)
        } else {
            VStack(spacing: 18) {
                Text("Ready")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.72))
                Button("Got it", action: onHide)
                    .buttonStyle(GlassPill(tinted: true))
            }
            .padding(.top, 15)
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
                .foregroundStyle(.white.opacity(0.62))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 16)

            ForEach(model.shown) { row in
                LaunchRow(row: row)
            }

            Text("These models improve your dictation by understanding what you meant.")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            HStack {
                Spacer()
                Button("Hide", action: onHide)
                    .buttonStyle(GlassPill())
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

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(row.name)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 8)
                if let note {
                    Text(note)
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(row.state == .loading ? 0.6 : 0.85))
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule()
                        .fill(Parrot.mix(Parrot.sky, .white, 0.35))
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

/// A line that breathes, for a wait with no number on it.
private struct Breath: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(lit ? 1 : 0.6))
            .padding(.top, 14)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    lit = true
                }
            }
    }
}

/// The bird at a size no menu bar drawing has.
///
/// `Resources/parrot.svg` is the drawing the icons are cut from, and AppKit
/// renders SVG natively, so it is the one asset that is sharp at 76 points. The
/// PNGs stop at 72 pixels — 24 points — and are the fallback for a build that
/// did not copy the drawing in.
struct PlumageBird: View {
    var size: CGFloat = 76

    var body: some View {
        Group {
            if let drawing {
                Image(nsImage: drawing)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if let solid = NSImage(named: "ParrotSolid") {
                LinearGradient(
                    colors: [Parrot.scarlet, Parrot.amber, Parrot.leaf, Parrot.sky],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .mask {
                    Image(nsImage: solid)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                }
            }
        }
        .frame(width: size * 46 / 68, height: size)
    }

    private var drawing: NSImage? {
        guard let url = Bundle.main.url(forResource: "parrot", withExtension: "svg")
        else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// What `.buttonStyle(.glass)` gives on macOS 26, spelled out here because the
/// deployment target is 14 and the style is not available below it.
private struct GlassPill: ButtonStyle {
    /// The one button on the panel that is being asked for, rather than
    /// offered. `Glass.regular.tint(_)` is the same idea on macOS 26.
    var tinted = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: tinted ? 13 : 12, weight: tinted ? .medium : .regular))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.6 : 0.92))
            .padding(.horizontal, tinted ? 20 : 13)
            .padding(.vertical, tinted ? 7 : 5)
            .background(fill(pressed: configuration.isPressed), in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    tinted ? Parrot.action.opacity(0.5) : .white.opacity(0.14),
                    lineWidth: tinted ? 1 : 0.5
                )
            }
    }

    private func fill(pressed: Bool) -> AnyShapeStyle {
        guard tinted else {
            return AnyShapeStyle(Color.white.opacity(pressed ? 0.06 : 0.12))
        }
        return AnyShapeStyle(Parrot.action.opacity(pressed ? 0.22 : 0.38))
    }
}
