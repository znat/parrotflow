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
