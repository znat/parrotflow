import AppKit
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

    /// The same on both screens, and different in the two contexts. Setting up
    /// has one way out and it does what it says: the app quits. Both
    /// permissions are required, and a requirement you can walk past is not
    /// one. Revisiting has no installation left to cancel.
    func declineTitle(in context: PermissionsContext) -> String {
        context == .installing ? "Cancel installation" : "Not now"
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

final class PermissionsModel: ObservableObject {
    @Published var micStatus: Permissions.Status = .notDetermined
    @Published var axStatus: Permissions.Status = .notGranted
    @Published var axBlocker: String?

    /// What is left to ask for, fixed when the window opens.
    ///
    /// Fixed rather than recomputed so "1 of 2" does not become "1 of 1" under
    /// the reader the moment they grant the first one — a counter that changes
    /// its own total reads as the app losing count.
    @Published private(set) var steps: [PermissionStep] = []
    @Published private(set) var index = 0
    /// The system has been asked and the answer is not here yet.
    @Published private(set) var asked = false
    @Published private(set) var context: PermissionsContext = .installing

    var current: PermissionStep? { steps.indices.contains(index) ? steps[index] : nil }

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
    func begin(context: PermissionsContext) {
        self.context = context
        refresh()
        steps = PermissionStep.allCases.filter { status(of: $0) != .granted }
        index = 0
        asked = false
    }

    func markAsked() { asked = true }

    /// Only reachable when revisiting — during setup the button that would
    /// call this quits instead.
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
        model.steps = PermissionStep.allCases
        model.index = PermissionStep.allCases.firstIndex(of: step) ?? 0
        model.asked = asked
        return model
    }

    /// Move past anything that has been granted since the last look. Called on
    /// the poll, so the screen advances itself the moment the box is ticked
    /// rather than waiting to be dismissed.
    func advancePastGranted() {
        while let step = current, status(of: step) == .granted {
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
    private var window: NSWindow?
    private var timer: Timer?
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

    private func build() {
        let view = PermissionsView(
            onAsk: { [weak self] step in self?.ask(step) },
            onDecline: { [weak self] in self?.decline() },
            onClose: { [weak self] in self?.window?.close() }
        ).environmentObject(model)

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "\(AppVariant.displayName) Permissions"
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: PermissionMetrics.width, height: PermissionMetrics.height))
        self.window = window

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
}

struct PermissionsView: View {
    @EnvironmentObject private var model: PermissionsModel

    var onAsk: (PermissionStep) -> Void = { _ in }
    var onDecline: () -> Void = {}
    var onClose: () -> Void = {}

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

            if let step = model.current {
                StepPane(
                    step: step,
                    status: model.status(of: step),
                    asked: model.asked,
                    context: model.context,
                    blocker: step == .accessibility ? model.axBlocker : nil,
                    onAsk: { onAsk(step) },
                    onDecline: onDecline
                )
            } else {
                DonePane(
                    micStatus: model.micStatus, axStatus: model.axStatus, onClose: onClose
                )
            }
        }
        .padding(28)
        .frame(width: PermissionMetrics.width, height: PermissionMetrics.height)
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
                Landing()
            }
        }
        .frame(height: 88)
    }

    /// Mid-sentence, so the meter has something to show.
    private static let hearing: PillModel = {
        let model = PillModel()
        model.state = .recording
        model.level = 0.62
        return model
    }()
}

/// The four feathers, then a field with the words already in it and the caret
/// after them. `PlumageMark` is documented as the pill once it has heard you,
/// which makes it exactly the right mark to show arriving somewhere.
private struct Landing: View {
    var body: some View {
        HStack(spacing: 12) {
            // Scaled up rather than redrawn: it is the app's mark at label size
            // everywhere else, and this is the one place it is the subject of
            // the picture rather than a label on one.
            PlumageMark()
                .scaleEffect(1.5)
                .frame(width: 18)

            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 2) {
                Text("hold the hotkey and talk")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.primary)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Parrot.action)
                    .frame(width: 2, height: 16)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
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
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 20)

            Text(everything ? "Ready" : "Something was switched off")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .padding(.bottom, 7)

            // Reachable two ways now: a permission revoked in System Settings
            // while this window is open, or a skip from the menu bar. Either
            // way what is true is that something is missing, which it says
            // rather than pretending the app is fine.
            Text(everything
                ? "Hold your hotkey, say something, let go."
                : "ParrotFlow needs both. Reopen this window from the menu bar when you want to "
                    + "finish, or check what is missing below.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)

            StatusLine(title: "Microphone", status: micStatus)
            StatusLine(title: "Accessibility", status: axStatus)

            Spacer(minLength: 16)

            HStack {
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var everything: Bool { micStatus == .granted && axStatus == .granted }
}

private struct StatusLine: View {
    let title: String
    let status: Permissions.Status

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12))
            StatusBadge(status: status)
            Spacer()
        }
        .padding(.vertical, 3)
    }
}

private struct StatusBadge: View {
    let status: Permissions.Status

    var body: some View {
        Text(status.label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .granted: return Parrot.leaf
        case .denied: return Parrot.scarlet
        case .notDetermined, .notGranted: return Parrot.amber
        }
    }
}
