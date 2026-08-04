import Foundation

/// Everything "hey parrot" can reach, in one list.
///
/// Two kinds, because not everything worth saying is a text rewrite. A
/// **transform** is text in, text out, and comes from `transforms:` in the
/// config. An **action** runs Swift — fixing a spelling opens a panel and
/// writes a YAML rule, which no prompt can express.
///
/// Keeping both in one catalogue is the point: the router sees a flat list of
/// names and descriptions and does not care which kind it picked, while the
/// config stays honest by only ever holding transforms.
///
/// It carries a `Transform` and not a `Prompt`, which it did until a transform
/// stopped always being a prompt. `asPrompt` returns nil for a `command:` body,
/// so building this from `config.prompts` quietly dropped every script from the
/// list the router chooses between — and a router given nine of your ten tools
/// does not fail, it picks the nearest of the nine. Measured: "use slack
/// handles" reached `slack`, the chat-tidying prompt, and tidied a sentence
/// instead of turning a name into a handle. Nothing said so, because from the
/// outside that is what a wrong route and a right route both look like.
enum Capability: Equatable {
    case action(Action)
    case transform(Config.Transform)

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
        case .transform(let transform): return transform.name
        }
    }

    var describedAs: String {
        switch self {
        case .action(let action): return action.describedAs
        case .transform(let transform): return transform.description
        }
    }

    /// Which of the three bodies it is, for anything printing the catalogue.
    /// The router never sees this: what a tool is made of is not a reason to
    /// pick it, and putting it in the listing would be one more thing for the
    /// model to weigh.
    var kind: String {
        switch self {
        case .action: return "built-in"
        case .transform(let transform):
            switch transform.body {
            case .prompt: return "prompt "
            case .replace: return "table  "
            case .command: return "program"
            }
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

    /// Built-ins first, then everything in `transforms:`.
    ///
    /// **All three bodies.** A `prompt:` costs a model call, a `command:` a
    /// process start and a `replace:` nothing at all, and none of that is a
    /// reason you cannot ask for one out loud. What decides whether something
    /// belongs here is whether it has a `description` worth matching spoken
    /// words against — which is the same question for all three.
    ///
    /// The cost is a longer list for the router to choose between, and a longer
    /// list is measurably harder to choose from. That is the trade: a tool that
    /// is not in the list is not merely unreachable, it makes its neighbours
    /// wrong, because the router answers with the nearest thing it was shown
    /// rather than admitting the right one is missing.
    ///
    /// A transform naming a built-in is dropped rather than allowed to shadow
    /// it. Shadowing `spelling` would silently disable the one command that has
    /// a validation set behind it, and the failure would look like the router
    /// misbehaving rather than like a name collision.
    init(transforms: [Config.Transform]) {
        var seen = Set(Capability.Action.allCases.map { $0.rawValue.lowercased() })
        var list: [Capability] = Capability.Action.allCases.map { .action($0) }

        for transform in transforms {
            let key = transform.name.lowercased()
            guard !seen.contains(key) else {
                Log.write("transforms: \"\(transform.name)\" collides with an existing name; skipped")
                continue
            }
            // Nothing to match spoken words against. It still runs from a
            // pipeline, where the name is written down rather than said.
            guard !transform.description.isEmpty else { continue }
            seen.insert(key)
            list.append(.transform(transform))
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
