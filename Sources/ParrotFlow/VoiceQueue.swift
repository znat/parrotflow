import Foundation

/// The coding agents' answers: the one playing, the ones waiting, and the last
/// ones heard. One list for every session, oldest first. Progress lines never
/// enter it.
struct VoiceQueue {

    /// Why the voice is held. It plays only when there is none.
    enum Hold: String {
        /// The Pause button.
        case user
        /// From hotkey down to the end of the dictation.
        case dictation
    }

    struct Entry: Equatable {
        let id: Int
        let session: String
        let text: String
        /// Split as `Speaker.say` splits, so a sentence index means the same in both.
        let sentences: [String]
        let style: Speaker.Style?
        let localVoice: String?
        let added: Date
        /// The sentence to start from: the one that was playing when it was held.
        fileprivate(set) var resume = 0

        var remaining: [String] { Array(sentences[resume...]) }
    }

    private(set) var playing: Entry?
    /// Next first: an answer held while playing goes back to the front.
    private(set) var waiting: [Entry] = []
    /// Newest first.
    private(set) var heard: [Entry] = []
    private(set) var holds: Set<Hold> = []
    static let heardLimit = 10

    private var lastID = 0
    /// Answers finished since the list started playing, for "2 of 3".
    private var played = 0

    /// The playing answer's place in the run, and the run's length so far.
    var place: (position: Int, count: Int)? {
        playing.map { _ in (played + 1, played + 1 + waiting.count) }
    }

    /// Nil, and nothing queued, when the text has nothing to say.
    @discardableResult
    mutating func add(
        session: String, text: String, style: Speaker.Style? = nil, localVoice: String? = nil, at now: Date = Date()
    ) -> Int? {
        let sentences = ClaudeSpeakable.sentences(ClaudeSpeakable.speakable(text))
        guard !sentences.isEmpty else { return nil }
        lastID += 1
        waiting.append(Entry(id: lastID, session: session, text: text, sentences: sentences, style: style,
                             localVoice: localVoice, added: now))
        return lastID
    }

    /// The answer to say now: nil while held, while one plays, or when none waits.
    mutating func startNext() -> Entry? {
        guard holds.isEmpty, playing == nil, !waiting.isEmpty else { return nil }
        playing = waiting.removeFirst()
        return playing
    }

    /// Progress lines are said only when no answer plays and nothing holds the voice.
    var takesProgress: Bool { holds.isEmpty && playing == nil }

    /// `stoppedAt`: the sentence that was playing, counted in `remaining`, as Speaker
    /// counts the line it was given. Nil when no sound had started.
    mutating func hold(_ cause: Hold, stoppedAt sentence: Int? = nil) {
        holds.insert(cause)
        played = 0
        guard var entry = playing else { return }
        if let sentence { entry.resume = min(entry.resume + max(sentence, 0), entry.sentences.count - 1) }
        waiting.insert(entry, at: 0)
        playing = nil
    }

    mutating func release(_ cause: Hold) {
        holds.remove(cause)
    }

    /// Ignored unless `id` is the one playing: a late callback for a held answer.
    mutating func finish(_ id: Int) {
        guard var entry = playing, entry.id == id else { return }
        entry.resume = 0
        heard.insert(entry, at: 0)
        if heard.count > Self.heardLimit { heard.removeLast(heard.count - Self.heardLimit) }
        playing = nil
        played = waiting.isEmpty ? 0 : played + 1
    }

    /// A new prompt in `session`: its answers, waiting or playing, are stale. Returns how many.
    @discardableResult
    mutating func drop(session: String) -> Int {
        let before = waiting.count
        waiting.removeAll { $0.session == session }
        var dropped = before - waiting.count
        if playing?.session == session {
            playing = nil
            dropped += 1
        }
        if playing == nil, waiting.isEmpty { played = 0 }
        return dropped
    }
}
