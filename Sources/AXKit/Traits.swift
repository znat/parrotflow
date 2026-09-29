import AppKit

/// What an operation asks of the user and of the Mac, declared before it
/// runs. A skill adds up its steps' traits and warns once, at the start.
/// A declaration is a prediction: `Outcome.cameToFront` and
/// `Outcome.verified` say what really happened.
public struct Traits: Codable, Equatable, Sendable {
    /// What the kit needs. What the target does after is the app's: a
    /// notification's "Open" or a service may bring an app in front.
    public enum Front: String, Codable, Comparable, Sendable {
        /// Accessibility calls only: the app stays where it is.
        case never
        /// In front only if the step hits a web page in a native app, which
        /// is not known before the run: Outlook's message body.
        case maybe
        /// The app comes in front for the step, then the previous app comes back.
        case always

        static let order: [Front] = [.never, .maybe, .always]
        public static func < (a: Front, b: Front) -> Bool {
            order.firstIndex(of: a)! < order.firstIndex(of: b)!
        }
    }

    public enum HandsOff: String, Codable, Comparable, Sendable {
        case none
        /// Keys are sent: a key the user types into that app meanwhile lands among them.
        case keyboard
        /// The real pointer moves: the user's mouse breaks the step.
        case pointer

        static let order: [HandsOff] = [.none, .keyboard, .pointer]
        public static func < (a: HandsOff, b: HandsOff) -> Bool {
            order.firstIndex(of: a)! < order.firstIndex(of: b)!
        }
    }

    public enum Reversible: String, Codable, Sendable {
        /// The kit can put the value it read before back.
        case yes
        /// It adds or sends something: nothing puts it back.
        case no
        /// A button or a menu item: what it does is the app's. See `looksIrreversible`.
        case dependsOnTarget
    }

    public var front: Front
    public var handsOff: HandsOff
    /// The general pasteboard is used for the step, then put back. A run
    /// killed in between leaves the user's clipboard lost.
    public var borrowsClipboard: Bool
    /// Running it twice gives the same result as once.
    public var safeToRetry: Bool
    /// The result is read back. When not, the caller checks the next screen.
    public var readsBack: Bool
    public var reversible: Reversible
    /// Elements found before it may be stale after it: find them again.
    public var invalidatesElements: Bool

    public init(front: Front = .never, handsOff: HandsOff = .none, borrowsClipboard: Bool = false,
                safeToRetry: Bool = true, readsBack: Bool = true, reversible: Reversible = .yes,
                invalidatesElements: Bool = false) {
        self.front = front
        self.handsOff = handsOff
        self.borrowsClipboard = borrowsClipboard
        self.safeToRetry = safeToRetry
        self.readsBack = readsBack
        self.reversible = reversible
        self.invalidatesElements = invalidatesElements
    }

    /// The traits of steps run one after another: the most any step asks.
    public static func combined(_ steps: [Traits]) -> Traits {
        let reversible: Reversible = steps.contains { $0.reversible == .no } ? .no
            : steps.contains { $0.reversible == .dependsOnTarget } ? .dependsOnTarget : .yes
        return Traits(front: steps.map(\.front).max() ?? .never,
                      handsOff: steps.map(\.handsOff).max() ?? .none,
                      borrowsClipboard: steps.contains(where: \.borrowsClipboard),
                      safeToRetry: steps.allSatisfy(\.safeToRetry),
                      readsBack: steps.allSatisfy(\.readsBack),
                      reversible: reversible,
                      invalidatesElements: steps.contains(where: \.invalidatesElements))
    }

    /// What to tell the user before a run, one line per thing asked of them.
    public var warnings: [String] {
        var lines: [String] = []
        if front == .always { lines.append("the app comes in front") }
        if front == .maybe { lines.append("the app may come in front: it has web pages in it") }
        switch handsOff {
        case .none: break
        case .keyboard: lines.append("do not type while it runs")
        case .pointer: lines.append("do not touch the mouse or the keyboard while it runs")
        }
        if borrowsClipboard { lines.append("the clipboard is used, then put back") }
        if reversible == .no { lines.append("a step cannot be undone") }
        return lines
    }

