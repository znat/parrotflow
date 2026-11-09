import Foundation
import Yams

/// Brings an older config.yaml up to the version this app writes.
///
/// A file says its version in a top-level `version:` line, and a file without
/// one is version 0. Each `Step` takes a file from the version before it to its
/// own, and every step above the file's version runs, in order. Then the
/// `version:` line is written.
///
/// The edits are made on lines, never by decoding and writing the YAML back
/// out, so a person's comments and order stay where they put them. Each step
/// checks before it edits, so a file that is half done, by hand or by an
/// earlier run, is finished rather than edited twice.
///
/// The result is decoded before anything is written. A step that leaves a
/// file the app cannot read, or that does not do what it is for, writes
/// nothing.
enum ConfigMigration {

    struct Step {
        let version: Int
        let summary: String
        let apply: ([String]) -> [String]
        /// What the edited file must hold. Asked of the decoded result.
        let holds: (Config) -> Bool
        /// What to edit by hand when `holds` fails.
        var byHand: String?
    }

    static let steps: [Step] = [sentenceRepairTransform, scriptsDeclareNeeds, voiceSection]

    static var current: Int { steps.last?.version ?? 0 }

    /// What to tell a person whose config needs a step it has not had.
    static var runIt: String {
        "`\(binary) --upgrade-config --write` rewrites the config, after a backup"
    }

    static var binary: String {
        Bundle.main.executablePath ?? "ParrotFlow"
    }

    // MARK: - Running

    enum Failure: LocalizedError {
        case newer(Int)
        case unreadable(String)
        case notDone(Int)

        var errorDescription: String? {
            switch self {
            case .newer(let version):
                return "config.yaml is version \(version), and this app knows up to"
                    + " \(ConfigMigration.current). Read as it is"
            case .unreadable(let why):
                return "the upgraded config would not load — \(why)"
            case .notDone(let version):
                return "step \(version) did not do what it is for"
                    + (ConfigMigration.steps.first { $0.version == version }?.byHand.map { ". " + $0 } ?? "")
            }
        }
    }

    struct Plan {
        let from: Int
        let steps: [Step]
        let before: String
        let after: String

        var changes: Bool { before != after }
        var to: Int { steps.last?.version ?? from }
    }

