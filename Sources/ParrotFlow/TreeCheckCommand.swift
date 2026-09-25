import AppKit

/// `--tree-check <app>` — what our walk sees, against a second opinion.
///
/// Every target that never reaches the model fails in one of four ways: the
/// app does not publish it, we walk the wrong window, the walk stops early, or
/// we read it and then a filter throws it away. From the outside all four look
/// identical — nothing is on screen, nothing is offered, and the model answers
/// "none of these".
///
/// So this walks the same window twice. Ours is `ScreenTargets`. The second
/// opinion is System Events, which is a different implementation of the same
/// C API, already on every Mac, and has no idea what our filters are. What
/// only one of them sees is the answer.
///
/// It was written after a measured bug of the fourth kind: every icon-only
/// button in every Chromium app carries an empty `AXTitle` and its name in
/// `AXDescription`, and `??` cannot tell an absent attribute from an empty
/// one. The name came out blank, blank non-text items are dropped, and
/// Spotify's entire playback row had never once been offered to anything.
/// This command prints that in one line.
///
/// The two sides do not name things the same way and are not meant to. We
/// compose a row's name from the text inside it, which is what makes Slack
/// work; System Events reads the attribute and stops. So "only we see it" is
/// usually that, and "only the reference sees it" is where the bugs are.
enum TreeCheckCommand {

