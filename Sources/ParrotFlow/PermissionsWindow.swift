import AppKit
import Combine
import SwiftUI

/// The two things macOS will not let this app do without being asked.
///
/// Both are required, and the walk is not skippable: the only way past a screen
/// is to grant it, and the only other button quits. The microphone is what the
/// app hears with, accessibility is what it writes and reads selections with,
/// and an install missing either is one that fails later, quietly, at the
/// moment someone is trying to use it — which is a worse place to find out.
/// Why the window is open, which decides what the second button says and does.
///
/// The same screen means two different things at two moments. During setup a
/// permission is a condition of having the app at all, and the way out is to
/// stop installing it. Afterwards the app is installed, running, and in the
/// menu bar — "cancel installation" there would be a threat about something
/// that already happened, and pressing it would quit an app the user opened a
/// window from. So the way out becomes a skip, and the window gets its close
/// button back.
enum PermissionsContext {
    case installing
    case revisiting

    /// Setting up has one way out and it does what it says: the app quits.
    /// Both permissions are required, and a requirement you can walk past is
    /// not one. Revisiting has no installation left to cancel.
    var declineTitle: String {
        self == .installing ? "Cancel installation" : "Not now"
    }
}

enum PermissionStep: CaseIterable {
    case microphone
    case accessibility

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        }
    }

    /// Says only why this permission, not what the app is or how it works —
    /// one sentence, read once, standing between someone and the thing they
    /// just installed.
    var reason: String {
        switch self {
        case .microphone:
            return "ParrotFlow needs microphone access to turn what you say into text."
        case .accessibility:
            return "ParrotFlow needs Accessibility access to type that text into "
                + "the app you're using."
        }
    }

    /// Named for what pressing it does, not for what it is for. Neither button
    /// grants anything: one makes macOS ask, the other opens the pane where you
    /// answer. Saying "Allow" would take credit for a decision this app does
    /// not get to make, and then the system dialog would read as a second ask.
    var actionTitle: String {
        switch self {
        case .microphone: return "Show the macOS prompt"
        case .accessibility: return "Open System Settings"
        }
    }

    /// The same on both screens, and different in the two contexts.
    func declineTitle(in context: PermissionsContext) -> String {
        context.declineTitle
    }

    /// Shown after the ask, while the answer is somewhere else.
    var waiting: String {
        switch self {
        case .microphone:
            return "Answer the prompt macOS just put up."
        case .accessibility:
            return "Find ParrotFlow in the list and tick it. This window updates itself."
        }
    }
}

/// A screen in the walk. The permissions are asked for one at a time; the
/// downloads are one screen that reports on all of them.
enum SetupStep: Equatable {
    case permission(PermissionStep)
    case downloads
}

final class PermissionsModel: ObservableObject {
    @Published var micStatus: Permissions.Status = .notDetermined
    @Published var axStatus: Permissions.Status = .notGranted
    @Published var axBlocker: String?
    /// Pushed from AppDelegate.handleTranscriberStatus, not polled — nothing
    /// in this file can ask the transcriber actor anything, and this window
    /// is not the one place that needs to know. Defaults to `.ready` rather
    /// than an "unknown" third case: a launch that never touches the
    /// transcriber (transcription disabled) should not sit on a
    /// "downloading" message forever for a download that will never start.
    @Published var speechModel: SpeechModelProgress = .ready
    /// Pushed from AppDelegate.updateUI, but only the name of a hotkey that
    /// actually registered — the menu bar's own fallback text (the
    /// *configured* key, shown even when registration failed) would tell
    /// someone to press a key that does nothing, in the one screen whose
    /// whole job is telling them what to press.
    @Published var hotkeyDisplay: String = "your hotkey"
    @Published var hotkeyRegistered: Bool = true
    /// Whether espeak-ng is on this Mac. Polled on the same timer as the
    /// permissions, so a Terminal install lands on the row without a button.
    @Published var espeak: EspeakPresence = .missing

    /// Every model this launch is fetching. Held so `begin` can tell whether
    /// there is a Downloads step at all; the panes observe the same object as
    /// an environment object.
    let downloads: ModelDownloads

    init(downloads: ModelDownloads = .shared) {
        self.downloads = downloads
    }

    enum EspeakPresence: Equatable {
        case missing
        /// Terminal has been opened on the command. Nothing to press until it
        /// lands or does not.
        case opening
        case found
    }

    enum SpeechModelProgress: Equatable {
        case ready
        case preparing(percent: Int?)
    }