    static func version(of text: String) -> Int {
        lines(text).lazy.compactMap { line -> Int? in
            guard let match = line.firstMatch(of: #/^version:\s*(\d+)\s*(#.*)?$/#) else { return nil }
            return Int(match.1)
        }.first ?? 0
    }

    /// The steps above the file's version, applied, and checked by decoding
    /// the result the way `ConfigStore.load()` does.
    static func plan(_ text: String, directory: URL) throws -> Plan {
        let from = version(of: text)
        guard from <= current else { throw Failure.newer(from) }
        let pending = steps.filter { $0.version > from }
        guard !pending.isEmpty else { return Plan(from: from, steps: [], before: text, after: text) }
        var edited = lines(text)
        for step in pending { edited = step.apply(edited) }
        edited = stamped(edited, version: current)
        let after = edited.joined(separator: "\n") + "\n"
        let decoded: Config
        do {
            decoded = try YAMLDecoder().decode(
                Config.self, from: after, userInfo: [.configDirectory: directory]
            )
        } catch {
            throw Failure.unreadable(String(describing: error))
        }
        for step in pending where !step.holds(decoded) { throw Failure.notDone(step.version) }
        return Plan(from: from, steps: pending, before: text, after: after)
    }

    struct Written {
        let plan: Plan
        let backup: URL
    }

    /// The file, upgraded in place, with the old one kept beside it as
    /// `config.yaml.bak-v<old>-<date>`. Nil when there was nothing to do.
    static func upgrade(at url: URL) throws -> Written? {
        let text = try String(contentsOf: url, encoding: .utf8)
        let plan = try plan(text, directory: url.deletingLastPathComponent())
        guard plan.changes else { return nil }
        // Through a symlink, so a config kept elsewhere stays linked.
        let target = url.resolvingSymlinksInPath()
        // A config can hold keys. Both files keep its mode, from the moment
        // they exist.
        let mode = (try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
            as? NSNumber)?.uint16Value ?? 0o600
        let backup = backupURL(for: url, version: plan.from)
        try create(backup, holding: Data(text.utf8), mode: mode)
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).upgrade-\(getpid())")
        try create(temporary, holding: Data(plan.after.utf8), mode: mode)
        guard rename(temporary.path, target.path) == 0 else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            unlink(temporary.path)
            throw failure
        }
        return Written(plan: plan, backup: backup)
    }

    /// A new file, refused if the path exists, created with `mode`.
    static func create(_ url: URL, holding data: Data, mode: UInt16) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(mode & 0o777))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            guard fchmod(fd, mode_t(mode & 0o777)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            unlink(url.path)
            throw error
        }
    }

    /// Never over an earlier backup: a second upgrade on the same day, after a
    /// person put the old file back, is a second backup.
    static func backupURL(for url: URL, version: Int, on date: Date = Date()) -> URL {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        let stem = "\(url.lastPathComponent).bak-v\(version)-\(format.string(from: date))"
        let folder = url.deletingLastPathComponent()
        var candidate = folder.appendingPathComponent(stem)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem)-\(n)")
            n += 1
        }
        return candidate
    }

    /// At launch, before the config is read, and for `--upgrade-config
    /// --write`. Says what happened, or nil when the file needed nothing. A
    /// failure leaves the file as it was.
    static func atLaunch(at url: URL = ConfigStore.fileURL) -> (message: String, failed: Bool)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            guard let written = try upgrade(at: url) else { return nil }
            Log.write("config: upgraded from version \(written.plan.from) to \(written.plan.to);"
                + " the old file is \(written.backup.path)")
            for step in written.plan.steps { Log.write("config: \(step.version) — \(step.summary)") }
            for line in diff(lines(written.plan.before), lines(written.plan.after), context: 0) {
                Log.write("config:   \(line)")
            }
            return ("config.yaml upgraded to version \(written.plan.to): "
                + written.plan.steps.map(\.summary).joined(separator: "; ")
                + ". The old file is \(written.backup.lastPathComponent)", false)
        } catch {
            Log.write("config: not upgraded — \(error.localizedDescription)")
            return ("config.yaml was not upgraded — \(error.localizedDescription)", true)
        }
    }

    // MARK: - Lines

    static func lines(_ text: String) -> [String] {
        var out = text.components(separatedBy: "\n")
        if out.last == "" { out.removeLast() }
        return out
    }

    static func indent(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    static func isBlank(_ line: String) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }

    static func isComment(_ line: String) -> Bool {
        line.drop { $0 == " " }.first == "#"
    }

    /// A line that holds a key or an item, not a blank or a comment.
    static func isContent(_ line: String) -> Bool {
        !isBlank(line) && !isComment(line)
    }

    /// The line that writes `key:` at `depth` spaces.
    static func keyLine(_ key: String, depth: Int, in lines: [String], within range: Range<Int>) -> Int? {
        range.first { i in
            let line = lines[i]
            guard indent(line) == depth else { return false }
            let rest = line.dropFirst(depth)
            guard rest.hasPrefix(key + ":") else { return false }
            let after = rest.dropFirst(key.count + 1)
            return after.isEmpty || after.first == " "
        }
    }

    /// The lines under the key at `at`: everything deeper than it, up to the
    /// last deeper line before the next one at its depth or shallower.
    static func body(of at: Int, in lines: [String]) -> Range<Int> {
        let depth = indent(lines[at])
        var end = at + 1
        var i = at + 1
        while i < lines.count {
            let line = lines[i]
            if !isBlank(line) {
                guard indent(line) > depth else { break }
                end = i + 1
            }
            i += 1
        }
        return (at + 1)..<end
    }

    /// The depth the children of the key at `at` are written at.
    static func childDepth(of at: Int, in lines: [String]) -> Int? {
        body(of: at, in: lines).lazy.filter { isContent(lines[$0]) }.map { indent(lines[$0]) }.first
    }

    /// The comment lines directly above `at`, at its depth: the paragraph that
    /// describes it.
    static func paragraph(above at: Int, in lines: [String]) -> Int {
        var start = at
        while start > 0, isComment(lines[start - 1]), indent(lines[start - 1]) == indent(lines[at]) {
            start -= 1
        }
        return start
    }

    /// `range` gone, and one of the two blank lines it leaves between its
    /// neighbours with it.
    static func removing(_ range: Range<Int>, from lines: [String]) -> [String] {
        var out = lines
        out.removeSubrange(range)
        let at = range.lowerBound
        if at > 0, at < out.count, isBlank(out[at - 1]), isBlank(out[at]) {
            out.remove(at: at)
        }
        return out
    }

    /// A new top-level section at the end, a blank line above it.
    static func appending(_ section: [String], to lines: [String]) -> [String] {
        lines.contains(where: isContent) ? lines + [""] + section : section
    }

    /// `version: N`, in place of the line that says it, or above the first
    /// key, under the comments that open the file.
    static func stamped(_ lines: [String], version: Int) -> [String] {
        var out = lines
        if let at = out.firstIndex(where: { $0.hasPrefix("version:") }) {
            out[at] = "version: \(version)"
            return out
        }
        guard let key = out.firstIndex(where: isContent) else { return out + ["version: \(version)"] }
        let above = paragraph(above: key, in: out)
        out.insert(contentsOf: ["version: \(version)", ""], at: above > 0 ? above : key)
        return out
    }

    // MARK: - 1: the sentence_repair transform

    /// The Swift `sentence_repair` stage, under either of its names, became
    /// the `sentence_repair` transform. The block goes, the transform is
    /// defined, and it is the first step of `pipeline:`. A block that said
    /// `enabled: false` gets the step too: the owner shipped the transform as
    /// the default.
    static let sentenceRepairTransform = Step(
        version: 1,
        summary: "sentence repair is the sentence_repair transform, the first pipeline step",
        apply: { lines in
            var out = lines
            for key in ["sentence_repair", "interpret"] { out = removingBlock(key, from: out) }
            out = removingStageSteps(from: out)
            out = definingTransform(in: out)
            out = listingStep(in: out)
            return reworded(out, comments: staleComments)
        },
        holds: { config in
            config.transform(named: "sentence_repair") != nil
                && Pipeline.resolved(config: config).steps.contains {
                    $0.stage == .transform && $0.transform == "sentence_repair"
                }
                && !config.transcription.retired.contains { ["sentence_repair", "interpret"].contains($0) }
                && !config.transcription.unknownStages.contains { ["sentence_repair", "interpret"].contains($0) }
        }
    )

    /// Comments the shipped config carried about the stage, and what the
    /// shipped config says now. Replaced only where every line still reads as
    /// shipped.
    static let staleComments: [([String], [String])] = [
        ([
            "  # Not a pipeline step either: it is handed spans measured on the transcript",
            "  # as the decoder wrote it, and any edit above it moves them. It runs second,",
            "  # after `sentence_repair` and before everything below.",
        ], [
            "  # Not a pipeline step: it is handed spans measured on the transcript as the",
            "  # decoder wrote it, and any edit above it moves them. It runs first, before",
            "  # everything below.",
        ]),
        ([
            "  # parse and the readings and calls no model. It steps aside while the",
            "  # `sentence_repair` block is on. See docs/pipelines.md.",
        ], [
            "  # parse and the readings and calls no model. See docs/pipelines.md.",
        ]),
    ]

    static func reworded(_ lines: [String], comments: [([String], [String])]) -> [String] {
        var out = lines
        for (old, new) in comments {
            guard let at = out.indices.first(where: { Array(out[$0...].prefix(old.count)) == old })
            else { continue }
            out.replaceSubrange(at..<(at + old.count), with: new)
        }
        return out
    }

    static let definition = [
        "# Sentence marks a pause wrote, taken out again. Reads the parse and the",
        "# readings and calls no model. See docs/pipelines.md.",
        "- name: sentence_repair",
        "  description: repair sentence boundaries a pause cut",
        "  command: built-in/sentence_repair/sentence_repair.py",
        "  returns: json",
        "  parse: true",
        "  readings: true",
    ]

    static func transcription(in lines: [String]) -> Int? {
        keyLine("transcription", depth: 0, in: lines, within: lines.indices)
    }

    /// `transcription.<key>:` with its comments, its option lines and the
    /// paragraph above it.
    static func removingBlock(_ key: String, from lines: [String]) -> [String] {
        guard let parent = transcription(in: lines),
              let depth = childDepth(of: parent, in: lines),
              let at = keyLine(key, depth: depth, in: lines, within: body(of: parent, in: lines))
        else { return lines }
        return removing(paragraph(above: at, in: lines)..<body(of: at, in: lines).upperBound, from: lines)
    }

    /// The `pipeline:` key under `transcription:`.
    static func pipelineLine(in lines: [String]) -> Int? {
        guard let parent = transcription(in: lines),
              let depth = childDepth(of: parent, in: lines) else { return nil }
        return keyLine("pipeline", depth: depth, in: lines, within: body(of: parent, in: lines))
    }

    /// Each `- ` item under `pipeline:`, as the range of lines it spans.
    static func items(under at: Int, in lines: [String]) -> [Range<Int>] {
        let span = body(of: at, in: lines)
        guard let depth = span.first(where: { isContent(lines[$0]) }).map({ indent(lines[$0]) })
        else { return [] }
        var found: [Range<Int>] = []
        for i in span where indent(lines[i]) == depth && lines[i].dropFirst(depth).hasPrefix("-") {
            var end = i + 1
            while end < span.upperBound, isContent(lines[end]), indent(lines[end]) > depth { end += 1 }
            found.append(i..<end)
        }
        return found
    }

    /// `- sentence_repair`, `- interpret` and `- stage: …` lines. Left in
    /// they name a stage that is not there.
    static func removingStageSteps(from lines: [String]) -> [String] {
        guard let at = pipelineLine(in: lines) else { return lines }
        if lines[at].contains("[") {
            var out = lines
            out[at] = withoutFlowItems(lines[at])
            return out
        }
        let named = #/^\s*(-\s*)?(stage:\s*)?(sentence_repair|interpret)\s*(#.*)?$/#
        let mapped = #/^\s*-\s*\{\s*stage:\s*(sentence_repair|interpret)\s*[,}].*$/#
        var out = lines
        for item in items(under: at, in: lines).reversed()
        where lines[item].contains(where: { $0.wholeMatch(of: named) != nil || $0.wholeMatch(of: mapped) != nil }) {
            out.removeSubrange(item)
        }
        return out
    }

    /// `[a, sentence_repair, b]` -> `[a, b]`. A `{transform: …}` item is not
    /// a bare name and stays.
    static func withoutFlowItems(_ line: String) -> String {
        var out = line
        for (pattern, template) in [
            (#"(?<=[\[,])\s*(sentence_repair|interpret)\s*(?=[,\]])"#, ""),
            (#",\s*,"#, ","),
            (#"\[\s*,\s*"#, "["),
            (#",\s*\]"#, "]"),
        ] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            out = expression.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    static func definingTransform(in lines: [String]) -> [String] {
        let named = #/^\s*-?\s*name:\s*["']?sentence_repair["']?\s*(#.*)?$/#
        guard let at = keyLine("transforms", depth: 0, in: lines, within: lines.indices) else {
            return appending(["transforms:"] + definition.map { "  " + $0 }, to: lines)
        }
        let span = body(of: at, in: lines)
        if span.contains(where: { lines[$0].wholeMatch(of: named) != nil }) { return lines }
        var out = lines
        if lines[at].wholeMatch(of: #/^transforms:\s*(\[\s*\])?\s*(#.*)?$/#) != nil, span.isEmpty {
            out[at] = "transforms:"
            out.insert(contentsOf: definition.map { "  " + $0 }, at: at + 1)
            return out
        }
        let depth = span.first { isContent(lines[$0]) }.map { indent(lines[$0]) } ?? 2
        let pad = String(repeating: " ", count: depth)
        out.insert(contentsOf: [""] + definition.map { pad + $0 }, at: span.upperBound)
        return out
    }

    static func listingStep(in lines: [String]) -> [String] {
        let listed = #/^\s*-\s*(transform|prompt):\s*["']?sentence_repair["']?\s*(#.*)?$/#
        guard let parent = transcription(in: lines) else {
            return appending(["transcription:", "  pipeline:", "    - transform: sentence_repair"], to: lines)
        }
        guard let at = pipelineLine(in: lines) else {
            let depth = childDepth(of: parent, in: lines) ?? 2
            let pad = String(repeating: " ", count: depth)
            var out = lines
            out.insert(contentsOf: [pad + "pipeline:", pad + "  - transform: sentence_repair"],
                       at: body(of: parent, in: lines).upperBound)
            return out
        }
        var out = lines
        if lines[at].contains("[") {
            guard !lines[at].contains("sentence_repair") else { return lines }
            let empty = lines[at].wholeMatch(of: #/^\s*pipeline:\s*\[\s*\]\s*(#.*)?$/#) != nil
            out[at] = lines[at].replacing(
                "[", with: empty ? "[{transform: sentence_repair}" : "[{transform: sentence_repair}, ",
                maxReplacements: 1)
            return out
        }
        let span = body(of: at, in: lines)
        if span.contains(where: { lines[$0].wholeMatch(of: listed) != nil }) { return lines }
        let commented = #/^(\s*)#\s*-\s*transform:\s*sentence_repair\s*$/#
        if let line = span.first(where: { lines[$0].wholeMatch(of: commented) != nil }),
           let match = lines[line].wholeMatch(of: commented) {
            out[line] = match.1 + "- transform: sentence_repair"
            let start = paragraph(above: line, in: lines)
            if lines[start..<line].contains(where: { $0.contains("sentence_repair") }) {
                out.removeSubrange(start..<line)
            }
            return out
        }
        let depth = span.first { isContent(lines[$0]) }.map { indent(lines[$0]) }
            ?? indent(lines[at]) + 2
        out.insert(String(repeating: " ", count: depth) + "- transform: sentence_repair", at: at + 1)
        return out
    }

    // MARK: - 2: a script declares what its envelope needs

    /// The `returns:`, `parse:` and `readings:` values an older example wrote
    /// for each built-in script. The script's `parrotflow:` line says the
    /// same now, except `disfluency.py`, which declares `parse: vectors`.
    static let shippedNeeds: [String: [String: Set<String>]] = [
        "built-in/dates/en.py": ["returns": ["json"]],
        "built-in/numbers/en.py": ["returns": ["json"]],
        "built-in/money/en.py": ["returns": ["json"]],
        "built-in/disfluency/disfluency.py": ["returns": ["json"], "parse": ["true"]],
        "built-in/sentence_repair/sentence_repair.py":
            ["returns": ["json"], "parse": ["true"], "readings": ["true"]],
    ]

    /// In each definition whose `command:` is a built-in script, a
    /// `returns:`, `parse:` or `readings:` line that holds the value an older
    /// example wrote goes. Any other value is the person's and stays.
    static let scriptsDeclareNeeds = Step(
        version: 2,
        summary: "built-in scripts declare returns:, parse: and readings:, so the"
            + " values the example wrote for them are gone; disfluency gets parse: vectors",
        apply: { lines in
            ["prompts", "transforms"].reduce(lines) { lines, section in
                guard let at = keyLine(section, depth: 0, in: lines, within: lines.indices) else {
                    return lines
                }
                return withoutShippedNeeds(definitions(under: at, in: lines), in: lines)
            }
        },
        holds: { config in
            config.transforms.allSatisfy { transform in
                guard case .command(let command) = transform.body,
                      let shipped = shippedNeeds[script(of: command)] else { return true }
                return !transform.written.spelled.contains { shipped[$0.key]?.contains($0.value) == true }
            }
        }
    )

    static func withoutShippedNeeds(_ items: [Range<Int>], in lines: [String]) -> [String] {
        var out = lines
        for item in items.reversed() {
            if lines[item.lowerBound].wholeMatch(of: #/^\s*-\s*\{.*\}\s*(#.*)?$/#) != nil {
                out[item.lowerBound] = withoutShippedNeeds(inFlow: lines[item.lowerBound])
                continue
            }
            guard let command = keyValue("command", in: item, of: lines),
                  let shipped = shippedNeeds[script(of: command.value)] else { continue }
            let stale = Config.Transform.Needs.keys.compactMap { key in
                keyValue(key, in: item, of: lines).flatMap { found in
                    found.line != item.lowerBound && shipped[key]?.contains(found.value.lowercased()) == true
                        ? found : nil
                }
            }
            for found in stale.sorted(by: { $0.line > $1.line }) {
                if let comment = found.comment {
                    out[found.line] = String(repeating: " ", count: indent(lines[found.line])) + comment
                } else {
                    out.remove(at: found.line)
                }
            }
        }
        return out
    }

    /// `- {name: x, command: built-in/…, returns: json}` on one line.
    static func withoutShippedNeeds(inFlow line: String) -> String {
        func first(_ pattern: String, in text: String) -> (range: Range<String.Index>, value: String)? {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let whole = Range(match.range, in: text), let value = Range(match.range(at: 1), in: text)
            else { return nil }
            return (whole, String(text[value]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
        }
        guard let command = first(#"[{,]\s*command:\s*([^,}]+)"#, in: line),
              let shipped = shippedNeeds[script(of: command.value)] else { return line }
        var out = line
        for key in Config.Transform.Needs.keys {
            for pattern in [#",\s*"# + key + #":\s*([^,}]*?)\s*(?=[,}])"#,
                            #"(?<=\{)\s*"# + key + #":\s*([^,}]*?)\s*,\s*"#] {
                guard let found = first(pattern, in: out),
                      shipped[key]?.contains(found.value.lowercased()) == true else { continue }
                out.removeSubrange(found.range)
                break
            }
        }
        return out
    }

    /// The script a `command:` names: its first word, `examples/` read as
    /// `built-in/`.
    static func script(of command: String) -> String {
        let value = command.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return TransformFolder.currentSpelling(String(value.split(separator: " ").first ?? ""))
    }

    /// Each `- ` item under the key at `at`, up to the next one.
    static func definitions(under at: Int, in lines: [String]) -> [Range<Int>] {
        let span = body(of: at, in: lines)
        guard let depth = span.first(where: { isContent(lines[$0]) }).map({ indent(lines[$0]) })
        else { return [] }
        let starts = span.filter { indent(lines[$0]) == depth && lines[$0].dropFirst(depth).hasPrefix("-") }
        return starts.indices.map { n in
            starts[n]..<(n + 1 < starts.count ? starts[n + 1] : span.upperBound)
        }
    }

    /// The `key: value` line of an item, at the depth of the item's own keys,
    /// with the value unquoted and its trailing comment apart.
    static func keyValue(_ key: String, in item: Range<Int>, of lines: [String])
        -> (line: Int, value: String, comment: String?)? {
        let first = lines[item.lowerBound]
        let dash = indent(first)
        let depth = dash + 1 + first.dropFirst(dash + 1).prefix { $0 == " " }.count
        let pattern = #/^(?<key>[A-Za-z_]+):(?:\s+(?<value>[^#]*?))?\s*(?<comment>#.*)?$/#
        for i in item {
            let line = i == item.lowerBound
                ? String(first.dropFirst(depth))
                : (indent(lines[i]) == depth ? String(lines[i].dropFirst(depth)) : "")
            guard let match = line.wholeMatch(of: pattern), match.key == key else { continue }
            let value = String(match.value ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return (i, value, match.comment.map(String.init))
        }
        return nil
    }

    // MARK: - 3: `claude:` is `voice:`

    /// `claude:` is `voice:`. Its `folders:` are `agents.claude`, and
    /// `codex: true` is `agents.codex`, holding `codex_folder`. Every other
    /// key moves across as it is. A file with both sections, or with
    /// `folders` or `codex` in a one-line `{…}`, is left for a person.
    static let voiceSection = Step(
        version: 3,
        summary: "claude: is voice:, and its folders and codex keys are voice.agents",
        apply: { lines in
            guard let at = keyLine("claude", depth: 0, in: lines, within: lines.indices),
                  keyLine("voice", depth: 0, in: lines, within: lines.indices) == nil else { return lines }
            let rest = lines[at].dropFirst("claude:".count)
            if rest.contains("{"), rest.contains("folders") || rest.contains("codex") { return lines }
            var out = withAgents(lines, under: at)
            out[at] = "voice:" + rest
            return out
        },
        holds: { !$0.retiredKeys.contains("claude") },
        byHand: "Rename `claude:` to `voice:` by hand, with `folders` and `codex` under"
            + " `voice.agents`, and keep only one of `claude:` and `voice:`"
    )

    /// `folders:` becomes `agents:` with `claude:` under it, in its place.
    /// `codex:` and `codex_folder:` go, with the comments above them.
    static func withAgents(_ lines: [String], under at: Int) -> [String] {
        let span = body(of: at, in: lines)
        guard let depth = childDepth(of: at, in: lines) else { return lines }
        func find(_ key: String) -> Int? { keyLine(key, depth: depth, in: lines, within: span) }
        func rest(_ line: Int, _ key: String) -> Substring { lines[line].dropFirst(depth + key.count + 1) }
        let folders = find("folders"), codex = find("codex"), codexFolder = find("codex_folder")
        var dropped = Set<Int>()
        for line in [codex, codexFolder].compactMap({ $0 }) {
            dropped.formUnion(paragraph(above: line, in: lines)...line)
        }
        let codexOn = codex.map { line in
            let said = rest(line, "codex").prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
            return ["true", "yes", "on", "y"].contains(said.lowercased())
        } ?? false
        let pad = String(repeating: " ", count: depth)
        var agents = [pad + "agents:", pad + "  claude:" + (folders.map { rest($0, "folders") } ?? "")]
        if let folders {
            // Block items may sit at the key's own depth.
            var end = body(of: folders, in: lines).upperBound
            while true {
                guard let item = (end..<span.upperBound).first(where: { isContent(lines[$0]) }),
                      indent(lines[item]) == depth, lines[item].dropFirst(depth).hasPrefix("-") else { break }
                end = body(of: item, in: lines).upperBound
            }
            let value = (folders + 1)..<end
            let shift = depth + 4 - (value.filter { isContent(lines[$0]) }.map { indent(lines[$0]) }.min() ?? 0)
            agents += value.map { i in
                isBlank(lines[i]) ? lines[i]
                    : shift >= 0 ? String(repeating: " ", count: shift) + lines[i]
                    : String(lines[i].dropFirst(min(-shift, indent(lines[i]))))
            }
            dropped.formUnion(folders..<end)
        }
        if codexOn { agents.append(pad + "  codex:" + (codexFolder.map { rest($0, "codex_folder") } ?? "")) }
        let place = folders ?? (codexOn ? dropped.min() : nil)
        var out: [String] = []
        for i in lines.indices {
            if i == place { out += agents }
            if !dropped.contains(i) { out.append(lines[i]) }
        }
        return out
    }

    // MARK: - Diff

    /// A unified diff, `context` lines either side of each change.
    static func diff(_ old: [String], _ new: [String], context: Int = 3) -> [String] {
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var ops: [(tag: Character, line: String, old: Int, new: Int)] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                ops.append(("-", old[i], i, j)); i += 1
            } else if j < new.count, inserted.contains(j) {
                ops.append(("+", new[j], i, j)); j += 1
            } else {
                ops.append((" ", old[i], i, j)); i += 1; j += 1
            }
        }
        let changed = ops.indices.filter { ops[$0].tag != " " }
        guard !changed.isEmpty else { return [] }
        var hunks: [ClosedRange<Int>] = []
        for k in changed {
            let span = max(0, k - context)...min(ops.count - 1, k + context)
            if let last = hunks.last, span.lowerBound <= last.upperBound + 1 {
                hunks[hunks.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                hunks.append(span)
            }
        }
        var out: [String] = []
        for hunk in hunks {
            let slice = ops[hunk]
            let oldCount = slice.filter { $0.tag != "+" }.count
            let newCount = slice.filter { $0.tag != "-" }.count
            let first = slice.first!
            out.append("@@ -\(first.old + 1),\(oldCount) +\(first.new + 1),\(newCount) @@")
            out += slice.map { "\($0.tag)\($0.line)" }
        }
        return out
    }
}
