import Foundation

/// The Pause you asked for. Where it is held, nil means not paused.
enum VoicePause: Equatable {
    case untilResumed
    case until(Date)

    /// The menu's ways to pause.
    enum Choice: String, CaseIterable, Decodable {
        case untilResumed = "until_resumed"
        case hour
        case tomorrow

        var title: String {
            switch self {
            case .untilResumed: "Pause until I resume"
            case .hour: "Pause for 1 hour"
            case .tomorrow: "Pause until tomorrow"
            }
        }
    }

    init(_ choice: Choice, now: Date, calendar: Calendar = .current) {
        switch choice {
        case .untilResumed: self = .untilResumed
        case .hour: self = .until(now.addingTimeInterval(3600))
        case .tomorrow: self = .until(Self.nextMorning(after: now, calendar: calendar))
        }
    }

    /// The next 8:00 strictly after `now`: today's before 8:00, else tomorrow's.
    static func nextMorning(after now: Date, calendar: Calendar) -> Date {
        calendar.nextDate(after: now, matching: DateComponents(hour: 8, minute: 0, second: 0),
                          matchingPolicy: .nextTime) ?? now.addingTimeInterval(86_400)
    }

    var deadline: Date? {
        if case .until(let date) = self { return date }
        return nil
    }

    /// What the app's defaults keep: `distantFuture` for until resumed.
    var stored: Date { deadline ?? .distantFuture }

    /// What a launch starts with. A deadline already past is no pause.
    static func restored(_ stored: Date?, now: Date) -> VoicePause? {
        guard let stored, stored > now else { return nil }
        return stored == .distantFuture ? .untilResumed : .until(stored)
    }

    /// "until 15:42", "until tomorrow 08:00", "until I resume".
    func phrase(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let deadline else { return "until I resume" }
        let time = Self.time(deadline, calendar: calendar, locale: locale)
        if calendar.isDate(deadline, inSameDayAs: now) { return "until \(time)" }
        if let next = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(deadline, inSameDayAs: next) {
            return "until tomorrow \(time)"
        }
        let day = DateFormatter()
        day.locale = locale
        day.timeZone = calendar.timeZone
        day.dateStyle = .short
        return "until \(day.string(from: deadline)) \(time)"
    }

    /// In the system's own 12- or 24-hour style.
    static func time(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// The Voice section of the status menu.
enum VoiceMenu {

    enum Action: Equatable {
        case pause(VoicePause.Choice)
        case resume
        /// An answer's id: again when heard, now when waiting.
        case play(Int)
        case goTo(session: String)
    }

    struct Row: Equatable {
        let title: String
        /// Nil: a line that says, not a thing to click.
        let action: Action?
        /// The pause shortcut does what this row does.
        var shortcut = false
    }

    /// The pause shortcut: resume when paused or held by a call, else pause until resumed.
    static func toggle(_ pause: VoicePause?, call: String? = nil) -> Action {
        pause == nil && call == nil ? .pause(.untilResumed) : .resume
    }

    /// `call`: the app holding the voice, "Zoom".
    static func rows(
        _ pause: VoicePause?, call: String? = nil, waiting: Int, now: Date, calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [Row] {
        let rows: [Row]
        if pause != nil || call != nil {
            let said = pause.map {
                $0 == .untilResumed ? "Paused" : "Paused " + $0.phrase(now: now, calendar: calendar, locale: locale)
            } ?? "Paused · \(call ?? "") is using the mic"
            rows = [Row(title: ([said] + [VoicePill.waiting(waiting)]).compactMap { $0 }.joined(separator: " · "),
                        action: nil),
                    Row(title: "Resume", action: .resume)]
        } else {
            rows = VoicePause.Choice.allCases.map { Row(title: $0.title, action: .pause($0)) }
        }
        let toggle = toggle(pause, call: call)
        return rows.map { row in
            var row = row
            row.shortcut = row.action == toggle
            return row
        }
    }
}

/// The Answers submenu: waiting answers in the order they will play, then the heard ones, newest first.
enum AnswersMenu {

    struct Row {
        let title: String
        let said: String
        /// "Play now" or "Play again", then "Go to session" when the session's window is known.
        let actions: [(title: String, action: VoiceMenu.Action)]
        /// The first heard row, after the waiting ones.
        var separated = false
    }

    /// "Answers", or "Answers · 3 waiting".
    static func title(_ queue: VoiceQueue) -> String {
        (["Answers"] + [VoicePill.waiting(queue.waiting.count)]).compactMap { $0 }.joined(separator: " · ")
    }

    static func rows(
        _ queue: VoiceQueue, name: (String) -> String, known: (String) -> Bool, now: Date
    ) -> [Row] {
        func row(_ entry: VoiceQueue.Entry, play: String) -> Row {
            let goTo: [(String, VoiceMenu.Action)] =
                known(entry.session) ? [("Go to session", .goTo(session: entry.session))] : []
            return Row(title: name(entry.session) + " · " + ago(entry.added, now: now), said: start(of: entry.text),
                       actions: [(play, .play(entry.id))] + goTo)
        }
        var heard = queue.heard.map { row($0, play: "Play again") }
        if !queue.waiting.isEmpty, !heard.isEmpty { heard[0].separated = true }
        return queue.waiting.map { row($0, play: "Play now") } + heard
    }

    /// "just now", "4 min ago", "2 h ago", "3 days ago".
    static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "just now"
        case ..<60: return "\(minutes) min ago"
        case ..<1_440: return "\(minutes / 60) h ago"
        case ..<2_880: return "yesterday"
        default: return "\(minutes / 1_440) days ago"
        }
    }

    /// The first words, on one line, cut at a word near `limit` characters.
    static func start(of text: String, limit: Int = 60) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > limit else { return line }
        let cut = line.prefix(limit)
        let words = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return words.trimmingCharacters(in: .punctuationCharacters) + "…"
    }
}
