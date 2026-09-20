import Foundation

/// Turns "click on Antonio" plus what is around the gaze into one decision:
/// which action, on which target.
///
/// A port of the prototype's `tools/jev_probe.py`, measured on 2026-09-20:
/// named targets 8/8 in English and French, 620-750 ms per call, ~3.3k input
/// tokens. The split it settled on is kept exactly — **the model selects, code
/// executes, the gaze breaks ties**:
///
/// - The model chooses one of six actions and one of the targets it was
///   offered. It is never asked to write a click, a key or a coordinate.
/// - It does not generate text. The words to type are cut out of the
///   utterance by `messageText`.
/// - It cannot decide a deictic ("this one", "ça"): the three nearest targets
///   came back 0.27 / 0.24 / 0.20, which is no answer. So it is asked only
///   *whether* the utterance points rather than names, and when it does, the
///   nearest clickable thing wins. That is the gaze's job, not the model's.
///
/// The request is built by hand rather than encoded from a dictionary because
/// key order is part of what was measured. `t0 … t40` in the order the
/// candidates were picked, and the state's keys in the order the probe sent
/// them, so the same snapshot and the same utterance produce the same call.
enum ActionDecider {

    // MARK: - What can be asked for

    /// The six, with the wording the model reads. Slack-shaped, and the set
    /// that was measured — an action added here is an action the other five
    /// have to be re-measured against.
    enum Act: String, CaseIterable {
        case click
        case type
        case sendMessage = "send_message"
        case search
        case scroll
        case none

        var describedAs: String {
            switch self {
            case .click:
                return "activate one on-screen target: press a button, open a conversation, follow a link, pick an item"
            case .type:
                return "put words into a text field without sending them"
            case .sendMessage:
                return "write a message and send it, in a conversation or to a person"
            case .search:
                return "look something up with the search field"
            case .scroll:
                return "move the view up or down"
            case .none:
                return "the utterance is not a request to act on this screen"
            }
        }
    }

    /// The nearest targets offered to the model, plus any whose name matches a
    /// word of the utterance however far away it is.
    ///
    /// Both halves earn their place. 40 is what fits in a call that costs
    /// 3.3k tokens; the name match is what let "send a message to john" reach
    /// John's button at 7.5 cm over his message at 5.1 cm, and "click on
    /// Antonio" reach a row 12 cm away.
    static let offered = 40

    struct Decision {
        var action: Act
        /// What the model picked, or nil for "none of these".
        var target: ScreenTargets.Item?
        /// `t12`, or `none` — for the log, where the probability belongs to it.
        var targetID: String
        /// What the model itself picked, before the gaze overrode it. The two
        /// differ on a deictic and nowhere else, and keeping both is what
        /// says which half was wrong when the click lands somewhere silly.
        var modelTargetID: String
        var actionProbability: Double
        var targetProbability: Double
        /// Whether the utterance carries the words to type, not just the ask.
        var hasText: Double
        /// Whether it points rather than names.
        var deictic: Double
        /// The words to type, cut out of the utterance.
        var text: String?
        /// True when the gaze chose the target, not the model.
        var byGaze: Bool
        var ms: Int
        var inputTokens: Int

        var line: String {
            var said = "\(action.rawValue) \(String(format: "%.2f", actionProbability))"
            said += " · target \(targetID) \(String(format: "%.2f", targetProbability))"
            if byGaze { said += " (gaze, over \(modelTargetID))" }
            said += " · text \(String(format: "%.2f", hasText))"
            said += " · deictic \(String(format: "%.2f", deictic))"
            return said
        }
    }

