import AppKit
import ApplicationServices

/// What is on screen in an app's focused window, in the shape a model can read.
///
/// A port of the prototype's `tools/axsnap.swift`, moved in here because
/// ParrotFlow already holds the Accessibility grant that walk needs and a
/// second binary would need its own. The item shape is unchanged on purpose:
/// a snapshot this writes can be read by `tools/jev_probe.py`, and the
/// snapshot that scored 8/8 on 2026-09-20 can be read by this. Same file,
/// same decision, or the port is wrong.
///
/// It reads one window — the app's focused one — and not the screen. A
/// window is what an instruction is about, it is what the accessibility API
/// is fast at, and the alternative is every window of every app for a
/// sentence that names one thing. During a run it also reads the parts of
/// the app that opened since the run's first read — see `Parts`.
enum ScreenTargets {

    // MARK: - The shape

    /// One thing on screen worth naming out loud.
    ///
    /// `x`/`y` are the centre and `w`/`h` the size, in accessibility
    /// coordinates, because that is what a click needs.
    struct Item: Codable, Equatable {
        var kind: String
        var role: String
        var name: String
        var value: String
        var x: Int
        var y: Int
        var w: Int
        var h: Int
        var actions: [String]
        /// Set when the item came from a part of the app that opened after
        /// the run started — "pop-up", "menu", "dialog", "sheet", "window" —
        /// rather than from the front window. Optional so that saved
        /// snapshots still read.
        var origin: String?
        /// "focused", "selected", "expanded", "checked": what the name does
        /// not say. Optional so that saved snapshots still read.
        var states: [String]?
        /// The same control across reads: a hash of role, name and the roles
        /// above it, then `.2`, `.3` for twins in walk order. No position.
        var key: String? = nil

        enum CodingKeys: String, CodingKey {
            case kind, role, name, value, x, y, w, h, actions, key
            case origin = "in"
            case states = "state"
        }

        var point: CGPoint { CGPoint(x: Double(x), y: Double(y)) }
        var isClickable: Bool { kind == Kind.click || kind == Kind.text }

        /// One choice in a list that is open right now — a suggestion under
        /// a recipient field, a row in a menu.
        ///
        /// Two things follow. It takes a real click: pressing one through
        /// the accessibility API reports success and closes the list without
        /// choosing anything. And activating it finishes the step — picking
        /// from a list is not opening a conversation, so nothing should run
        /// on from it.
        var isChoiceInAList: Bool {
            role == kAXMenuItemRole || (origin != nil && Self.rowRoles.contains(role))
        }

        /// What a row of a pop-up list is made of. Outlook's suggestion rows
        /// are `AXCell`s, or an `AXStaticText` holding the address, with no
        /// press action.
        static let rowRoles: Set<String> = ["AXCell", kAXRowRole, kAXMenuItemRole, kAXStaticTextRole]

        /// A field that narrows a list as you type into it — Slack's
        /// recipient field, a search box. The only kind of field a *name*
        /// belongs in: everywhere else, a name is just words.
        ///
        /// The role alone is Slack-shaped. Outlook's is
        /// `AXTextField "To Recipients"` — measured, at 1881,360 in a live
        /// compose form — so by role it read as a plain box, and a run that
        /// had reached the right field clicked it and stopped to wait for
        /// dictation instead of typing the name to narrow the list. What the
        /// field is called is the other half of the answer.
        var looksThingsUp: Bool {
            if role == kAXComboBoxRole || role == "AXSearchField" { return true }
            guard kind == Kind.text else { return false }
            let called = name.lowercased()
            return Item.fieldsThatFilter.contains { called.contains($0) }
        }

        /// Names that mean "type here and a list narrows". Substrings, so
        /// "To Recipients" and "Recipients (To)" both match.
        static let fieldsThatFilter = ["recipient", "search", "to:", "cc", "bcc"]
    }

    enum Kind {
        static let click = "click"
        static let text = "text"
        static let label = "label"
        static let other = "other"
        /// "and 3,140 more": the children of a wide element that were not read.
        static let more = "more"
    }

    /// An element with more children than this, and no list of the visible
    /// ones, has only this many read, plus the ones next to the caret when
    /// it is inside it, and otherwise its last few. The rest become one
    /// `Kind.more` item.
    static let wideChildren = 20

    /// The app's top-level parts — windows, pop-ups, menus, sheets — at the
    /// first read of a run. A part that is not in here opened since, and is
    /// read along with the front window. One that is, is never walked.
    struct Parts {
        let pid: pid_t
        let elements: [AXUIElement]
    }

    struct Rect: Codable, Equatable { var x: Int; var y: Int; var w: Int; var h: Int }

    struct Snapshot: Codable, Equatable {
        var app: String
        var window: String
        var frame: Rect
        var items: [Item]

        /// Where an item sits down the window, 0 at the top and 1 at the
        /// bottom. The composer and the search field are told apart by this
        /// and nothing else — neither carries a name.
        func relativeY(of item: Item) -> Double {
            Double(item.y - frame.y) / Double(max(frame.h, 1))
        }

        var json: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(self) else { return "{}" }
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        static func read(fromFile path: String) throws -> Snapshot {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        }
    }

    enum Failure: LocalizedError {
        case notTrusted
        case noWindow(String)
        case noSuchApp(String)

