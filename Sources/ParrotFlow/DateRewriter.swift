import Foundation

/// Rewrites the dates and clock times in a piece of text, without a model.
///
/// **Parked, and reachable only from `--dates`.** Nothing in the app calls it:
/// it is not a capability, the router cannot pick it, and `free_form` does not
/// know it exists. It works — 26/27 on tests/dates-cases.yaml, no model, 2ms —
/// and it is kept because the measurement was worth having and the clock half
/// is likely to survive whatever replaces the date half.
///
/// What parked it is a better idea about what a dictated date is. This file
/// assumes the instruction names a target format: "make the dates ISO", "with
/// slashes, month first". But dictation does not arrive that way. Said aloud,
/// "le 10 du 12" already *is* a format — the speaker chose day-then-month, and
/// what they want written is "10/12". The shape is in the utterance, not in a
/// separate instruction, and a rewriter that waits to be told a format cannot
/// see it.
///
/// That reframes the job from "reformat a date the detector found" to "write
/// the date the way it was spoken", which is closer to what `Numbers.swift`
/// does for numbers and probably belongs next to it rather than here. Left for
/// later, deliberately: the numbers it would build on are English-only today.
///
/// The division of labour is the point. Finding a date and rendering it in a
/// named format is arithmetic over a calendar — there is exactly one right
/// answer and no judgement in it — and that is the half a small model does
/// worst. Measured on tests/generic-cases.yaml, gemma turned `2026-01-15` into
/// `2026-January-15` asked to spell the month out, and `2026-04-09` into
/// `04/2026/09` asked for slashes month first: it knows the format and loses
/// the fields. The prompt that used to ship did worse still, answering "the
/// deadline is March 3 2026" with `2026-03-03` and dropping the sentence.
///
/// So `NSDataDetector` finds them and `DateFormatter` renders them, and only
/// the matched ranges are ever touched — everything the instruction did not ask
/// about is unchanged by construction rather than by asking nicely.
///
/// Multilingual for free, which is the part worth knowing. The detector reads
/// en, fr, es, de, it and pt without being told which, and independently of the
/// locale: measured under en_GB, en_US and fr_FR, "le point est le 3 mars 2026
/// à 9h30" is found in all three. Dutch yields only the time and Japanese
/// nothing, so this is wide but not universal.
///
/// Two behaviours inherited from the detector, both real:
///
///   - `12/03/2025` is read by the locale's convention — December 3rd under
///     en_US, March 12th under en_GB and fr_FR. That is the right answer to
///     an ambiguous input, but it does mean the result follows system settings.
///   - A date with no year resolves to the *next* one. "the meeting is 15
///     January" comes back as 2027, not 2026.
enum DateRewriter {

    // MARK: - What was asked for

    /// How the dates should come out. Derived from the instruction, which is
    /// the only part of this a model could plausibly do better — see
    /// `format(for:)` for why it does not have to.
    enum Format: Equatable {
        case iso
        case separated(Separator, Order)
        /// The month named rather than numbered: "3 March 2026".
        case spelled(Order)

        enum Separator: String, Equatable { case slash = "/", dot = ".", dash = "-" }
        /// Which field leads. `.locale` means "however this user writes dates".
        enum Order: Equatable { case dayFirst, monthFirst, locale }
    }

    /// How the clock times should come out.
    enum Clock: Equatable { case twentyFour, twelve }

    /// What the whole instruction is asking to be rewritten. Dates and times
    /// are separate passes because they are separate asks: "make the dates ISO"
    /// must not touch a time, and "use the 24 hour clock" must not touch a date.
    enum Request: Equatable {
        case dates(Format)
        case times(Clock)
        /// Nothing in the instruction names a date or clock format.
        case none
    }

    // MARK: - Reading the instruction

