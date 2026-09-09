import Foundation

/// The terms that share a sound, and how a place between them is decided.
///
/// `Mik` and `Mick` are two people and the decoder writes "Mick" for both.
/// Under the old model one of them owned the sound: `heard: Mick` was a rule
/// that rewrote every "Mick" to "Mik", and the only thing that could undo it
/// was Mik's portrait, where Mick lived as a counter-example. Mick had no
/// portrait at all.
///
/// A group is derived, never declared. No field says one exists — see
/// `groups(terms:uses:)` for the three links. Every member keeps its own
/// portrait, and one more member has no name: **plain**, the ordinary word
/// that sounds like this. Plain's portrait is the counter rows of the group's
/// members, pooled.
///
/// A group of one is every term that shares its sound with nothing, which is
/// almost all of them. Those go the way they always have — the caller reads
/// one portrait, not a group. See `docs/proposals/sound-groups.md`.
enum SoundGroup {

    /// How many named members one place may offer.
    ///
    /// Four, and the pill shows them plus "as heard". The old ceiling of two
    /// readings a place was a property of the shape — one span, one
    /// alternative — and a group place is the one thing that breaks it.
    static let ceiling = 4

    /// A set of terms that share a sound.
    struct Group: Equatable {
        /// The terms, sorted, so a group reads the same way twice.
        let members: [String]
        /// Every word that opens it: each member's spelling and each member's
        /// `heard:` renderings, lowercased.
        let openings: Set<String>

        var isGroup: Bool { members.count > 1 }
    }

    // MARK: - Deriving

    /// Every group in a vocabulary, one per term, singletons included.
    ///
    /// Three links, and any of them puts two terms together:
    ///
    /// - one term's spelling is a `heard:` rendering of the other;
    /// - the two share a `heard:` rendering;
    /// - a counter row under one term has a span that is the other's spelling.
    ///
    /// They are transitive: linking Mik to Mick and Mick to Mic puts all three
    /// in one group. Case never decides — a rendering is written the way the
    /// decoder wrote it, and a spelling the way its owner spells it.
    static func groups(
        terms: [String: Config.Vocabulary.Term], uses: [String: [TermUses.Use]] = [:]
    ) -> [Group] {
        let names = terms.keys.sorted()
        guard !names.isEmpty else { return [] }
        var at: [String: Int] = [:]
        for (index, name) in names.enumerated() { at[name.lowercased()] = index }

        var parent = Array(names.indices)
        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var walk = index
            while parent[walk] != walk { let next = parent[walk]; parent[walk] = root; walk = next }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let (x, y) = (find(a), find(b))
            if x != y { parent[max(x, y)] = min(x, y) }
        }

        var sharing: [String: [Int]] = [:]
        for (index, name) in names.enumerated() {
            for rendering in terms[name]?.heard ?? [] {
                let word = rendering.lowercased()
                // A rendering that is another term's spelling.
                if let other = at[word], other != index { union(index, other) }
                sharing[word, default: []].append(index)
            }
            // A counter row's span is the ordinary word that stood there. When
            // that word is another term, the two are the same sound.
            for row in uses[name] ?? [] where row.counter {
                if let other = at[row.span.lowercased()], other != index { union(index, other) }
            }
        }
        // A rendering two terms both claim.
        for (_, claimants) in sharing where claimants.count > 1 {
            for index in claimants.dropFirst() { union(claimants[0], index) }
        }

        var bundled: [Int: [Int]] = [:]
        for index in names.indices { bundled[find(index), default: []].append(index) }
        return bundled.keys.sorted().map { root in
            let members = (bundled[root] ?? []).map { names[$0] }.sorted()
            var openings = Set<String>()
            for member in members {
                openings.insert(member.lowercased())
                for rendering in terms[member]?.heard ?? [] {
                    openings.insert(rendering.lowercased())
                }
            }
            return Group(members: members, openings: openings)
        }
    }

    /// The group a heard word opens, or nil when no group of two or more does.
    ///
    /// A word opens a group when it is a member's spelling or a member's
    /// `heard:` rendering. A counter span does not open one: it links two
    /// terms, and what it stands for is plain.
    static func opened(by word: String, in groups: [Group]) -> Group? {
        let needle = word.lowercased()
        return groups.first { $0.isGroup && $0.openings.contains(needle) }
    }

    /// Every rendering that must not become a substitution rule.
    ///
    /// Two kinds, and both open a group instead of rewriting: a rendering that
    /// is another term's spelling, and a rendering two terms share. A rule
    /// there would write one member's name over the other's sound before
    /// anything could read the sentence.
    static func openings(in terms: [String: Config.Vocabulary.Term]) -> Set<String> {
        var seen: [String: Int] = [:]
        var spellings = Set<String>()
        for name in terms.keys { spellings.insert(name.lowercased()) }
        for (name, entry) in terms {
            for rendering in entry.heard {
                let word = rendering.lowercased()
                // Its own spelling is not a link. `vercel` -> `Vercel` is a
                // capital being fixed, and every term may render itself.
                guard word != name.lowercased() else { continue }
                seen[word, default: 0] += 1
            }
        }
        var out = Set<String>()
        for (word, count) in seen where count > 1 || spellings.contains(word) {
            out.insert(word)
        }
        return out
    }

    // MARK: - Deciding

    /// One candidate at a place: what it scored, and the floor it has to clear.
    ///
    /// Plain has no floor. Its portrait is pooled counter rows, and a floor is
    /// read off a term's own uses.
    struct Candidate: Equatable {
        let name: String
        let score: Double
        let floor: Double?

        /// Below its own floor is out. A candidate with fewer than
        /// `TermPortrait.floorMinimum` uses has no floor and is never out on
        /// that ground.
        var stands: Bool { floor.map { score > $0 } ?? true }
    }

    /// What the group says about a place.
    enum Verdict: Equatable {
        /// Write this member's spelling.
        case write(String)
        /// Keep what was heard: plain won, or nobody stood.
        case keep
        /// Two or more stand and none of them leads. The pill asks, and these
        /// are the members to offer, best first.
        case open([String])
    }

    /// The nearest centre, with floors.
    ///
    /// 1. A candidate below its own floor is out.
    /// 2. Among those standing, the best wins if it leads the second by more
    ///    than `band`.
    /// 3. A named member winning writes its spelling; plain winning keeps what
    ///    was heard.
    /// 4. Nobody standing keeps what was heard.
    /// 5. Two standing and no lead opens the place.
    ///
    /// The heard spelling gets no bonus. Which homophone the recogniser
    /// reached for is frequency, not evidence.
    static func decide(
        _ members: [Candidate], plain: Double?, band: Double = 0.01
    ) -> Verdict {
        var standing = members.filter(\.stands)
        // Plain is a member with no name and no floor.
        if let plain { standing.append(Candidate(name: "", score: plain, floor: nil)) }
        let ranked = standing.sorted { $0.score > $1.score }
        guard let best = ranked.first else { return .keep }
        if ranked.count > 1, best.score - ranked[1].score <= band {
            return .open(ranked.filter { !$0.name.isEmpty }.map(\.name))
        }
        return best.name.isEmpty ? .keep : .write(best.name)
    }
}
