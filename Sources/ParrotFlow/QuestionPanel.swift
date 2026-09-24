import AppKit
import SwiftUI

/// What the user said to a question. `text` is nil when nobody answered.
struct QuestionAnswer: Equatable {
    var text: String?
    /// `option`, `text` or `voice`; `escape` or `timeout` when `text` is nil.
    var via: String

    var reply: [String: Any] { ["answer": text as Any? ?? NSNull(), "via": via] }
}

/// Where the panel goes: next to what the question is about, never over it.
enum QuestionPlacement {
    static let gap: CGFloat = 12

    /// Below `near`, then above, right and left: the first that fits on
    /// `screen`. When none fits, the side with the most room. Everything is
    /// in AppKit coordinates; `screen` is a visible frame.
    static func place(
        _ size: CGSize, near: CGRect?, on screen: CGRect, gap: CGFloat = gap
    ) -> (frame: CGRect, side: String) {
        guard let near else {
            return (CGRect(
                x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                width: size.width, height: size.height
            ), "centre")
        }
        func alongX(_ x: CGFloat) -> CGFloat { max(screen.minX, min(x, screen.maxX - size.width)) }
        func alongY(_ y: CGFloat) -> CGFloat { max(screen.minY, min(y, screen.maxY - size.height)) }
        let x = alongX(near.midX - size.width / 2)
        let y = alongY(near.maxY - size.height)
        let sides: [(String, CGRect)] = [
            ("below", CGRect(x: x, y: near.minY - gap - size.height,
                             width: size.width, height: size.height)),
            ("above", CGRect(x: x, y: near.maxY + gap, width: size.width, height: size.height)),
            ("right", CGRect(x: near.maxX + gap, y: y, width: size.width, height: size.height)),
            ("left", CGRect(x: near.minX - gap - size.width, y: y,
                            width: size.width, height: size.height)),
        ]
        if let fits = sides.first(where: { screen.contains($0.1) }) { return (fits.1, fits.0) }
        let room: [String: CGFloat] = [
            "below": near.minY - screen.minY, "above": screen.maxY - near.maxY,
            "right": screen.maxX - near.maxX, "left": near.minX - screen.minX,
        ]
        let best = sides.max { room[$0.0, default: 0] < room[$1.0, default: 0] } ?? sides[0]
        return (best.1, "\(best.0), cut off")
    }