    /// What is left to ask for, fixed when the window opens.
    ///
    /// Fixed rather than recomputed so "1 of 2" does not become "1 of 1" under
    /// the reader the moment they grant the first one — a counter that changes
    /// its own total reads as the app losing count.
    @Published private(set) var steps: [SetupStep] = []
    @Published private(set) var index = 0
    /// The system has been asked and the answer is not here yet.
    @Published private(set) var asked = false
    @Published private(set) var context: PermissionsContext = .installing

    var current: SetupStep? { steps.indices.contains(index) ? steps[index] : nil }

    func status(of step: PermissionStep) -> Permissions.Status {
        switch step {
        case .microphone: return micStatus
        case .accessibility: return axStatus
        }
    }

    func refresh() {
        micStatus = Permissions.microphone
        axStatus = Permissions.accessibility
        axBlocker = Permissions.accessibilityBlocker
    }

    /// Start the walk. Anything already granted is not a screen — nobody needs
    /// to be told about a permission they have given.
    ///
    /// The Downloads step is always the last one, granted permissions or not.
    /// It reports fetches that started at launch rather than starting them, so
    /// there is nothing to skip past — except on a launch that fetches nothing
    /// at all, where the registry is empty and the step would be blank.
    func begin(context: PermissionsContext) {
        self.context = context
        refresh()
        espeak = Phonemes.locate() == nil ? .missing : .found
        steps = PermissionStep.allCases
            .filter { status(of: $0) != .granted }
            .map(SetupStep.permission)
        if !downloads.rows.isEmpty { steps.append(.downloads) }
        index = 0
        asked = false
    }

    func markAsked() { asked = true }

    /// The way forward from a step that is not asking for anything: the
    /// Downloads step's Continue, and the skip a revisit offers.
    func skip() {
        guard index < steps.count else { return }
        index += 1
        asked = false
    }

    /// Parked on one step, for `--panel-sheet`. The statuses are left at their
    /// defaults, which is what a first launch actually shows.
    static func showing(
        _ step: PermissionStep, asked: Bool = false, context: PermissionsContext = .installing
    ) -> PermissionsModel {
        let model = PermissionsModel()
        model.context = context
        model.steps = PermissionStep.allCases.map(SetupStep.permission) + [.downloads]
        model.index = PermissionStep.allCases.firstIndex(of: step) ?? 0
        model.asked = asked
        return model
    }

    /// Parked on the Downloads step, for `--panel-sheet` and `--panels setup`.
    static func showingDownloads(
        _ downloads: ModelDownloads, context: PermissionsContext = .installing,
        espeak: EspeakPresence = .missing
    ) -> PermissionsModel {
        let model = PermissionsModel(downloads: downloads)
        model.context = context
        model.steps = PermissionStep.allCases.map(SetupStep.permission) + [.downloads]
        model.index = PermissionStep.allCases.count
        model.espeak = espeak
        return model
    }

    /// Past every step, for `--panel-sheet` — `showing(_:)` always parks on
    /// one, and DonePane is only ever reached by walking off the end of
    /// `steps`, which nothing outside this file can set directly.
    static func done(
        speechModel: SpeechModelProgress = .ready, hotkeyDisplay: String = "Right ⌥",
        hotkeyRegistered: Bool = true, axStatus: Permissions.Status = .granted,
        downloads: ModelDownloads = ModelDownloads(), espeak: EspeakPresence = .found
    ) -> PermissionsModel {
        let model = PermissionsModel(downloads: downloads)
        model.micStatus = .granted
        model.axStatus = axStatus
        model.steps = PermissionStep.allCases.map(SetupStep.permission) + [.downloads]
        model.index = model.steps.count
        model.speechModel = speechModel
        model.hotkeyDisplay = hotkeyDisplay
        model.hotkeyRegistered = hotkeyRegistered
        model.espeak = espeak
        return model
    }

    /// Move past anything that has been granted since the last look. Called on
    /// the poll, so the screen advances itself the moment the box is ticked
    /// rather than waiting to be dismissed.
    func advancePastGranted() {
        while case .permission(let step)? = current, status(of: step) == .granted {
            index += 1
            asked = false
        }
    }

    /// The size the window needs for the screen it is on. The permission
    /// screens are one instrument and one paragraph; the other two are lists
    /// that outgrew them.
    var contentSize: NSSize {
        NSSize(width: PermissionMetrics.width, height: PermissionMetrics.height(for: current))
    }
}

