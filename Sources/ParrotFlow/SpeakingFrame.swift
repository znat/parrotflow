import AppKit
import ApplicationServices
import QuartzCore

/// A glow around the window of the Claude session that is speaking. It
/// brightens with the voice and follows the window if it moves.
final class SpeakingFrame {

    /// The configured purple, lightened: as it is, #5F46CA read as too dark.
    var color = ContextIdentity.nsColor(ContextIdentity.defaultPrimary) {
        didSet { paint() }
    }

    private var panel: NSPanel?
    /// A bright line on the window's edge, and a wide halo around it.
    private let core = CAShapeLayer()
    private let halo = CAShapeLayer()
    /// The voice's lift, falling slowly so the glow pulses instead of flickering.
    private var shown: CGFloat = 0
    private var target: AXUIElement?
    private var follow: Timer?
    private var hiding: DispatchWorkItem?
    /// Room outside the window for the halo to spread into.
    private let margin: CGFloat = 48

    /// Frames this one window and follows it. A window that closes hides the frame.
    /// Called when the frame re-ties to the element now at the remembered place.
    var onRetarget: ((AXUIElement, CGRect) -> Void)?
    private var targetHost: pid_t?
    private var coveredNow = false
    private var lastRect: CGRect?

    /// Frames `window` (a window or a pane) and follows it. `rect` is where it
    /// was last seen: if the element dies or starts answering for another pane,
    /// the one still at `rect` is used instead, never the one with focus.
    func show(window: AXUIElement, host: pid_t, rect: CGRect?) {
        hiding?.cancel()
        follow?.invalidate()
        shown = 0
        target = window
        targetHost = host
        lastRect = rect
        guard let frame = resolve() else { return hide(now: true) }
        let panel = self.panel ?? makePanel()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        place(panel, around: frame)
        // Always run: during a fade-out alphaValue still reads 1, and that fade would end at 0.
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = coveredNow ? 0 : 1 }
        // A read that timed out also gives nil, and `show` runs again only when the speaking session changes.
        var misses = 0
        follow = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self, self.target != nil, let panel = self.panel else { return }
            guard let frame = self.resolve() else {
                misses += 1
                return misses >= 3 ? self.hide(now: true) : ()
            }
            misses = 0
            self.place(panel, around: frame)
        }
    }

    /// Where the framed element is now. Ghostty rebuilds its accessibility
    /// elements as focus moves, and a kept reference then dies or reports the
    /// focused pane: the glow followed focus.
    private func resolve() -> CGRect? {
        guard let target, let host = targetHost else { return nil }
        let now = Self.frame(of: target)
        if let last = lastRect {
            if let now, Self.close(now, last) { return now }
            if let found = Self.element(at: last, host: host) {
                self.target = found
                onRetarget?(found, last)
                return last
            }
        }
        guard let now else { return nil }
        lastRect = now
        onRetarget?(target, now)
        return now
    }

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 4 && abs(a.minY - b.minY) < 4 && abs(a.width - b.width) < 4 && abs(a.height - b.height) < 4
    }

    /// The host's window or pane at `rect`, looked up afresh.
    static func element(at rect: CGRect, host pid: pid_t) -> AXUIElement? {
        guard var queue = value(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]
        else { return nil }
        var depth = 0
        // 24 children over 6 levels is millions of calls on the main thread in a deep tree.
        var budget = 400
        while !queue.isEmpty, depth < 6 {
            var next: [AXUIElement] = []
            for element in queue {
                budget -= 1
                if budget < 0 { return nil }
                let kind = role(of: element)
                if kind == kAXWindowRole || kind == kAXScrollAreaRole, let frame = frame(of: element),
                   close(frame, rect) {
                    return element
                }
                if let children = value(element, kAXChildrenAttribute) as? [AXUIElement] {
                    next += children.prefix(24)
                }
            }
            queue = next
            depth += 1
        }
        return nil
    }

    /// Half a second after the voice stops, so a pause between sentences
    /// does not blink.
    func hide(now: Bool = false) {
        hiding?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.follow?.invalidate()
            self.target = nil
            // A `show` since then replaces this fade and its completion runs at once.
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in
                                                     if self?.target == nil { panel.orderOut(nil) }
                                                 })
        }
        hiding = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.5), execute: work)
    }

    /// 0 to about 0.3: the voice's loudness. Rises at once, falls over
    /// about a quarter of a second.
    func level(_ rms: Float) {
        shown = max(CGFloat(min(1, rms * 10)), shown * 0.82)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.05)
        core.opacity = Float(0.7 + 0.2 * shown)
        core.lineWidth = 2 + 2 * shown
        halo.opacity = Float(0.35 + 0.5 * shown)
        halo.lineWidth = 5 + 7 * shown
        halo.shadowRadius = 10 + 16 * shown
        CATransaction.commit()
    }

    private func paint() {
        let bright = color.blended(withFraction: 0.45, of: .white) ?? color
        let vivid = color.blended(withFraction: 0.25, of: .white) ?? color
        core.strokeColor = bright.cgColor
        core.shadowColor = bright.cgColor
        halo.strokeColor = vivid.withAlphaComponent(0.6).cgColor
        halo.shadowColor = vivid.cgColor
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.alphaValue = 0
        let view = NSView()
        view.wantsLayer = true
        for layer in [halo, core] {
            layer.fillColor = nil
            layer.shadowOffset = .zero
            layer.shadowOpacity = 1
            view.layer?.addSublayer(layer)
        }
        core.lineWidth = 2
        core.shadowRadius = 4
        halo.lineWidth = 5
        halo.shadowRadius = 10
        halo.opacity = 0.35
        paint()
        panel.contentView = view
        self.panel = panel
        return panel
    }

    /// Whether `rect` is out of sight. The glow floats above everything, so
    /// around a covered window it looked like it framed the window in front.
    static func covered(_ rect: CGRect, host: pid_t) -> Bool {
        guard let top = NSScreen.screens.first?.frame.maxY,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let windows = list.compactMap { window -> (pid: pid_t, bounds: CGRect)? in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"]
            else { return nil }
            return (pid, CGRect(x: x, y: y, width: width, height: height))
        }
        return covered(rect, host: host, top: top, windows: windows)
    }

    /// `windows` are on screen, front to back, measured from the top of the main
    /// screen like Accessibility. Out of sight: the first one at the centre is
    /// another app's or another window of the host, or none is there (minimized,
    /// on another Space, the app hidden).
    static func covered(_ rect: CGRect, host: pid_t, top: CGFloat, windows: [(pid: pid_t, bounds: CGRect)]) -> Bool {
        let flipped = CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        let centre = CGPoint(x: flipped.midX, y: flipped.midY)
        guard let front = windows.first(where: { $0.bounds.contains(centre) }) else { return true }
        return front.pid != host || !front.bounds.insetBy(dx: -4, dy: -4).contains(flipped)
    }

    private func place(_ panel: NSPanel, around window: CGRect) {
        let hidden = targetHost.map { Self.covered(window, host: $0) } ?? false
        if hidden != coveredNow {
            coveredNow = hidden
            panel.alphaValue = hidden ? 0 : 1
            if hidden { Log.write("claude voice: glow off, the speaking window is out of sight") }
        }
        let outer = window.insetBy(dx: -margin, dy: -margin)
        if panel.frame != outer { panel.setFrame(outer, display: false) }
        let bounds = CGRect(origin: .zero, size: outer.size)
        let edge = CGPath(
            roundedRect: bounds.insetBy(dx: margin - 2, dy: margin - 2),
            cornerWidth: 12, cornerHeight: 12, transform: nil
        )
        for layer in [halo, core] {
            layer.frame = bounds
            layer.path = edge
        }
    }

    // MARK: - Finding the window

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    /// The app Claude runs in: the first ancestor of its process that is a
    /// regular app (the Claude app, Terminal, Ghostty, VS Code…). None under
    /// tmux, whose server is not a child of any app.
    static func hostApp(of pid: pid_t) -> NSRunningApplication? {
        var current: pid_t? = pid
        for _ in 0..<24 {
            guard let process = current else { return nil }
            if let app = NSRunningApplication(processIdentifier: process), app.activationPolicy == .regular {
                return app
            }
            current = parent(of: process)
        }
        return nil
    }

    /// The window the host has focused now. Read when a prompt is sent, it
    /// is the window that session lives in.
    static func focusedWindow(host pid: pid_t) -> AXUIElement? {
        element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
    }

    /// The split pane that has focus, when the host has panes: the scroll
    /// area around the focused text. Ghostty 1.4 exposes each split this way
    /// ("Left pane" > AXScrollArea > AXTextArea). Nil anywhere else, and for
    /// a pane that fills its window.
    static func focusedPane(host pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard var current = element(app, kAXFocusedUIElementAttribute),
              let window = element(app, kAXFocusedWindowAttribute),
              let windowFrame = frame(of: window) else { return nil }
        for _ in 0..<4 {
            if role(of: current) == kAXScrollAreaRole, let paneFrame = frame(of: current),
               paneFrame.width > 200, paneFrame.height > 120,
               paneFrame.width < windowFrame.width - 40 || paneFrame.height < windowFrame.height - 80 {
                return current
            }
            guard let parent = element(current, kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    /// These calls run on the main thread. A timeout set on an element covers
    /// only that element, and the default lets a hung host hold the thread for seconds.
    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func role(of element: AXUIElement) -> String? {
        value(element, kAXRoleAttribute) as? String
    }

    /// A first guess for a session no prompt has been seen from: the host's
    /// only window, else the one whose title names the project. Nil when that
    /// is ambiguous: the main window is whichever has focus, so guessing it
    /// framed the wrong window.
    static func guessWindow(host pid: pid_t, project: String) -> AXUIElement? {
        let sized = sizedWindows(host: pid)
        guard !sized.isEmpty else { return nil }
        if sized.count == 1 { return sized[0] }
        if !project.isEmpty,
           let named = sized.first(where: { title(of: $0)?.localizedCaseInsensitiveContains(project) == true }) {
            return named
        }
        return nil
    }

    /// The host's windows big enough to hold a session.
    private static func sizedWindows(host pid: pid_t, limit: Int = .max) -> [AXUIElement] {
        let windows = value(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.prefix(limit).filter { window in
            guard let frame = frame(of: window) else { return false }
            return frame.width > 200 && frame.height > 150
        }
    }

    // MARK: - Codex

    /// A process on the way up from the agent's.
    struct Ancestor {
        var pid: pid_t
        var bundle: String?
        var regular = false
        var arguments: [String] = []
    }

    enum CodexHost: Equatable {
        case app(pid_t)
        /// The pid says nothing of the window: find it by its title.
        case byTitle
        case none
    }

    /// Where a Codex session runs. The desktop app and the VS Code extension
    /// start a `codex app-server` of their own. Codex 0.157 and later serve
    /// terminal sessions from one shared app server instead, started with
    /// `setsid` by the first terminal session, then left to launchd.
    static func codexHost(_ chain: [Ancestor]) -> CodexHost {
        var server = false
        for (index, process) in chain.enumerated() {
            if process.arguments.contains("app-server") {
                let parent = index + 1 < chain.count ? chain[index + 1].arguments.first : nil
                let underCodex = parent.map { ($0 as NSString).lastPathComponent == "codex" } ?? false
                if process.arguments.contains("--managed-daemon") || underCodex { return .byTitle }
                server = true
            } else if process.regular, process.bundle != "com.openai.codex.cli" {
                // The CLI inside ChatGPT.app is a bundle too, with no window.
                return .app(process.pid)
            }
        }
        return server ? .byTitle : .none
    }

    static func ancestors(of pid: pid_t) -> [Ancestor] {
        var chain: [Ancestor] = []
        var current: pid_t? = pid
        while let process = current, chain.count < 24 {
            let app = NSRunningApplication(processIdentifier: process)
            chain.append(Ancestor(pid: process, bundle: app?.bundleIdentifier,
                                  regular: app?.activationPolicy == .regular, arguments: arguments(of: process)))
            current = parent(of: process)
        }
        return chain
    }

    private static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return arguments(procargs: Array(buffer.prefix(size)))
    }

    /// `KERN_PROCARGS2`: argc as an Int32, the executable path, NUL padding,
    /// then the arguments and the environment, each ending in a NUL.
    static func arguments(procargs: [UInt8]) -> [String] {
        guard procargs.count > 4 else { return [] }
        let argc = procargs.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        return procargs.dropFirst(4).split(separator: 0).dropFirst().prefix(argc)
            .map { String(bytes: $0, encoding: .utf8) ?? "" }
    }

    /// Whether `title` names `project` as Codex writes it there: whole, or cut to
    /// 21 characters and "..." past 24. "parrotflow" is not in "parrotflow-scratch".
    static func names(_ title: String?, project: String) -> Bool {
        guard let title, !project.isEmpty else { return false }
        let needle = project.count > 24 ? String(project.prefix(21)) + "..." : project
        func wordy(_ index: String.Index?) -> Bool {
            guard let index else { return false }
            let letter = title[index]
            return letter.isLetter || letter.isNumber || "-_.".contains(letter)
        }
        var from = title.startIndex
        while let found = title.range(of: needle, options: .caseInsensitive, range: from..<title.endIndex) {
            let before = found.lowerBound > title.startIndex ? title.index(before: found.lowerBound) : nil
            let after = found.upperBound < title.endIndex ? found.upperBound : nil
            if !wordy(before), !wordy(after) { return true }
            from = title.index(after: found.lowerBound)
        }
        return false
    }

    /// The only window whose title names the project, once those at `taken`
    /// are set aside. None, or two: nil, since a wrong glow is worse than none.
    static func pick(_ windows: [(title: String?, rect: CGRect?)], project: String, taken: [CGRect]) -> Int? {
        let free = windows.indices.filter { index in
            guard names(windows[index].title, project: project) else { return false }
            return !taken.contains { place in windows[index].rect.map { close($0, place) } ?? false }
        }
        return free.count == 1 ? free[0] : nil
    }

    /// The window, in any of the running `hosts`, that `pick` chooses.
    static func titledWindow(project: String, hosts: Set<String>, taken: [CGRect]) -> (host: pid_t, window: AXUIElement)? {
        var found: [(host: pid_t, window: AXUIElement)] = []
        for app in NSWorkspace.shared.runningApplications where hosts.contains(app.bundleIdentifier ?? "") {
            found += sizedWindows(host: app.processIdentifier, limit: 20).map { (app.processIdentifier, $0) }
        }
        let described = found.map { (title: title(of: $0.window), rect: frame(of: $0.window)) }
        return pick(described, project: project, taken: taken).map { found[$0] }
    }

    /// The host's focused window, when its title names the project.
    static func focusedWindow(host pid: pid_t, naming project: String) -> AXUIElement? {
        focusedWindow(host: pid).flatMap { names(title(of: $0), project: project) ? $0 : nil }
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let found = value(parent, attribute), CFGetTypeID(found) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (found as! AXUIElement)
    }

    /// The window a pane sits in. A window is its own.
    static func window(of element: AXUIElement) -> AXUIElement? {
        role(of: element) == kAXWindowRole ? element : Self.element(element, kAXWindowAttribute)
    }

    private static func title(of window: AXUIElement) -> String? {
        value(window, kAXTitleAttribute) as? String
    }

    /// Accessibility measures from the top of the main screen, AppKit from the bottom.
    static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = value(window, kAXPositionAttribute), let size = value(window, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        // swiftlint:disable force_cast
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        // swiftlint:enable force_cast
        guard let top = NSScreen.screens.first?.frame.maxY else { return nil }
        return CGRect(x: origin.x, y: top - origin.y - extent.height, width: extent.width, height: extent.height)
    }
}
