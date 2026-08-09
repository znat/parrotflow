import Foundation

/// What the vocabulary pass would write where a decoded word stood.
///
///     ParrotFlow --inflected Matthieu "Mathieu's"     # -> Matthieu's
///
/// `Vocabulary.inflected` is a pure function with no model, no audio and no
/// config behind it, and it decides whether a possessive survives a
/// substitution. It had no set until it was found dropping one. This is the
/// entry point `scripts/check-possessive.sh` scores, so the set runs against
/// the shipped function rather than against a copy of it — the compromise
/// `scripts/real-words.swift` had to make and this does not.
enum InflectedCommand {
    static func run(term: String, heard: String) -> Int32 {
        print(Vocabulary.inflected(term, like: heard))
        return 0
    }
}