/// A single plain window that walks one permission at a time.
///
/// It used to show both at once, each with its own Request button, and fire the
/// microphone prompt on first launch the instant it appeared — a system dialog
/// on top of a window explaining the system dialog, before anyone had read
/// either. One screen, one permission, one button: the explanation is finished
/// being read before anything is asked.
///
/// Everything else the app can be told lives in config.yaml, which the Settings
/// menu item opens.
final class PermissionsWindowController {
    let model = PermissionsModel()
    /// Re-runs the fetches, for the button a blocking failure puts in the foot.
    /// Set by `AppDelegate`; the window neither owns nor starts a download.
    var onRetryDownloads: (() -> Void)?
    private var window: NSWindow?
    private var timer: Timer?
    private var sizeWatch: AnyCancellable?
    /// When Terminal was opened on the espeak install, so the row can stop
    /// saying so.
    private var openedTerminalAt: Date?
    private var accessibilityObserver: NSObjectProtocol?
    /// The step a fronting attempt is under way for, and how many ticks it
    /// gets to actually land. A step is only worth fighting for the moment it
    /// first appears — activation is asynchronous and the first attempt does
    /// not always take (see poll below), so this allows a few retries rather
    /// than marking it "done" the instant one attempt is fired and never
    /// checking whether it actually worked.
    private var fronting: (index: Int, attemptsLeft: Int)?
    /// The step that has already been in front at least once. Checked before
    /// `fronting` is ever armed, and for good — granting Accessibility means
    /// clicking into System Settings, not this window, and the first
    /// successful appearance is the only one this window is owed. Without
    /// this, clicking into Settings to tick the box put the window out of
    /// key focus again, `fronting`'s budget hadn't run out yet, and the next
    /// tick re-fronted it on top of the very checkbox someone was reaching
    /// for.
    private var succeededIndex: Int?

    init() {
        accessibilityObserver = Permissions.observeAccessibilityChanges { [weak self] in
            self?.poll()
        }
    }

    deinit {
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
        }
    }

    func show(_ context: PermissionsContext = .revisiting) {
        model.begin(context: context)

        if window == nil { build() }
        // Set per showing, not at build: the same window is both, and which
        // one it is now decides whether the title bar offers a third way out.
        window?.styleMask = context == .installing ? [.titled] : [.titled, .closable]
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
        fronting = nil
        succeededIndex = model.index

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        model.refresh()
        pollEspeak()
        model.advancePastGranted()
        guard model.current != nil else { fronting = nil; return }

        // Once this step has been in front at all, it is done — regardless
        // of what has focus now, or whether `fronting`'s own budget has any
        // attempts left. See `succeededIndex`'s doc comment.
        if window?.isKeyWindow == true { succeededIndex = model.index }
        guard succeededIndex != model.index else { return }

        // A new step gets a few ticks' worth of attempts to land its one
        // successful appearance — activation is asynchronous and does not
        // always take on the first try.
        if fronting?.index != model.index {
            fronting = (model.index, attemptsLeft: 3)
        }
        guard var attempt = fronting, attempt.attemptsLeft > 0 else { return }
        attempt.attemptsLeft -= 1
        fronting = attempt
        let target = attempt.index

        NSApp.activate(ignoringOtherApps: true)
        // NSApp.activate only lands on the next turn of the run loop — see
        // the same trap in CorrectionPanel.present(). Calling
        // makeKeyAndOrderFront synchronously right after it here did nothing,
        // because activation had not actually happened yet.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.fronting?.index == target else { return }
            self.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// No "check again" button. The binary is looked for on the same tick that
    /// looks for a ticked checkbox, so an install in Terminal lands on its own.
    private func pollEspeak() {
        if Phonemes.locate() != nil {
            if model.espeak != .found { model.espeak = .found }
            openedTerminalAt = nil
            return
        }
        if model.espeak == .found { model.espeak = .missing }
        // An install can be cancelled or fail in Terminal, and nothing tells
        // this window. Without a way back, the one row with a button loses it.
        if model.espeak == .opening, let opened = openedTerminalAt,
           Date().timeIntervalSince(opened) > Self.terminalGiveUpSeconds {
            model.espeak = .missing
            openedTerminalAt = nil
        }
    }

    /// Long enough for `brew install espeak-ng` on a slow connection, and for
    /// the Homebrew installer in front of it.
    private static let terminalGiveUpSeconds: TimeInterval = 300

    private func build() {
        let view = PermissionsView(
            onAsk: { [weak self] step in self?.ask(step) },
            onDecline: { [weak self] in self?.decline() },
            onClose: { [weak self] in self?.window?.close() },
            onContinue: { [weak self] in self?.model.skip() },
            onRetry: { [weak self] in self?.onRetryDownloads?() },
            onInstallEspeak: { [weak self] in
                guard let self else { return }
                guard EspeakInstall.runInTerminal() else { return }
                self.model.espeak = .opening
                self.openedTerminalAt = Date()
            }
        )
        .environmentObject(model)
        .environmentObject(model.downloads)

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "\(AppVariant.displayName) Setup"
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        window.setContentSize(model.contentSize)
        self.window = window

        // The screens are three different heights, and the window is sized to
        // its content rather than to the tallest of them. `objectWillChange`
        // fires before the change lands, so the size is read on the next turn.
        sizeWatch = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizeToStep() }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.timer?.invalidate()
            self?.timer = nil
        }
    }

    /// Leaving. During setup that means the app — a button reading "cancel
    /// installation" that quietly moved to the next screen would be the kind of
    /// wording nobody trusts twice. Revisiting, it is a skip, and the walk ends
    /// on the screen that says what is still missing.
    /// Only when it actually changed: `setContentSize` on every published
    /// change would fight a window somebody is looking at.
    private func resizeToStep() {
        guard let window else { return }
        let wanted = model.contentSize
        guard window.contentLayoutRect.size.height != wanted.height else { return }
        window.setContentSize(wanted)
        window.center()
    }

    private func decline() {
        guard model.context == .installing else {
            model.skip()
            return
        }
        window?.close()
        NSApp.terminate(nil)
    }

    private func ask(_ step: PermissionStep) {
        model.markAsked()
        switch step {
        case .microphone:
            Permissions.requestMicrophone { [weak self] _ in self?.poll() }
        case .accessibility:
            // AXIsProcessTrustedWithOptions with the prompt option is what
            // registers this binary with TCC — skip it and the app may not
            // be in the list to tick, which reads as the instructions being
            // wrong. It also puts up its own system alert with an "Open
            // System Settings" button, so a second, explicit open() here
            // used to land on top of that alert as a doubled prompt. The
            // alert's own button is the one way through now.
            Permissions.requestAccessibility()
        }
    }
}