    /// Reads the instruction with keywords rather than a model call.
    ///
    /// Deliberate, and measured — see tests/dates-cases.yaml. The vocabulary of
    /// date formats is tiny and closed ("ISO", "slashes", "day first", "spell
    /// the month out"), which is the one shape where matching words is not a
    /// liability. It also costs nothing and cannot invent a format, where the
    /// model path costs a call and can.
    ///
    /// What it deliberately does not do is guess. An instruction that names no
    /// format at all gets `.iso` when it is clearly about dates, because that
    /// was the removed prompt's rule and it is the only format a speaker never
    /// has to explain — but an instruction that is not about dates or times at
    /// all returns `.none`, and the caller leaves the text alone.
    static func request(for instruction: String) -> Request {
        let said = instruction.lowercased()

        func mentions(_ words: [String]) -> Bool {
            words.contains { said.contains($0) }
        }

        // Clock first: "24 hour" is unambiguous, where "format the times" alone
        // is not, and a sentence naming both is asking about the clock.
        if mentions(["24 hour", "24-hour", "24h", "twenty four hour",
                     "military time", "24 heures", "format 24"]) {
            return .times(.twentyFour)
        }
        if mentions(["12 hour", "12-hour", "am pm", "am/pm", "12 heures"]) {
            return .times(.twelve)
        }

        let aboutDates = mentions(["date", "day", "month", "year", "jour", "mois", "année"])
        guard aboutDates else { return .none }

        let order: Format.Order =
            mentions(["day first", "day month year", "dd/mm", "day-first", "jour d'abord"]) ? .dayFirst
            : mentions(["month first", "month day year", "mm/dd", "month-first"]) ? .monthFirst
            : .locale

        if mentions(["spell", "written out", "write the month out", "long form",
                     "month out", "in words", "en toutes lettres"]) {
            return .dates(.spelled(order))
        }
        if mentions(["slash", "/"]) { return .dates(.separated(.slash, order)) }
        if mentions(["dot", "full stop"]) { return .dates(.separated(.dot, order)) }
        if mentions(["dash", "hyphen"]) {
            // A dash with no stated order is ISO, which is the format people
            // mean when they say "with dashes" and the one ISO already is.
            return order == .locale ? .dates(.iso) : .dates(.separated(.dash, order))
        }
        return .dates(.iso)
    }

    // MARK: - Rewriting

    /// A time, matched on its own terms rather than by the date detector.
    ///
    /// Clock times are regular in a way dates are not — two fields, a fixed
    /// separator, an optional meridiem — so a pattern is exact here where it
    /// would be reckless on dates. It also keeps the two passes independent:
    /// the date detector swallows "3 March 2026 at 9:30" whole, and asking it
    /// for the time half back is harder than finding the time directly.
    private static let timePattern = try? NSRegularExpression(
        pattern: #"\b(\d{1,2})\s*(?:[:h.]\s*(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)|\b(\d{1,2})\s*[:h]\s*(\d{2})\b"#,
        options: [.caseInsensitive]
    )

    /// Applies `instruction` to `text`, or returns it unchanged.
    ///
    /// `languages` is the configured dictation list, used only to pick which
    /// language a spelled-out month is written in — the detector needs no such
    /// hint to *find* the date.
    static func apply(instruction: String, to text: String, languages: [String] = ["en"]) -> String {
        switch request(for: instruction) {
        case .none: return text
        case .dates(let format): return rewriteDates(in: text, as: format, languages: languages)
        case .times(let clock): return rewriteTimes(in: text, as: clock)
        }
    }

    static func rewriteDates(in text: String, as format: Format, languages: [String]) -> String {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue
        ) else { return text }

        let locale = monthLocale(for: text, languages: languages)
        let formatter = DateFormatter()
        formatter.locale = locale

        var output = text
        // Back to front: replacing shifts every range after it.
        let matches = detector
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
            .reversed()

