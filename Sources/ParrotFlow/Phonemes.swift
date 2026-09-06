import Foundation

/// How a word sounds, as IPA, so a name can be recognised by ear rather than
/// by spelling.
///
/// The decoder writes what it thought it heard. `Gelar` comes back as `geler`,
/// `Ghostty` as `Ghost E`, `Claude Code` as `cloth code`. None of those is
/// near its term by letters — `geler`/`Gelar` is 0.60 — and all three are the
/// same sound: /dʒɛlɚ/, /ɡoʊsti/, /klɑθkoʊd/. Comparing sounds instead of
/// spellings is what reaches them.
///
/// Measured on 184 hand-labelled manglings, sound against letters, as the
/// share of terms a proposer reaches at each floor:
///
///     floor   letters   sound
///     0.50      84%      91%
///     0.70      50%      66%
///     0.75      40%      65%
///     0.85      19%      36%
///
/// Sound wins at every floor. It is still only a proposer: `praise` and
/// `Praisy` score 0.76, so the homophone stays for the sentence to settle.
/// See `VocabularyJudge.phonemeParts` for the floor and what it costs.
///
/// **espeak-ng runs as a separate process, and that is deliberate.** It is
/// GPL-3. A separate program invoked over stdin and stdout is not part of this
/// program; linking it in would be. Nothing here loads its code, and the only
/// thing that crosses the boundary is text.
///
/// Absent espeak-ng, every question returns nil and the stage that asks does
/// nothing. It is not bundled yet, so on most machines that is what happens.
enum Phonemes {

    /// Stress and length. espeak marks them; they are prosody, not identity,
    /// and keeping them made every score depend on which syllable espeak
    /// guessed was stressed.
    static let marks: Set<Character> = ["ˈ", "ˌ", "ː", "ˑ"]

    /// Where espeak-ng is, if it is anywhere.
    ///
    /// Resolved once when it is there. When it is not, the search runs again:
    /// it can be installed while the app is running, and the setup screen
    /// offers to do exactly that. Four `isExecutableFile` calls, and only on a
    /// machine that does not have it.
    static var binary: String? { firstLook ?? locate() }

    private static let firstLook: String? = locate()

    /// `PARROTFLOW_ESPEAK` first, so a test can point at a stub, then the
    /// two places Homebrew puts it, then the system path.
    static func locate() -> String? {
        var places: [String] = []
        if let named = ProcessInfo.processInfo.environment["PARROTFLOW_ESPEAK"] {
            places.append(named)
        }
        places += ["/opt/homebrew/bin/espeak-ng", "/usr/local/bin/espeak-ng",
                   "/usr/bin/espeak-ng"]
        return places.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Asking espeak

    private static var cache: [String: String] = [:]
    private static let cacheLock = NSLock()

    /// The IPA of every word given, in one call. Absent from the result means
    /// espeak had nothing to say about it.
    ///
    /// Batched because the process costs more to start than to run: 1 word and
    /// 500 words differ by a few milliseconds. A dictation asks once.
    ///
    /// - Parameter voice: an espeak voice, `en-us` for English.
    static func of(_ words: [String], voice: String) -> [String: String] {
        guard let binary else { return [:] }
        var answer: [String: String] = [:]
        var ask: [String] = []
        cacheLock.lock()
        for word in words {
            let clean = cleaned(word)
            guard !clean.isEmpty else { continue }
            if let known = cache["\(voice)\u{0}\(clean)"] {
                answer[word] = known
            } else {
                ask.append(clean)
            }
        }
        cacheLock.unlock()

        let wanted = Array(Set(ask)).sorted()
        if !wanted.isEmpty, let said = run(binary, wanted, voice: voice) {
            cacheLock.lock()
            for (word, ipa) in zip(wanted, said) {
                cache["\(voice)\u{0}\(word)"] = ipa
            }
            cacheLock.unlock()
            let map = Dictionary(uniqueKeysWithValues: zip(wanted, said))
            for word in words where answer[word] == nil {
                if let ipa = map[cleaned(word)] { answer[word] = ipa }
            }
        }
        return answer
    }

    /// One IPA line per word, or nil if the call failed or came back the wrong
    /// shape.
    ///
    /// **The line count is checked, and that is not defensive coding.**
    /// `espeak-ng -q --ipa` does not emit one line per input line: it splits
    /// on punctuation, so a full stop in the input silently shifts every line
    /// after it. Zipping the two lists without checking scored every word
    /// against some other word's sound, and the first measurement built that
    /// way reported the opposite of the truth. `cleaned` removes what splits,
    /// and this refuses the answer if anything else does.
    private static func run(
        _ binary: String, _ words: [String], voice: String
    ) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-q", "--ipa", "-v", voice]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            Log.write("phonemes: \(binary) would not start — \(error.localizedDescription)")
            return nil
        }
        // Read while writing. espeak's output pipe fills at about 64 KB and
        // then it blocks, so writing everything first deadlocks on a long list.
        var collected = Data()
        let reader = DispatchQueue(label: "phonemes.read")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            collected = output.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        input.fileHandleForWriting.write(Data(words.joined(separator: "\n").utf8))
        try? input.fileHandleForWriting.close()
        done.wait()
        process.waitUntilExit()
        _ = try? errors.fileHandleForReading.readToEnd()