// MARK: - View

enum PermissionMetrics {
    static let width: CGFloat = 460
    static let height: CGFloat = 328

    /// The other two screens are lists, and they outgrew the permission
    /// screens rather than fitting inside them.
    static let downloadsHeight: CGFloat = 700
    static let doneHeight: CGFloat = 470

    static func height(for step: SetupStep?) -> CGFloat {
        switch step {
        case .permission: return height
        case .downloads: return downloadsHeight
        case nil: return doneHeight
        }
    }
}

struct PermissionsView: View {
    @EnvironmentObject private var model: PermissionsModel

    var onAsk: (PermissionStep) -> Void = { _ in }
    var onDecline: () -> Void = {}
    var onClose: () -> Void = {}
    var onContinue: () -> Void = {}
    var onRetry: () -> Void = {}
    var onInstallEspeak: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                PlumageMark()
                Text(AppVariant.displayName.uppercased())
                    .foregroundStyle(Parrot.action)
                Spacer()
                if model.steps.count > 1, let step = model.current,
                   let position = model.steps.firstIndex(of: step) {
                    Text("\(position + 1) of \(model.steps.count)".uppercased())
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .kerning(0.9)

            switch model.current {
            case .permission(let step):
                StepPane(
                    step: step,
                    status: model.status(of: step),
                    asked: model.asked,
                    context: model.context,
                    blocker: step == .accessibility ? model.axBlocker : nil,
                    onAsk: { onAsk(step) },
                    onDecline: onDecline
                )
            case .downloads:
                DownloadsPane(
                    context: model.context,
                    espeak: model.espeak,
                    onDecline: onDecline,
                    onContinue: onContinue,
                    onRetry: onRetry,
                    onInstallEspeak: onInstallEspeak
                )
            case nil:
                DonePane(
                    micStatus: model.micStatus, axStatus: model.axStatus,
                    speechModel: model.speechModel, hotkeyDisplay: model.hotkeyDisplay,
                    hotkeyRegistered: model.hotkeyRegistered, espeak: model.espeak,
                    onClose: onClose
                )
            }
        }
        .padding(28)
        .frame(
            width: PermissionMetrics.width,
            height: PermissionMetrics.height(for: model.current)
        )
        // Stated rather than inherited. In the app this is the window's own
        // background and setting it changes nothing; drawn on `--panel-sheet`
        // there is no window to inherit from, and without this the pane came
        // out with light chrome and white text on it.
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The piece of the app this permission switches on, drawn with the app's own
/// parts rather than illustrated.
///
/// A microphone glyph says "microphone", which the heading already says. The
/// recording pill says what is about to appear at the bottom of the screen
/// every time you hold the key — so the screen that asks for the microphone is
/// also the only place anyone is told what the pill is before it turns up over
/// their work. That is the whole argument for it: the illustration is the
/// feature, at the size it will really be.
private struct Instrument: View {
    let step: PermissionStep

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.045))

            switch step {
            case .microphone:
                // The real view, at its real size. It carries its own dark
                // glass, which is what it will look like over your document.
                // Sized explicitly: the pill fills whatever it is given, and
                // the panel that owns it is what decides its width in the app.
                PillView().environmentObject(Instrument.hearing)
                    .frame(width: PillMetrics.recording(hasIcon: false) + PillMetrics.bleed * 2,
                           height: PillMetrics.height + PillMetrics.bleed * 2)
            case .accessibility:
                SettingsRowMock()
            }
        }
        .frame(height: 88)
    }

    /// Mid-sentence, so the meter has something to show.
    private static let hearing: PillModel = {
        let model = PillModel()
        model.state = .recording(nil)
        model.level = 0.62
        return model
    }()
}

