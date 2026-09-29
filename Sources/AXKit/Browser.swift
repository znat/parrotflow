import AppKit

/// Tabs, the address bar and the history of a Chromium browser (Chrome,
/// Edge, Brave), through accessibility only.
///
/// Measured 09-29 in a throwaway Chrome behind other windows: pressing a
/// tab, setting the address bar's value, pressing a suggestion and setting
/// the History page's search all work with Chrome left behind. Keys typed
/// into the address bar bring Chrome in front, so none are sent. The
/// suggestion list and the History page are web areas, yet an AXPress or a
/// value set on them works behind: they are not played through `Controls`,
/// whose page rule would bring Chrome in front.
public struct Browser {
    public let app: App

    public init(_ app: App) { self.app = app }

    public struct Tab {
        public let element: Element
        /// As the tab shows it, without Chrome's " - Memory usage - 30 MB".
        public let title: String
        public let isSelected: Bool
        public let window: Element
    }

    /// Every tab in every window, from the windows' tab strips. A page's own
    /// tabs (History's "By date") have the same role and are left out.
    public var tabs: [Tab] {
        app.windows.flatMap { window -> [Tab] in
            guard let strip = window.first(budget: 400, where: { $0.role == kAXTabGroupRole && !$0.isInWebArea })
            else { return [] }
            return strip.children.filter { $0.subrole == "AXTabButton" }.map {
                Tab(element: $0, title: Browser.cleanTitle($0.title ?? $0.name ?? ""),
                    isSelected: ($0.value as? NSNumber)?.intValue == 1, window: window)
            }
        }
    }