    /// The roles worth comparing. Static text is left out: there are hundreds
    /// of them, they are dropped from the candidates anyway, and they would
    /// bury the things that can be acted on.
    private static let interesting: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuButton",
        "AXLink", "AXRow", "AXCell", "AXTextField", "AXTextArea", "AXComboBox",
        "AXSearchField", "AXPopUpButton", "AXImage", "AXSlider", "AXTab",
    ]

    static func run(app name: String) -> Int32 {
        defer { Log.flush() }
        NSApplication.shared.setActivationPolicy(.accessory)

        guard AXIsProcessTrusted() else {
            print("✗ no Accessibility grant for this process — see docs/actions.md")
            return 1
        }

        let started = Date()
        let snapshot: ScreenTargets.Snapshot
        do {
            snapshot = try ScreenTargets.snapshot(ofApp: name)
        } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }
        let ourMs = Int(Date().timeIntervalSince(started) * 1000)
        print("tree check   \(snapshot.app) “\(snapshot.window)”")
        print("  ours       \(snapshot.items.count) items in \(ourMs) ms")

        let referenceStarted = Date()
        guard let reference = secondOpinion(app: name) else {
            print("  ✗ the second walk found no window for \(name)")
            return 1
        }
        let referenceMs = Int(Date().timeIntervalSince(referenceStarted) * 1000)
        let worth = reference.filter { interesting.contains($0.role) }
        print("  reference  \(reference.count) elements in \(referenceMs) ms"
              + " — \(worth.count) of them can be acted on")

        // Matched by name or by where it is. Name alone is too strict: we
        // compose a row's name from the text inside it, which is what makes
        // Slack readable and which the reference does not do, so hundreds of
        // rows we do have would read as missing. Same middle, same element.
        let ours = Set(snapshot.items.map { key($0.name) }).subtracting([""])
        let theirs = Set(worth.map { key($0.name) }).subtracting([""])
        let ourPoints = snapshot.items.map { CGPoint(x: Double($0.x), y: Double($0.y)) }
        let theirPoints = worth.map { $0.at }

        /// Same middle, within ten points, is the same element under another
        /// name. A bucket would split a one-pixel difference across a
        /// boundary and call it missing.
        func near(_ point: CGPoint, _ others: [CGPoint]) -> Bool {
            others.contains { abs($0.x - point.x) <= 10 && abs($0.y - point.y) <= 10 }
        }

        var seen: Set<String> = []
        let gone = worth.filter {
            guard !$0.name.isEmpty,
                  !ours.contains(key($0.name)),
                  !near($0.at, ourPoints) else { return false }
            return seen.insert(key($0.name)).inserted
        }
        let extra = snapshot.items.filter {
            !$0.name.isEmpty
                && !theirs.contains(key($0.name))
                && !near(CGPoint(x: Double($0.x), y: Double($0.y)), theirPoints)
        }

        print("")
        // Every miss is either a rule doing its job or a bug. Saying which
        // is the whole value of this: a list of 201 that is mostly hidden
        // one-pixel buttons teaches nothing, and the four it is hiding are
        // the reason to run it.
        let window = CGRect(
            x: Double(snapshot.frame.x), y: Double(snapshot.frame.y),
            width: Double(snapshot.frame.w), height: Double(snapshot.frame.h)
        )
        let tooBig = window.width * window.height * 0.12
        var why: [String: Int] = [:]
        var unexplained: [String] = []
        var elsewhere: [String] = []
        for element in gone {
            let area = element.size.width * element.size.height
            if element.part == .menuBar {
                why["in the menu bar, which the walk does not read", default: 0] += 1
            } else if element.part != .focused {
                // The Outlook case. Not a rule doing its job: a whole part of
                // the app the walk never looks at.
                elsewhere.append(describe(element))
            } else if element.size.width <= 2 || element.size.height <= 2 {
                why["too small to click", default: 0] += 1
            } else if !window.insetBy(dx: -2, dy: -2).contains(element.at) {
                why["outside the window", default: 0] += 1
            } else if area > tooBig {
                why["bigger than 12 % of the window", default: 0] += 1
            } else if !element.actions.contains(kAXPressAction),
                      !element.actions.contains(kAXConfirmAction),
                      !["AXStaticText", "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
                        .contains(element.role) {
                // A decorative image, a group that holds things. Nothing can
                // be done to it, so it is not a target.
                why["nothing can be done to it", default: 0] += 1
            } else {
                unexplained.append(describe(element))
            }
        }
        for (reason, count) in why.sorted(by: { $0.value > $1.value }) {
            print("  · \(count) dropped: \(reason)")
        }
        if !elsewhere.isEmpty {
            print("")
            print("  ✗ \(elsewhere.count) outside the focused window — a part of the app the walk never reads:")
            for line in elsewhere.sorted().prefix(20) { print("      \(line)") }
        }
        if unexplained.isEmpty && elsewhere.isEmpty {
            print("  ✓ every miss is a rule doing its job — nothing unexplained")
        } else if unexplained.isEmpty {
            print("  ✓ inside the focused window, every miss is a rule doing its job")
        } else {
            print("")
            print("  ✗ \(unexplained.count) no rule explains — these are the bugs:")
            for line in unexplained.sorted().prefix(30) { print("      \(line)") }
            if unexplained.count > 30 { print("      … and \(unexplained.count - 30) more") }
        }

        if !extra.isEmpty {
            print("")
            print("  \(extra.count) we have and it does not — usually a name we composed")
            print("  from the text inside a row, which is what makes Slack readable:")
            for item in extra.prefix(6) {
                print("      \(item.role)  “\(item.name.prefix(52))”")
            }
        }
        return unexplained.isEmpty && elsewhere.isEmpty ? 0 : 2
    }

    /// Lowercased and stripped of everything but letters and digits. The two
    /// sides differ on whitespace, bullets and the odd zero-width character,
    /// and none of that is a finding.
    private static func describe(_ element: Element) -> String {
        String(
            format: "%-13@ %5d,%-5d %4dx%-4d “%@”",
            element.role as NSString, Int(element.at.x), Int(element.at.y),
            Int(element.size.width), Int(element.size.height), element.name as NSString
        )
    }

    private static func key(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private struct Element {
        let role: String
        let name: String
        let at: CGPoint
        let size: CGSize
        let actions: [String]
        /// Which top-level part of the app it was found in. Our walk reads
        /// only the focused window, so anything elsewhere is missed by
        /// construction — measured on Outlook, whose recipient suggestions
        /// live in a part of their own.
        var part: Part = .focused
    }

    enum Part { case focused, otherWindow, menuBar, other }

    /// A second walker that shares nothing with `ScreenTargets` but the API.
    ///
    /// Breadth-first rather than depth-first, so a traversal bug in one shows
    /// up as a difference. No 12 % rule, no blank-name rule, no de-duplication
    /// — the point is to see what the filters remove. And every name attribute
    /// is read on its own, because the bug that prompted this command was a
    /// chain of `??` that stopped at an attribute which was present and empty.
    ///
    /// System Events was tried first and is not usable here: 37 seconds on a
    /// Spotify window, and it returned 42 elements where this returns
    /// hundreds. A reference that misses things cannot find things that are
    /// missing.
    private static func secondOpinion(app: String) -> [Element]? {
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == app || $0.bundleIdentifier == app
        }) else { return nil }
        let pid = running.processIdentifier
        let root = AXUIElementCreateApplication(pid)
        var window: AXUIElement?
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            root, kAXFocusedWindowAttribute as CFString, &value
        ) == .success { window = (value as! AXUIElement) }
        if window == nil,
           AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] { window = windows.first }
        guard let focused = window else { return nil }

        // Every top-level part, each walked on its own and labelled — the
        // focused window, other windows, the menu bar, anything else the app
        // hangs off itself (a pop-up list, a floating panel).
        var roots: [(AXUIElement, Part)] = [(focused, .focused)]
        if AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &value) == .success,
           let children = value as? [AXUIElement] {
            for child in children where !CFEqual(child, focused) {
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
                let kind: Part = (role as? String) == kAXMenuBarRole ? .menuBar
                    : (role as? String) == kAXWindowRole ? .otherWindow : .other
                roots.append((child, kind))
            }
        }

        var out: [Element] = []
        for (start, part) in roots {
            var queue = [start]
            var budget = 40_000
            while !queue.isEmpty, budget > 0 {
                budget -= 1
                let element = queue.removeFirst()
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                let box = frame(of: element)
                var found = Element(
                    role: (role as? String) ?? "", name: anyName(of: element),
                    at: box.origin, size: box.size, actions: actionNames(of: element)
                )
                found.part = part
                out.append(found)
                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                    element, kAXChildrenAttribute as CFString, &children
                ) == .success, let kids = children as? [AXUIElement] {
                    queue.append(contentsOf: kids)
                }
            }
        }
        return out
    }

    /// Where it is and how big, for matching the two sides up and for saying
    /// enough about a miss to act on it.
    private static func frame(of element: AXUIElement) -> CGRect {
        var origin: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXPositionAttribute as CFString, &origin) == .success,
              AXUIElementCopyAttributeValue(
                element, kAXSizeAttribute as CFString, &size) == .success
        else { return CGRect(x: -1, y: -1, width: 0, height: 0) }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(origin as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(
            x: point.x + extent.width / 2, y: point.y + extent.height / 2,
            width: extent.width, height: extent.height
        )
    }

    /// What the element says can be done to it.
    private static func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    /// The first attribute that says anything, each read on its own.
    private static func anyName(of element: AXUIElement) -> String {
        for attribute in [
            kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue",
            kAXHelpAttribute, kAXValueAttribute,
        ] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element, attribute as CFString, &value
            ) == .success else { continue }
            let text = (value as? String)
                ?? (value as? NSAttributedString)?.string
                ?? (value as? NSNumber)?.stringValue ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

}