    /// Button and item titles that send, delete or discard: a press on one
    /// cannot be undone. A guess from the title, for `dependsOnTarget`.
    /// Share, Reply and Forward only open a draft (09-29), so they are not here.
    public static var irreversibleVerbs = [
        "Send", "Delete", "Remove", "Discard", "Don't Save", "Don’t Save", "Erase", "Empty Trash",
        "Submit", "Post", "Publish", "Pay", "Buy", "Purchase", "Leave",
        "Envoyer", "Supprimer", "Effacer", "Ne pas enregistrer", "Publier", "Payer", "Acheter", "Quitter",
    ]

    /// The verb alone, or followed by a word or an ellipsis: "Send", "Send
    /// now", "Delete…". Not "Sender" or "Postpone".
    public static func looksIrreversible(_ title: String) -> Bool {
        irreversibleVerbs.contains { verb in
            [verb, verb + " *", verb + "…", verb + "..."].contains { Glob.matches($0, title) }
        }
    }
}

/// The kit's public operations, each with its declared traits.
public enum Gesture: String, CaseIterable, Codable, Sendable {
    case setDate, setText, setNumber, step, ensure, press, choose, menu, disclose, select
    case typeText, insert, paste, pick, shortcut, contextMenu, reveal, typeDate
    case answerDialog, drag, typeKeys, pressKeys
    case moveWindow, resizeWindow, minimizeWindow, fullScreen, place, tile
    case launch, open, openWith, activate, raise, wake
    case menuExtra, copy, textOf, notificationAction, service, capture

    /// In a native window. `page` gives the traits in a web page.
    public var native: Traits {
        switch self {
        case .setDate, .setText, .setNumber, .ensure, .choose, .disclose, .select, .reveal:
            return Traits()
        case .step:
            return Traits(safeToRetry: false)
        // A menu item runs in the background (File > Export on the bench), but
        // one that acts on the key window does not: use `shortcut` for those.
        case .press, .menu, .contextMenu, .menuExtra, .notificationAction, .service:
            return Traits(safeToRetry: false, readsBack: false, reversible: .dependsOnTarget)
        case .answerDialog:
            return Traits(safeToRetry: false, reversible: .dependsOnTarget)
        case .typeText:
            return Traits(handsOff: .keyboard)
        case .typeDate:
            return Traits(handsOff: .keyboard)
        case .insert:
            return Traits(safeToRetry: false, reversible: .no)
        case .paste:
            // A background app keeps its Paste item disabled (09-28).
            return Traits(front: .always, handsOff: .keyboard, borrowsClipboard: true, safeToRetry: false,
                          readsBack: false, reversible: .no)
        case .pick:
            return Traits(handsOff: .keyboard, safeToRetry: false, reversible: .no)
        case .shortcut:
            // No key window in the background, even with the item enabled (09-29).
            return Traits(front: .always, handsOff: .keyboard, safeToRetry: false, readsBack: false,
                          reversible: .dependsOnTarget)
        case .copy:
            return Traits(front: .always, handsOff: .keyboard, borrowsClipboard: true)
        case .drag:
            return Traits(front: .always, handsOff: .pointer, safeToRetry: false, readsBack: false, reversible: .no)
        case .typeKeys:
            return Traits(handsOff: .keyboard, safeToRetry: false, readsBack: false, reversible: .no)
        case .pressKeys:
            return Traits(handsOff: .keyboard, safeToRetry: false, readsBack: false, reversible: .dependsOnTarget)
        case .moveWindow, .resizeWindow, .minimizeWindow, .fullScreen, .place, .tile, .raise:
            return Traits()
        case .launch, .textOf, .capture:
            return Traits()
        case .open, .openWith:
            // A browser opens a second tab for the same URL.
            return Traits(safeToRetry: false, readsBack: false)
        case .activate:
            return Traits(front: .always)
        case .wake:
            return Traits(invalidatesElements: true)
        }
    }