/// What Accessibility actually asks for is a row in System Settings, not
/// anything this app draws — so the picture is that row, not a metaphor for
/// it. The switch animates on a loop rather than sitting lit: someone reading
/// this has not ticked it yet, and a switch already on would show the answer
/// instead of the question. `allowsHitTesting(false)` on the mock switch is
/// not a precaution — nothing here is wired to anything, ever.
private struct SettingsRowMock: View {
    @State private var isOn = false

    var body: some View {
        HStack(spacing: 10) {
            appIcon
            Text(AppVariant.displayName)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            MockToggle(isOn: isOn)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: 260)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true).delay(0.5)) {
                isOn = true
            }
        }
    }

    /// The real app icon, the same file System Settings itself reads. Loaded
    /// by path rather than `NSImage(named:)`: a loose `AppIcon.icns` with no
    /// asset-catalog entry doesn't reliably resolve by name, and silently
    /// drawing the wrong mark is worse than a fallback that says so by being
    /// visibly different. `PlumageMark` falls back only if that ever fails —
    /// running the bare binary outside any bundle, mainly.
    @ViewBuilder
    private var appIcon: some View {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            PlumageMark(size: 20)
                .frame(width: 24, height: 24)
        }
    }
}

/// Shaped and sized after the real macOS toggle in Privacy & Security, not
/// approximated from memory — capsule track, round knob inset by 2pt, knob
/// on the side the value is on. Never a real `Toggle`: a control that can be
/// clicked invites clicking it, and clicking this one would do nothing.
private struct MockToggle: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Parrot.action : Color.primary.opacity(0.18))
            .frame(width: 34, height: 20)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .padding(2)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
            .allowsHitTesting(false)
    }
}

private struct StepPane: View {
    let step: PermissionStep
    let status: Permissions.Status
    let asked: Bool
    let context: PermissionsContext
    let blocker: String?
    let onAsk: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Instrument(step: step)
                .padding(.top, 20)
                .padding(.bottom, 18)

            // Says what kind of screen this is before the heading says which
            // one. "Microphone" on its own is a subject, not a request — and
            // someone who has just installed a dictation app and been handed a
            // window with a picture on it is owed the word "permission" before
            // they are asked to press anything.
            //
            // Amber, which is what a permission that is not granted already
            // wears on the last screen. One colour, one meaning, both places.
            Text(eyebrow)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .kerning(0.9)
                .foregroundStyle(status == .denied ? Parrot.scarlet : Parrot.amber)
                .padding(.bottom, 6)

            Text(step.title)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .padding(.bottom, 7)

