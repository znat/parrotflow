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
    func show(window: AXUIElement) {
        hiding?.cancel()
        shown = 0
        target = window
        guard let frame = Self.frame(of: window) else { return hide(now: true) }
        let panel = self.panel ?? makePanel()
        place(panel, around: frame)
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        }
        follow?.invalidate()
        follow = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self, let target = self.target, let panel = self.panel else { return }
            guard let frame = Self.frame(of: target) else { return self.hide(now: true) }
            self.place(panel, around: frame)
        }
    }

    /// Half a second after the voice stops, so a pause between sentences
    /// does not blink.
    func hide(now: Bool = false) {
        hiding?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.follow?.invalidate()
            self.target = nil
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
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

    private func place(_ panel: NSPanel, around window: CGRect) {
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
    /// only window, else the one whose title names the project, else its
    /// main window. The caller keeps the answer, so it is not re-guessed
    /// each time focus moves.
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
        return element(app, kAXMainWindowAttribute) ?? sized[0]
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
