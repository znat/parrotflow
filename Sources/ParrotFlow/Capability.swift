import Foundation

/// Everything "hey parrot" can reach, in one list.
///
/// Two kinds, because not everything worth saying is a text rewrite. A
/// **transform** is text in, text out, and comes from `prompts:` in the config.
/// An **action** runs Swift — fixing a spelling opens a panel and writes a YAML
/// rule, which no prompt can express.
///
/// Keeping both in one catalogue is the point: the router sees a flat list of
/// names and descriptions and does not care which kind it picked, while the
/// config stays honest by only ever holding transforms.
enum Capability: Equatable {
    case action(Action)
    case transform(Config.Prompt)

    /// The built-ins. Registered here rather than in the config so they cannot
    /// be deleted by editing a file, and so they keep working when `prompts:`
    /// is empty — which it is by default.
    enum Action: String, CaseIterable {
        /// "Tasmin spells T A S M E E N" — extract the rule and propose it.
        case spelling
        /// Open the correction panel on the current selection.
        case vocabulary

        var describedAs: String {
            switch self {
            case .spelling:
                return "fix a name or word the speaker just spelled out letter by letter"
            case .vocabulary:
                return "open the correction panel to fix the selected text by hand"
            }
        }
    }

    var name: String {
        switch self {
        case .action(let action): return action.rawValue
        case .transform(let prompt): return prompt.name
        }
    }

    var describedAs: String {
        switch self {
        case .action(let action): return action.describedAs
        case .transform(let prompt): return prompt.description
        }
    }

    var isTransform: Bool {
        if case .transform = self { return true }
        return false
    }
}

/// The catalogue handed to the router, assembled at config load.
struct Catalogue {
    let capabilities: [Capability]

    /// Built-ins first, then the config's prompts.
    ///
    /// A prompt naming a built-in is dropped rather than allowed to shadow it.
    /// Shadowing `spelling` would silently disable the one command that has a
    /// validation set behind it, and the failure would look like the router
    /// misbehaving rather than like a name collision.
    init(prompts: [Config.Prompt]) {
        var seen = Set(Capability.Action.allCases.map { $0.rawValue.lowercased() })
        var list: [Capability] = Capability.Action.allCases.map { .action($0) }

        for prompt in prompts {
            let key = prompt.name.lowercased()
            guard !seen.contains(key) else {
                Log.write("prompts: \"\(prompt.name)\" collides with an existing name; skipped")
                continue
            }
            seen.insert(key)
            list.append(.transform(prompt))
        }
        capabilities = list
    }

    func capability(named name: String) -> Capability? {
        let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return capabilities.first { $0.name.lowercased() == key }
    }

    /// What the router reads. One line each, name first, so the model's answer
    /// is a token it has just seen rather than something it composes.
    var listing: String {
        capabilities
            .map { "\($0.name): \($0.describedAs)" }
            .joined(separator: "\n")
    }

    var names: [String] { capabilities.map { $0.name } }
}
