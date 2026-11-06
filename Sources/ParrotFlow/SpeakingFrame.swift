import AppKit
import ApplicationServices
import QuartzCore

/// A glow around the window of the Claude session that is speaking. It
/// brightens with the voice and follows the window if it moves.
final class SpeakingFrame {

    var color = ContextIdentity.nsColor(ContextIdentity.defaultPrimary) {
        didSet { glow.strokeColor = color.cgColor; glow.shadowColor = color.cgColor }
    }

    private var panel: NSPanel?
    private let glow = CAShapeLayer()
    private var target: (host: pid_t, project: String)?
    private var follow: Timer?
    private var hiding: DispatchWorkItem?
    /// Room outside the window for the glow to spread into.
    private let margin: CGFloat = 16

    func show(claude pid: pid_t, project: String) {
        hiding?.cancel()
        guard let host = Self.hostApp(of: pid) else { return hide(now: true) }
        target = (host.processIdentifier, project)
        guard let frame = Self.windowFrame(host: host.processIdentifier, project: project) else {
            return hide(now: true)
        }
        let panel = self.panel ?? makePanel()
        place(panel, around: frame)
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        }
        follow?.invalidate()
        follow = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self, let target = self.target, let panel = self.panel,
                  let frame = Self.windowFrame(host: target.host, project: target.project) else { return }
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

    /// 0 to about 0.3: the voice's loudness.
    func level(_ rms: Float) {
        let lift = CGFloat(min(1, rms * 5))
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        glow.opacity = Float(0.45 + 0.55 * lift)
        glow.shadowRadius = 6 + 12 * lift
        CATransaction.commit()
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
        glow.fillColor = nil
        glow.lineWidth = 3
        glow.strokeColor = color.cgColor
        glow.shadowColor = color.cgColor
        glow.shadowOffset = .zero
        glow.shadowOpacity = 1
        glow.shadowRadius = 6
        glow.opacity = 0.45
        view.layer?.addSublayer(glow)
        panel.contentView = view
        self.panel = panel
        return panel
    }

    private func place(_ panel: NSPanel, around window: CGRect) {
        let outer = window.insetBy(dx: -margin, dy: -margin)
        if panel.frame != outer { panel.setFrame(outer, display: false) }
        let bounds = CGRect(origin: .zero, size: outer.size)
        glow.frame = bounds
        glow.path = CGPath(
            roundedRect: bounds.insetBy(dx: margin - 1.5, dy: margin - 1.5),
            cornerWidth: 11, cornerHeight: 11, transform: nil
        )
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

    /// The host's only window, else the one whose title names the project,
    /// else its main window. In AppKit coordinates.
    static func windowFrame(host pid: pid_t, project: String) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        let framed = windows.compactMap { window -> (AXUIElement, CGRect)? in
            guard let frame = frame(of: window), frame.width > 200, frame.height > 150 else { return nil }
            return (window, frame)
        }
        guard !framed.isEmpty else { return nil }
        if framed.count == 1 { return framed[0].1 }
        if !project.isEmpty, let named = framed.first(where: {
            title(of: $0.0)?.localizedCaseInsensitiveContains(project) == true
        }) {
            return named.1
        }
        var main: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &main) == .success,
           let main, CFGetTypeID(main) == AXUIElementGetTypeID() {
            // swiftlint:disable:next force_cast
            if let frame = frame(of: main as! AXUIElement) { return frame }
        }
        return framed[0].1
    }

    private static func title(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
        return value as? String
    }

    /// Accessibility measures from the top of the main screen, AppKit from the bottom.
    private static func frame(of window: AXUIElement) -> CGRect? {
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