        var errorDescription: String? {
            switch self {
            case .notTrusted:
                return "Accessibility is not granted, so nothing on screen can be read."
            case .noWindow(let name):
                return "\(name) has no window that publishes anything."
            case .noSuchApp(let name):
                return "\(name) is not running."
            }
        }
    }

    // MARK: - Taking one

    /// The app in front, whose focused window an action works in. Nil when
    /// that is ParrotFlow itself.
    static func frontmostApp() -> String? {
        NSWorkspace.shared.frontmostApplication.flatMap {
            $0.processIdentifier == getpid() ? nil : $0.localizedName
        }
    }

    /// The focused window of a named app, else its first window. `--app` in
    /// the prototype: it is how a snapshot is taken of something that is not
    /// in front, and how the same window can be snapshotted twice.
    static func snapshot(ofApp name: String, budget: Int = 8000) throws -> Snapshot {
        var parts: Parts?
        return try snapshot(ofApp: name, budget: budget, since: &parts)
    }

    static func snapshot(
        ofApp name: String, budget: Int = 8000, since parts: inout Parts?
    ) throws -> Snapshot {
        guard AXIsProcessTrusted() else { throw Failure.notTrusted }
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == name || $0.bundleIdentifier == name
        }) else { throw Failure.noSuchApp(name) }
        let pid = running.processIdentifier
        wake(pid)
        let app = AXUIElementCreateApplication(pid)
        let window = (attribute(app, kAXFocusedWindowAttribute) as! AXUIElement?)
            ?? (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first
        guard let window else { throw Failure.noWindow(name) }
        return read(window, pid: pid, budget: budget, since: &parts)
    }

    /// The front window, and the parts of the app that were not there when
    /// `parts` was taken. Only the list of parts is read to tell: windows
    /// that were already open are never walked.
    private static func read(
        _ window: AXUIElement, pid: pid_t, budget: Int, since parts: inout Parts?
    ) -> Snapshot {
        let now = topLevel(of: AXUIElementCreateApplication(pid))
        guard let known = parts, known.pid == pid else {
            parts = Parts(pid: pid, elements: now)
            return walk(window, pid: pid, budget: budget)
        }
        let front = frame(of: window)
        let opened = now.filter { part in
            guard !CFEqual(part, window), !known.elements.contains(where: { CFEqual($0, part) })
            else { return false }
            let box = frame(of: part)
            if let box, box == front { return false }
            return box.map { $0.width > 0 && $0.height > 0 } ?? true
        }
        return walk(window, pid: pid, budget: budget, opened: opened)
    }

    /// Windows, pop-ups, menus and sheets: the app element's windows and its
    /// children, once each. Outlook's suggestion list is one of the children
    /// and not a window.
    static func topLevel(of app: AXUIElement) -> [AXUIElement] {
        var all = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        for child in attribute(app, kAXChildrenAttribute) as? [AXUIElement] ?? []
        where !all.contains(where: { CFEqual($0, child) }) {
            all.append(child)
        }
        return all
    }

    /// What a part that opened is called in a snapshot's `in`.
    private static func origin(of part: AXUIElement) -> String {
        let role = string(part, kAXRoleAttribute) ?? ""
        let subrole = string(part, kAXSubroleAttribute) ?? ""
        if role == kAXSheetRole { return "sheet" }
        if role == kAXMenuRole || role == kAXMenuBarRole { return "menu" }
        if subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole { return "dialog" }
        if role == kAXWindowRole && subrole == kAXStandardWindowSubrole { return "window" }
        return "pop-up"
    }

    /// Presses whatever is at a point through the accessibility API, without
    /// touching the mouse. Says whether anything was pressed.
    ///
    /// A synthetic click has to move the pointer there first, and moving the
    /// pointer closes things: a Slack hovercard, an open menu, anything drawn
    /// because the mouse or the keyboard put it there. Measured on the first
    /// real use — "click on Nathan" found Nathan, reported the click, and all
    /// that happened was the menu he was in collapsing.
    ///
    /// `AXPress` is what the element itself says it can do, and it is how
    /// VoiceOver activates everything. Nothing moves, so nothing closes.
    ///
    /// The hit test lands on the deepest element, which is usually the label
    /// inside the button rather than the button, so it walks up until
    /// something advertises the action.
    static func press(at point: CGPoint) -> AXError {
        performing(kAXPressAction, at: point)
    }

    /// Opens the element's own menu — what a right-click gives you.
    ///
    /// `AXShowMenu` is on every one of the 224 items of a real Slack window
    /// and on all 86 of its picker, so this reaches further than a press
    /// does. The rows it opens arrive in the next snapshot as `AXMenuItem`,
    /// which already takes a real click rather than a press.
    static func showMenu(at point: CGPoint) -> Bool {
        perform(kAXShowMenuAction, at: point)
    }

    /// Any accessibility action, on whatever is under the point.
    ///
    /// The hit test lands on the deepest element, which is usually the label
    /// inside the button rather than the button, so it walks up until
    /// something advertises the action.
    static func perform(_ action: String, at point: CGPoint) -> Bool {
        performing(action, at: point) == .success
    }

    /// As `perform`, with the error. `.actionUnsupported` when nothing under
    /// the point has the action.
    static func performing(_ action: String, at point: CGPoint) -> AXError {
        let system = AXUIElementCreateSystemWide()
        var under: AXUIElement?
        let hit = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &under)
        guard hit == .success, let element = under else { return hit == .success ? .failure : hit }
        var current = element
        for _ in 0..<6 {
            if actionNames(current).contains(action) {
                return AXUIElementPerformAction(current, action as CFString)
            }
            guard let parent = attribute(current, kAXParentAttribute) else { return .actionUnsupported }
            current = parent as! AXUIElement
        }
        return .actionUnsupported
    }

    /// The box the caret is in, when it is one that words go into and is
    /// empty — the end state of every request that writes something.
    ///
    /// A message, a comment, a reply: the thing asked for is not the words,
    /// it is the caret sitting in the right place with nothing typed yet.
    /// Returns what to call it, or nil when the caret is somewhere that is
    /// not waiting for words.
    ///
    /// A field that narrows a list is deliberately not one of these. ⌘N puts
    /// the caret in Slack's recipient field and the request is nowhere near
    /// finished — that field is a step, not a destination.
    static func readyForWords(ofApp name: String) -> String? {
        focusedElement(ofApp: name).flatMap(readyForWords)
    }

    private static func readyForWords(_ element: AXUIElement) -> String? {
        let role = string(element, kAXRoleAttribute) ?? ""
        guard role == kAXTextAreaRole || role == kAXTextFieldRole else { return nil }
        let called = (string(element, kAXTitleAttribute)
            ?? string(element, kAXDescriptionAttribute) ?? "")
        guard !Item.fieldsThatFilter.contains(where: { called.lowercased().contains($0) })
        else { return nil }
        let inside = (string(element, kAXValueAttribute) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard inside.isEmpty else { return nil }
        return called.isEmpty ? "the box" : called
    }

    /// Whether the caret is in a field that narrows a list — the only kind of
    /// field a recipe is allowed to type a name into. Checked before every
    /// keystroke, so a recipe that has lost track of the window can never
    /// type into a message box.
    static func caretIsInLookupField(ofApp name: String) -> Bool {
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == name || $0.bundleIdentifier == name
        }) else { return false }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        guard let element = attribute(app, kAXFocusedUIElementAttribute) as! AXUIElement?
        else { return false }
        let role = string(element, kAXRoleAttribute) ?? ""
        if role == kAXComboBoxRole || role == "AXSearchField" { return true }
        guard role == kAXTextFieldRole || role == kAXTextAreaRole else { return false }
        // The caret often sits in a text field inside the combo box rather
        // than on the combo box itself.
        if let parent = attribute(element, kAXParentAttribute) as! AXUIElement?,
           string(parent, kAXRoleAttribute) == kAXComboBoxRole { return true }
        let called = [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue"]
            .lazy.compactMap { string(element, $0) }
            .first { !$0.isEmpty }?.lowercased() ?? ""
        return Item.fieldsThatFilter.contains { called.contains($0) }
    }

    /// The running app's bundle ID, by its name or its bundle ID.
    static func bundle(ofApp name: String) -> String? {
        NSWorkspace.shared.runningApplications.first {
            $0.localizedName == name || $0.bundleIdentifier == name
        }?.bundleIdentifier
    }

    /// Whether the caret is in a box a message is written in, where Return
    /// would send it: a text area, or a text field in the bottom fifth of
    /// its window (the composer test the loop used). A field that narrows a
    /// list is not one.
    static func focusIsMessageBox(ofApp name: String) -> Bool {
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == name || $0.bundleIdentifier == name
        }) else { return false }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        guard let element = attribute(app, kAXFocusedUIElementAttribute) as! AXUIElement?
        else { return false }
        let role = string(element, kAXRoleAttribute) ?? ""
        guard role == kAXTextAreaRole || role == kAXTextFieldRole,
              !caretIsInLookupField(ofApp: name) else { return false }
        if role == kAXTextAreaRole { return true }
        guard let box = frame(of: element),
              let window = attribute(app, kAXFocusedWindowAttribute) as! AXUIElement?,
              let area = frame(of: window) else { return false }
        return (box.midY - area.minY) / max(area.height, 1) > 0.8
    }

    /// The focused element as one line, for a log that has to say where the
    /// keystrokes went.
    static func focusDescription(ofApp name: String) -> String {
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.localizedName == name || $0.bundleIdentifier == name
        }) else { return "no such app" }
        return focusedElement(ofApp: name).map(describe) ?? "nothing has focus"
    }

    private static func describe(_ element: AXUIElement) -> String {
        let role = string(element, kAXRoleAttribute) ?? "?"
        let called = [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue"]
            .lazy.compactMap { string(element, $0) }.first { !$0.isEmpty } ?? ""
        let inside = string(element, kAXValueAttribute) ?? ""
        let parent = (attribute(element, kAXParentAttribute) as! AXUIElement?)
            .flatMap { string($0, kAXRoleAttribute) } ?? "?"
        return "\(role) “\(called)” holding “\(inside.prefix(30))”, inside \(parent)"
    }

    /// The frames of every element with a role, in the app's focused window.
    ///
    /// For things the snapshot does not keep because nothing can be pressed
    /// on them — a table offers a menu, not a press.
    static func elements(ofApp name: String, role wanted: String) -> [CGRect] {
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == name || $0.bundleIdentifier == name
        }) else { return [] }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        guard let window = attribute(app, kAXFocusedWindowAttribute) as! AXUIElement? else { return [] }
        var found: [CGRect] = []
        var queue = [window]
        var budget = 20_000
        while !queue.isEmpty, budget > 0 {
            let element = queue.removeFirst()
            budget -= 1
            if string(element, kAXRoleAttribute) == wanted, let box = frame(of: element) {
                found.append(box)
            }
            queue.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        return found
    }

    /// Something small that can be pressed at a point, or nil — for a
    /// control that only exists while the pointer is over its block, like
    /// Notion's ⋮⋮ handle. Walks up a few levels from the deepest element,
    /// since the hit lands on the icon inside the button.
    static func pressableFrame(at point: CGPoint) -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        var under: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &under) == .success,
              var current = under else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(current, &pid)
        guard pid != getpid() else { return nil }
        for _ in 0..<4 {
            let can = actionNames(current)
            if can.contains(kAXPressAction) || string(current, kAXRoleAttribute) == kAXButtonRole,
               let box = frame(of: current), box.width < 80, box.height < 80 {
                return box
            }
            guard let parent = attribute(current, kAXParentAttribute) else { return nil }
            current = parent as! AXUIElement
        }
        return nil
    }

    /// The rows of a suggestion list under a field, wherever the app keeps it.
    ///
    /// Measured in Outlook: the list is not in the focused window and not in
    /// the app's window list either — it is one of the app's other top-level
    /// parts — and its rows are `AXCell`s with no press action, which the
    /// snapshot drops as things that cannot be acted on. They are clicked
    /// where they are, so a press action is not needed.
    static func listRows(ofApp name: String, under field: CGRect) -> [Item] {
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == name || $0.bundleIdentifier == name
        }) else { return [] }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        var roots = attribute(app, kAXChildrenAttribute) as? [AXUIElement] ?? []
        roots += attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let wanted: Set<String> = ["AXCell", kAXRowRole, kAXMenuItemRole]
        let band = CGRect(x: field.minX - 400, y: field.maxY - 4,
                          width: field.width + 800, height: 504)
        // Outlook's window holds ~40k elements; a full walk per poll took 58 s.
        roots.sort { (frame(of: $0).map { $0.width * $0.height } ?? 0) < (frame(of: $1).map { $0.width * $0.height } ?? 0) }
        var found: [Item] = []
        var queue = roots
        var next = 0
        while next < queue.count, next < 20_000 {
            let element = queue[next]
            next += 1
            let box = frame(of: element)
            if let box, box.width > 0, box.height > 0, !box.intersects(band) { continue }
            let role = string(element, kAXRoleAttribute) ?? ""
            let text = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                .lazy.compactMap { string(element, $0) }.first { !$0.isEmpty } ?? ""
            // Seen 09-22: the row was an AXStaticText holding the address.
            let isRow = wanted.contains(role) || (role == kAXStaticTextRole && text.contains("@"))
            if isRow, let box,
               box.minY >= field.maxY - 4, box.minY <= field.maxY + 500,
               box.maxX > field.minX, box.minX < field.maxX,
               box.height > 8, box.height < 120 {
                if !text.isEmpty, !found.contains(where: {
                    abs($0.y - Int(box.midY)) < 6 && abs($0.x - Int(box.midX)) < 6
                }) {
                    found.append(Item(
                        kind: Kind.click, role: role, name: clean(text), value: "",
                        x: Int(box.midX), y: Int(box.midY), w: Int(box.width), h: Int(box.height),
                        actions: []
                    ))
                }
                if !text.isEmpty { continue }
            }
            queue.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        // Seen 09-22: folder and message cells sit under the field before the
        // suggestions open; only a suggestion carries an address.
        return found.filter { $0.name.contains("@") }.sorted { $0.y < $1.y }
    }

    /// What the hit test finds at a point: role, name, and frame as items
    /// carry it. For the run recorder.
    static func hit(at point: CGPoint) -> [String: Any] {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit
        ) == .success, let element = hit else { return [:] }
        var found: [String: Any] = [
            "role": string(element, kAXRoleAttribute) ?? "",
            "name": [kAXTitleAttribute, kAXDescriptionAttribute]
                .lazy.compactMap { string(element, $0) }.first { !$0.isEmpty } ?? "",
            "value": string(element, kAXValueAttribute).map { String($0.prefix(200)) } ?? "",
        ]
        if let box = frame(of: element) {
            found["x"] = Int(box.midX.rounded())
            found["y"] = Int(box.midY.rounded())
            found["w"] = Int(box.width.rounded())
            found["h"] = Int(box.height.rounded())
        }
        return found
    }

    /// The focused element's role, or nil.
    static func focusRole(ofApp name: String) -> String? {
        focusedElement(ofApp: name).flatMap(role)
    }

    private static func role(_ element: AXUIElement) -> String? {
        let role = string(element, kAXRoleAttribute)
        return string(element, kAXSubroleAttribute) == "AXSearchField" ? "AXSearchField" : role
    }

    private static func focusedElement(ofApp name: String) -> AXUIElement? {
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == name || $0.bundleIdentifier == name
        }) else { return nil }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        return attribute(app, kAXFocusedUIElementAttribute) as! AXUIElement?
    }

    /// The focused element, read once: its frame, role, a line describing
    /// it, and the empty box words go into when it is one.
    struct Focus {
        var frame: CGRect?
        var role: String?
        var described: String
        var readyBox: String?
    }

    static func focused(ofApp name: String) -> Focus? {
        guard let element = focusedElement(ofApp: name) else { return nil }
        let box = frame(of: element).flatMap { $0.width > 1 && $0.height > 1 ? $0 : nil }
        return Focus(frame: box, role: role(element), described: describe(element),
                     readyBox: readyForWords(element))
    }

    /// The name of what is at a point, for the never-press check on a click
    /// that has no element behind it.
    static func name(at point: CGPoint) -> String {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit
        ) == .success, let element = hit else { return "" }
        return [kAXTitleAttribute, kAXDescriptionAttribute]
            .lazy.compactMap { string(element, $0) }.first { !$0.isEmpty } ?? ""
    }

    /// Where an app's pop-up list is, if accessibility can see it at all.
    ///
    /// Asked from inside a run, while the app is still in front: Outlook
    /// closes its suggestion list the moment it loses focus, so a capture
    /// taken from a terminal looks at a closed list and proves nothing.
    /// Two ways of looking, and both are reported:
    /// what is at a grid of points under a field, and every element the app
    /// exposes anywhere whose text matches.
    static func findList(
        ofApp name: String, under field: CGRect, matching needle: String
    ) -> [String] {
        var lines: [String] = []
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == name || $0.bundleIdentifier == name
        }) else { return ["no such app"] }
        let pid = running.processIdentifier
        let app = AXUIElementCreateApplication(pid)

        // 1. The points under the field.
        let system = AXUIElementCreateSystemWide()
        var seen = Set<String>()
        for dy in stride(from: 30.0, through: 330.0, by: 60.0) {
            for fx in [0.2, 0.5] {
                let point = CGPoint(x: field.minX + field.width * fx, y: field.maxY + dy)
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
                      var element = hit else { continue }
                var owner: pid_t = 0
                AXUIElementGetPid(element, &owner)
                var chain: [String] = []
                for _ in 0..<8 {
                    let role = string(element, kAXRoleAttribute) ?? "?"
                    let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                        .lazy.compactMap { string(element, $0) }.first { !$0.isEmpty } ?? ""
                    chain.append(label.isEmpty ? role : "\(role) “\(label.prefix(28))”")
                    if role == kAXWindowRole { break }
                    guard let parent = attribute(element, kAXParentAttribute) else { break }
                    element = parent as! AXUIElement
                }
                let line = "at \(Int(point.x)),\(Int(point.y))\(owner == pid ? "" : " (another app, pid \(owner))"): "
                    + chain.prefix(4).joined(separator: " ← ")
                if seen.insert(line).inserted { lines.append(line) }
            }
        }

        // 2. Everything the app exposes, windows and all.
        var roots = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        roots += attribute(app, kAXChildrenAttribute) as? [AXUIElement] ?? []
        var queue = roots
        var visited = 0
        var matches = 0
        let wanted = needle.lowercased()
        while visited < queue.count, visited < 80_000, matches < 6 {
            let element = queue[visited]
            visited += 1
            let text = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                .compactMap { string(element, $0) }.joined(separator: " ").lowercased()
            if text.contains("@"), text.contains(wanted),
               let box = frame(of: element), box.minY < field.maxY + 500, box.minY > field.minY - 20 {
                matches += 1
                lines.append("found \(string(element, kAXRoleAttribute) ?? "?") at \(Int(box.minX)),\(Int(box.minY))"
                             + " \(Int(box.width))x\(Int(box.height)): “\(text.prefix(50))”")
            }
            queue.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        lines.append("searched \(visited) elements in \(roots.count) top-level parts — \(matches) with an address near the field")
        return lines
    }

    /// Every window the app has, by frame. Taken before typing, so that a
    /// window which appears afterwards can be told apart.
    static func windowFrames(ofApp name: String) -> [CGRect] {
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == name || $0.bundleIdentifier == name
        }) else { return [] }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.compactMap { frame(of: $0) }
    }

    /// What is in the windows an app opened since `known` was taken.
    ///
    /// Outlook draws its recipient suggestions as a window of their own:
    /// measured, it had four windows while the list was open and two once it
    /// closed, and the walk of the focused window never saw a single name in
    /// it. Slack draws its list inside the window, which is why the same
    /// recipe worked there first.
    static func newWindows(ofApp name: String, besides known: [CGRect]) -> [Item] {
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == name || $0.bundleIdentifier == name
        }) else { return [] }
        let pid = running.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.flatMap { window -> [Item] in
            guard let box = frame(of: window),
                  !known.contains(where: { abs($0.minX - box.minX) < 2 && abs($0.minY - box.minY) < 2
                                          && abs($0.width - box.width) < 2 && abs($0.height - box.height) < 2 })
            else { return [] }
            return walk(window, pid: pid, budget: 3000).items
        }
    }

    /// Where the keyboard is, in the app's front window.
    ///
    /// After a step, this is where the work is: ⌘N leaves the caret in the
    /// recipient field, a click leaves it in what was clicked.
    static func focus(ofApp name: String) -> CGPoint? {
        focusFrame(ofApp: name).map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    /// The focused element's frame, in accessibility coordinates.
    static func focusFrame(ofApp name: String) -> CGRect? {
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == name
        }) else { return nil }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        guard let focused = attribute(app, kAXFocusedUIElementAttribute) as! AXUIElement?,
              let box = frame(of: focused), box.width > 1, box.height > 1
        else { return nil }
        return box
    }

    private static func name(of pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
    }

    /// An Electron window publishes almost nothing until it is asked to.
    /// Measured by the prototype: without this the first walk of Slack comes
    /// back nearly empty.
    private static func wake(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    // MARK: - The walk

    private struct Found {
        let frame: CGRect
        let kind: String
        let name: String
        let role: String
        let value: String
        let actions: [String]
        var origin: String? = nil
        var states: [String] = []
        var path = ""
    }

    /// What one walk carries down the tree.
    private struct Walk {
        var budget: Int
        let deadline: Date
        /// The focused element and its ancestors up to the app: how a wide
        /// element knows which of its children are near. Empty when nothing
        /// is focused.
        let near: [AXUIElement]
        var origin: String? = nil
        var capped: [String] = []
        /// Set once the focused element, or its nearest kept ancestor, has
        /// been marked.
        var focusMarked = false
    }

    private static func walk(
        _ window: AXUIElement, pid: pid_t, budget: Int,
        opened: [AXUIElement] = []
    ) -> Snapshot {
        var found: [Found] = []
        let windowFrame = frame(of: window) ?? .zero
        let started = Date()
        // Seen 09-22: Finder's Downloads list took 27 s to walk, and Escape
        // cannot reach inside one step.
        var state = Walk(budget: budget, deadline: started.addingTimeInterval(3),
                         near: focusChain(pid: pid))
        collect(window, into: &found, path: "", state: &state)
        if Date() >= state.deadline {
            Log.write("actions: the walk stopped after 3 s with \(budget - state.budget) elements read")
        } else if state.budget <= 0 {
            // The walk stopped before the end of the tree, so anything missing
            // is missing because of this rather than because the app hides it.
            Log.write("actions: the walk ran out at \(budget) elements — this window is bigger")
        }
        let walked = budget - state.budget
        // A pop-up is small. These bound one that is not.
        state = Walk(budget: 3000, deadline: Date().addingTimeInterval(1),
                     near: state.near, capped: state.capped, focusMarked: state.focusMarked)
        var extra: [String] = []
        for part in opened {
            state.origin = origin(of: part)
            let before = found.count
            collect(part, into: &found, path: "", state: &state)
            extra.append("\(string(part, kAXRoleAttribute) ?? "?") as \(state.origin ?? "") (\(found.count - before) found)")
        }
        if !extra.isEmpty {
            Log.write("actions: also read what opened since the first read — \(extra.joined(separator: ", "))")
        }
        if !state.capped.isEmpty {
            Log.write("actions: capped \(state.capped.count) wide element(s) at \(wideChildren) children"
                + " — \(state.capped.joined(separator: ", "))")
        }
        Log.write("actions: walked \(walked + 3000 - state.budget) elements in"
            + " \(Int(Date().timeIntervalSince(started) * 1000)) ms")

        // A container is not a target: at some size it holds the thing meant
        // rather than being it. 12 % of the window is where the prototype put
        // the line.
        //
        // A text field is exempt, because it holds no targets — it is one.
        // Measured on TextEdit: its text area fills the window, the rule
        // dropped it, and the window came back with two items and nothing to
        // type into. Slack's composer is small enough that the prototype
        // never saw this.
        let tooBig = windowFrame.width * windowFrame.height * 0.12
        var items: [Item] = []
        for item in found {
            let fits = item.frame.width * item.frame.height <= tooBig
            guard fits || item.kind == Kind.text || item.kind == Kind.more else { continue }
            let blank = item.name.trimmingCharacters(in: .whitespaces).isEmpty
                && item.value.trimmingCharacters(in: .whitespaces).isEmpty
            // A nameless text field is still a target — the composer has no
            // name anywhere. A nameless anything else cannot be asked for.
            guard !blank || item.kind == Kind.text else { continue }
            items.append(
                Item(
                    kind: item.kind, role: item.role, name: item.name, value: item.value,
                    x: Int(item.frame.midX), y: Int(item.frame.midY),
                    w: Int(item.frame.width), h: Int(item.frame.height),
                    actions: item.actions.filter { $0 != "AXScrollToVisible" },
                    origin: item.origin, states: item.states.isEmpty ? nil : item.states,
                    key: shortHash("\(item.role)\u{1}\(item.name)\u{1}\(item.path)")
                )
            )
        }

        // A row and the group inside it carry the same name and nearly the
        // same frame. Keep the outer one, which is what a click wants: the
        // walk adds a parent after its children. Seen 09-23 in Slack: a
        // sidebar row was an AXRow in one read and an AXGroup in the next.
        var kept: [Item] = []
        for item in items.reversed() {
            let duplicate = kept.contains {
                $0.name == item.name && $0.kind == item.kind
                    && abs($0.x - item.x) < 20 && abs($0.y - item.y) < 20
            }
            if !duplicate { kept.append(item) }
        }
        kept.reverse()
        var twins: [String: Int] = [:]
        for index in kept.indices {
            guard let key = kept[index].key else { continue }
            twins[key, default: 0] += 1
            if twins[key]! > 1 { kept[index].key = "\(key).\(twins[key]!)" }
        }
        // Reading order.
        kept.sort { ($0.y, $0.x) < ($1.y, $1.x) }

        return Snapshot(
            app: name(of: pid),
            window: string(window, kAXTitleAttribute) ?? "",
            frame: Rect(
                x: Int(windowFrame.minX), y: Int(windowFrame.minY),
                w: Int(windowFrame.width), h: Int(windowFrame.height)
            ),
            items: kept
        )
    }

    /// FNV-1a, 32 bits: Swift's `Hasher` is seeded per process.
    private static func shortHash(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return String(format: "%08x", hash)
    }

    /// Roles that wrap everything in web apps, left out of a key's path so
    /// that a wrapper added or removed does not change it.
    private static let plainRoles: Set<String> = [kAXGroupRole, "AXGenericElement", kAXUnknownRole]

    /// Post-order, so the deepest kept element on the focus chain is the one
    /// marked: Teams focuses a group inside its composer, not the composer.
    private static func states(of element: AXUIElement, role: String, state: inout Walk) -> [String] {
        var out: [String] = []
        if !state.focusMarked, state.near.contains(where: { CFEqual($0, element) }) {
            out.append("focused")
            state.focusMarked = true
        }
        if (attribute(element, kAXSelectedAttribute) as? Bool) == true { out.append("selected") }
        if (attribute(element, kAXExpandedAttribute) as? Bool) == true { out.append("expanded") }
        if role == kAXCheckBoxRole || role == kAXRadioButtonRole,
           (attribute(element, kAXValueAttribute) as? NSNumber)?.intValue == 1 {
            out.append("checked")
        }
        return out
    }

    /// The focused element and its ancestors, deepest first.
    private static func focusChain(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        guard let start = attribute(app, kAXFocusedUIElementAttribute) as! AXUIElement? else { return [] }
        var chain = [start]
        var current = start
        while chain.count < 60, let parent = attribute(current, kAXParentAttribute) {
            current = parent as! AXUIElement
            chain.append(current)
        }
        return chain
    }

    /// The children to walk. A list, table or outline gives the rows on
    /// screen. Anything else wider than `wideChildren` gives its first ones
    /// and those next to the caret; `more` is how many were
    /// left out.
    private static func children(
        of element: AXUIElement, role: String, state: inout Walk
    ) -> (children: [AXUIElement], more: Int) {
        // A list of thousands of files: only the rows on screen can be meant.
        switch role {
        case kAXOutlineRole, kAXTableRole:
            if let rows = attribute(element, kAXVisibleRowsAttribute) as? [AXUIElement] { return (rows, 0) }
        case kAXListRole:
            if let rows = attribute(element, kAXVisibleChildrenAttribute) as? [AXUIElement] { return (rows, 0) }
        default:
            break
        }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success
        else { return (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [], 0) }
        if count == 0 { return ([], 0) }
        guard count > wideChildren else {
            return (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [], 0)
        }
        if let shown = attribute(element, kAXVisibleChildrenAttribute) as? [AXUIElement], shown.count < count {
            return (shown, 0)
        }
        func range(_ start: Int, _ length: Int) -> [AXUIElement] {
            var values: CFArray?
            AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, start, length, &values)
            return values as? [AXUIElement] ?? []
        }
        var picked = range(0, wideChildren)
        func add(_ more: [AXUIElement]) {
            for child in more where !picked.contains(where: { CFEqual($0, child) }) { picked.append(child) }
        }
        let side = 3
        let chain = state.near
        if let at = chain.firstIndex(where: { CFEqual($0, element) }), at > 0 {
            let all = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            if let index = all.firstIndex(where: { CFEqual($0, chain[at - 1]) }) {
                add(Array(all[max(0, index - side)...min(all.count - 1, index + side)]))
            }
        } else {
            // Outside it, the last ones. Seen on Slack: the newest messages
            // are the last children of a group of 23, next to the composer,
            // and its last child is a 1x1 marker, so comparing ends by frame
            // did not work.
            add(range(count - (2 * side + 1), 2 * side + 1))
        }
        state.capped.append("\(role) \(count)")
        return (picked, count - picked.count)
    }

    /// Walks the subtree and returns its visible text.
    ///
    /// The return value is the point of the recursion: Slack's rows and
    /// buttons carry no title of their own, and their name is in the static
    /// texts underneath them. Without this, half a window is nameless.
    @discardableResult
    private static func collect(
        _ element: AXUIElement, into out: inout [Found], depth: Int = 0, inRow: Bool = false,
        path: String, state: inout Walk
    ) -> String {
        guard depth < 40, state.budget > 0, Date() < state.deadline else { return "" }
        state.budget -= 1
        let role = string(element, kAXRoleAttribute) ?? "?"
        let (children, more) = children(of: element, role: role, state: &state)
        let isRow = state.origin != nil && role != kAXStaticTextRole && Item.rowRoles.contains(role)
        var text = ""
        let inner = plainRoles.contains(role) || path.hasSuffix("/\(role)") ? path : "\(path)/\(role)"
        for child in children {
            let below = collect(child, into: &out, depth: depth + 1, inRow: inRow || isRow,
                                path: inner, state: &state)
            if !below.isEmpty && text.count < 120 {
                text += (text.isEmpty ? "" : " ") + below
            }
        }
        // Only where a value is short. Outlook's message body is an
        // AXTextArea of 395,489 characters.
        let own = Self.valueRoles.contains(role)
            && string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole
            ? string(element, kAXValueAttribute) ?? "" : ""
        if role == kAXStaticTextRole && !own.trimmingCharacters(in: .whitespaces).isEmpty {
            text = own
        }
        let box = frame(of: element)
        if let box, box.width > 2, box.height > 2, box.width < 3000 {
            let actions = actionNames(element)
            var kind = kindOf(role: role, actions: actions, children: children.count)
            // A pop-up's rows take a click whatever they advertise. A text
            // inside a row names the row instead; outside a pop-up, a text is
            // a dialog's message, not a row.
            if state.origin != nil, kind == nil || kind == Kind.label, Item.rowRoles.contains(role),
               role != kAXStaticTextRole || (state.origin == "pop-up" && !inRow) {
                kind = Kind.click
            }
            if let kind {
                // First one that says something. An attribute that is present
                // and empty is not a name, and `??` cannot tell the two apart
                // — measured on Spotify, where every icon button carries an
                // empty title and its name in the description: `AXButton "" /
                // "Go back"`. The chain stopped at the empty title, the item
                // came out blank, and blank non-text items are dropped. None
                // of the playback controls has ever been offered to anything.
                var name = [
                    kAXTitleAttribute, kAXDescriptionAttribute,
                    "AXPlaceholderValue", kAXHelpAttribute,
                ].lazy.compactMap { string(element, $0) }
                    .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                if name.isEmpty && kind != Kind.label { name = text }
                // Measured 09-22: the red and orange window buttons carry no
                // title, description or help, so they could never be picked.
                if name.isEmpty, let subrole = string(element, kAXSubroleAttribute),
                   let spoken = Self.windowButtons[subrole] {
                    name = spoken
                }
                let value = kind == Kind.label ? clean(own)
                    : kind == Kind.text || Self.valueRoles.contains(role)
                    ? String(own.replacingOccurrences(of: "\n", with: " ").prefix(100))
                    : ""
                out.append(
                    Found(
                        frame: box, kind: kind, name: clean(name), role: role,
                        value: value, actions: actions, origin: state.origin,
                        states: states(of: element, role: role, state: &state), path: path
                    )
                )
            }
        }
        if more > 0 {
            out.append(
                Found(
                    frame: box ?? .zero, kind: Kind.more, name: "and \(Self.counted(more)) more",
                    role: role, value: "", actions: [], origin: state.origin
                )
            )
        }
        return text
    }

    /// The roles whose value is read: small fields, and the text that names
    /// things. Never a text area.
    private static let valueRoles: Set<String> = [
        kAXStaticTextRole, kAXTextFieldRole, kAXComboBoxRole, "AXSearchField",
        "AXDateTimeArea", kAXSliderRole, "AXIncrementor", kAXValueIndicatorRole,
    ]

    private static func counted(_ number: Int) -> String {
        let format = NumberFormatter()
        format.numberStyle = .decimal
        format.locale = Locale(identifier: "en_US")
        return format.string(from: NSNumber(value: number)) ?? String(number)
    }

    /// Named for what they do. Measured 09-22: named "close button", the red
    /// button lost "close this window" to Finder's "Close tab" at 0.52.
    private static let windowButtons: [String: String] = [
        "AXCloseButton": "Close window", "AXMinimizeButton": "Minimize window",
        "AXFullScreenButton": "Full screen", "AXZoomButton": "Zoom window",
    ]

    private static func kindOf(role: String, actions: [String], children: Int) -> String? {
        if role == kAXTextFieldRole || role == kAXTextAreaRole
            || role == kAXComboBoxRole || role == "AXSearchField"
            || role == "AXDateTimeArea" { return Kind.text }
        if actions.contains(kAXPressAction) || actions.contains(kAXConfirmAction) { return Kind.click }
        if role == kAXStaticTextRole { return Kind.label }
        // Something that does its own thing and holds nothing that could have
        // been meant instead.
        let real = actions.filter {
            $0 != "AXScrollToVisible" && $0 != "AXShowMenu" && $0 != "AXRaise" && !$0.hasPrefix("AXScroll")
        }
        if !real.isEmpty && children == 0 { return Kind.other }
        return nil
    }

    private static func clean(_ text: String) -> String {
        String(text.replacingOccurrences(of: "\n", with: " ").prefix(80))
    }

    // MARK: - Accessibility plumbing

    private static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) else { return nil }
        return text(of: value)
    }

    /// Every type an accessibility attribute comes back as. Seen 09-23:
    /// Outlook's date and time pickers hold a date, read as nothing, so every
    /// change to them looked like no change.
    private static func text(of value: Any) -> String? {
        if let text = value as? String { return text }
        if let attributed = value as? NSAttributedString { return attributed.string }
        if let date = value as? Date { return shownDate.string(from: date) }
        if let url = value as? URL { return url.absoluteString }
        if let number = value as? NSNumber { return number.stringValue }
        if let list = value as? [Any] {
            let parts = list.prefix(8).compactMap { text(of: $0) }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        if CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() {
            let element = value as! AXUIElement
            return [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                .lazy.compactMap { attribute(element, $0) as? String }.first { !$0.isEmpty }
        }
        if CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() {
            let packed = value as! AXValue
            switch AXValueGetType(packed) {
            case .cfRange:
                var range = CFRange(); AXValueGetValue(packed, .cfRange, &range)
                return "\(range.location)+\(range.length)"
            case .cgPoint:
                var point = CGPoint.zero; AXValueGetValue(packed, .cgPoint, &point)
                return "\(Int(point.x)),\(Int(point.y))"
            case .cgSize:
                var size = CGSize.zero; AXValueGetValue(packed, .cgSize, &size)
                return "\(Int(size.width))x\(Int(size.height))"
            case .cgRect:
                var rect = CGRect.zero; AXValueGetValue(packed, .cgRect, &rect)
                return "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
            default: return nil
            }
        }
        return nil
    }

    /// As the user's Mac writes a date and a time, so the model reads what
    /// the field shows.
    private static let shownDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        return AXUIElementCopyActionNames(element, &names) == .success ? (names as? [String] ?? []) : []
    }
}
