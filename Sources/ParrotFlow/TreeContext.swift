import AppKit
import ApplicationServices

/// The conversation around the box, for an app whose screen is a tree.
///
/// A terminal publishes its whole screen as one string, which is why `Context`
/// could read one with a single call. Slack publishes a tree: 973 nodes for one
/// window, 602 of them carrying text, and 16,342 characters once flattened —
/// eight times what a later stage is allowed to see. So the work here is not
/// reading, it is choosing: which subtree is the conversation, and which of its
/// labels are words somebody wrote rather than furniture the app drew.
///
/// Measured on a real Slack window, 2026-09-18: the walk takes 130–150ms. That
/// is why it runs where `Context.capturePress` already runs, off the main
/// thread and after recording has started, and why nothing here is on the path
/// that makes the hotkey feel fast.
///
/// Collection and assembly are separate on purpose. `nodes(under:)` is
/// accessibility and cannot be tested without a running Slack; `assemble` is a
/// pure function over labels and is scored by `scripts/check-tree-context.sh`.
enum TreeContext {

    /// One element worth keeping: what it is, what it says, where it sits, and
    /// whether it belongs to a message.
    ///
    /// The flag is the difference between the conversation and the furniture
    /// around it. The pane holding the messages also holds the composer's
    /// formatting bar and the channel header, labelled "Bold", "Schedule for
    /// later", "Files & links" — a filter by wording would be an endless list.
    ///
    /// Slack labels each message group with `Author: what they said`, and the
    /// paragraphs, file names and links of that message hang under it. So the
    /// author label is the boundary: inside it is language, outside it is the
    /// app talking about itself. The `AXList` that names the conversation is a
    /// marker beside the messages, not their parent — it holds one label and no
    /// rows, which is why an earlier version of this read one line.
    struct Node: Equatable {
        let role: String
        let label: String
        let frame: CGRect?
        var inMessage: Bool = false
    }

    /// What a walk found, before anything is cut to size.
    struct Assembled: Equatable {
        /// The channel or direct message this window is showing.
        let place: String
        /// Whoever is named as an author, plus the members the header lists.
        let people: [String]
        /// The conversation, newest last, one label per line.
        let text: String
    }

    // MARK: - Reading the tree

    private static let nodeLimit = 4000
    private static let depthLimit = 26

    /// Every labelled element under `element`, in drawing order.
    ///
    /// Buttons, checkboxes and pop-ups are dropped here rather than in
    /// `assemble`: their labels are instructions to the user ("Download",
    /// "More actions"), and the one button worth reading — the member list — is
    /// picked out by name before the rest go.
    static func nodes(under element: AXUIElement) -> [Node] {
        var found: [Node] = []
        walk(element, depth: 0, inList: false, into: &found)
        return found
    }