            Text(step.reason)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            // Only after the ask. Before it, the screen has one thing to say
            // and one button to press, and a line about what happens next is a
            // second thing to read first.
            if asked {
                Text(status == .denied ? deniedNote : step.waiting)
                    .font(.system(size: 11))
                    .foregroundStyle(
                        status == .denied
                            ? AnyShapeStyle(Parrot.amber) : AnyShapeStyle(.tertiary)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            if asked, let blocker {
                Text(blocker)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            Spacer(minLength: 16)

            HStack(spacing: 10) {
                // Not offered during setup: both permissions are required, and a
                // way out here would be a way to finish installing without
                // either — the exact state that fails later, silently, at the
                // moment someone holds the key and nothing is written.
                // Revisiting still gets it, and the window's own close button
                // besides — this screen only ever asks to skip, never to quit.
                if context != .installing {
                    Button(step.declineTitle(in: context), action: onDecline)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 12))
                }

                Spacer()

                Button(actionTitle, action: onAsk)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Named for where pressing it lands, which a refusal changes.
    ///
    /// macOS prompts once. After that `requestMicrophone` opens the pane
    /// instead, so a button still offering to ask is a button that does
    /// something else than it says — and it would say it directly under the
    /// line explaining that Settings is now the only way back.
    private var actionTitle: String {
        if status == .denied { return "Open System Settings" }
        return asked ? "Ask again" : step.actionTitle
    }

    /// Three states, three words for them, in the order they happen.
    private var eyebrow: String {
        if status == .denied { return "PERMISSION REFUSED" }
        return asked ? "WAITING FOR YOU" : "PERMISSION NEEDED"
    }

    /// macOS prompts once. After a refusal the only way back is the pane.
    private var deniedNote: String {
        step == .microphone
            ? "macOS only asks once. Turn it on for ParrotFlow in System Settings, under Privacy & Security."
            : "Tick ParrotFlow under Privacy & Security → Accessibility."
    }
}

private struct DonePane: View {
    let micStatus: Permissions.Status
    let axStatus: Permissions.Status
    let speechModel: PermissionsModel.SpeechModelProgress
    let hotkeyDisplay: String
    let hotkeyRegistered: Bool
    let espeak: PermissionsModel.EspeakPresence
    let onClose: () -> Void

    @EnvironmentObject private var downloads: ModelDownloads

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 16)

            Text(title)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .padding(.bottom, 7)

            invitation
                .padding(.bottom, 12)

            // Three groups rather than one run of lines, because each is
            // answered somewhere else: a permission in System Settings, a
            // download by waiting, and espeak-ng in Terminal.
            group("Permissions") {
                SetupLine(glyph: micStatus.glyph, title: "Microphone", trailing: micStatus.note)
                SetupLine(
                    glyph: axStatus.glyph, title: "Accessibility", trailing: axStatus.note
                )
            }

            if !downloads.rows.isEmpty {
                group("Downloads") {
                    ForEach(downloads.rows) { row in
                        SetupLine(
                            glyph: row.glyph, title: row.name, trailing: row.doneNote,
                            trailingIsPercent: row.percent != nil
                        )
                    }
                }
            }

            group("On your Mac") {
                SetupLine(
                    glyph: espeak == .found ? .granted : .absent,
                    title: "eSpeak NG",
                    trailing: espeak == .found ? nil : "not found"
                )
            }

            Spacer(minLength: 12)

            HStack {
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func group<Content: View>(
        _ name: String, @ViewBuilder lines: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .kerning(0.9)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            lines()
        }
        .padding(.bottom, 12)
    }

    private var everything: Bool { micStatus == .granted && axStatus == .granted }

    /// "Ready" oversold it while the model was still on its way in — someone
    /// reads that word, holds the hotkey, and dictates into a download that
    /// has not finished. Only true once both permissions and the model are
    /// all the way there.
    ///
    /// Only the speech model counts. The other four can still be coming down
    /// while you dictate: the stages that read them stand aside.
    private var title: String {
        guard everything else { return "Something was switched off" }
        if case .preparing = speechModel { return "Almost ready" }
        if !hotkeyRegistered { return "Almost ready" }
        return "Ready"
    }

    /// Both permissions granted is the gate for reaching this screen at all
    /// (see `PermissionsModel.begin`'s step filter) — what is still open past
    /// that is only ever the speech model, and only ever a matter of time,
    /// not a decision to make. So the two states get their own sentence
    /// rather than a status line read in silence: one says dictate now, the
    /// other says what to wait for and then dictate.
    ///
    /// The hotkey is a key someone presses, not a word in a sentence — plain
    /// prose let it blend into "Hold Right Option and start dictating." and
    /// read past. Its own line, in the same bordered mark this window
    /// already uses for a key combination, is what makes it the one thing to
    /// notice here.
    @ViewBuilder
    private var invitation: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch speechModel {
            case .ready:
                EmptyView()
            case .preparing:
                Text("The speech model is still downloading.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if everything, hotkeyRegistered {
                HStack(spacing: 6) {
                    Text(holdVerb)
                    HotkeyBadge(text: hotkeyDisplay)
                    Text("and start dictating.")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            } else if everything {
                // hotkeyRegistered is false here: both permissions are
                // granted, but the configured key never bound — another app
                // already holds it, most likely. Naming the key it wanted
                // would tell someone to press a key that does nothing.
                Text("ParrotFlow's hotkey isn't registered. Check hotkey.key in config.yaml, "
                    + "then reopen this window from the menu bar.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("ParrotFlow needs both. Reopen this window from the menu bar when you want to "
                    + "finish, or check what is missing below.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var holdVerb: String {
        if case .preparing = speechModel { return "Once it's done, hold" }
        return "Hold"
    }
}

/// One line of the last screen: a glyph in a fixed column, a name, and a word
/// at the right edge only where the glyph cannot say it.
private struct SetupLine: View {
    let glyph: SetupGlyph
    let title: String
    var trailing: String?
    var trailingIsPercent: Bool = false

    var body: some View {
        HStack(spacing: 9) {
            GlyphView(glyph: glyph)
            Text(title).font(.system(size: 12))
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: trailingIsPercent ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(
                        trailingIsPercent
                            ? AnyShapeStyle(Parrot.action) : AnyShapeStyle(.tertiary)
                    )
            }
        }
        .padding(.vertical, 2)
    }
}

/// The six states a line can be in, drawn rather than written.
enum SetupGlyph: Equatable {
    case granted
    case switchedOff
    case downloading
    case queued
    case turnedOff
    case absent
}

private struct GlyphView: View {
    let glyph: SetupGlyph
    @State private var spinning = false

    var body: some View {
        Group {
            switch glyph {
            case .granted:
                Image(systemName: "checkmark").bold().foregroundStyle(Parrot.leaf)
            case .switchedOff:
                Image(systemName: "xmark").bold().foregroundStyle(Parrot.scarlet)
            case .turnedOff:
                Image(systemName: "minus").bold().foregroundStyle(.tertiary)
            case .downloading:
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(Parrot.action, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .frame(width: 10, height: 10)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                            spinning = true
                        }
                    }
            case .queued:
                Circle()
                    .stroke(
                        Color.secondary.opacity(0.6),
                        style: StrokeStyle(lineWidth: 1.2, dash: [2.2, 2.2])
                    )
                    .frame(width: 10, height: 10)
            case .absent:
                Circle()
                    .stroke(Parrot.amber, lineWidth: 1.5)
                    .frame(width: 10, height: 10)
            }
        }
        .font(.system(size: 10, weight: .bold))
        .frame(width: 14, height: 14)
    }
}

/// The same bordered field this window already draws for a key combination
/// — one mark for "this is a key you press," not two.
private struct HotkeyBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Color.primary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: Parrot.fieldRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Parrot.fieldRadius, style: .continuous)
                    .strokeBorder(Parrot.action.opacity(0.55), lineWidth: 1.5)
            }
    }
}