        for match in matches {
            guard let date = match.date,
                  let full = Range(match.range, in: text),
                  // The detector's range is wider than the date. Asked about
                  // "we start on March 3 2026" it returns "start on March 3
                  // 2026", and replacing that whole span deleted two words
                  // nobody mentioned — the exact failure this file exists to
                  // prevent, committed by the file itself. So the span is
                  // trimmed back to the date, and a span that cannot be
                  // trimmed with confidence is left alone.
                  let range = trimmedToDate(full, in: text)
            else { continue }
            let matched = String(text[range])

            // A match carrying a time as well as a date is left alone. The
            // detector returns "3 March 2026 at 9:30" as one range, and
            // rewriting it as a date would delete the time — the failure this
            // whole file exists to avoid. Refusing costs a second attempt;
            // silently dropping half a sentence costs the sentence.
            if containsTime(matched) {
                Log.write("dates: left \"\(matched)\" alone — it carries a time too")
                continue
            }

            // Only the fields that were actually said come back. "3 décembre"
            // becomes "3/12", never "03/12/2026" — the detector resolves a
            // missing year to the next occurrence, so emitting one would print
            // a year the speaker did not say and may not mean. This is the
            // same rule as everywhere else here: render, never invent.
            formatter.dateFormat = template(
                for: format,
                locale: locale,
                year: yearText(in: matched, date: date),
                padded: isPadded(matched)
            )
            let rendered = formatter.string(from: date)
            guard rendered != matched else { continue }
            output.replaceSubrange(
                Range(match.range, in: output) ?? range, with: rendered
            )
        }
        return output
    }

    static func rewriteTimes(in text: String, as clock: Clock) -> String {
        guard let pattern = timePattern else { return text }
        var output = text

        for match in pattern
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
            .reversed()
        {
            guard let range = Range(match.range, in: text) else { continue }
            func group(_ index: Int) -> String? {
                guard let r = Range(match.range(at: index), in: text) else { return nil }
                return String(text[r])
            }

            // Either the meridiem alternative matched (groups 1-3) or the bare
            // clock one (groups 4-5).
            let meridiem = group(3)?.lowercased().replacingOccurrences(of: ".", with: "")
            let hourText = group(1) ?? group(4)
            let minuteText = group(2) ?? group(5)
            guard let hourText, var hour = Int(hourText) else { continue }
            let minute = minuteText.flatMap(Int.init) ?? 0
            guard hour <= 24, minute < 60 else { continue }

            if let meridiem {
                guard hour <= 12 else { continue }
                if meridiem == "pm", hour != 12 { hour += 12 }
                if meridiem == "am", hour == 12 { hour = 0 }
            } else if hour > 23 {
                continue
            }

            let rendered: String
            switch clock {
            case .twentyFour:
                rendered = String(format: "%02d:%02d", hour % 24, minute)
            case .twelve:
                let suffix = hour < 12 ? "am" : "pm"
                var twelve = hour % 12
                if twelve == 0 { twelve = 12 }
                rendered = minute == 0
                    ? "\(twelve)\(suffix)"
                    : String(format: "%d:%02d%@", twelve, minute, suffix)
            }
            guard rendered != String(text[range]) else { continue }
            output.replaceSubrange(Range(match.range, in: output) ?? range, with: rendered)
        }
        return output
    }

    // MARK: - Details

    /// The `DateFormatter` pattern for a format, carrying two properties of the
    /// input forward: whether a year was written, and whether its numbers were
    /// zero-padded. A transcript that says "3 décembre" wants "3/12", not
    /// "03/12" — the padding was not there to begin with, and adding it is a
    /// change nobody asked for.
    private static func template(
        for format: Format, locale: Locale, year: String?, padded: Bool
    ) -> String {
        let day = padded ? "dd" : "d"
        let month = padded ? "MM" : "M"

        func ordered(_ order: Format.Order, separator: String) -> String {
            let fields = resolve(order, locale: locale) == .dayFirst
                ? [day, month] : [month, day]
            return (fields + (year.map { _ in ["yyyy"] } ?? [])).joined(separator: separator)
        }

        switch format {
        case .iso:
            // ISO with no year is the year-less calendar date of the standard,
            // minus its leading dashes, which nobody dictating wants to read.
            // Padded regardless: fixed width is the whole point of the format.
            return year == nil ? "MM-dd" : "yyyy-MM-dd"
        case .separated(let separator, let order):
            return ordered(order, separator: separator.rawValue)
        case .spelled(let order):
            switch resolve(order, locale: locale) {
            case .dayFirst: return year == nil ? "d MMMM" : "d MMMM yyyy"
            default: return year == nil ? "MMMM d" : "MMMM d, yyyy"
            }
        }
    }

    /// The year as it appears in the matched text, or nil when it does not.
    ///
    /// Compared against the resolved date rather than pattern-matched, so a
    /// four-digit number that is not the year — "on 3 December, all 2000 of
    /// them" is not one match, but the principle holds — cannot be mistaken
    /// for one.
    private static func yearText(in matched: String, date: Date) -> String? {
        let year = Calendar.current.component(.year, from: date)
        let full = String(year)
        if matched.contains(full) { return full }
        // Two-digit years: "12/03/25" said the year, in its own way.
        let short = String(full.suffix(2))
        let pattern = #"(?<!\d)"# + short + #"(?!\d)"#
        if matched.range(of: pattern, options: .regularExpression) != nil,
           matched.range(of: #"\d{1,2}\s*[/.\-]\s*\d{1,2}\s*[/.\-]\s*\d{2}"#,
                         options: .regularExpression) != nil {
            return short
        }
        return nil
    }

    /// Whether the source wrote its numbers with a leading zero.
    private static func isPadded(_ matched: String) -> Bool {
        matched.range(of: #"(?<!\d)0\d(?!\d)"#, options: .regularExpression) != nil
    }

    /// `.locale` resolved against how this user actually writes dates, read
    /// from the locale's own short date format rather than a country list.
    private static func resolve(_ order: Format.Order, locale: Locale) -> Format.Order {
        guard order == .locale else { return order }
        let template = DateFormatter.dateFormat(
            fromTemplate: "yMd", options: 0, locale: locale
        ) ?? "M/d/y"
        guard let day = template.firstIndex(of: "d"),
              let month = template.firstIndex(of: "M") else { return .monthFirst }
        return day < month ? .dayFirst : .monthFirst
    }

    /// Which language a spelled-out month is written in.
    ///
    /// The text decides, not the system: a French sentence wants "3 mars 2026"
    /// on an English Mac. Reuses the recogniser the correction prompts use, so
    /// the same 52/53 measurement covers it, and falls back to the current
    /// locale when there is not enough text to tell.
    private static func monthLocale(for text: String, languages: [String]) -> Locale {
        let code = DictationLanguage.detect(
            text, allowed: languages, fallback: languages.first ?? "en"
        )
        // Region matters for field order, so keep the user's rather than
        // inventing one: their language for the month name, their region for
        // everything else.
        guard let region = Locale.current.region?.identifier else { return Locale(identifier: code) }
        return Locale(identifier: "\(code)_\(region)")
    }

    private static let timeMarker = try? NSRegularExpression(
        pattern: #"\d\s*[:h]\s*\d{2}|\b\d{1,2}\s*(am|pm|a\.m\.|p\.m\.)|\bnoon\b|\bmidnight\b|\bmidi\b"#,
        options: [.caseInsensitive]
    )

    /// Narrows the detector's range to the date inside it.
    ///
    /// Words are kept from the first that looks like part of a date to the
    /// last; anything outside that is the detector's generosity and belongs to
    /// the sentence. Returns nil when nothing in the span looks like a date,
    /// which is the safe answer — the caller then leaves it alone.
    private static func trimmedToDate(
        _ range: Range<String.Index>, in text: String
    ) -> Range<String.Index>? {
        var first: Range<String.Index>?
        var last: Range<String.Index>?
        text.enumerateSubstrings(in: range, options: .byWords) { word, wordRange, _, _ in
            guard let word, isDateWord(word) else { return }
            if first == nil { first = wordRange }
            last = wordRange
        }
        guard let first, let last else { return nil }
        return first.lowerBound..<last.upperBound
    }

    /// Cheap month and weekday names for every language this could be in.
    /// Built once: `DateFormatter` symbol lookups are not free, and this runs
    /// per word.
    private static let calendarWords: Set<String> = {
        var words = Set<String>()
        for identifier in ["en", "fr", Locale.current.identifier] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: identifier)
            for group in [formatter.monthSymbols, formatter.shortMonthSymbols,
                          formatter.standaloneMonthSymbols, formatter.weekdaySymbols,
                          formatter.shortWeekdaySymbols] {
                for symbol in group ?? [] {
                    words.insert(symbol.lowercased().trimmingCharacters(in: .punctuationCharacters))
                }
            }
        }
        return words
    }()

    private static func isDateWord(_ word: String) -> Bool {
        if word.contains(where: \.isNumber) { return true }
        return calendarWords.contains(word.lowercased())
    }

    private static func containsTime(_ text: String) -> Bool {
        guard let timeMarker else { return false }
        return timeMarker.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)
        ) != nil
    }
}