    enum Failure: LocalizedError {
        case noKey(String)
        case http(Int, String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noKey(let where_):
                return "No key for the action decider — \(where_)."
            case .http(let code, let body):
                return "The action decider answered \(code): \(body.prefix(200))"
            case .unreadable(let what):
                return "The action decider's answer could not be read: \(what)"
            }
        }
    }

    // MARK: - Choosing what to offer

    /// The 40 nearest, then anything further whose name shares a word with
    /// the utterance. Words of three letters or more, so "to", "on" and "in"
    /// do not drag half the window in.
    static func candidates(
        in snapshot: ScreenTargets.Snapshot, for utterance: String
    ) -> [ScreenTargets.Item] {
        let spoken = Set(words(of: utterance).filter { $0.count > 2 })
        var picked = Array(snapshot.items.prefix(offered))
        for item in snapshot.items.dropFirst(offered) {
            if !spoken.isDisjoint(with: Set(words(of: item.name))) { picked.append(item) }
        }
        return picked
    }

    /// How a target is described to the model. One line, role first, then its
    /// name, then how far the gaze is from it.
    ///
    /// A text field carries no name anywhere in Slack, so where it sits in the
    /// window is the only thing that says what it is. The composer is at the
    /// bottom, the search field at the top, and everything else is a text
    /// field with nothing more to say about it.
    static func describe(_ item: ScreenTargets.Item, in snapshot: ScreenTargets.Snapshot) -> String {
        let role = item.role.replacingOccurrences(of: "AX", with: "")
        var name = item.name.isEmpty ? item.value.trimmingCharacters(in: .whitespaces) : item.name
        if item.kind == ScreenTargets.Kind.text && name.isEmpty {
            let down = snapshot.relativeY(of: item)
            if down > 0.8 {
                name = "message composer (empty text area at the bottom)"
            } else if down < 0.15 {
                name = "search field (top)"
            } else {
                name = "empty text field"
            }
        }
        return "\(role) “\(String(name.prefix(70)))”, \(item.cm) cm from the gaze"
    }

    /// The words to type, out of the utterance itself.
    ///
    /// The model is not asked to write them. It was never measured writing
    /// anything, it would cost a second question and a longer answer, and a
    /// message it composed is a message nobody said.
    static func messageText(in utterance: String) -> String? {
        if let quoted = firstMatch(#"["“](.+?)["”]"#, in: utterance, group: 1) {
            return quoted.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let after = #"\b(?:saying|that says|that|say|tell (?:him|her|them)|disant|:)\s+(.+)$"#
        if let rest = firstMatch(after, in: utterance, group: 1, caseInsensitive: true) {
            return rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: - The call

    static func decide(
        utterance: String, snapshot: ScreenTargets.Snapshot, config: Config.Actions.Decider,
        done: [String] = []
    ) async throws -> Decision {
        guard let key = config.apiKey.resolve() else {
            throw Failure.noKey(config.apiKey.described)
        }
        let offers = candidates(in: snapshot, for: utterance)
        let body = request(
            utterance: utterance, snapshot: snapshot, offers: offers,
            model: config.model, done: done
        )

        var request = URLRequest(url: config.url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = config.timeoutSeconds

        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try read(data, offers: offers, utterance: utterance, ms: ms)
    }

    /// The JSON, with its keys in the order the probe sent them.
    static func request(
        utterance: String, snapshot: ScreenTargets.Snapshot,
        offers: [ScreenTargets.Item], model: String, done: [String] = []
    ) -> String {
        let note = "The user looks at a point on the screen and speaks. Each target gives its "
            + "distance from that point in cm; nearer targets are more likely to be meant, but a "
            + "name in the utterance beats distance."
        let targets = offers.enumerated().map { index, item in
            ("t\(index)", quoted(describe(item, in: snapshot)))
        }
        // What has already been done for this utterance, in order.
        //
        // One utterance is not always one step: "send a message to Antonio and
        // Peter" is a new message, then a name, then another name, then the
        // words. Without this the same question gets the same answer forever,
        // because nothing in the state says the first step happened.
        var pairs: [(String, String)] = [
            ("utterance", quoted(utterance)),
            ("app", quoted(snapshot.app)),
            ("window", quoted(snapshot.window)),
            ("note", quoted(note)),
        ]
        if !done.isEmpty {
            pairs.append(("done", "[" + done.map(quoted).joined(separator: ",") + "]"))
            pairs.append(("next", quoted(
                "The steps in `done` have already happened. Answer with the next step only, "
                + "and answer `none` when the utterance has been carried out in full."
            )))
        }
        pairs.append(("targets", object(targets)))
        let state = object(pairs)
        // `none` means one more thing once steps have been taken: there is
        // nothing left to do. Without it the loop cannot stop — measured, with
        // both recipients in `done` it still answered "Peter", at 0.40.
        //
        // Only when `done` is not empty, so a single-step call is word for
        // word the one that was measured.
        let actions = object(Act.allCases.map { act in
            guard act == .none, !done.isEmpty else { return (act.rawValue, quoted(act.describedAs)) }
            return (act.rawValue, quoted(
                act.describedAs + ", or the steps in `done` have already carried it out in full"
            ))
        })
        let targetChoices = object(
            targets.map { ($0.0, $0.1) } + [("none", quoted("no listed target fits the utterance"))]
        )
        let questions = object([
            ("action", object([
                ("type", quoted("choice")),
                ("instructions", quoted("What does the user ask to do on this screen?")),
                ("criteria", actions),
            ])),
            ("target", object([
                ("type", quoted("choice")),
                ("instructions", quoted(
                    "Which target in `targets` does the utterance act on? For a message to a "
                    + "person, that is the person or their conversation; for typing, the text field."
                )),
                ("criteria", targetChoices),
            ])),
            ("has_text", object([
                ("type", quoted("noul")),
                ("instructions", quoted(
                    "Does the utterance contain the words to type or send, not only the request "
                    + "to type or send something?"
                )),
            ])),
            ("deictic", object([
                ("type", quoted("noul")),
                ("instructions", quoted(
                    "Does the utterance point at what the user is looking at (\"this\", \"here\", "
                    + "\"that one\", \"ça\", \"ici\") rather than naming it?"
                )),
            ])),
        ])
        return object([("state", state), ("model", quoted(model)), ("questions", questions)])
    }

    private static func read(
        _ data: Data, offers: [ScreenTargets.Item], utterance: String, ms: Int
    ) throws -> Decision {
        guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = top["answers"] as? [String: Any]
        else { throw Failure.unreadable("no answers in it") }

        func choice(_ name: String) throws -> (String, Double) {
            guard let answer = answers[name] as? [String: Any],
                  let picked = answer["choice"] as? String
            else { throw Failure.unreadable("no \(name)") }
            let probabilities = answer["probabilities"] as? [String: Double] ?? [:]
            return (picked, probabilities[picked] ?? 0)
        }
        func noul(_ name: String) -> Double {
            ((answers[name] as? [String: Any])?["noul"] as? Double) ?? 0
        }

        let (actionName, actionProbability) = try choice("action")
        let action = Act(rawValue: actionName) ?? .none
        let (targetID, targetProbability) = try choice("target")
        var target: ScreenTargets.Item?
        if targetID != "none", let index = Int(targetID.dropFirst()), offers.indices.contains(index) {
            target = offers[index]
        }
        let deictic = noul("deictic")
        let hasText = noul("has_text")

        // The utterance points rather than names, so the model may have had
        // nothing to go on — over the three nearest it came back 0.27 / 0.24 /
        // 0.20, which is no answer. Then the gaze decides: the nearest thing
        // that can be clicked or typed into.
        //
        // Only then. The prototype overrode every deictic, and on the twelve
        // measured utterances that cost two of them: "reply here: on it,
        // thanks" and "reply to this message: sounds good" both name the
        // composer through the model (t2, 0.80 and 0.64) and both were
        // dragged onto a group 0.7 cm nearer that happens to be pressable.
        // Rule and evidence in docs/actions.md. A target that can already
        // take the action is an answer, whatever made it.
        var byGaze = false
        var id = targetID
        let unusable = target == nil || target?.isClickable == false
        if deictic > 0.5, action != .none, unusable,
           let nearest = offers.first(where: { $0.isClickable }) {
            target = nearest
            id = offers.firstIndex(of: nearest).map { "t\($0)" } ?? targetID
            byGaze = true
        }

        return Decision(
            action: action, target: target, targetID: id, modelTargetID: targetID,
            actionProbability: actionProbability, targetProbability: targetProbability,
            hasText: hasText, deictic: deictic,
            text: hasText > 0.5 ? messageText(in: utterance) : nil,
            byGaze: byGaze, ms: ms,
            inputTokens: ((top["usage"] as? [String: Any])?["input_tokens"] as? Int) ?? 0
        )
    }

    // MARK: - Small tools

    private static func words(of text: String) -> [String] {
        let lowered = text.lowercased()
        return matches(#"[a-zà-ÿ]+"#, in: lowered)
    }

    private static func object(_ pairs: [(String, String)]) -> String {
        "{" + pairs.map { "\(quoted($0.0)):\($0.1)" }.joined(separator: ",") + "}"
    }

    private static func quoted(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return encoded
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func firstMatch(
        _ pattern: String, in text: String, group: Int, caseInsensitive: Bool = false
    ) -> String? {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > group,
              let found = Range(match.range(at: group), in: text)
        else { return nil }
        return String(text[found])
    }
}