    /// Where a run's panel waits: beside the app's window when there is room,
    /// else in the screen's corner farthest from where the user looks. The
    /// flag says which edge stays put as the panel grows: the top, or the
    /// bottom in a bottom corner. AppKit coordinates.
    static func aside(
        _ size: CGSize, window: CGRect?, aim: CGPoint?, on screen: CGRect, gap: CGFloat = gap
    ) -> (frame: CGRect, side: String, pinTop: Bool) {
        if let window {
            let y = max(screen.minY, min(window.maxY, screen.maxY) - size.height)
            let right = CGRect(x: window.maxX + gap, y: y, width: size.width, height: size.height)
            if screen.contains(right) { return (right, "right of the window", true) }
            let left = CGRect(x: window.minX - gap - size.width, y: y,
                              width: size.width, height: size.height)
            if screen.contains(left) { return (left, "left of the window", true) }
        }
        let margin: CGFloat = 16
        let look = aim ?? window.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: screen.midX, y: screen.midY)
        let left = look.x > screen.midX
        let top = look.y < screen.midY
        let x = left ? screen.minX + margin : screen.maxX - margin - size.width
        let y = top ? screen.maxY - margin - size.height : screen.minY + margin
        return (CGRect(x: x, y: y, width: size.width, height: size.height),
                "\(top ? "top" : "bottom") \(left ? "left" : "right")", top)
    }

    /// Accessibility coordinates to AppKit ones. AX counts down from the
    /// top-left of the primary screen, which is `NSScreen.screens[0]`.
    static func flipped(_ rect: CGRect) -> CGRect {
        let primary = NSScreen.screens.first?.frame ?? .zero
        return CGRect(x: rect.minX, y: primary.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The visible frame of the screen `rect` is most on (AppKit coordinates).
    static func screen(for rect: CGRect?) -> CGRect {
        let screens = NSScreen.screens
        guard let rect else {
            return (NSScreen.main ?? screens.first)?.visibleFrame ?? .zero
        }
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        if let hit = screens.first(where: { $0.frame.contains(centre) }) { return hit.visibleFrame }
        let best = screens.max {
            $0.frame.intersection(rect).width * $0.frame.intersection(rect).height
                < $1.frame.intersection(rect).width * $1.frame.intersection(rect).height
        }
        return (best ?? NSScreen.main)?.visibleFrame ?? .zero
    }
}

/// An action run's panel: the request, the agent's plan as a checklist, and
/// what the run is doing now. A question from the run appears in it, next to
/// what the question is about; after the answer it goes back to its place.
/// When the run ends it shows how, and stays until ✕ or Escape.
///
/// A question is answered by clicking an option, by its number, by typing
/// after "Something else…", or by holding the action key and speaking.
/// Escape stops the run.
///
/// During an agent run a field under the plan takes words for the agent,
/// typed or spoken. While it has focus or holds unsent text, steps that touch
/// the screen wait (`holdsRun`). It takes keyboard focus only for typing: until then
/// the app the run acts on keeps it. Asked outside a run, it is the question
/// alone, and it goes away with the answer.
@MainActor final class QuestionPanel {
    static let shared = QuestionPanel()
    nonisolated static let seconds: TimeInterval = 60
    nonisolated static let other = "Something else…"

    var primaryColor = ContextIdentity.defaultPrimary {
        didSet { model.primaryColor = primaryColor }
    }
    var theme: ContextAppearance = .system {
        didSet { model.theme = theme }
    }
    /// The action key's name, for the footer. Nil leaves the voice line out.
    var hotkey: String? {
        didSet { model.hotkey = hotkey }
    }
    /// Where the last question went and why, for `--panels`.
    var onPlaced: ((CGRect, String) -> Void)?

    /// Called when a run's panel comes up: the pill can step back.
    var onRunShown: (() -> Void)?

    private(set) var isAsking = false
    /// A run's progress is on screen, running or ended.
    private(set) var showsRun = false
    /// Runs shown so far: a caller compares it before and after a run.
    private(set) var runsShown = 0
    /// Closed by the user during the run: updates stay off screen.
    private var dismissed = false
    private var spot: (frame: CGRect, side: String, pinTop: Bool)?
    private var runWindow: CGRect?
    private var runAim: CGPoint?
    private var runScreen: CGRect = .zero
    private var idleEscape: Any?
    /// The side and anchor last reported to `onPlaced`: a new height is not a move.
    private var placedAs: String?
    private let model = QuestionModel()
    private let keys = OfferKeys()
    private var panel: QuestionWindow?
    private var hosting: NSView?
    private var finish: ((QuestionAnswer) -> Void)?
    private var deadline: DispatchWorkItem?
    private var escapePoll: Timer?
    private var near: CGRect?
    private var screen: CGRect = .zero
    /// The app that was in front when typing had to activate this one.
    private var cameFrom: NSRunningApplication?
    /// The app the run acts on, by name, for giving it focus back.
    var runApp: String?
    /// Sent to the run and not yet taken by the agent, oldest first.
    private var steers: [String] = []
    /// Focus is on its way back to the run's app.
    private var handingBack = false
    private var steerEscape: Any?
    private var reviewFinish: (([String], String) -> Void)?
    private var reviewClock: DispatchWorkItem?
    nonisolated static let reviewSeconds: TimeInterval = 300

    /// `near` and `window` are in accessibility coordinates. With no `near`,
    /// the panel is centred on the screen `window` is on.
    func ask(
        title: String, steps: [String], question: String, options: [String],
        near: CGRect?, window: CGRect? = nil, seconds: TimeInterval = seconds
    ) async -> QuestionAnswer {
        if isAsking { answer(QuestionAnswer(text: nil, via: "timeout")) }
        return await withCheckedContinuation { (done: CheckedContinuation<QuestionAnswer, Never>) in
            finish = { done.resume(returning: $0) }
            isAsking = true
            if !showsRun {
                model.title = title
                model.plan = nil
                model.activity = nil
                model.outcome = nil
                model.running = false
                model.closable = false
                model.review = nil
                model.reviewing = false
            }
            model.asking = true
            model.steps = Array(steps.suffix(4))
            model.question = question
            model.options = Array(options.prefix(4)) + [Self.other]
            model.typing = false
            model.text = ""
            model.onPick = { [weak self] in self?.pick($0) }
            model.onSubmit = { [weak self] in self?.submit() }
            model.onCancel = { [weak self] in self?.escape() }
            self.near = near.map(QuestionPlacement.flipped)
            if !showsRun || self.near != nil {
                screen = QuestionPlacement.screen(for: self.near ?? window.map(QuestionPlacement.flipped))
            }
            Log.write("action: asking — \(question) [\(options.joined(separator: " | "))]")
            show()
            takeKeys(digits: true)
            restartClock(seconds)
        }
    }

    /// The action key's words, while a question is up.
    /// Dictation while the answer field is open goes into the field: the
    /// panel is ParrotFlow's own window, so a paste would land in the app
    /// in front instead.
    func dictate(_ words: String) -> Bool {
        if !isAsking, steerHasFocus {
            model.steerText += (model.steerText.isEmpty ? "" : " ") + words
            return true
        }
        guard isAsking, model.typing else { return false }
        model.text += (model.text.isEmpty ? "" : " ") + words
        restartClock(Self.seconds)
        return true
    }

    func answer(voice: String) {
        let said = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAsking, !said.isEmpty else { return }
        let options = Array(model.options.dropLast())
        answer(QuestionAnswer(text: Self.option(said, among: options) ?? said, via: "voice"))
    }

    /// Another surface needs the screen, or the user closed the panel.
    func close() {
        if isAsking { answer(QuestionAnswer(text: nil, via: "timeout")) }
        endReview("closed")
        model.reviewing = false
        stopIdleEscape()
        stopSteerEscape()
        if model.running { dismissed = true }
        showsRun = model.running
        panel?.orderOut(nil)
    }

    // MARK: - A run's progress

    /// A new run: its title, and nothing done yet. `window` and `aim` are in
    /// accessibility coordinates: the app's window and where the user looks.
    func begin(title: String, window: CGRect?, aim: CGPoint?) {
        if isAsking { answer(QuestionAnswer(text: nil, via: "timeout")) }
        endReview("superseded")
        model.review = nil
        model.reviewing = false
        stopIdleEscape()
        showsRun = true
        dismissed = false
        model.running = true
        model.asking = false
        model.title = Self.title(title)
        model.plan = nil
        model.activity = nil
        model.outcome = nil
        model.steps = []
        model.steers = false
        model.steerText = ""
        model.said = []
        steers = []
        handingBack = false
        startSteerEscape()
        model.closable = true
        model.onClose = { [weak self] in self?.closeButton() }
        runWindow = window.map(QuestionPlacement.flipped)
        runAim = aim.map { QuestionPlacement.flipped(CGRect(origin: $0, size: .zero)).origin }
        near = nil
        screen = QuestionPlacement.screen(for: runWindow
            ?? runAim.map { CGRect(origin: $0, size: CGSize(width: 1, height: 1)) })
        runScreen = screen
        spot = nil
        placedAs = nil
        runsShown += 1
        show()
        onRunShown?()
    }

    /// The runner's `progress` message. Only the keys it carries change.
    func update(_ progress: [String: Any]) {
        guard showsRun else { return }
        if progress.keys.contains("plan") {
            model.plan = (progress["plan"] as? [[String: Any]]).map { rows in
                rows.map {
                    RunTask(content: $0["content"] as? String ?? "",
                            status: $0["status"] as? String ?? "pending",
                            notes: $0["notes"] as? [String] ?? [])
                }
            }
        }
        if progress.keys.contains("activity") { model.activity = progress["activity"] as? String }
        if progress.keys.contains("steers") { model.steers = progress["steers"] as? Bool == true }
        if let outcome = progress["outcome"] as? String { model.outcome = outcome }
        refresh()
    }

    /// The run is over. `outcome` stands when the runner sent none.
    func end(outcome: String) {
        if isAsking { answer(QuestionAnswer(text: nil, via: "timeout")) }
        guard showsRun else { return }
        let hadKey = panel?.isKeyWindow == true
        model.running = false
        model.activity = nil
        steers = []
        stopSteerEscape()
        if hadKey { handBack() }
        if model.outcome == nil { model.outcome = outcome }
        if dismissed {
            showsRun = false
            return
        }
        refresh()
        startIdleEscape()
    }

    // MARK: - The review after a run

    /// The runner is reviewing the run that ended: a line says so.
    func awaitReview() {
        guard showsRun, !model.running else { return }
        model.reviewing = true
        refresh()
    }

    /// No review is coming.
    func reviewGone() {
        model.reviewing = false
        refresh()
    }

    /// The review under the run's outcome, with Keep and Drop on each
    /// proposal. Returns the files kept and how it ended: `answered`,
    /// `closed`, `timeout` or `superseded`. Nothing is kept unless every
    /// proposal was answered.
    func review(_ review: RunReview) async -> (kept: [String], via: String) {
        model.reviewing = false
        guard showsRun, !dismissed, !model.running, panel?.isVisible == true else {
            refresh()
            return ([], "closed")
        }
        endReview("superseded")
        return await withCheckedContinuation { (done: CheckedContinuation<([String], String), Never>) in
            reviewFinish = { done.resume(returning: ($0, $1)) }
            model.review = review
            model.kept = [:]
            model.expanded = []
            model.deciding = true
            model.onKeep = { [weak self] in self?.choose($0, keep: $1) }
            model.onExpand = { [weak self] in self?.expand($0) }
            Log.write("action: review — \(review.proposals.map(\.file).joined(separator: ", "))")
            refresh()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.endReview("timeout") }
            }
            reviewClock = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.reviewSeconds, execute: work)
            if review.proposals.isEmpty { endReview("answered") }
        }
    }

    /// A new request takes the panel.
    func dropReview() {
        endReview("superseded")
    }

    private func choose(_ index: Int, keep: Bool) {
        guard reviewFinish != nil, let review = model.review,
              review.proposals.indices.contains(index) else { return }
        model.kept[index] = keep
        refresh()
        if model.kept.count == review.proposals.count { endReview("answered") }
    }

    private func expand(_ index: Int) {
        if model.expanded.contains(index) {
            model.expanded.remove(index)
        } else {
            model.expanded.insert(index)
        }
        refresh()
    }

    private func endReview(_ via: String) {
        reviewClock?.cancel()
        reviewClock = nil
        guard let finish = reviewFinish else { return }
        reviewFinish = nil
        model.deciding = false
        let kept = via == "answered"
            ? (model.review?.proposals ?? []).indices.filter { model.kept[$0] == true }
                .map { model.review!.proposals[$0].file }
            : []
        refresh()
        Log.write("action: review \(via) — kept \(kept.isEmpty ? "nothing" : kept.joined(separator: ", "))")
        finish(kept, via)
    }

    private func refresh() {
        guard !dismissed, panel?.isVisible == true else { return }
        layout()
        // SwiftUI sizes new rows on its next pass.
        DispatchQueue.main.async { [weak self] in self?.layout() }
    }

    // MARK: - Words to the run

    /// A run that takes words from the user: an agent run, still going.
    var takesSteer: Bool { showsRun && model.running && model.steers && !dismissed }

    /// Steps that touch the screen wait while this is true: the user is
    /// typing to the run, or focus is going back to the run's app.
    var holdsRun: Bool {
        guard takesSteer else { return false }
        return handingBack || steerHasFocus
            || !model.steerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var steerHasFocus: Bool {
        takesSteer && !isAsking && model.steerFocused && panel?.isKeyWindow == true
    }

    /// Typed and sent, or said with the action key.
    func steer(_ words: String, via: String) {
        let said = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard takesSteer, !said.isEmpty else { return }
        steers.append(said)
        model.said.append(SteerLine(text: said, taken: false))
        Log.write("action: steer (\(via)) — \(said.prefix(200))")
        refresh()
    }

    /// The runner's `steer` verb: what was sent since it last asked.
    func takeSteers() -> [String] {
        let taken = steers
        steers = []
        guard !taken.isEmpty else { return [] }
        for index in model.said.indices { model.said[index].taken = true }
        refresh()
        let shown = model.said
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            self.model.said.removeAll { line in line.taken && shown.contains(line) }
            self.refresh()
        }
        return taken
    }

    private func sendSteer() {
        let typed = model.steerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard takesSteer, !typed.isEmpty else { return }
        model.steerText = ""
        steer(typed, via: "text")
        handBack()
    }

    /// The run's app gets keyboard focus back. ParrotFlow activates first:
    /// a key panel of an inactive app can stay key when the app in front is
    /// asked to activate again, and only an active app can hand activation on.
    private func handBack() {
        model.steerFocused = false
        let owner = cameFrom ?? runApp.flatMap { name in
            NSWorkspace.shared.runningApplications.first { $0.localizedName == name }
        }
        cameFrom = nil
        guard panel?.isKeyWindow == true || NSApp.isActive, let owner else { return }
        handingBack = true
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            owner.activate()
            // As after a typed answer: the next step checks the app is in front.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.handingBack = false
            }
        }
    }

    /// Escape while the panel is key, taken before the field editor sees it,
    /// so it is handled once. The global `EscapeWatch` never sees it then.
    private func startSteerEscape() {
        stopSteerEscape()
        steerEscape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            return MainActor.assumeIsolated {
                let panel = QuestionPanel.shared
                guard !panel.isAsking, panel.takesSteer, panel.panel?.isKeyWindow == true
                else { return event }
                panel.escape()
                return nil
            }
        }
    }

    private func stopSteerEscape() {
        if let steerEscape { NSEvent.removeMonitor(steerEscape) }
        steerEscape = nil
    }

    /// ✕ during a run stops it, as Escape does.
    private func closeButton() {
        if model.running { EscapeWatch.press() }
        close()
    }

    /// Escape closes an ended run's panel. A global monitor: the panel is
    /// never key here, and the key still reaches the app in front.
    private func startIdleEscape() {
        stopIdleEscape()
        idleEscape = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { QuestionPanel.shared.close() }
        }
    }

    private func stopIdleEscape() {
        if let idleEscape { NSEvent.removeMonitor(idleEscape) }
        idleEscape = nil
    }

    /// The request, cut to fit the panel's title line.
    nonisolated static func title(_ request: String) -> String {
        let words = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = words.prefix(1).uppercased() + words.dropFirst()
        guard first.count > 44 else { return first }
        let cut = first.prefix(44)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }

    /// The option a spoken or typed answer names: the whole label, or its
    /// first word when no other option starts with it ("yes", "no").
    static func option(_ said: String, among options: [String]) -> String? {
        func plain(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
                .trimmingCharacters(in: .whitespaces)
        }
        let words = plain(said)
        if let whole = options.first(where: { plain($0) == words }) { return whole }
        let first = options.filter { plain($0).split(separator: " ").first.map(String.init) == words }
        return first.count == 1 ? first[0] : nil
    }

    // MARK: - Answers

    private func pick(_ index: Int) {
        guard isAsking, model.options.indices.contains(index) else { return }
        if index == model.options.count - 1 {
            startTyping()
            return
        }
        answer(QuestionAnswer(text: model.options[index], via: "option"))
    }

    private func submit() {
        let typed = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAsking, !typed.isEmpty else { return }
        let options = Array(model.options.dropLast())
        answer(QuestionAnswer(text: Self.option(typed, among: options) ?? typed, via: "text"))
    }

    /// Escape reaches this only while the panel is key. In the run's field
    /// it clears what was typed; an empty field stops the run.
    private func escape() {
        if !isAsking, takesSteer {
            if !model.steerText.isEmpty {
                model.steerText = ""
                return
            }
            EscapeWatch.press()
            handBack()
            return
        }
        guard isAsking else { return }
        EscapeWatch.press()
        answer(QuestionAnswer(text: nil, via: "escape"))
    }

    private func answer(_ answer: QuestionAnswer) {
        guard let finish else { return }
        self.finish = nil
        isAsking = false
        keys.stop()
        deadline?.cancel()
        deadline = nil
        escapePoll?.invalidate()
        escapePoll = nil
        panel?.allowsKey = false
        model.asking = false
        model.typing = false
        if showsRun, !dismissed {
            near = nil
            screen = runScreen
            layout()
        } else {
            panel?.orderOut(nil)
        }
        Log.write("action: answered (\(answer.via)) — \(answer.text ?? "nothing")")
        // The next step checks that the target app is in front.
        if cameFrom == nil, takesSteer, panel?.isKeyWindow == true { handBack() }
        guard let owner = cameFrom else { return finish(answer) }
        cameFrom = nil
        owner.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { finish(answer) }
    }

    // MARK: - Keys and clock

    /// The digits and Escape, only while the panel is up. Without Input
    /// Monitoring the tap gets nothing; Escape then reaches `EscapeWatch`.
    private func takeKeys(digits: Bool) {
        let letters = digits ? Set((1 ... model.options.count).map(String.init)) : []
        keys.start(until: Date().addingTimeInterval(Self.seconds + 30), letters: letters,
                   onlyClaimed: true) { [weak self] key in
            guard let self else { return }
            switch key {
            case .letter(let digit):
                if let n = Int(digit) { self.pick(n - 1) }
            case .dismiss:
                self.escape()
            case .firstReturn:
                break
            }
        }
        escapePoll?.invalidate()
        escapePoll = nil
        if !keys.isRunning {
            escapePoll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isAsking, EscapeWatch.wasAsked else { return }
                    self.answer(QuestionAnswer(text: nil, via: "escape"))
                }
            }
        }
    }

    private func restartClock(_ seconds: TimeInterval) {
        deadline?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.answer(QuestionAnswer(text: nil, via: "timeout"))
            }
        }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// The one moment the panel takes keyboard focus. Teams closes its
    /// suggestion list when its window loses focus; not handled yet.
    private func startTyping() {
        model.typing = true
        takeKeys(digits: false)
        restartClock(Self.seconds)
        layout()
        // The field is only in the view after SwiftUI's next pass.
        DispatchQueue.main.async { [weak self] in self?.layout() }
        guard let panel else { return }
        panel.allowsKey = true
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, !panel.isKeyWindow else { return }
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                self.cameFrom = front
            }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - The window

    private func show() {
        if panel == nil { build() }
        layout()
        panel?.riseIntoView(makeKey: false)
    }

    private func layout() {
        guard let panel, let hosting else { return }
        let size = hosting.fittingSize
        // The window's transparent bleed counts towards the gap.
        let gap = QuestionPlacement.gap - QuestionMetrics.bleed
        var (frame, side) = QuestionPlacement.place(size, near: near, on: screen, gap: gap)
        if showsRun, near == nil {
            // Placed once per run; after that only the height changes.
            let spot = self.spot ?? QuestionPlacement.aside(
                size, window: runWindow, aim: runAim, on: screen, gap: gap)
            self.spot = spot
            let y = spot.pinTop ? spot.frame.maxY - size.height : spot.frame.minY
            frame = CGRect(x: spot.frame.minX,
                           y: max(screen.minY, min(y, screen.maxY - size.height)),
                           width: size.width, height: size.height)
            side = spot.side
        }
        panel.setFrame(frame, display: true)
        hosting.frame = NSRect(origin: .zero, size: size)
        let placed = "\(side) \(near.map { "\($0)" } ?? "")"
        if placed != placedAs { onPlaced?(frame, side) }
        placedAs = placed
    }

    private func build() {
        let hosting = FirstClickHostingView(rootView: QuestionView().environmentObject(model))
        let panel = QuestionWindow(
            contentRect: NSRect(x: 0, y: 0, width: QuestionMetrics.windowWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The Context shadow is drawn by the SwiftUI surface.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = nil
        panel.onCancel = { [weak self] in self?.escape() }
        panel.keyable = { [weak self] in
            guard let self else { return false }
            return self.takesSteer && !self.isAsking
        }
        model.onSteer = { [weak self] in self?.sendSteer() }
        model.onCancel = { [weak self] in self?.escape() }
        self.panel = panel
        self.hosting = hosting
    }
}

enum QuestionMetrics {
    static let surfaceWidth: CGFloat = 448
    static let padding: CGFloat = 16
    /// Transparent room for the three-point shadow and one-point outline.
    static let bleed: CGFloat = 7
    static let windowWidth: CGFloat = surfaceWidth + bleed * 2
}

/// Key only while the user types an answer, or during a run that takes words.
private final class QuestionWindow: NSPanel {
    var allowsKey = false
    var keyable: (() -> Bool)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { allowsKey || keyable?() == true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// A click on an option works the first time, while another app is active.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A message sent to the run; `taken` once the agent has it.
struct SteerLine: Equatable {
    var text: String
    var taken: Bool
}

struct RunTask: Equatable {
    var content: String
    /// `pending`, `in_progress`, `completed` or `cancelled`.
    var status: String
    /// What went wrong while it was in progress, newest last.
    var notes: [String]
}

/// The review of a run, as the runner sends it (`review.py`).
struct RunReview: Equatable {
    struct Proposal: Equatable {
        var file: String
        var content: String
        var why: String
        /// It replaces a file that exists.
        var exists: Bool
    }

    var nextTime: String
    var learned: [String]
    var time: [String]
    var wentWrong: [String]
    var proposals: [Proposal]

    init(nextTime: String, learned: [String], time: [String], wentWrong: [String],
         proposals: [Proposal]) {
        self.nextTime = nextTime
        self.learned = learned
        self.time = time
        self.wentWrong = wentWrong
        self.proposals = proposals
    }

    init(_ message: [String: Any]) {
        let report = message["report"] as? [String: Any] ?? [:]
        self.init(
            nextTime: report["next_time"] as? String ?? "",
            learned: report["learned"] as? [String] ?? [],
            time: report["time"] as? [String] ?? [],
            wentWrong: report["went_wrong"] as? [String] ?? [],
            proposals: (message["proposals"] as? [[String: Any]] ?? []).map {
                Proposal(file: $0["file"] as? String ?? "", content: $0["content"] as? String ?? "",
                         why: $0["why"] as? String ?? "", exists: $0["exists"] as? Bool ?? false)
            })
    }
}

final class QuestionModel: ObservableObject {
    @Published var title = ""
    @Published var plan: [RunTask]?
    @Published var activity: String?
    @Published var outcome: String?
    @Published var running = false
    @Published var asking = false
    @Published var closable = false
    @Published var steps: [String] = []
    @Published var question = ""
    @Published var options: [String] = []
    @Published var typing = false
    @Published var text = ""
    @Published var hotkey: String?
    @Published var primaryColor = ContextIdentity.defaultPrimary
    @Published var theme: ContextAppearance = .system
    /// The run takes words: the agent said so.
    @Published var steers = false
    @Published var steerText = ""
    @Published var steerFocused = false
    @Published var said: [SteerLine] = []
    var onSteer: (() -> Void)?
    /// The runner is reviewing the run that ended.
    @Published var reviewing = false
    @Published var review: RunReview?
    /// Proposal index: kept or dropped.
    @Published var kept: [Int: Bool] = [:]
    @Published var expanded: Set<Int> = []
    /// Keep and Drop are offered.
    @Published var deciding = false
    var onKeep: ((Int, Bool) -> Void)?
    var onExpand: ((Int) -> Void)?
    var onPick: ((Int) -> Void)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?
}

struct QuestionView: View {
    @EnvironmentObject private var model: QuestionModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var scale
    @FocusState private var fieldFocused: Bool
    @FocusState private var steerFocused: Bool
    @State private var hovered: Int?

    private var effectiveColorScheme: ColorScheme {
        model.theme.resolved(against: colorScheme)
    }

    private var theme: ContextTheme {
        ContextTheme(scheme: effectiveColorScheme, primaryHex: model.primaryColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let plan = model.plan, !plan.isEmpty {
                checklist(plan)
            } else if model.asking, !model.steps.isEmpty {
                steps
            }
            if model.running, !model.said.isEmpty {
                saidLines
            }
            if model.asking {
                Text(model.question)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 9)
                VStack(spacing: 5) {
                    ForEach(Array(model.options.enumerated()), id: \.offset) { index, option in
                        row(index, option)
                    }
                }
                if model.typing { field }
            } else {
                status
                if model.running, model.steers { steerField }
                if model.reviewing {
                    Text("Reviewing the run…")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.muted)
                        .padding(.top, 6)
                }
                if let review = model.review { reviewed(review) }
            }
            footer
        }
        .padding(QuestionMetrics.padding)
        .frame(width: QuestionMetrics.surfaceWidth, alignment: .topLeading)
        .foregroundStyle(theme.foreground)
        .contextSurface(
            RoundedRectangle(cornerRadius: ContextIdentity.radius, style: .continuous),
            border: theme.edge, theme: theme
        )
        .padding(QuestionMetrics.bleed)
        .environment(\.colorScheme, effectiveColorScheme)
        .onExitCommand { model.onCancel?() }
        .onChange(of: model.typing) { _, typing in
            if typing { DispatchQueue.main.async { fieldFocused = true } }
        }
        .onChange(of: steerFocused) { _, focused in model.steerFocused = focused }
        .onChange(of: model.steerFocused) { _, focused in
            if !focused, steerFocused { steerFocused = false }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ContextVoiceMark(color: theme.accent)
                .frame(width: 15, height: 15)
            Text(model.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if model.closable {
                Button { model.onClose?() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.muted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.running ? "Stop and close" : "Close")
            }
        }
        .padding(.bottom, 10)
    }

    private func checklist(_ plan: [RunTask]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(plan.enumerated()), id: \.offset) { _, task in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        mark(task.status)
                            .frame(width: 14, alignment: .center)
                        Text(task.content)
                            .font(.system(size: 13, weight: task.status == "in_progress" ? .semibold : .regular,
                                          design: .rounded))
                            .foregroundStyle(task.status == "completed" || task.status == "cancelled"
                                             ? theme.muted : theme.foreground)
                            .strikethrough(task.status == "cancelled", color: theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(task.notes.suffix(2).enumerated()), id: \.offset) { _, note in
                        Text("↳ " + note)
                            .font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(theme.muted)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 22)
                    }
                }
            }
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder private func mark(_ status: String) -> some View {
        switch status {
        case "completed":
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.accent)
        case "in_progress":
            Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.accent)
        case "cancelled":
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.muted)
        default:
            Image(systemName: "square").font(.system(size: 11, weight: .regular))
                .foregroundStyle(theme.muted)
        }
    }

    /// What the run is doing, or how it ended.
    @ViewBuilder private var status: some View {
        if let outcome = model.outcome, !model.running {
            Text(outcome)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.foreground)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(model.activity ?? "working…")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(theme.muted)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reviewed(_ review: RunReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            reviewPart("Next time", [review.nextTime].filter { !$0.isEmpty })
            reviewPart("Learned", review.learned)
            reviewPart("Where the time went", review.time)
            reviewPart("What went wrong", review.wentWrong)
            ForEach(Array(review.proposals.enumerated()), id: \.offset) { index, proposal in
                proposalRow(index, proposal)
            }
        }
        .padding(.top, 12)
    }

    @ViewBuilder private func reviewPart(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.muted)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func proposalRow(_ index: Int, _ proposal: RunReview.Proposal) -> some View {
        let open = model.expanded.contains(index)
        let choice = model.kept[index]
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button { model.onExpand?(index) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.muted)
                            .frame(width: 10)
                        Text(proposal.file)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.foreground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(proposal.exists ? "update" : "new")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? "Hide the file" : "Show the file")
                Spacer(minLength: 0)
                if model.deciding, choice == nil {
                    choiceButton("Keep", lit: true) { model.onKeep?(index, true) }
                    choiceButton("Drop", lit: false) { model.onKeep?(index, false) }
                } else {
                    Text(choice == true ? (model.deciding ? "Keeping" : "Saved")
                         : choice == false ? "Dropped" : "Not saved")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(choice == true ? theme.accent : theme.muted)
                }
            }
            Text(proposal.why)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if open {
                Text(proposal.content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(40)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(theme.controlFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .padding(8)
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(theme.controlEdge, lineWidth: 1)
        }
    }

    private func choiceButton(_ title: String, lit: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(lit ? theme.accent : theme.muted)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(lit ? theme.accent.opacity(0.13) : theme.controlFill,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(lit ? theme.accent.opacity(0.65) : theme.controlEdge, lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.accent)
                    Text(step)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.bottom, 12)
    }

    private func row(_ index: Int, _ option: String) -> some View {
        let other = index == model.options.count - 1
        let lit = hovered == index || (other && model.typing)
        return Button { model.onPick?(index) } label: {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.muted)
                    .frame(minWidth: 9)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(theme.controlFill, in: RoundedRectangle(cornerRadius: 3))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(theme.controlEdge, lineWidth: 0.5)
                    }
                Text(option)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(other ? theme.muted : theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                lit ? theme.accent.opacity(0.13) : theme.controlFill,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(lit ? theme.accent.opacity(0.65) : theme.controlEdge, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = index } else if hovered == index { hovered = nil }
        }
    }

    private var field: some View {
        TextField("Type your answer", text: $model.text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .focused($fieldFocused)
            .onSubmit { model.onSubmit?() }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(theme.foreground)
            .background(theme.controlFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        fieldFocused ? theme.accent : theme.controlEdge,
                        lineWidth: fieldFocused ? 1.25 : 1
                    )
            }
            .padding(.top, 8)
    }

    /// What the user sent to the run: a clock until the agent takes it, then a tick.
    private var saidLines: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(model.said.suffix(2).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: line.taken ? "checkmark" : "clock")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(line.taken ? theme.accent : theme.muted)
                        .frame(width: 14, alignment: .center)
                    Text("You: " + line.text)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.muted)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.bottom, 10)
    }

    private var steerField: some View {
        TextField("Tell it something while it works", text: $model.steerText)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .focused($steerFocused)
            .onSubmit { model.onSteer?() }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(theme.foreground)
            .background(theme.controlFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        steerFocused ? theme.accent : theme.controlEdge,
                        lineWidth: steerFocused ? 1.25 : 1
                    )
            }
            .padding(.top, 10)
    }

    private var footer: some View {
        Text(footerText)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(theme.muted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 12)
    }

    private var footerText: String {
        if !model.asking, model.running, model.steers, model.steerFocused || !model.steerText.isEmpty {
            return "paused while you type · ↩ sends · esc " + (model.steerText.isEmpty ? "stops" : "clears")
        }
        if model.deciding { return "keep or drop each · esc closes and saves nothing" }
        if !model.asking { return model.running ? "esc stops" : "esc closes" }
        var parts: [String] = []
        if model.typing { parts.append("↩ sends") }
        if let hotkey = model.hotkey, !hotkey.isEmpty { parts.append("hold \(hotkey) to answer by voice") }
        parts.append("esc stops")
        return parts.joined(separator: " · ")
    }
}
