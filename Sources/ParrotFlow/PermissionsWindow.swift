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

/// A screen in the walk. The permissions are asked for one at a time, and then
/// there is one screen for everything: what was granted, what is downloading,
/// and what is on this Mac already.
enum SetupStep: Equatable {
    case permission(PermissionStep)
    case setup
}

final class PermissionsModel: ObservableObject {
    @Published var micStatus: Permissions.Status = .notDetermined
    @Published var axStatus: Permissions.Status = .notGranted
    @Published var axBlocker: String?
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

    var current: SetupStep { steps.indices.contains(index) ? steps[index] : .setup }

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
    /// The setup screen is always the last step, and it is where the walk ends.
    /// It reports the fetches that started at launch rather than starting them,
    /// so there is nothing to wait for on it and nothing after it.
    func begin(context: PermissionsContext) {
        self.context = context
        refresh()
        espeak = Phonemes.locate() == nil ? .missing : .found
        steps = PermissionStep.allCases
            .filter { status(of: $0) != .granted }
            .map(SetupStep.permission)
        steps.append(.setup)
        index = 0
        asked = false
    }

    func markAsked() { asked = true }

    /// The skip a revisit offers on a permission screen. It cannot walk past
    /// the setup screen: that is the end of the walk, and its button closes
    /// the window rather than advancing.
    func skip() {
        guard index + 1 < steps.count else { return }
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
        model.steps = PermissionStep.allCases.map(SetupStep.permission) + [.setup]
        model.index = PermissionStep.allCases.firstIndex(of: step) ?? 0
        model.asked = asked
        return model
    }

    /// Parked on the setup screen, for `--panel-sheet` and `--panels setup`.
    static func showingSetup(
        _ downloads: ModelDownloads, context: PermissionsContext = .installing,
        axStatus: Permissions.Status = .granted, hotkeyDisplay: String = "Right ⌥",
        hotkeyRegistered: Bool = true, espeak: EspeakPresence = .missing
    ) -> PermissionsModel {
        let model = PermissionsModel(downloads: downloads)
        model.context = context
        model.micStatus = .granted
        model.axStatus = axStatus
        model.steps = PermissionStep.allCases.map(SetupStep.permission) + [.setup]
        model.index = PermissionStep.allCases.count
        model.hotkeyDisplay = hotkeyDisplay
        model.hotkeyRegistered = hotkeyRegistered
        model.espeak = espeak
        return model
    }

    /// Move past anything that has been granted since the last look. Called on
    /// the poll, so the screen advances itself the moment the box is ticked
    /// rather than waiting to be dismissed.
    func advancePastGranted() {
        while case .permission(let step) = current, status(of: step) == .granted,
              index + 1 < steps.count {
            index += 1
            asked = false
        }
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
    /// Set once the window has been centred, so a later resize can keep the
    /// title bar where it is instead of jumping back to the middle.
    private var centred = false
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
        resizeToContent()
        window?.center()
        centred = true
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
            onRetry: { [weak self] in self?.onRetryDownloads?() },
            onInstallEspeak: { [weak self] in
                guard let self else { return }
                let started = EspeakInstall.runInTerminal { [weak self] opened in
                    guard let self, !opened, self.model.espeak == .opening else { return }
                    self.model.espeak = .missing
                    self.openedTerminalAt = nil
                }
                guard started else { return }
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
        self.window = window
        resizeToContent()

        // Two screens of different shapes, and the setup screen's own height
        // moves as rows settle, a failure appears, or eSpeak NG turns up. Both
        // publishers fire before the change lands, so the size is read on the
        // next turn of the run loop.
        //
        // Debounced rather than hopped to the next turn: the poll writes to the
        // model once a second and a download reports every percent, and each
        // one of those would otherwise cost a layout pass to find out the
        // height has not changed.
        sizeWatch = Publishers.Merge(model.objectWillChange, model.downloads.objectWillChange)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.resizeToContent() }

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
    /// The window takes the height its content asks for.
    ///
    /// Only when it actually changed: setting the size on every published
    /// change would fight a window somebody is looking at. The top edge is put
    /// back afterwards, because `setContentSize` keeps the bottom-left corner
    /// and a window that grows upward moves its own title bar out from under
    /// the pointer.
    private func resizeToContent() {
        guard let window, let content = window.contentViewController?.view else { return }
        let fitting = content.fittingSize
        guard fitting.height > 0 else { return }
        let wanted = NSSize(width: PermissionMetrics.width, height: fitting.height)
        guard abs(window.contentLayoutRect.height - wanted.height) > 0.5 else { return }

        let top = window.frame.maxY
        window.setContentSize(wanted)
        guard centred else { return }
        var frame = window.frame
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true)
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

    /// The permission screens are one instrument and one paragraph, and that
    /// is a fixed shape. The setup screen is four lists whose length depends on
    /// what is installed, what failed and whether eSpeak NG is here, so it is
    /// measured rather than declared — see `resizeToContent`. This is the size
    /// the sheet draws it at when it has no window to ask.
    static let setupHeight: CGFloat = 740

    static func height(for step: SetupStep) -> CGFloat? {
        switch step {
        case .permission: return height
        case .setup: return nil
        }
    }
}

struct PermissionsView: View {
    @EnvironmentObject private var model: PermissionsModel