private extension Permissions.Status {
    var glyph: SetupGlyph {
        self == .granted ? .granted : .switchedOff
    }

    /// Nothing beside a granted permission: the glyph says it.
    var note: String? {
        self == .granted ? nil : "switched off"
    }
}

private extension ModelDownload {
    var glyph: SetupGlyph {
        switch state {
        case .installed: return .granted
        case .downloading: return .downloading
        case .waiting: return .queued
        case .off: return .turnedOff
        // Amber for a fetch the app retries by itself, a cross for one that
        // holds a dictation up.
        case .failed: return blocking ? .switchedOff : .absent
        }
    }

    var percent: Int? {
        if case .downloading(let percent) = state { return percent }
        return nil
    }

    /// The word at the right edge of the last screen's line, where a glyph
    /// cannot carry it.
    var doneNote: String? {
        switch state {
        case .downloading(let percent): return percent.map { "\($0)%" }
        case .off(let reason): return reason
        case .failed: return "did not arrive"
        case .installed, .waiting: return nil
        }
    }
}

// MARK: - Downloads

/// What the app is fetching, and the one thing it looks for instead.
///
/// Nothing here starts a download. They start at launch, in `warmModels`, and
/// they carry on whether or not this window is open. The rows report.
private struct DownloadsPane: View {
    let context: PermissionsContext
    let espeak: PermissionsModel.EspeakPresence
    let onDecline: () -> Void
    let onContinue: () -> Void
    let onRetry: () -> Void
    let onInstallEspeak: () -> Void

    @EnvironmentObject private var downloads: ModelDownloads

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(downloads.summary.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .kerning(0.9)
                .foregroundStyle(eyebrowColour)
                .padding(.top, 20)
                .padding(.bottom, 6)

            Text("Downloads")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .padding(.bottom, 7)

            Text("ParrotFlow needs the following models to process your dictation on this Mac.")
                .font(.system(size: 14))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            group(
                "Speech and sound",
                "These audio models process your voice, transform it into text and provide"
                    + " additional cues to correct transcription artifacts.",
                rows: downloads.rows(in: .sound)
            )

            group(
                "Language",
                "These language models help ParrotFlow apply your vocabulary and correct"
                    + " transcription artifacts by understanding what you mean.",
                rows: downloads.rows(in: .language)
            )

            groupKey("Already on your Mac, or not")
                .padding(.top, 16)
                .padding(.bottom, 7)
            EspeakRow(presence: espeak, onInstall: onInstallEspeak)

            Spacer(minLength: 14)

            HStack(spacing: 10) {
                // Offered here and not on the permission screens, and it means
                // what it says: this quits the app. Only while installing —
                // revisiting, it would say "Not now" beside a Continue that
                // does the same thing.
                if context == .installing {
                    Button(context.declineTitle, action: onDecline)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 12))
                }

                Spacer()

