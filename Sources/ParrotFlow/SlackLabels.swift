import AppKit

/// Slack's labels: what a label says about a message, a person, a place or
/// the sidebar, and how a pane's labels become the published text. Pure, so
/// `--tree-test` scores it without Slack running.
extension SlackReader {

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
        /// Inside a run of code: `` `EDITOR_FRAME_ANCESTORS=` `` rather than a
        /// word somebody wrote. Chromium marks it with the `AXCodeStyleGroup`
        /// subrole, so this is not a Slack rule.
        var code: Bool = false
    }

    /// One line of the conversation, and enough about it to tell a message
    /// from Slack's announcement of that same message.
    private struct Line {
        let text: String
        let frame: CGRect?
        let announced: Bool

        /// Whether this line is drawn around the other one. Unknown boxes
        /// answer true: a tree that publishes no geometry is the case the
        /// wording rule was written for.
        func holds(_ other: Line) -> Bool {
            guard let mine = frame, let theirs = other.frame else { return true }
            return mine.insetBy(dx: -2, dy: -2).contains(theirs)
        }
    }

    /// What a walk found, before anything is cut to size.
    struct Assembled: Equatable {
        /// The channel or direct message this window is showing.
        let place: String
        /// Whoever is named as an author, plus the members the header lists.
        let people: [String]
        /// The conversation, newest last, one label per line.
        let text: String
        /// What was written as code, in the order it appears. A term found here
        /// was marked as code by whoever typed it, which is a better reason to
        /// write it that way than anything a spelling rule can work out.
        let code: [String]
    }

    /// Rows that organise the sidebar rather than name anything in it.
    private static let sections: Set<String> = [
        "Threads", "Huddles", "Recap", "Drafts & sent", "Directories", "Starred",
        "Priority", "Activity", "DMs", "Later", "Canvases", "Files", "Templates",
        "Automations", "Apps", "Slack Connect", "External connections", "More",
        "Channels", "Direct messages", "Channels and direct messages", "Add channels",
        "VIP unreads", "Direct Messages", "My team", "Unreads", "Mentions",
    ]

    /// `Mik Okun (notifications snoozed), status: …` and `sws-engineering-internal
    /// (private, is a member, 14 members, …)` — a sidebar row is a name followed
    /// by whatever Slack has to say about it today. Presence, unread counts and
    /// draft marks change while you dictate; the name does not.
    ///
    /// A channel is written with its `#`, a person without. The tell is the
    /// shape rather than the metadata: a public channel's row carries no
    /// metadata at all, and one word in lower case is not how anybody's name is
    /// drawn here.
    static func rosterNames(in label: String) -> [String] {
        var name = label
        if let status = name.range(of: ", status:") { name = String(name[..<status.lowerBound]) }
        if let open = name.range(of: " (") { name = String(name[..<open.lowerBound]) }
        name = name.trimmingCharacters(in: .whitespaces)
        // A section drawn with an emoji arrives as "relaxed My team": the emoji
        // is read out as its own name, in lower case, in front of the heading.
        if let space = name.firstIndex(of: " "), name.first?.isLowercase == true,
           name[name.index(after: space)].isUppercase {
            name = String(name[name.index(after: space)...])
        }
        // A group conversation is drawn as everybody in it.
        let parts = name.components(separatedBy: ", ").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return parts.compactMap { part -> String? in
            guard !part.isEmpty, part.count <= 60, !sections.contains(part),
                  part.rangeOfCharacter(from: .letters) != nil else { return nil }
            let channel = !part.contains(" ") && part == part.lowercased()
            return channel ? "#\(part)" : part
        }
    }

    /// How many names and code runs are published, and how long one may be.
    /// `context.text` is capped at 2000 characters and these are published
    /// beside it, so they are capped too: a busy channel has a hundred authors
    /// and a pasted file is one code run of any length.
    static let maxSpans = 40
    static let maxSpanChars = 200

    /// The sidebar is a list of short names, so it is capped higher: this
    /// speaker's has 44 channels and people in it.
    static let maxRoster = 80

    /// `Reply to thread in sws-engineering-internal`, `Reply to thread with
    /// Salman Adeeb`: the name Slack gives a reply box in the Threads view.
    static func threadPlace(in name: String) -> String? {
        for (prefix, sigil) in [("Reply to thread in ", "#"), ("Reply to thread with ", "")]
        where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : sigil + rest
        }
        return nil
    }

    static let memberPrefix = "View all "

    /// `sws-engineering-internal (private channel)`, `Tasmeen Kathuria (direct
    /// message, away)` — the label Slack puts on the message list, and the one
    /// thing on screen that names the conversation without the window title's
    /// unread counts and notification marks.
    static func place(in label: String) -> String? {
        // "Recent history in sws-engineering-internal (private channel)" is a
        // marker on an empty list Slack keeps beside the messages. It names the
        // channel and holds none of it, and an earlier version stopped there
        // and published three characters.
        guard !label.hasPrefix("Recent history") else { return nil }
        guard let open = label.range(of: " (", options: .backwards),
              label.hasSuffix(")") else { return nil }
        let kind = label[open.upperBound...].dropLast().lowercased()
        // "group direct message" as well as "direct message, away": Slack says
        // which kind of conversation it is, and how many people are in it.
        guard kind.contains("channel") || kind.contains("direct message") else { return nil }
        // A thread in the side panel: "Thread in sws-engineering-internal (channel)".
        var name = String(label[..<open.lowerBound])
        if name.hasPrefix("Thread in ") { name.removeFirst("Thread in ".count) }
        let isChannel = kind.contains("channel")
        return isChannel ? "#\(name)" : name
    }

    /// `Martin Alix: @channel Thank you everyone!` — Slack writes whoever spoke
    /// into the label of each message group, and the paragraphs of that message
    /// hang under it. This answers "is this a message", which is a question
    /// about the window's shape.
    ///
    /// Anything can be a display name, `mik` and `deploy-bot` included, so this
    /// asks only for the shape: a few words, then a colon, then a space. A URL
    /// fails on the space — `http://localhost:3000` has none after its colon.
    static func speaker(in label: String) -> String? {
        guard let colon = label.firstIndex(of: ":") else { return nil }
        let name = String(label[..<colon])
        let words = name.split(separator: " ")
        guard (1...4).contains(words.count), name.count <= 48,
              words.allSatisfy({ $0.first?.isLetter == true || $0.first?.isNumber == true }),
              label.index(after: colon) < label.endIndex,
              label[label.index(after: colon)] == " "
        else { return nil }
        return tidy(name)
    }

    /// The same label read as a person, which is a stricter question: this name
    /// is published as `context.people` and offered to a dictation as a
    /// spelling, so "tip: try this" must not make somebody called Tip.
    ///
    /// Capitalisation is what separates the two. It costs the lowercase display
    /// names — `mik` stays out of `people` — and those are the ones a speaker
    /// says as an ordinary word anyway. The message itself is kept either way,
    /// because `speaker` decides that.
    static func author(in label: String) -> String? {
        guard let name = speaker(in: label) else { return nil }
        let words = name.split(separator: " ")
        guard words.allSatisfy({ $0.first?.isUppercase == true || $0.first?.isNumber == true })
        else { return nil }
        return name
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
    ///
    /// Cut in one piece from the clock on, so "I uploaded 3 files." in front of
    /// it stays. On a real window, 2026-09-28, 21 of 21 announcements ended
    /// with a clock, and none had counts without one.
    static func trimAnnouncement(_ label: String) -> String {
        let suffix = "\\s*\\d{1,2}:\\d{2}(:\\d{2})? ?[AP]M\\.?"
            + "(,?\\s*\\d+ (reaction|repl(y|ies)|attachment|link|file|edit)s?)*\\.?,?\\s*$"
        var text = label
        if let found = text.range(of: suffix, options: .regularExpression) {
            text.removeSubrange(found)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// The conversation as text, the place, and the people, from one walk.
    ///
    /// Pure, so `--tree-test` scores it without Slack running.
    static func assemble(_ nodes: [Node], title: String?) -> Assembled {
        var named = ""
        var people: [String] = []
        var lines: [Line] = []
        var code: [String] = []

        for node in nodes {
            let label = node.label
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if named.isEmpty, let here = place(in: label) { named = here }
            if let author = author(in: label), !author.isEmpty, people.count < maxSpans,
               !people.contains(author) {
                people.append(author)
            }
            for member in members(in: label)
            where !member.isEmpty && people.count < maxSpans && !people.contains(member) {
                people.append(member)
            }
            guard node.inMessage, !isFurniture(label) else { continue }
            if node.code, code.count < maxSpans, label.count <= maxSpanChars,
               !code.contains(label) { code.append(label) }
            // The screen-reader announcement of a message, which the message
            // itself follows. Dropped by shape — a name, a colon, and an
            // ellipsis where the text was cut — rather than by comparing it
            // with what comes next, because the two are not always adjacent.
            if speaker(in: label) != nil, label.hasSuffix("…") { continue }
            // Only Slack's own announcement of a message carries the clock and
            // the counts. Trimming every label would cut "let's meet at 9:03 PM."
            // out of a sentence somebody wrote.
            let announced = speaker(in: label) != nil
            let said = announced ? trimAnnouncement(label) : label
            guard !said.isEmpty else { continue }
            lines.append(Line(text: said, frame: node.frame, announced: announced))
        }

        // Slack announces each message and then draws it, so the same words
        // arrive twice. The copy is dropped by where it is, not by how it
        // reads: the announcement's box contains the message's own. Two people
        // can both write "ok", and a rule about wording alone would delete the
        // second one.
        var kept: [Line] = []
        for (i, line) in lines.enumerated() {
            let neighbours = lines[max(0, i - 2)..<min(lines.count, i + 3)]
            let copied = neighbours.contains { other in
                other.announced && !line.announced && other.text != line.text
                    && other.text.contains(line.text) && other.holds(line)
            }
            if copied { continue }
            // A paragraph is drawn as a group and again as the text inside it.
            // One person saying "ok" twice is two boxes, one under the other.
            if let last = kept.last, last.text == line.text,
               last.holds(line) || line.holds(last) { continue }
            kept.append(line)
        }
        if named.isEmpty, let title { named = cleanTitle(title) }
        return Assembled(
            place: named, people: people,
            text: kept.map(\.text).joined(separator: "\n"), code: code)
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
}