    var onAsk: (PermissionStep) -> Void = { _ in }
    var onDecline: () -> Void = {}
    var onClose: () -> Void = {}
    var onRetry: () -> Void = {}
    var onInstallEspeak: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                PlumageMark()
                Text(AppVariant.displayName.uppercased())
                    .foregroundStyle(Parrot.action)
                Spacer()
                if model.steps.count > 1,
                   let position = model.steps.firstIndex(of: model.current) {
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
            case .setup:
                SetupPane(
                    micStatus: model.micStatus, axStatus: model.axStatus,
                    hotkeyDisplay: model.hotkeyDisplay,
                    hotkeyRegistered: model.hotkeyRegistered,
                    context: model.context, espeak: model.espeak,
                    onDecline: onDecline, onClose: onClose, onRetry: onRetry,
                    onInstallEspeak: onInstallEspeak
                )
            }
        }
        .padding(28)
        .frame(width: PermissionMetrics.width)
        .frame(height: PermissionMetrics.height(for: model.current))
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

// MARK: - The setup screen

/// Where the glyph column ends and the text column begins, so a note under a
/// line and the bar under it both start where the name does.
enum SetupMetrics {
    static let glyph: CGFloat = 14
    static let gap: CGFloat = 9
    static var indent: CGFloat { glyph + gap }
}

/// One screen: what was granted, what is being fetched, and what is on this
/// Mac already.
///
/// The title is the state and the glyphs are the detail. Only the permissions
/// and the models a dictation waits on can change the title. The other three
/// arrive in their own time and say so on their own line.
///
/// Nothing here starts a download. They start at launch in `warmModels` and
/// carry on with the window closed, which is why Done never waits.
private struct SetupPane: View {
    let micStatus: Permissions.Status
    let axStatus: Permissions.Status
    let hotkeyDisplay: String
    let hotkeyRegistered: Bool
    let context: PermissionsContext
    let espeak: PermissionsModel.EspeakPresence
    let onDecline: () -> Void
    let onClose: () -> Void
    let onRetry: () -> Void
    let onInstallEspeak: () -> Void

    @EnvironmentObject private var downloads: ModelDownloads

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .padding(.top, 20)
                .padding(.bottom, 7)

            invitation

            group("Permissions") {
                SetupLine(glyph: micStatus.glyph, title: "Microphone", note: micStatus.note)
                SetupLine(glyph: axStatus.glyph, title: "Accessibility", note: axStatus.note)
            }

            models(
                "Speech and sound",
                "These audio models process your voice, transform it into text and provide"
                    + " additional cues to correct transcription artifacts.",
                in: .sound
            )

            models(
                "Language",
                "These language models help ParrotFlow apply your vocabulary and correct"
                    + " transcription artifacts by understanding what you mean.",
                in: .language
            )

