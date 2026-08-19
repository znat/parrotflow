import Foundation

/// What kind of thing a vocabulary term names.
///
/// Recorded on the term as `kind:` when the correction panel writes it, so a
/// later stage can ask the question without tagging the sentence again. Nothing
/// mechanical reads it yet — it is here so the stages that will need it have
/// something to read, the way `seen` and `from` were added to a pronunciation
/// before anything counted them.
///
/// The proposal comes from `NLTagger`'s `.nameTypeOrLexicalClass`, which is
/// right about people and wrong about products often enough that this has to be
/// editable in the panel: measured on `tests/judge-cases.yaml`, it calls
/// `Tasmin` a PersonalName and is right, and calls both `Vercel` and `Olama`
/// PlaceName, which they are not.
enum WordKind: String, Codable, Equatable, CaseIterable {
    case person
    case place
    case organization
    case word

    /// Everything that is not one of the three name tags is `word`. The tag
    /// vocabulary is much larger than this — Verb, Determiner, Number — and
    /// none of the rest tells a later stage anything it could act on.
    static func from(tag: String?) -> WordKind {
        switch tag {
        case "PersonalName": return .person
        case "PlaceName": return .place
        case "OrganizationName": return .organization
        default: return .word
        }
    }

    /// Short enough for a column that sits beside two text fields.
    var label: String {
        switch self {
        case .person: return "Person"
        case .place: return "Place"
        case .organization: return "Org"
        case .word: return "Word"
        }
    }
}
