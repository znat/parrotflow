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
        /// Another app is using the mic: `CallState`.
        case call
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
        /// Asked for from the menu: it plays through a pause or a call, not through a dictation.
        fileprivate(set) var asked = false
        /// Each sentence's samples, kept for a replay. Nil when not made in one go.
        fileprivate(set) var audio: [[Float]]?

        var remaining: [String] { Array(sentences[resume...]) }
    }

    private(set) var playing: Entry?
    /// Next first: an answer held while playing goes back to the front.
    private(set) var waiting: [Entry] = []
    /// Newest first.
    private(set) var heard: [Entry] = []
    private(set) var holds: Set<Hold> = []
    static let heardLimit = 10
    /// Samples of `heard` audio kept in all: about 30 MB of Float. Past it, the oldest lose theirs.
    var audioLimit = 7_500_000

    private var lastID = 0
    /// Answers finished since the list started playing, for "2 of 3".
    private var played = 0
    /// The run playing now began when a hold let go of a list.
    private(set) var resumed = false

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
        guard playing == nil, let next = waiting.first,
              holds.isEmpty || next.asked && holds.isSubset(of: [.user, .call]) else { return nil }
        playing = waiting.removeFirst()
        return playing
    }

    func entry(_ id: Int) -> Entry? {
        ([playing].compactMap { $0 } + waiting + heard).first { $0.id == id }
    }

    /// `id` goes first and is asked: a heard answer again from its start, or a waiting one now.
    /// The one playing goes back in front of the rest, at `stoppedAt`. False when `id` is gone.
    @discardableResult
    mutating func ask(_ id: Int, stoppedAt sentence: Int? = nil) -> Bool {
        guard entry(id) != nil else { return false }
        putBack(stoppedAt: sentence)
        guard var asked = waiting.first(where: { $0.id == id }) ?? heard.first(where: { $0.id == id }) else {
            return false
        }
        waiting.removeAll { $0.id == id }
        asked.asked = true
        waiting.insert(asked, at: 0)
        return true
    }

    /// Progress lines are said only when no answer plays and nothing holds the voice.
    var takesProgress: Bool { holds.isEmpty && playing == nil }

    /// `stoppedAt`: the sentence that was playing, counted in `remaining`, as Speaker
    /// counts the line it was given. Nil when no sound had started.
    /// A pause or a call takes back every ask: those answers wait like the others.
    mutating func hold(_ cause: Hold, stoppedAt sentence: Int? = nil) {
        holds.insert(cause)
        putBack(stoppedAt: sentence)
        if cause != .dictation { waiting.indices.forEach { waiting[$0].asked = false } }
    }

    private mutating func putBack(stoppedAt sentence: Int?) {
        played = 0
        resumed = false
        guard var entry = playing else { return }
        if let sentence { entry.resume = min(entry.resume + max(sentence, 0), entry.sentences.count - 1) }
        waiting.insert(entry, at: 0)
        playing = nil
    }

    mutating func release(_ cause: Hold) {
        holds.remove(cause)
        if !waiting.isEmpty { resumed = true }
    }

    /// Ignored unless `id` is the one playing: a late callback for a held answer. `audio`: every
    /// sentence, made in this one go. An answer heard before keeps its place in `heard`.
    mutating func finish(_ id: Int, audio: [[Float]]? = nil) {
        guard var entry = playing, entry.id == id else { return }
        entry.resume = 0
        entry.asked = false
        if let index = heard.firstIndex(where: { $0.id == id }) {
            heard[index].audio = heard[index].audio ?? audio
        } else {
            entry.audio = entry.audio ?? audio
            heard.insert(entry, at: 0)
            if heard.count > Self.heardLimit { heard.removeLast(heard.count - Self.heardLimit) }
        }
        var kept = 0
        for index in heard.indices {
            let size = heard[index].audio?.reduce(0) { $0 + $1.count } ?? 0
            if kept + size > audioLimit { heard[index].audio = nil } else { kept += size }
        }
        playing = nil
        played = waiting.isEmpty ? 0 : played + 1
        if waiting.isEmpty { resumed = false }
    }

    /// The one playing is heard, as if it had ended.
    mutating func skip(audio: [[Float]]? = nil) {
        if let id = playing?.id { finish(id, audio: audio) }
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
        if playing == nil, waiting.isEmpty {
            played = 0
            resumed = false
        }
        return dropped
    }
}

/// What a call did to the voice.
enum VoiceCall: Equatable {
    /// The app holds the voice: the `.call` hold.
    case on(String)
    /// It ended with answers waiting. The voice stays paused, `.user`, until resumed.
    case over
    /// Not now: still paused, and no pill.
    case dismissed
}

/// What the pill says about the voice.
enum VoicePill: Equatable {
    /// `status` is "2 waiting", "1 of 3" or nil.
    case speaking(name: String, status: String?, goToSession: Bool)
    case paused(waiting: Int)
    case call(app: String)
    case callOver(waiting: Int)

    /// A dictation hold alone shows nothing: the recording pill has the screen.
    /// `name` is the playing session's; nil shows nothing. A call shows only while answers wait.
    /// An answer asked for from the menu shows as speaking, even through a pause.
    static func of(_ queue: VoiceQueue, name: String?, goToSession: Bool, call: VoiceCall? = nil) -> VoicePill? {
        if queue.playing?.asked == true, let name {
            return .speaking(name: name, status: nil, goToSession: goToSession)
        }
        if queue.holds.contains(.user) {
            switch call {
            case .over? where queue.waiting.isEmpty: return nil
            case .over?: return .callOver(waiting: queue.waiting.count)
            case .dismissed?: return nil
            case .on?, nil: return .paused(waiting: queue.waiting.count)
            }
        }
        if queue.holds.contains(.call) {
            guard case .on(let app)? = call, !queue.waiting.isEmpty else { return nil }
            return .call(app: app)
        }
        guard queue.holds.isEmpty, queue.playing != nil, let name else { return nil }
        let status: String?
        if queue.resumed, let place = queue.place, place.count > 1 {
            status = "\(place.position) of \(place.count)"
        } else {
            status = waiting(queue.waiting.count)
        }
        return .speaking(name: name, status: status, goToSession: goToSession)
    }

    /// None when nothing waits.
    static func waiting(_ count: Int) -> String? { count > 0 ? "\(count) waiting" : nil }

    /// For the log and the test cases: "speaking a · 2 waiting · go to session", "paused · 3 waiting".
    var summary: String {
        switch self {
        case .speaking(let name, let status, let goTo):
            return (["speaking " + name, status] + [goTo ? "go to session" : nil]).compactMap { $0 }.joined(separator: " · ")
        case .paused(let waiting):
            return "paused · \(waiting) waiting"
        case .call(let app):
            return "paused · \(app) is using the mic"
        case .callOver(let waiting):
            return "call over · \(waiting) waiting"
        }
    }
}