    static func cleanTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #" - [^-]+ - [\d.,]+ ?[KMG]B$"#, with: "", options: .regularExpression)
    }

    /// The tab whose title holds every word of `query`, case and accents
    /// ignored; the selected one first when several do.
    public func tab(matching query: String) -> Tab? {
        let found = tabs.filter { Browser.matches(query, $0.title) }
        return found.first(where: \.isSelected) ?? found.first
    }

    static func matches(_ query: String, _ text: String) -> Bool {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let haystack = fold(text)
        let words = fold(query).split(whereSeparator: \.isWhitespace)
        return !words.isEmpty && words.allSatisfy { haystack.contains($0) }
    }

    /// Makes the tab the one shown in its window. The window stays where
    /// it is: `App.raise` brings it up within the app.
    @discardableResult
    public func show(_ tab: Tab) throws -> Outcome {
        if tab.isSelected { return Outcome(before: tab.title, after: tab.title, method: "none, already shown", verified: true) }
        try tab.element.perform(kAXPressAction)
        let ok = Controls.wait { (tab.element.value as? NSNumber)?.intValue == 1 }
        if !ok { throw AXKitError.notApplied("show the tab \"\(tab.title)\"") }
        return Outcome(before: nil, after: tab.title, method: "AXPress the tab", verified: true)
    }

    /// Closes the tab with its close button.
    @discardableResult
    public func close(_ tab: Tab) throws -> Outcome {
        guard let button = tab.element.children.first(where: { $0.role == kAXButtonRole }) else {
            throw AXKitError.ax(.actionUnsupported, "no close button on the tab \"\(tab.title)\"")
        }
        let count = tabs.count
        try button.perform(kAXPressAction)
        let ok = Controls.wait { tabs.count < count }
        if !ok { throw AXKitError.notApplied("close the tab \"\(tab.title)\"") }
        return Outcome(before: tab.title, after: nil, method: "AXPress the tab's close button", verified: true)
    }

    /// The window shown in front of the app's others.
    public var window: Element? { app.mainWindow ?? app.focusedWindow ?? app.windows.first }

    /// The address bar: the one text field in the window's toolbar.
    public func addressBar(in window: Element? = nil) -> Element? {
        let toolbar = (window ?? self.window)?.first(budget: 400) { $0.role == kAXToolbarRole }
        return toolbar?.first(budget: 200) { $0.role == kAXTextFieldRole }
    }

    /// The shown tab's URL, as the address bar holds it.
    public func address(in window: Element? = nil) -> String? { addressBar(in: window)?.valueText }

    /// A new tab in the window, from the button after its tab strip.
    @discardableResult
    public func newTab(in window: Element? = nil) throws -> Outcome {
        guard let window = window ?? self.window,
              let strip = window.first(budget: 400, where: { $0.role == kAXTabGroupRole && !$0.isInWebArea }),
              let holder = strip.parent?.parent ?? strip.parent
        else { throw AXKitError.ax(.failure, "no tab strip") }
        guard let button = holder.children.first(where: { $0.role == kAXButtonRole }) else {
            throw AXKitError.ax(.failure, "no new-tab button beside the tab strip")
        }
        let count = tabs.count
        try button.perform(kAXPressAction)
        let ok = Controls.wait { tabs.count > count }
        if !ok { throw AXKitError.notApplied("open a new tab") }
        return Outcome(before: "\(count) tabs", after: "\(tabs.count) tabs", method: "AXPress the new-tab button", verified: true)
    }

    public struct Suggestion {
        public enum Kind: String, Codable, Sendable {
            /// A page: from the history, a bookmark, or the URL typed.
            case page
            /// A page already open in a tab: `switchButton` shows it.
            case openTab
            /// A search with the default engine.
            case search
        }

        public let element: Element
        /// The row as the browser reads it out: title, URL, then its kind.
        public let text: String
        public let kind: Kind
        public let url: String?
        public let switchButton: Element?
    }

    /// What the address bar suggests for `text`: history, bookmarks, open
    /// tabs and searches, in the browser's order. Types nothing: the value
    /// is set. The shown tab's address changes until one is pressed, so
    /// call this on a new tab.
    public func suggestions(for text: String, in window: Element? = nil, timeout: Double = 3) throws -> [Suggestion] {
        guard let bar = addressBar(in: window) else { throw AXKitError.ax(.failure, "no address bar") }
        try bar.set(kAXValueAttribute, to: text as NSString)
        var last: [String] = []
        var rows: [Element] = []
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            rows = suggestionRows()
            let now = rows.compactMap(\.valueText)
            if !now.isEmpty, now == last { break }
            last = now
            Thread.sleep(forTimeInterval: 0.15)
        }
        return rows.map(Browser.suggestion)
    }

    /// Rows of the suggestion list, a small web page with ids match-0, match-1…
    func suggestionRows() -> [Element] {
        var seen = Set<String>()
        return app.windows.flatMap { window -> [Element] in
            guard let list = window.first(budget: 300, where: { $0.role == kAXListRole && $0.isInWebArea
                && $0.children.contains { ($0.domIdentifier ?? "").hasPrefix("match-") } }) else { return [] }
            return list.children.filter { ($0.domIdentifier ?? "").hasPrefix("match-") }
        }.filter { seen.insert($0.domIdentifier ?? "").inserted }
    }

    static func suggestion(_ row: Element) -> Suggestion {
        let text = row.valueText ?? ""
        let url = text.range(of: #"[a-z][a-z0-9+.-]*://\S+"#, options: .regularExpression).map { String(text[$0]) }
        let action = row.first(budget: 40) { $0.domIdentifier == "action" }
        let kind: Suggestion.Kind = action != nil ? .openTab : url != nil ? .page : .search
        return Suggestion(element: row, text: text, kind: kind, url: url, switchButton: action)
    }

    /// Goes where the suggestion leads, in the shown tab. For an open tab,
    /// `switchTab: true` shows that tab instead of loading it again.
    @discardableResult
    public func go(_ suggestion: Suggestion, switchTab: Bool = false, in window: Element? = nil) throws -> Outcome {
        let target = switchTab ? suggestion.switchButton ?? suggestion.element : suggestion.element
        let before = address(in: window)
        try target.perform(kAXPressAction)
        let ok = Controls.wait { suggestionRows().isEmpty }
        if !ok { throw AXKitError.notApplied("go to \"\(suggestion.text)\": the list is still open") }
        // Switching from an empty new tab closes it, a moment later (09-29).
        if switchTab { settleTabs() }
        return Outcome(before: before, after: address(in: window),
                       method: switchTab ? "AXPress the switch button" : "AXPress the suggestion", verified: true)
    }

    /// Loads a URL or a search in a new tab, through the address bar's
    /// first suggestion, which is what was set.
    @discardableResult
    public func open(_ text: String, in window: Element? = nil) throws -> Outcome {
        try newTab(in: window)
        guard let first = try suggestions(for: text, in: window).first else {
            throw AXKitError.ax(.failure, "no suggestion for \"\(text)\"")
        }
        return try go(first, in: window)
    }

    /// Until the tab count has not changed for 0.5 s, 2 s at most.
    func settleTabs() {
        var count = tabs.count
        var since = Date()
        let end = Date().addingTimeInterval(2)
        while Date() < end, Date().timeIntervalSince(since) < 0.5 {
            Thread.sleep(forTimeInterval: 0.1)
            let now = tabs.count
            if now != count { (count, since) = (now, Date()) }
        }
    }

    public struct Visit: Codable, Sendable {
        public let title: String
        public let url: String?
        /// The row as the History page reads it out: its day, time and title.
        public let text: String
    }

    /// The History page's matches for `query`, newest first. Opens it in a
    /// new tab, searches, reads, and closes the tab.
    public func history(matching query: String, in window: Element? = nil, timeout: Double = 5) throws -> [Visit] {
        try open("chrome://history", in: window)
        let shown = window ?? self.window
        let opened = tabs.first { $0.isSelected && $0.window == shown }
        defer { if let opened { try? close(opened) } }
        var search: Element?
        _ = Wait.until(app, timeout: timeout) {
            search = self.window?.first(depth: 30) { $0.subrole == "AXSearchField" && $0.isInWebArea }
            return search != nil
        }
        guard let search else { throw AXKitError.ax(.failure, "no search field on the History page") }
        try search.set(kAXValueAttribute, to: query as NSString)
        var visits: [Visit] = []
        var last = -1
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            Thread.sleep(forTimeInterval: 0.3)
            visits = readVisits()
            if !visits.isEmpty, visits.count == last { break }
            last = visits.count
        }
        return visits
    }

    func readVisits() -> [Visit] {
        guard let page = window?.first(depth: 12, where: { $0.role == "AXWebArea" }) else { return [] }
        var visits: [Visit] = []
        var seen = Set<String>()
        var stack = Array(page.children.reversed())
        var left = 6000
        while let element = stack.popLast(), left > 0 {
            left -= 1
            if element.role == kAXRowRole, let link = element.first(budget: 60, where: { $0.role == "AXLink" }) {
                let url = (link.attribute(kAXURLAttribute) as? URL)?.absoluteString
                let text = element.name ?? ""
                guard seen.insert(text + (url ?? "")).inserted else { continue }
                visits.append(Visit(title: link.name ?? link.title ?? "", url: url, text: text))
            } else {
                stack.append(contentsOf: element.children.reversed())
            }
        }
        return visits
    }
}
