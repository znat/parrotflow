import AppKit

/// A request to act on the screen, handed to `built-in/recipes/runner.py`.
/// The runner decides: a recipe when one fits, the loop otherwise. It asks
/// for each screen step and `RecipeProcess` does it.
///
/// A recipe replaces the loop's one wide question — "what now?" over every
/// target in the window — with steps that ask only narrow ones. On a message
/// to two people in Slack the loop failed 6 of 6 at that question
/// (0.32–0.52, reaching for the sidebar); the recipe passed it.
enum Recipes {

    struct Run {
        /// False only when the runner answered `none`.
        var ran = false
        var ok = false
        var lines: [String] = []
        /// What the loop did, when no recipe fit.
        var loop: Report?
    }

    /// The loop's account of a run, as the runner sends it.
    struct Report {
        /// What the pill says when only one thing happened.
        var said: String
        /// Every step, for a run that took more than one.
        var markdown: String?
        var acted: Bool
        var stopped: String
        var steps: [String]
        var shown: [String]

        init(_ from: [String: Any]) {
            said = from["said"] as? String ?? ""
            markdown = from["markdown"] as? String
            acted = from["acted"] as? Bool ?? false
            stopped = from["stopped"] as? String ?? ""
            steps = from["steps"] as? [String] ?? []
            shown = from["shown"] as? [String] ?? []
        }
    }

    /// `recipes: false` goes straight to the loop. `readApp` reads that app's
    /// focused window first instead of the one of the app in front.
    static func run(
        utterance: String, app: String, config: Config.Actions, execute: Bool = true,
        recipes: Bool? = nil, readApp: String? = nil, maxSteps: Int? = nil,
        heard: String? = nil
    ) async -> Run {
        var run = Run()
        func say(_ line: String) {
            run.lines.append(line)
            Log.write("recipe: \(line)")
        }
        let screen = NSScreen.screens.first?.frame ?? .zero
        var request: [String: Any] = [
            "run": utterance, "app": app, "execute": execute,
            "letters": max(1, config.lookupLetters),
            "screen": ["w": Int(screen.width), "h": Int(screen.height)],
            "recipes": recipes ?? config.recipes,
            "read_app": readApp as Any? ?? NSNull(),
            "loop": [
                "max_steps": maxSteps ?? config.maxSteps, "send": config.send,
                "spotlight": config.spotlight, "lookup_letters": config.lookupLetters,
            ] as [String: Any],
        ]
        if execute, config.planner != nil { request["review"] = true }
        if let heard, heard != utterance { request["heard"] = heard }
        request["bundle"] = NSWorkspace.shared.runningApplications
            .first { $0.localizedName == app }?.bundleIdentifier ?? ""
        let ended = await RecipeProcess.shared.run(request, app: app, config: config, say: say)
        let end = ended["end"] as? String ?? "failed"
        run.ran = end != "none"
        run.ok = ["planned", "ready", "done"].contains(end)
        run.loop = (ended["loop"] as? [String: Any]).map(Report.init)
        return run
    }

    /// A decision on a window that is handed over rather than read, for
    /// `--act`. `mode` is `decide`, `look` (the offers only) or `request`
    /// (the body that would be sent). Returns the runner's answer.
    static func decide(
        _ utterance: String, on snapshot: ScreenTargets.Snapshot, done: [String],
        mode: String, config: Config.Actions
    ) async -> [String: Any] {
        let items = snapshot.items.enumerated().map {
            encode($0.element, id: $0.offset + 1, never: config.neverPress)
        }
        let request: [String: Any] = [
            "decide": utterance, "snapshot": encode(snapshot, id: 0, items: items),
            "done": done, "mode": mode,
        ]
        return await RecipeProcess.shared.run(
            request, app: snapshot.app, config: config, say: { Log.write("recipe: \($0)") }
        )
    }

    // MARK: - What the runner reads

    /// An item as a step reply carries it, with this app's verdicts on it so
    /// the rules stay here: `lookup`, `in_list`, `clickable`, and `refused`,
    /// the `never_press` word its name matches.
    static func encode(_ item: ScreenTargets.Item, id: Int, never: [String]) -> [String: Any] {
        ["id": id, "role": item.role, "name": item.name, "value": item.value, "kind": item.kind,
         "x": item.x, "y": item.y, "w": item.w, "h": item.h,
         "actions": item.actions, "lookup": item.looksThingsUp, "in_list": item.isChoiceInAList,
         "clickable": item.isClickable, "in": item.origin as Any? ?? NSNull(),
         "state": item.states ?? [], "key": item.key as Any? ?? NSNull(),
         "refused": ScreenAction.refuses(item.name, never) as Any? ?? NSNull()]
    }

    static func encode(
        _ snapshot: ScreenTargets.Snapshot, id: Int, items: [[String: Any]]
    ) -> [String: Any] {
        ["id": id, "app": snapshot.app, "bundle": ScreenTargets.bundle(ofApp: snapshot.app) ?? "",
         "window": snapshot.window,
         "frame": ["x": snapshot.frame.x, "y": snapshot.frame.y,
                   "w": snapshot.frame.w, "h": snapshot.frame.h],
         "items": items]
    }

    /// What is on screen now that was not before, matched on kind and name.
    static func appeared(
        from before: ScreenTargets.Snapshot, to after: ScreenTargets.Snapshot
    ) -> [ScreenTargets.Item] {
        let was = Set(before.items.map { $0.kind + "\u{1}" + $0.name })
        return after.items.filter { !was.contains($0.kind + "\u{1}" + $0.name) }
    }

    // MARK: - Shared

    /// The rows typing made appear. Menu items where the app uses them —
    /// Slack's picker does — and otherwise whatever clickable things appeared
    /// below the field, because Outlook's list is built differently.
    static func list(
        in app: String, since before: ScreenTargets.Snapshot, windows: [CGRect],
        under field: ScreenTargets.Item?, deep: Bool = false, ms: Int = 3000
    ) async -> ([ScreenTargets.Item], Int) {
        let start = Date()
        var waited = 0
        while waited < ms {
            try? await Task.sleep(nanoseconds: 250_000_000)
            waited = Int(Date().timeIntervalSince(start) * 1000)
            // Outlook's list: outside the window, rows that cannot be pressed.
            if deep, let field {
                let box = CGRect(x: field.x - field.w / 2, y: field.y - field.h / 2,
                                 width: field.w, height: field.h)
                let rows = ScreenTargets.listRows(ofApp: app, under: box)
                if !rows.isEmpty { return (rows, waited) }
                continue
            }
            // A list drawn as a window of its own — Outlook's.
            // Text as well as buttons: whether its rows are pressable is not
            // known, and the click goes to where a row is either way.
            let popup = ScreenTargets.newWindows(ofApp: app, besides: windows).filter {
                ($0.kind == ScreenTargets.Kind.click || $0.kind == ScreenTargets.Kind.label)
                    && !($0.name.isEmpty && $0.value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !popup.isEmpty { return (popup, waited) }
            guard let now = try? ScreenTargets.snapshot(ofApp: app) else { continue }
            let menu = now.items.filter { $0.isChoiceInAList }
            if !menu.isEmpty { return (menu, waited) }
            let below = appeared(from: before, to: now).filter { item in
                guard item.kind == ScreenTargets.Kind.click, !item.name.isEmpty else { return false }
                guard let field else { return true }
                return item.y > field.y && item.y < field.y + 600
            }
            if !below.isEmpty { return (below, waited) }
        }
        return ([], waited)
    }
}
