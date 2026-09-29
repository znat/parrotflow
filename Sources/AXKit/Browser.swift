import AppKit

/// Tabs, the address bar and the history of a browser, through
/// accessibility only: Chromium (Chrome, Edge, Brave) and Safari.
///
/// Measured 09-29 in a throwaway Chrome behind other windows: pressing a
/// tab, setting the address bar's value, pressing a suggestion and setting
/// the History page's search all work with Chrome left behind. Keys typed
/// into the address bar bring Chrome in front, so none are sent. The
/// suggestion list and the History page are web areas, yet an AXPress or a
/// value set on them works behind: they are not played through `Controls`,
/// whose page rule would bring Chrome in front.
///
/// Measured 09-29 in Safari 27 behind other windows: pressing a tab or the
/// New Tab button, and reading the History view, work there. Setting the
/// address field's value makes Safari run a Google search by itself, so
/// Safari's address field is never written: `open` goes through
/// `App.open`. Its suggestions cannot be chosen without keys, so
/// `suggestions` and `go` are Chromium only.
public struct Browser {
    public let app: App
    public let engine: Engine

    public enum Engine: String, Sendable {
        case chromium, safari
    }

    public init(_ app: App) {
        self.app = app
        engine = (app.bundleIdentifier ?? "").hasPrefix("com.apple.Safari") ? .safari : .chromium
    }

    public struct Tab {
        public let element: Element
        /// As the tab shows it, without Chrome's " - Memory usage - 30 MB".
        public let title: String
        public let isSelected: Bool
        public let window: Element
        /// The window's only tab, when the browser hides its tab bar for one
        /// (Safari): `element` is then the window.
        public let isAlone: Bool
    }

    /// Every tab in every window, from the windows' tab strips. A page's own
    /// tabs (History's "By date") have the same role and are left out.
    public var tabs: [Tab] {
        app.windows.filter { $0.subrole == kAXStandardWindowSubrole }.flatMap { window -> [Tab] in
            guard let strip = tabStrip(in: window) else {
                guard engine == .safari else { return [] }
                return [Tab(element: window, title: window.title ?? "", isSelected: true, window: window, isAlone: true)]
            }
            return strip.children.filter { $0.subrole == "AXTabButton" }.map {
                Tab(element: $0, title: Browser.cleanTitle($0.title ?? $0.name ?? ""),
                    isSelected: ($0.value as? NSNumber)?.intValue == 1, window: window, isAlone: false)
            }
        }
    }

