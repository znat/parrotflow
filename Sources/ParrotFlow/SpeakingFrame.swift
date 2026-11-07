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
        if !coveredNow, panel.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        }
        follow?.invalidate()
        follow = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self, self.target != nil, let panel = self.panel else { return }
            guard let frame = self.resolve() else { return self.hide(now: true) }
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
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              var queue = value as? [AXUIElement] else { return nil }
        var depth = 0
        while !queue.isEmpty, depth < 6 {
            var next: [AXUIElement] = []
            for element in queue {
                let kind = role(of: element)
                if kind == kAXWindowRole || kind == kAXScrollAreaRole, let frame = frame(of: element),
                   close(frame, rect) {
                    return element
                }
                var kids: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &kids) == .success,
                   let children = kids as? [AXUIElement] {
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
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 },
                                                 completionHandler: { if panel.alphaValue == 0 { panel.orderOut(nil) } })
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

    /// Whether another app's window sits in front of `rect`'s centre. The glow
    /// floats above everything, so around a covered window it looked like it
    /// framed the window in front.
    static func covered(_ rect: CGRect, host: pid_t) -> Bool {
        guard let top = NSScreen.screens.first?.frame.maxY,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        // Window bounds are measured from the top of the main screen, like Accessibility.
        let centre = CGPoint(x: rect.midX, y: top - rect.midY)
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
                  CGRect(x: x, y: y, width: width, height: height).contains(centre) else { continue }
            return (window[kCGWindowOwnerPID as String] as? pid_t) != host
        }
        return false
    }

    private func place(_ panel: NSPanel, around window: CGRect) {
        let hidden = targetHost.map { Self.covered(window, host: $0) } ?? false
        if hidden != coveredNow {
            coveredNow = hidden
            if hidden { Log.write("claude voice: glow off, the speaking window is behind another app") }
        }
        if hidden { panel.alphaValue = 0 } else if panel.isVisible, panel.alphaValue == 0 { panel.alphaValue = 1 }
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

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return value as? String
    }

    /// A first guess for a session no prompt has been seen from: the host's
    /// only window, else the one whose title names the project. Nil when that
    /// is ambiguous: the main window is whichever has focus, so guessing it
    /// framed the wrong window.
    static func guessWindow(host pid: pid_t, project: String) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        let sized = windows.filter { window in
            guard let frame = frame(of: window) else { return false }
            return frame.width > 200 && frame.height > 150
        }
        guard !sized.isEmpty else { return nil }
        if sized.count == 1 { return sized[0] }
        if !project.isEmpty,
           let named = sized.first(where: { title(of: $0)?.localizedCaseInsensitiveContains(project) == true }) {
            return named
        }
        return nil
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }

    private static func title(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
        return value as? String
    }

    /// Accessibility measures from the top of the main screen, AppKit from the bottom.
    static func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
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