            group("Other") { espeakLines }

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                // It means what it says: during setup this quits the app.
                // Revisiting, there is no installation left to cancel.
                if context == .installing {
                    Button(context.declineTitle, action: onDecline)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 12))
                }

                Spacer()

                Button(primaryTitle, action: primaryAction)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: What the screen is saying

    private enum Moment {
        case almostReady
        case ready
        case permissionLost
        case somethingDidNotArrive
        case dictationOff
    }

    /// A permission first: it is the only one of these that cannot be fixed by
    /// waiting, and it is fixed somewhere else.
    ///
    /// An empty registry means `transcription.enabled` is false. `warmModels`
    /// declares all five rows before this window opens and returns before
    /// declaring any only on that one setting, so there is nothing else it can
    /// mean.
    private var moment: Moment {
        if lostPermission != nil { return .permissionLost }
        if downloads.rows.isEmpty { return .dictationOff }
        if downloads.blockingFailure != nil { return .somethingDidNotArrive }
        return downloads.speechIsIn ? .ready : .almostReady
    }

    private var lostPermission: PermissionStep? {
        if micStatus != .granted { return .microphone }
        if axStatus != .granted { return .accessibility }
        return nil
    }

    /// The model still being waited for, which is the one the title is about.
    ///
    /// Not the first blocking row: Parakeet lands before Silero VAD starts, and
    /// naming it then would say an installed model is still coming down.
    private var awaited: ModelDownload? {
        downloads.rows.first { $0.blocking && $0.state.isPending }
    }

    private var title: String {
        switch moment {
        // A setting that is off is a setting that was switched off, whether
        // the switch is in System Settings or in config.yaml.
        case .permissionLost, .dictationOff: return "Something was switched off"
        case .somethingDidNotArrive: return "Something did not arrive"
        case .almostReady: return "Almost ready"
        case .ready: return hotkeyRegistered ? "Ready" : "Almost ready"
        }
    }

    /// The sentence under the title, and the key it ends on.
    ///
    /// The key is a bordered field rather than a word, so it cannot be read
    /// past — which means the sentence cannot be one `Text` that wraps around
    /// it. It breaks where the key starts instead.
    @ViewBuilder
    private var invitation: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let lead {
                Text(lead)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let (before, after) = keySentence, hotkeyRegistered {
                HStack(spacing: 5) {
                    Text(before)
                    HotkeyBadge(text: hotkeyDisplay)
                    Text(after)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }

    private var lead: String? {
        switch moment {
        case .permissionLost:
            guard let step = lostPermission else { return nil }
            return "\(step.title) is switched off. Turn it back on in System Settings,"
                + " and this window updates itself."
        case .dictationOff:
            return "Dictation is switched off. Set transcription: enabled: true in"
                + " config.yaml, then reopen this window."
        case .somethingDidNotArrive:
            // The row that failed, not the first one a dictation waits on: a
            // voice detector that did not arrive must not be reported as a
            // speech model that did not arrive.
            guard let row = downloads.blockingFailure else { return nil }
            let opening = "\(row.name) could not be downloaded, and \(row.costOfFailure)."
            // The key line finishes this sentence. Without a hotkey there is no
            // key line, and it would end on "or".
            return hotkeyRegistered ? "\(opening) Try again, or" : "\(opening) Try again"
        case .almostReady:
            guard hotkeyRegistered else { return unregisteredHotkey }
            guard let row = awaited else { return nil }
            return "\(row.name) is still coming down. Once it is here,"
        case .ready:
            return hotkeyRegistered ? nil : unregisteredHotkey
        }
    }

    /// Both permissions are granted and the model is in, but the configured key
    /// never bound — another app already holds it, most likely. Naming the key
    /// it wanted would tell someone to press a key that does nothing.
    private var unregisteredHotkey: String {
        "ParrotFlow's hotkey isn't registered. Check hotkey.key in config.yaml, "
            + "then reopen this window from the menu bar."
    }

    private var keySentence: (String, String)? {
        switch moment {
        case .permissionLost, .dictationOff: return nil
        case .somethingDidNotArrive: return ("hold", "later and it tries again on its own.")
        case .almostReady: return ("hold", "and start dictating.")
        case .ready: return ("Hold", "and start dictating.")
        }
    }

    /// A failure nobody is waiting on stays on its own line. Only a model a
    /// dictation waits for reaches the foot.
    private var primaryTitle: String {
        guard moment == .somethingDidNotArrive else { return "Done" }
        return downloads.blockingFailure?.state.failure?.retryTitle ?? "Done"
    }

    private func primaryAction() {
        if moment == .somethingDidNotArrive,
           downloads.blockingFailure?.state.failure?.retryTitle != nil {
            onRetry()
        } else {
            onClose()
        }
    }

    // MARK: The groups

    @ViewBuilder
    private func group<Content: View>(
        _ name: String, blurb: String? = nil, @ViewBuilder lines: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .kerning(0.9)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            // The group carries the explanation, so the lines are bare: a
            // glyph, a name, a size.
            if let blurb {
                Text(blurb)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 5)
            }
            lines()
        }
        .padding(.top, 14)
    }

    @ViewBuilder
    private func models(
        _ name: String, _ blurb: String, in group: ModelDownload.Group
    ) -> some View {
        let rows = downloads.rows(in: group)
        if !rows.isEmpty {
            self.group(name, blurb: blurb) {
                ForEach(rows) { row in
                    SetupLine(
                        glyph: row.glyph, title: row.name, detail: row.sizeLabel,
                        note: row.note, noteIsPercent: row.percent != nil,
                        percent: row.percent
                    )
                    if let why = row.why {
                        SetupNote(text: why, tone: row.blocking ? Parrot.scarlet : Parrot.amber)
                    }
                }
            }
        }
    }

    /// The one line the app cannot fetch, so the one line with a button.
    ///
    /// Amber, not scarlet: CharsiuG2P covers the base case, so an absent eSpeak
    /// NG costs some names rather than the feature.
    @ViewBuilder
    private var espeakLines: some View {
        SetupLine(
            glyph: espeak == .found ? .granted : (espeak == .opening ? .downloading : .absent),
            title: "eSpeak NG",
            detail: "GPL-3 · a separate program",
            note: espeak == .opening ? "Terminal open" : nil,
            button: espeak == .missing ? ("Run in Terminal", onInstallEspeak) : nil
        )
        if espeak != .found {
            SetupNote(text: espeakHow, tone: Parrot.amber)
            CommandField()
        }
    }

    private var espeakHow: String {
        if espeak == .opening {
            return "Terminal is running it now. This line notices on its own when it lands."
        }
        let backs = "Backs up CharsiuG2P on names it misses."
        if EspeakInstall.brew != nil {
            return "\(backs) Not installed. This runs it in Terminal, where you can watch it."
        }
        return "\(backs) Not installed, and neither is Homebrew. This installs Homebrew first,"
            + " then eSpeak NG."
    }
}