        guard process.terminationStatus == 0 else {
            Log.write("phonemes: espeak-ng exited \(process.terminationStatus)")
            return nil
        }
        let lines = String(decoding: collected, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count == words.count else {
            Log.write("phonemes: espeak-ng answered \(lines.count) line(s)"
                + " for \(words.count) word(s); dropped")
            return nil
        }
        return lines.map(clip)
    }

    /// One espeak line reduced to the sound in it.
    ///
    /// Stress, length and whitespace go — see `marks`. So does a language
    /// switch: espeak writes `(en)ɹˈɛdkɹɔːl(fr)` when it decides a word in a
    /// French sentence is English, and those four characters are a note about
    /// the pronunciation rather than part of it. Left in, `Redcrawl` and
    /// `red rock` compare with two markers between them.
    ///
    /// English never sees one — 0 of the 7041 distinct words in this speaker's
    /// archive — so the floor measured without this still holds. It matters
    /// the day the stage runs on a French sentence.
    static func clip(_ line: String) -> String {
        var out = "", depth = 0
        for character in line {
            if character == "(" { depth += 1; continue }
            if character == ")" { depth = max(0, depth - 1); continue }
            guard depth == 0, !marks.contains(character), !character.isWhitespace
            else { continue }
            out.append(character)
        }
        return out
    }

    /// A word espeak can be asked about: letters, apostrophes and single
    /// spaces. Everything else splits its output — see `run`.
    static func cleaned(_ word: String) -> String {
        let kept = word.map { character -> Character in
            character.isLetter || character == "'" || character == "\u{2019}"
                ? character : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    // MARK: - Comparing

    /// How close two sounds are, on the metric the spellings are compared with.
    ///
    /// Normalised Levenshtein over IPA symbols, times the square root of the
    /// length ratio — `Vocabulary.gluedSimilarity`, with sounds in place of
    /// letters. The same metric on purpose: the floors either side of the
    /// judge are read against each other, and two numbers that mean different
    /// things cannot be.
    ///
    /// Checked against the Python that measured the tables above:
    /// `Olama`/`Ollama` 1.00, `praise`/`Praisy` 0.76.
    static func similarity(_ a: String, _ b: String) -> Float {
        let left = Array(a), right = Array(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }

        var previous = Array(0...right.count)
        for i in 1...left.count {
            var current = [i]
            for j in 1...right.count {
                current.append(min(
                    current[j - 1] + 1, previous[j] + 1,
                    previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)
                ))
            }
            previous = current
        }
        let base = 1 - Float(previous[right.count]) / Float(max(left.count, right.count))
        let ratio = Float(min(left.count, right.count)) / Float(max(left.count, right.count))
        return base * sqrt(ratio)
    }
}
