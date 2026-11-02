import Foundation

/// The terms that share a sound.
///
/// `Mik` and `Mick` are two people and the decoder writes "Mick" for both.
/// One place over that word carries every member as a reading, and the clause
/// decider picks one, offers several, or keeps what was heard — see
/// `ClauseSession.readGroup`.
///
/// A group is derived, never declared. No field says one exists — see
/// `groups(terms:uses:)` for the three links. A group of one is every term
/// that shares its sound with nothing, which is almost all of them. See
/// `docs/proposals/sound-groups.md`.
enum SoundGroup {

    /// How many named members one place may offer.
    ///
    /// Four, and the pill shows them plus "as heard". The old ceiling of two
    /// readings a place was a property of the shape — one span, one
    /// alternative — and a group place is the one thing that breaks it.
    static let ceiling = 4

    /// The readings one group place offers: what was heard, then the members.
    ///
    /// The heard word is a member's own spelling as often as not, and then it
    /// is one of the names the cap counts. Counting only the rest, a group of
    /// five put five names on the pill.
    static func offered(_ heard: String, of members: [String]) -> [String] {
        let rest = members.filter { $0.caseInsensitiveCompare(heard) != .orderedSame }
        let room = rest.count == members.count ? ceiling : ceiling - 1
        return [heard] + rest.prefix(room)
    }

    /// A set of terms that share a sound.
    struct Group: Equatable {
        /// The terms, sorted, so a group reads the same way twice.
        let members: [String]
        /// Every word that opens it: each member's spelling and each member's
        /// `heard:` renderings, lowercased.
        let openings: Set<String>
        /// The renderings each member wrote down, as they are spelled.
        let renderings: [String: [String]]

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
            var written: [String: [String]] = [:]
            for member in members {
                openings.insert(member.lowercased())
                written[member] = terms[member]?.heard ?? []
                for rendering in written[member] ?? [] {
                    openings.insert(rendering.lowercased())
                }
            }
            return Group(members: members, openings: openings, renderings: written)
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
    ///
    /// Counted per owning term, not per entry. `Versal` and `versal` under one
    /// term are two renderings of it, and counting entries made that term's own
    /// rendering look shared: it stopped being a rule and opened no group,
    /// because the group is a singleton.
    static func openings(in terms: [String: Config.Vocabulary.Term]) -> Set<String> {
        var owners: [String: Set<String>] = [:]
        var spellings = Set<String>()
        for name in terms.keys { spellings.insert(name.lowercased()) }
        for (name, entry) in terms {
            for rendering in entry.heard {
                let word = rendering.lowercased()
                // Its own spelling is not a link. `vercel` -> `Vercel` is a
                // capital being fixed, and every term may render itself.
                guard word != name.lowercased() else { continue }
                owners[word, default: []].insert(name.lowercased())
            }
        }
        var out = Set<String>()
        for (word, claimants) in owners where claimants.count > 1 || spellings.contains(word) {
            out.insert(word)
        }
        return out
    }

    /// The members of `term`'s group that stand in this sentence, as words.
    ///
    /// Each word is charged to one member: the term that spells it that way
    /// when there is one, and otherwise the term that wrote the rendering
    /// down. Without that, "Mick is adjusting the piano." would name both Mick
    /// and Mik — `Mick` is one's spelling and the other's rendering — and
    /// every correction of it would be refused.
    ///
    /// Two members standing in one sentence is a sentence that belongs to
    /// neither. See `CorrectionRecording`.
    static func standing(in sentence: String, of term: String, in groups: [Group]) -> [String] {
        guard let group = groups.first(where: {
            $0.members.contains { $0.caseInsensitiveCompare(term) == .orderedSame }
        }) else { return [] }
        var owner: [String: String] = [:]
        func stands(_ word: String) -> Bool {
            !places(of: word, in: sentence).isEmpty
        }
        for member in group.members where stands(member) {
            owner[member.lowercased()] = member
        }
        for member in group.members {
            for rendering in group.renderings[member] ?? []
            where owner[rendering.lowercased()] == nil && stands(rendering) {
                owner[rendering.lowercased()] = member
            }
        }
        return Array(Set(owner.values)).sorted()
    }

    /// Every whole-word occurrence of `needle`, matched without case.
    ///
    /// Without case because a member opening a sentence is capitalised there
    /// and not in the row that recorded it.
    static func places(of needle: String, in text: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        func letter(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while let found = text.range(
            of: needle, options: [.caseInsensitive], range: from ..< text.endIndex
        ) {
            let before = found.lowerBound == text.startIndex
                || !letter(text[text.index(before: found.lowerBound)])
            let after = found.upperBound == text.endIndex || !letter(text[found.upperBound])
            if before && after { out.append(found) }
            guard found.lowerBound < text.endIndex else { break }
            from = text.index(after: found.lowerBound)
        }
        return out
    }
}
