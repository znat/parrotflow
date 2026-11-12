import AppKit
import ApplicationServices

/// The Claude app lists its Code sessions in a sidebar, one row each. While a
/// session other than the open one speaks, the glow marks its row instead of
/// the whole window.
final class ClaudeAppRows {

    struct Row: Equatable {
        var title: String
        var frame: CGRect
    }

    enum Glow: Equatable {
        case window(why: String)
        case row(CGRect)
    }

    /// What a session is called until it gets a title. Many rows can say it.
    static let untitled = "New session"
    /// Measured on the Claude app, 2026-11-11: a row's menu button, the row two or three
    /// levels above it, and the button on the open session's title.
    static let menuPrefix = "More options for "
    static let rowClass = "hit-row"
    static let renameSuffix = ", rename session"

    /// `open`: the open session's title, nil when none was read. Every doubt glows the window.
    static func glow(speaking: String, open: String?, rows: [Row], window: CGRect) -> Glow {
        if speaking == untitled { return .window(why: "the session has no title yet") }
        guard let open else { return .window(why: "no open session read") }
        if open == speaking { return .window(why: "it is the open session") }
        let matches = rows.filter { $0.title == speaking }
        guard let row = matches.first else { return .window(why: "no row has its title") }
        guard matches.count == 1 else { return .window(why: "\(matches.count) rows share its title") }
        guard row.frame.height > 0, window.insetBy(dx: -1, dy: -1).contains(row.frame) else {
            return .window(why: "its row is out of view")
        }
        return .row(row.frame)
    }

    let title: String
    private var reads = 0
    private var window: AXUIElement?
    private var renameButton: AXUIElement?
    /// Rows whose menu names `title`. More than one: the title is not enough.
    private var rows: [AXUIElement] = []
    private var last: Glow?

    init(title: String) {
        self.title = title
    }

    /// For `SpeakingFrame.show`: the row to glow inside `target`'s window, or nil for `target`.
    /// A walk of the window costs about 70 ms, so it runs every tenth read or when
    /// an element it found has gone. Other reads take the found elements' frames.
    func spot(_ target: AXUIElement) -> CGRect? {
        reads += 1
        if reads % 10 == 1 { walk(target) }
        let seen = reread() ?? { walk(target); return reread() }()
        let glow = seen.map { Self.glow(speaking: title, open: $0.open, rows: $0.rows, window: $0.window) }
            ?? .window(why: "the window could not be read")
        switch (last, glow) {
        case (.row?, .row): break
        case (.window?, .window): break
        case (_, .row): Log.write("claude voice: glow on the session's row in the Claude app")
        case (_, .window(let why)): Log.write("claude voice: glow on the Claude app window, \(why)")
        }
        last = glow
        if case .row(let frame) = glow { return frame }
        return nil
    }

    /// The open title and the rows, from the elements the last walk found. Nil when one has gone.
    private func reread() -> (open: String?, rows: [Row], window: CGRect)? {
        guard let window, let bounds = SpeakingFrame.frame(of: window) else { return nil }
        var open: String?
        if let renameButton {
            guard let label = SpeakingFrame.value(renameButton, kAXDescriptionAttribute) as? String,
                  label.hasSuffix(Self.renameSuffix) else { return nil }
            open = String(label.dropLast(Self.renameSuffix.count))
        }
        var found: [Row] = []
        for row in rows {
            guard let frame = SpeakingFrame.frame(of: row) else { return nil }
            found.append(Row(title: title, frame: frame))
        }
        return (open, found, bounds)
    }

    /// Finds the open session's rename button and the rows named `title`. A walk that
    /// runs out of budget or time keeps neither, so the window glows.
    private func walk(_ target: AXUIElement) {
        renameButton = nil
        rows = []
        window = SpeakingFrame.window(of: target)
        guard let window else { return }
        // The window held about 900 elements with a long conversation open: 70 ms.
        var budget = 2500
        let deadline = Date() + 0.3
        var stack = [window]
        let attributes = [kAXRoleAttribute, kAXChildrenAttribute, kAXDescriptionAttribute] as CFArray
        while let element = stack.popLast() {
            budget -= 1
            guard budget > 0, Date() < deadline else {
                renameButton = nil
                rows = []
                return
            }
            AXUIElementSetMessagingTimeout(element, 0.25)
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values) == .success,
                  let values = values as? [AnyObject], values.count == 3 else { continue }
            let role = values[0] as? String
            let label = values[2] as? String ?? ""
            if role == kAXPopUpButtonRole, label == Self.menuPrefix + title, let row = Self.row(around: element) {
                rows.append(row)
            } else if role == kAXButtonRole, label.hasSuffix(Self.renameSuffix) {
                renameButton = element
            }
            stack += values[1] as? [AXUIElement] ?? []
        }
    }

    private static func row(around menu: AXUIElement) -> AXUIElement? {
        var current = menu
        for _ in 0..<4 {
            guard let parent = SpeakingFrame.element(current, kAXParentAttribute) else { return nil }
            if (SpeakingFrame.value(parent, "AXDOMClassList") as? [String])?.contains(rowClass) == true { return parent }
            current = parent
        }
        return nil
    }
}