/// One line: a glyph in a fixed column, a name, what it costs, and a word at
/// the right edge only where the glyph cannot say it.
private struct SetupLine: View {
    let glyph: SetupGlyph
    let title: String
    var detail: String?
    var note: String?
    var noteIsPercent = false
    /// Draws a 2 px bar under this line and no other.
    var percent: Int?
    var button: (title: String, action: () -> Void)?

    var body: some View {
        HStack(spacing: SetupMetrics.gap) {
            GlyphView(glyph: glyph)
            Text(title).font(.system(size: 12))
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if let note {
                Text(note)
                    .font(.system(size: 11, weight: noteIsPercent ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(
                        noteIsPercent
                            ? AnyShapeStyle(Parrot.action) : AnyShapeStyle(.tertiary)
                    )
            }
            if let button {
                Button(button.title, action: button.action).controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottomLeading) { bar }
    }

    @ViewBuilder
    private var bar: some View {
        if let percent {
            GeometryReader { geometry in
                let room = max(0, geometry.size.width - SetupMetrics.indent)
                Rectangle()
                    .fill(Parrot.action)
                    .frame(width: room * CGFloat(percent) / 100, height: 2)
                    .offset(x: SetupMetrics.indent)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

/// The one line under a name that says why it failed, or what to do about it.
private struct SetupNote: View {
    let text: String
    let tone: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, SetupMetrics.indent)
            .padding(.bottom, 4)
    }
}

/// The chained one-liner is 140 characters. Inside a sentence it is unreadable
/// and unselectable, so it gets a field and a way to copy.
private struct CommandField: View {
    @State private var copied = false

    var body: some View {
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
        .padding(.vertical, 6)
        .background(
            Color.primary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: Parrot.fieldRadius, style: .continuous)
        )
        .padding(.leading, SetupMetrics.indent)
        .padding(.bottom, 2)
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
        .frame(width: SetupMetrics.glyph, height: SetupMetrics.glyph)
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
            .padding(.vertical, 2)
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

    /// The word at the right edge, where a glyph cannot carry it.
    var note: String? {
        switch state {
        case .downloading(let percent): return percent.map { "\($0)%" }
        case .off(let reason): return reason
        case .installed, .waiting, .failed: return nil
        }
    }

    /// The one line under the name, only on a failure. A model nothing waits
    /// on clears its own failed fetch, so its line says what happens next
    /// rather than asking for a decision.
    var why: String? {
        guard let failure = state.failure else { return nil }
        guard !blocking else { return failure.message }
        return failure.message + " The next dictation that needs it tries again."
    }
}