    /// In a web page (Chromium, Electron, WebKit). A page behind other
    /// windows queues keys and ignores clicks (09-28), so every control
    /// comes in front, and several are typed instead of set.
    public var page: Traits {
        var traits = native
        switch self {
        // The ones that call `Controls.inFront`.
        case .setDate, .setText, .setNumber, .step, .ensure, .press, .choose, .typeText, .insert, .pick:
            traits.front = .always
        case .place, .tile, .fullScreen, .resizeWindow:
            // Enhanced UI is turned off to place the window, which rebuilds the tree.
            traits.invalidatesElements = true
        default: break
        }
        switch self {
        case .setDate, .choose, .insert:
            // Typed: parts of a date input, a <select>'s item, text at the caret.
            traits.handsOff = max(traits.handsOff, .keyboard)
        case .setText:
            // A text area is typed into; an input takes AXValue.
            traits.handsOff = max(traits.handsOff, .keyboard)
        default: break
        }
        return traits
    }

    public func traits(pages: Bool) -> Traits { pages ? page : native }
}

extension Gesture {
    /// Before the run, knowing only the app. `App.pages` walks the app's
    /// windows: for many steps, read it once and pass it to `traits(for:)`.
    public func traits(in app: App?, target title: String? = nil) -> Traits {
        traits(for: app?.pages ?? .none, target: title)
    }

    /// With an app that has some pages, a step that would come in front for
    /// a page may come in front: which element it hits is not known yet.
    /// A press on a button or item that sends or deletes becomes irreversible.
    public func traits(for pages: App.Pages, target title: String? = nil) -> Traits {
        guard pages == .some else { return resolved(self.traits(pages: pages == .all), title) }
        var traits = native
        if page.front == .always, native.front == .never { traits.front = .maybe }
        traits.invalidatesElements = page.invalidatesElements
        return resolved(traits, title)
    }

    /// With the element in hand: exact.
    public func traits(on element: Element) -> Traits {
        resolved(traits(pages: element.isInWebArea), element.title ?? element.name)
    }

    func resolved(_ traits: Traits, _ title: String?) -> Traits {
        var traits = traits
        if traits.reversible == .dependsOnTarget, let title, Traits.looksIrreversible(title) {
            traits.reversible = .no
        }
        return traits
    }
}

extension App {
    /// Chromium and Electron ship their engine as a framework, known by the
    /// SwiftShader library it carries (Chrome has no libEGL). WebKit apps
    /// do not, so they are known by id, or by a web area in a window.
    public static var pageBundles: Set<String> = ["com.apple.Safari", "com.microsoft.teams2"]

    public enum Pages: String, Codable, Sendable {
        case none
        /// A native app with a web view in it, as Outlook's message body.
        case some
        /// Its whole interface is web pages: Chrome, Slack, Teams.
        case all
    }

    /// Whether the app draws its interface as web pages: then its controls
    /// need it in front. From the bundle, then from its windows if running.
    public var pages: Pages {
        if let bundle = bundleIdentifier, App.pageBundles.contains(bundle) { return .all }
        if let url = running?.bundleURL, App.bundleHasEngine(url) { return .all }
        return windows.contains { $0.first(budget: 2000) { $0.role == "AXWebArea" } != nil } ? .some : .none
    }

    /// Before launch: from the bundle alone, so never `some`.
    public static func pages(bundle: String) -> Pages {
        if pageBundles.contains(bundle) { return .all }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return .none }
        return bundleHasEngine(url) ? .all : .none
    }

    static func bundleHasEngine(_ url: URL) -> Bool {
        let frameworks = (try? FileManager.default.contentsOfDirectory(
            atPath: url.appendingPathComponent("Contents/Frameworks").path)) ?? []
        return frameworks.contains { $0 == "Electron Framework.framework" || $0.hasSuffix(" Framework.framework")
            && FileManager.default.fileExists(atPath: url.appendingPathComponent(
                "Contents/Frameworks/\($0)/Libraries/libvk_swiftshader.dylib").path) }
    }
}