                // Never disabled. Nothing on this screen is a condition of
                // going on: the speech model is the only one a dictation waits
                // for, and it says so on the screen after this one.
                Button(primaryTitle, action: primaryAction)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func group(_ name: String, _ what: String, rows: [ModelDownload]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                groupKey(name).padding(.bottom, 3)
                // The group carries the explanation, so the rows are bare: a
                // name, a size, a state.
                Text(what)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 7)
                VStack(spacing: 6) {
                    ForEach(rows) { DownloadRow(row: $0) }
                }
            }
            .padding(.top, 16)
        }
    }

    private func groupKey(_ name: String) -> some View {
        Text(name.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .kerning(0.9)
            .foregroundStyle(.tertiary)
    }

    /// A failure nobody is waiting on stays inside its own row. Only a model a
    /// dictation waits for reaches the foot.
    private var primaryTitle: String {
        downloads.blockingFailure?.retryTitle ?? "Continue"
    }

    private func primaryAction() {
        if downloads.blockingFailure?.retryTitle != nil { onRetry() } else { onContinue() }
    }

    private var eyebrowColour: Color {
        if downloads.rows.contains(where: { $0.state.hasFailed }) { return Parrot.scarlet }
        if downloads.anyDownloading { return Parrot.action }
        if downloads.rows.allSatisfy({ $0.state == .installed }) { return Parrot.leaf }
        return Parrot.amber
    }
}

private struct DownloadRow: View {
    let row: ModelDownload

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(row.name).font(.system(size: 13, weight: .semibold))
                    Text(row.sizeLabel).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                // The second line exists only to say why a row failed.
                if let why = row.state.failure {
                    Text(sentence(for: why))
                        .font(.system(size: 11))
                        .foregroundStyle(row.blocking ? Parrot.scarlet : Parrot.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            state
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06))
        .overlay(alignment: .bottomLeading) { bar }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// A model nothing waits on clears its own failed fetch, so the row says
    /// what happens next rather than asking for a decision.
    private func sentence(for why: ModelDownload.Failure) -> String {
        guard !row.blocking else { return why.message }
        return why.message + " The next dictation that needs it tries again."
    }

    @ViewBuilder
    private var state: some View {
        switch row.state {
        case .downloading(let percent):
            if let percent {
                Text("\(percent)%")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Parrot.action)
            } else {
                // No number rather than an invented one: this fetch reports no
                // fraction.
                GlyphView(glyph: .downloading)
            }
        case .waiting:
            SetupBadge(text: "Waiting", color: .secondary)
        case .installed:
            SetupBadge(text: "Installed", color: Parrot.leaf)
        case .off(let reason):
            SetupBadge(text: reason, color: .secondary)
        case .failed:
            SetupBadge(
                text: row.blocking ? "Failed" : "Will retry",
                color: row.blocking ? Parrot.scarlet : Parrot.amber
            )
        }
    }

    @ViewBuilder
    private var bar: some View {
        if let percent = row.percent {
            GeometryReader { geometry in
                Rectangle()
                    .fill(Parrot.action)
                    .frame(width: geometry.size.width * CGFloat(percent) / 100, height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

/// The one row no button can fetch, so the one row with controls.
///
/// Amber, not scarlet: CharsiuG2P covers the base case, so an absent eSpeak NG
/// costs some names rather than the feature.
private struct EspeakRow: View {
    let presence: PermissionsModel.EspeakPresence
    let onInstall: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text("eSpeak NG").font(.system(size: 13, weight: .semibold))
                        Text("GPL-3 · a separate program")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Text("Backs up CharsiuG2P on names it misses.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if presence != .found {
                        Text(how)
                            .font(.system(size: 11))
                            .foregroundStyle(Parrot.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                switch presence {
                case .missing:
                    Button("Run in Terminal", action: onInstall).controlSize(.small)
                case .opening:
                    SetupBadge(text: "Terminal open", color: .secondary)
                case .found:
                    SetupBadge(text: "Found", color: Parrot.leaf)
                }
            }

            // The chained one-liner is 130 characters. Inside a sentence it is
            // unreadable and unselectable, so it gets a field and a way to copy.
            if presence != .found {
                HStack(alignment: .top, spacing: 8) {
                    Text(EspeakInstall.command)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(copied ? "Copied" : "Copy") {
                        EspeakInstall.copyCommand()
                        copied = true
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .padding(.vertical, 7)
                .background(
                    Color.primary.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: Parrot.fieldRadius, style: .continuous)
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    private var how: String {
        if presence == .opening {
            return "Terminal is running it now. This row notices on its own when it lands."
        }
        if EspeakInstall.brew != nil {
            return "Not installed. This runs it in Terminal, where you can watch it."
        }
        return "Not installed, and neither is Homebrew. This installs Homebrew first,"
            + " then eSpeak NG."
    }
}

private struct SetupBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .kerning(0.3)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .fixedSize()
    }
}