    private static func walk(
        _ element: AXUIElement, depth: Int, inList: Bool, into found: inout [Node]
    ) {
        guard found.count < nodeLimit, depth < depthLimit else { return }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let text = label(of: element)
        // A composer carries the sentence being dictated, not the conversation,
        // and `input` publishes it already.
        let messages = (inList || text.flatMap(author(in:)) != nil) && role != "AXTextArea"
        if let text, !text.isEmpty, role != "AXButton" || text.hasPrefix(memberPrefix) {
            found.append(Node(
                role: role, label: text, frame: frame(of: element), inMessage: messages))
        }
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            walk(child, depth: depth + 1, inList: messages, into: &found)
        }
    }

    /// The subtree holding the conversation the caret is in.
    ///
    /// Climbed from the focused composer rather than picked out of the window,
    /// because one Slack window can show two of everything: the window that was
    /// measured had two composers in it, one for a direct message and one for a
    /// channel. Geometry would have had to guess between them, and would have
    /// guessed again every time the sidebar was resized.
    ///
    /// The ancestor that also contains the message list is the pane. Nil means
    /// no such ancestor was found, and the caller falls back to the window.
    static func conversation(around focused: AXUIElement) -> AXUIElement? {
        var element = focused
        for _ in 0..<depthLimit {
            guard let parent = attribute(element, kAXParentAttribute) else { return nil }
            let up = parent as! AXUIElement
            if (attribute(up, kAXRoleAttribute) as? String) == "AXWindow" { return nil }
            if holdsMessageList(up) { return up }
            element = up
        }
        return nil
    }

    /// Whether this element contains the list Slack labels with the channel or
    /// direct message it is showing. Bounded: the composer's ancestors are
    /// shallow, and a full walk per rung would cost the whole window each time.
    private static func holdsMessageList(_ element: AXUIElement, depth: Int = 0) -> Bool {
        guard depth < 6 else { return false }
        if (attribute(element, kAXRoleAttribute) as? String) == "AXList",
           let label = label(of: element), place(in: label) != nil {
            return true
        }
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            if holdsMessageList(child, depth: depth + 1) { return true }
        }
        return false
    }

    // MARK: - Making sense of the labels

    private static let memberPrefix = "View all "

    /// `sws-engineering-internal (private channel)`, `Tasmeen Kathuria (direct
    /// message, away)` — the label Slack puts on the message list, and the one
    /// thing on screen that names the conversation without the window title's
    /// unread counts and notification marks.
    static func place(in label: String) -> String? {
        guard let open = label.range(of: " ("), label.hasSuffix(")") else { return nil }
        let kind = label[open.upperBound...].dropLast().lowercased()
        // "group direct message" as well as "direct message, away": Slack says
        // which kind of conversation it is, and how many people are in it.
        guard kind.contains("channel") || kind.contains("direct message") else { return nil }
        let name = String(label[..<open.lowerBound])
        let isChannel = kind.contains("channel")
        return isChannel ? "#\(name)" : name
    }

    /// `Martin Alix: @channel Thank you everyone!` — Slack writes the author
    /// into the label of each message group, which is the one name NLTagger
    /// cannot find: it sits at the start of a line in front of a colon, where
    /// a tagger sees a heading rather than a person.
    static func author(in label: String) -> String? {
        guard let colon = label.firstIndex(of: ":") else { return nil }
        let name = String(label[..<colon])
        let words = name.split(separator: " ")
        guard (1...4).contains(words.count), name.count <= 48,
              words.allSatisfy({ $0.first?.isUppercase == true || $0.first?.isNumber == true }),
              label.index(after: colon) < label.endIndex,
              label[label.index(after: colon)] == " "
        else { return nil }
        return tidy(name)
    }

    /// `View all 14 members. Includes Mik Okun, Parsa Gouran, and Sa…` — three
    /// of them, which is what the header shows without a click. The rest are
    /// behind a button, and this stage does not press buttons.
    static func members(in label: String) -> [String] {
        guard label.hasPrefix(memberPrefix),
              let includes = label.range(of: "Includes ") else { return [] }
        let list = label[includes.upperBound...]
            .replacingOccurrences(of: ", and ", with: ", ")
            .replacingOccurrences(of: " and ", with: ", ")
        return list.components(separatedBy: ", ")
            .map { tidy($0) }
            // A trimmed name ends in an ellipsis, and half a name is worse than
            // no name: it would match a dictated word by sound and write it.
            .filter { !$0.isEmpty && !$0.hasSuffix("…") && !$0.hasSuffix("...") }
    }

    /// A name as it would be written down, or nothing.
    ///
    /// Slack ends an announcement with a full stop, so the author of the last
    /// sentence arrives as `Matthieu Joannon.`, and a name with a stop on it
    /// would be offered to a dictation as a spelling. "User" is what the tree
    /// calls somebody it has not loaded yet.
    static func tidy(_ name: String) -> String {
        let clean = name
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            .trimmingCharacters(in: .whitespaces)
        return clean == "User" || clean.count < 2 ? "" : clean
    }

    /// Labels the app drew rather than words somebody wrote.
    ///
    /// Slack repeats itself for screen readers: every message is announced once
    /// as `Author: the text…` and again as the text itself, and each carries a
    /// timestamp twice, a reaction count, and the actions menu. None of that is
    /// language, and all of it would crowd out the conversation in the 2000
    /// characters a later stage is allowed to see.
    static func isFurniture(_ label: String) -> Bool {
        if label.count < 2 { return true }
        if furniture.contains(label) { return true }
        if label.hasSuffix(" emoji") || label.hasPrefix("View all ") { return true }
        if label.hasPrefix("Last reply ") || label.hasPrefix("Download ") { return true }
        if label.hasPrefix("Message to ") || label.hasPrefix("Press enter") { return true }
        if label.hasPrefix("Today at ") || label.hasPrefix("Yesterday at ") { return true }
        if label.hasPrefix("React with ") || label.hasPrefix("Jump to ") { return true }
        // "Sep 15th at 10:18:19 PM", "Tuesday, September 15th Press enter to…",
        // "2 days ago" — when a message was said, which no later stage can use.
        if label.range(of: "^[A-Z][a-z]{2,8} \\d{1,2}(st|nd|rd|th)? at \\d",
                       options: .regularExpression) != nil { return true }
        if label.range(of: "^[A-Z][a-z]+day, [A-Z][a-z]+ \\d{1,2}",
                       options: .regularExpression) != nil { return true }
        if label.range(of: "^\\d+ (second|minute|hour|day|week|month|year)s? ago$",
                       options: .regularExpression) != nil { return true }
        if label.range(of: "^\\d{1,2}:\\d{2}(:\\d{2})?( [AP]M)?$",
                       options: .regularExpression) != nil { return true }
        if label.range(of: "^\\+\\d+$", options: .regularExpression) != nil { return true }
        return false
    }

    private static let furniture: Set<String> = [
        "Message actions", "More actions", "Reactions", "Composer actions",
        "Formatting", "composer", "New", "View thread", "Channel",
        "Thread", "Saved items", "Activity", "More", "Huddle",
        "Save for later", "Ask Slackbot", "Jump to date", "Add reaction",
    ]

    /// What Slack appends when it announces a message: the clock, then the
    /// counts. `… reinventing the wheel ? 12:09 AM. 3 replies, 1 link.` is one
    /// sentence somebody wrote and three facts the app added, and the facts are
    /// numbers a speller would try to match against words on screen.
    static func trimAnnouncement(_ label: String) -> String {
        var text = label
        let tails = [
            "\\s*\\d+ (reaction|reply|repl(y|ies)|attachment|link|file|edit)s?\\.?$",
            "\\s*\\d+ replies\\.?$",
            "\\s*,$",
            "\\s*\\d{1,2}:\\d{2}(:\\d{2})? ?[AP]M\\.?$",
        ]
        var cut = true
        while cut {
            cut = false
            for pattern in tails {
                if let found = text.range(of: pattern, options: .regularExpression) {
                    text.removeSubrange(found)
                    cut = true
                }
            }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// The conversation as text, the place, and the people, from one walk.
    ///
    /// Pure, so it can be scored without Slack running — see
    /// `scripts/check-tree-context.sh`.
    static func assemble(_ nodes: [Node], title: String?) -> Assembled {
        var named = ""
        var people: [String] = []
        var lines: [String] = []

        for node in nodes {
            let label = node.label
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if named.isEmpty, let here = place(in: label) { named = here }
            if let author = author(in: label), !author.isEmpty, !people.contains(author) {
                people.append(author)
            }
            for member in members(in: label)
            where !member.isEmpty && !people.contains(member) { people.append(member) }
            guard node.inMessage, !isFurniture(label) else { continue }
            // The screen-reader announcement of a message, which the message
            // itself follows. Dropped by shape — a name, a colon, and an
            // ellipsis where the text was cut — rather than by comparing it
            // with what comes next, because the two are not always adjacent.
            if author(in: label) != nil, label.hasSuffix("…") { continue }
            lines.append(trimAnnouncement(label))
        }

        // Slack draws the same words at several depths, so a label that is a
        // fragment of another is the same message read twice.
        var kept: [String] = []
        for line in lines {
            if lines.contains(where: { $0 != line && $0.contains(line) }) { continue }
            if kept.last == line { continue }
            kept.append(line)
        }
        if named.isEmpty, let title { named = cleanTitle(title) }
        return Assembled(place: named, people: people, text: kept.joined(separator: "\n"))
    }

    /// `! Tasmeen Kathuria (DM) - Swoop Enterprise - 21 new items - Slack` is a
    /// window title with a notification mark and an unread count in it. Neither
    /// is part of the conversation's name, and both change while you dictate.
    static func cleanTitle(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespaces)
        while let first = text.first, "!*•".contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let parts = text.components(separatedBy: " - ")
            .filter { $0.range(of: "^\\d+ new items?$", options: .regularExpression) == nil }
            .filter { $0 != "Slack" }
        return parts.joined(separator: " - ")
    }

    // MARK: - Accessibility plumbing

    private static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    /// Value first, then title, then description: the value is what a message
    /// says, and the description is what a screen reader would announce about
    /// it. An element that has both is worth reading for the text it holds.
    private static func label(of element: AXUIElement) -> String? {
        for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = attribute(element, name) as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// The window holding an element, for the title and as the fallback when no
    /// conversation subtree is found.
    static func window(of element: AXUIElement) -> AXUIElement? {
        if let window = attribute(element, kAXWindowAttribute) { return (window as! AXUIElement) }
        var current = element
        for _ in 0..<depthLimit {
            guard let parent = attribute(current, kAXParentAttribute) else { return nil }
            let up = parent as! AXUIElement
            if (attribute(up, kAXRoleAttribute) as? String) == "AXWindow" { return up }
            current = up
        }
        return nil
    }

    static func title(of window: AXUIElement) -> String? {
        attribute(window, kAXTitleAttribute) as? String
    }
}