    /// Chrome: a tab group outside the page. Safari: the "Tab bar" list,
    /// shown only from two tabs; its page sits in a tab group of its own.
    func tabStrip(in window: Element) -> Element? {
        switch engine {
        case .chromium: return window.first(budget: 400) { $0.role == kAXTabGroupRole && !$0.isInWebArea }
        case .safari: return window.children.first { $0.subrole == "AXOpaqueProviderList" }
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
        if tab.isSelected || tab.isAlone { return Outcome(before: tab.title, after: tab.title, method: "none, already shown", verified: true) }
        try tab.element.perform(kAXPressAction)
        let ok = Controls.wait { (tab.element.value as? NSNumber)?.intValue == 1 }
        if !ok { throw AXKitError.notApplied("show the tab \"\(tab.title)\"") }
        return Outcome(before: nil, after: tab.title, method: "AXPress the tab", verified: true)
    }

    /// Closes the tab with its close button.
    @discardableResult
    public func close(_ tab: Tab) throws -> Outcome {
        let count = tabs.count
        if tab.isAlone {
            guard let button = tab.window.element(kAXCloseButtonAttribute) else {
                throw AXKitError.ax(.actionUnsupported, "no close button on the window \"\(tab.title)\"")
            }
            try button.perform(kAXPressAction)
        } else if let action = tab.element.actions.first(where: { System.actionName($0) == "close tab" }) {
            // Safari: a named action on the tab, not a button in it.
            try tab.element.perform(action)
        } else {
            guard let button = tab.element.children.first(where: { $0.role == kAXButtonRole }) else {
                throw AXKitError.ax(.actionUnsupported, "no close button on the tab \"\(tab.title)\"")
            }
            try button.perform(kAXPressAction)
        }
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

    /// The shown tab's URL: the page's own, else what the address bar holds.
    /// Safari's address field shows a shortened address.
    public func address(in window: Element? = nil) -> String? {
        let page = (window ?? self.window)?.first(depth: 8) { $0.role == "AXWebArea" }
        if let url = page?.attribute(kAXURLAttribute) as? URL { return url.absoluteString }
        return engine == .safari ? nil : addressBar(in: window)?.valueText
    }

    /// A new tab in the window, from the button after its tab strip.
    @discardableResult
    public func newTab(in window: Element? = nil) throws -> Outcome {
        guard let window = window ?? self.window else { throw AXKitError.ax(.failure, "no window") }
        let button: Element?
        switch engine {
        case .chromium:
            guard let strip = tabStrip(in: window), let holder = strip.parent?.parent ?? strip.parent else {
                throw AXKitError.ax(.failure, "no tab strip")
            }
            button = holder.children.first { $0.role == kAXButtonRole }
        case .safari:
            // It lists no AXPress, and takes it (09-29).
            button = window.first(budget: 200) { $0.role == kAXButtonRole && $0.parent?.role == kAXToolbarRole
                && $0.name == "New Tab" }
        }
        guard let button else { throw AXKitError.ax(.failure, "no new-tab button") }
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
        guard engine == .chromium else {
            throw AXKitError.ax(.actionUnsupported, "Safari runs a search when its address field is set, "
                                + "and its suggestions take no press")
        }
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
        if engine == .safari { return try openInSafari(text) }
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

    /// Safari: through Launch Services, which opens a new tab. A search
    /// becomes a Google search URL.
    func openInSafari(_ text: String) throws -> Outcome {
        let url: URL
        if let given = URL(string: text), given.scheme != nil {
            url = given
        } else {
            var search = URLComponents(string: "https://www.google.com/search")!
            search.queryItems = [URLQueryItem(name: "q", value: text)]
            url = search.url!
        }
        let count = tabs.count
        let before = address()
        try App.open(url, with: app.bundleIdentifier ?? "com.apple.Safari")
        let ok = Controls.wait { tabs.count > count && address() != before }
        if !ok { throw AXKitError.notApplied("open \(url.absoluteString) in Safari") }
        return Outcome(before: before, after: address(), method: "App.open with Safari", verified: true)
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
        if engine == .safari { return try safariHistory(matching: query, timeout: timeout) }
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

    /// Safari's History view, opened with its ⌘Y item (a toggle), read
    /// with every day group opened, then left as it was. Its search field
    /// ignores a value set (09-29), so the rows are matched here.
    func safariHistory(matching query: String, timeout: Double) throws -> [Visit] {
        guard let item = Controls.menuItem(shortcut: "y", in: app) else {
            throw AXKitError.ax(.failure, "no ⌘Y History item in \(app.name ?? "Safari")")
        }
        let outline = { self.window?.first(depth: 16) { $0.role == kAXOutlineRole && !$0.isInWebArea } }
        let wasOpen = outline() != nil
        if !wasOpen {
            try item.perform(kAXPressAction)
            guard Wait.until(app, timeout: timeout, { outline() != nil }) else {
                throw AXKitError.notApplied("open the History view")
            }
        }
        defer { if !wasOpen { try? item.perform(kAXPressAction) } }
        guard let list = outline() else { throw AXKitError.notApplied("open the History view") }
        _ = Wait.until(app, timeout: timeout) { !list.elements(kAXRowsAttribute).isEmpty }
        let text = { (row: Element) -> [String] in
            var found: [String] = []
            var stack = Array(row.children.reversed())
            while let element = stack.popLast(), found.count < 8 {
                if element.role == kAXStaticTextRole || element.role == kAXTextFieldRole,
                   let value = element.valueText, !value.isEmpty { found.append(value) }
                stack.append(contentsOf: element.children.reversed())
            }
            return found
        }
        var opened: [Element] = []
        defer { for group in opened.reversed() { try? group.set(kAXDisclosingAttribute, to: kCFBooleanFalse) } }
        for group in list.elements(kAXRowsAttribute) where group.bool(kAXDisclosingAttribute) == false {
            if (try? group.set(kAXDisclosingAttribute, to: kCFBooleanTrue)) != nil { opened.append(group) }
        }
        if !opened.isEmpty { _ = Wait.settled(app, on: list, quiet: 0.3, timeout: 2) }
        return list.elements(kAXRowsAttribute).compactMap { row -> Visit? in
            let parts = text(row)
            guard let url = parts.first(where: { $0.contains("://") }) else { return nil }
            let title = parts.first ?? ""
            guard Browser.matches(query, title + " " + url) else { return nil }
            return Visit(title: title, url: url, text: parts.joined(separator: " | "))
        }
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
