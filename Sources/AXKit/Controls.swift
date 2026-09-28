import AppKit
import ApplicationServices

/// What an operation did, read back from the element after it.
public struct Outcome: Codable, Equatable, Sendable {
    public var before: String?
    public var after: String?
    /// The calls made, in order.
    public var method: String
    /// The value read back is the one asked for. `nil`: nothing to read back.
    public var verified: Bool?
}

/// Operations on one kind of control each. Every write is read back, because
/// the accessibility API returns success when the app ignores the value.
/// They are all accessibility calls: none needs the app in front.
public enum Controls {
    /// How long a change may take to show after the call.
    public static var settle: Double = 1

    /// A date picker. Only a `CFDate` is taken: strings, ISO strings and
    /// numbers are refused (-25201). One call writes date and time; a
    /// date-only picker writes the hidden time too.
    @discardableResult
    /// A page's date input is set part by part; `keys: false` keeps it to
    /// accessibility calls.
    public static func setDate(_ date: Date, on element: Element, keys: Bool = true) throws -> Outcome {
        if element.role == "AXDateField" || element.role == "AXTimeField" {
            return try setPageDate(date, on: element, keys: keys)
        }
        let area = element.role == "AXDateTimeArea" ? element
            : element.first(budget: 50) { $0.role == "AXDateTimeArea" } ?? element
        let before = area.value as? Date
        try area.set(kAXValueAttribute, to: date as NSDate)
        let ok = wait { (area.value as? Date).map { abs($0.timeIntervalSince(date)) < 60 } ?? false }
        let outcome = Outcome(before: before.map(iso), after: (area.value as? Date).map(iso),
                              method: "set AXValue (date)", verified: ok)
        if !ok { throw AXKitError.notApplied("set the date of \(describe(area))") }
        return outcome
    }

    /// A text field or combo box. In a page, a value set reaches the page for
    /// inputs, React included, but never for contenteditable: the text shows
    /// and the page is not told. So a page's text area is typed into.
    @discardableResult
    public static func setText(_ text: String, on element: Element) throws -> Outcome {
        if element.role == kAXTextAreaRole, element.isInWebArea, let pid = element.pid {
            return try typeText(text, into: element, route: .process(pid))
        }
        let before = element.valueText
        try element.set(kAXValueAttribute, to: text as NSString)
        let ok = wait { element.valueText == text }
        let outcome = Outcome(before: before, after: element.valueText, method: "set AXValue (text)",
                              verified: ok)
        if !ok { throw AXKitError.notApplied("set the text of \(describe(element))") }
        return outcome
    }

    /// A slider. Chromium refuses a value set on one, so in a page it is
    /// stepped to the number instead.
    @discardableResult
    public static func setNumber(_ number: Double, on element: Element) throws -> Outcome {
        let before = element.valueText
        if element.isInWebArea { return try stepTo(number, element) }
        try element.set(kAXValueAttribute, to: number as NSNumber)
        let ok = wait { (element.value as? NSNumber)?.doubleValue == number }
        let outcome = Outcome(before: before, after: element.valueText, method: "set AXValue (number)",
                              verified: ok)
        if !ok { throw AXKitError.notApplied("set the number of \(describe(element))") }
        return outcome
    }

    /// A slider or stepper, `count` steps up (positive) or down. A stepper
    /// ignores a value set, so this is the way to move one.
    @discardableResult
    public static func step(_ element: Element, by count: Int) throws -> Outcome {
        let before = element.valueText
        let action = count >= 0 ? kAXIncrementAction : kAXDecrementAction
        for _ in 0..<abs(count) { try element.perform(action) }
        let ok = count == 0 || wait { element.valueText != before }
        let outcome = Outcome(before: before, after: element.valueText,
                              method: "\(action) ×\(abs(count))", verified: ok)
        if !ok { throw AXKitError.notApplied("step \(describe(element))") }
        return outcome
    }

    /// A checkbox, switch or radio: pressed only when it is not already in
    /// the wanted state. Their value cannot be set: the call succeeds and
    /// nothing changes.
    @discardableResult
    public static func ensure(_ on: Bool, _ element: Element) throws -> Outcome {
        let state = { (element.value as? NSNumber).map { $0.intValue == 1 } }
        let before = state()
        if before == nil { throw AXKitError.unreadable("turn \(on ? "on" : "off") \(describe(element))") }
        guard before != on else {
            return Outcome(before: before.map(String.init), after: before.map(String.init),
                           method: "none, already \(on ? "on" : "off")", verified: true)
        }
        try element.perform(kAXPressAction)
        let ok = wait { state() == on }
        let outcome = Outcome(before: before.map(String.init), after: state().map(String.init),
                              method: "AXPress", verified: ok)
        if !ok { throw AXKitError.notApplied("turn \(on ? "on" : "off") \(describe(element))") }
        return outcome
    }

    /// A button, a segment, a radio, a tab: pressed. Nothing to read back in
    /// general; the caller checks what the press was for.
    @discardableResult
    public static func press(_ element: Element) throws -> Outcome {
        try element.perform(kAXPressAction)
        return Outcome(before: nil, after: nil, method: "AXPress", verified: nil)
    }

    /// A pop-up button: opened, then the item pressed. Its value cannot be
    /// set, and its items are not children until it is open.
    @discardableResult
    public static func choose(_ item: String, in popup: Element) throws -> Outcome {
        let before = popup.valueText
        guard before != item else {
            return Outcome(before: before, after: before, method: "none, already chosen", verified: true)
        }
        if popup.isInWebArea, let pid = popup.pid {
            // A page's <select> opens a native menu whose items are not
            // reachable. Typed while it is closed and focused, the name picks it.
            guard Input.prepare(popup) else { throw AXKitError.ax(.cannotComplete, "focus \(describe(popup))") }
            try Input.type(item, to: .process(pid))
            let ok = wait { popup.valueText == item }
            let outcome = Outcome(before: before, after: popup.valueText, method: "keys (typed the item)",
                                  verified: ok)
            if !ok { throw AXKitError.notApplied("choose \"\(item)\" in \(describe(popup))") }
            return outcome
        }
        try popup.perform(kAXPressAction)
        var found: Element?
        _ = wait { found = popup.first(budget: 200) { $0.role == kAXMenuItemRole && $0.title == item }
                   return found != nil }
        guard let found else {
            try? popup.first(budget: 50) { $0.role == kAXMenuRole }?.perform(kAXCancelAction)
            throw AXKitError.ax(.failure, "no item \"\(item)\" in \(describe(popup))")
        }
        try found.perform(kAXPressAction)
        let ok = wait { popup.valueText == item }
        let outcome = Outcome(before: before, after: popup.valueText, method: "AXPress, AXPress item",
                              verified: ok)
        if !ok { throw AXKitError.notApplied("choose \"\(item)\" in \(describe(popup))") }
        return outcome
    }

    /// A menu bar item by its path, e.g. ["File", "Export", "PDF…"]. The leaf
    /// takes AXPress with every menu closed, so nothing opens on screen.
    @discardableResult
    public static func menu(_ path: [String], in app: App) throws -> Outcome {
        guard let bar = app.element.element(kAXMenuBarAttribute) else {
            throw AXKitError.ax(.failure, "\(app.name ?? "the app") has no menu bar")
        }
        var current = bar
        for (index, title) in path.enumerated() {
            let wanted = index == 0 ? kAXMenuBarItemRole : kAXMenuItemRole
            guard let next = current.first(budget: 400, where: { $0.role == wanted && $0.title == title })
            else { throw AXKitError.ax(.failure, "no menu item \"\(path[...index].joined(separator: " > "))\"") }
            current = next
        }
        try current.perform(kAXPressAction)
        return Outcome(before: nil, after: nil, method: "AXPress \(path.joined(separator: " > "))",
                       verified: nil)
    }

    /// An outline row, opened or closed. `AXExpanded` is ignored by
    /// NSOutlineView; `AXDisclosing` works.
    @discardableResult
    public static func disclose(_ open: Bool, _ row: Element) throws -> Outcome {
        let before = row.bool(kAXDisclosingAttribute)
        guard before != open else {
            return Outcome(before: before.map(String.init), after: before.map(String.init),
                           method: "none, already \(open ? "open" : "closed")", verified: true)
        }
        try row.set(kAXDisclosingAttribute, to: open as CFBoolean)
        let ok = wait { row.bool(kAXDisclosingAttribute) == open }
        let outcome = Outcome(before: before.map(String.init), after: row.bool(kAXDisclosingAttribute).map(String.init),
                              method: "set AXDisclosing", verified: ok)
        if !ok { throw AXKitError.notApplied("\(open ? "open" : "close") \(describe(row))") }
        return outcome
    }

    /// Rows of a table or outline, by index, selected on the table. A row's
    /// own `AXSelected` is ignored by NSTableView.
    @discardableResult
    public static func select(rows indexes: [Int], in table: Element) throws -> Outcome {
        let rows = table.elements(kAXRowsAttribute)
        guard indexes.allSatisfy({ rows.indices.contains($0) }) else {
            throw AXKitError.ax(.illegalArgument, "rows \(indexes) of \(rows.count)")
        }
        let chosen = indexes.map { rows[$0] }
        let current = { Set(table.elements(kAXSelectedRowsAttribute)) }
        let before = current()
        try table.set(kAXSelectedRowsAttribute, to: chosen.map(\.ref) as CFArray)
        let ok = wait { current() == Set(chosen) }
        let outcome = Outcome(before: "\(before.count) rows", after: "\(current().count) rows",
                              method: "set AXSelectedRows", verified: ok)
        if !ok { throw AXKitError.notApplied("select rows \(indexes) of \(describe(table))") }
        return outcome
    }

    /// Everything the field holds replaced by typing: select-all through
    /// accessibility, then the text as keys to the field's process.
    @discardableResult
    public static func typeText(_ text: String, into element: Element, route: Input.Route) throws -> Outcome {
        let before = element.valueText
        guard Input.prepare(element) else { throw AXKitError.ax(.cannotComplete, "focus \(describe(element))") }
        try Input.selectAll(element)
        try Input.type(text, to: route)
        let ok = wait { element.valueText == text }
        let outcome = Outcome(before: before, after: element.valueText, method: "select all, keys", verified: ok)
        if !ok { throw AXKitError.notApplied("type into \(describe(element))") }
        return outcome
    }

    static func stepTo(_ number: Double, _ element: Element) throws -> Outcome {
        let before = element.valueText
        let read = { (element.value as? NSNumber)?.doubleValue ?? Double(element.valueText ?? "") }
        var steps = 0
        while let now = read(), now != number, steps < 200 {
            try element.perform(now < number ? kAXIncrementAction : kAXDecrementAction)
            steps += 1
            guard wait({ read() != now }) else { break }
            if let after = read(), (now < number) != (after < number), after != number { break }
        }
        let ok = read() == number
        let outcome = Outcome(before: before, after: element.valueText, method: "steps ×\(steps)", verified: ok)
        if !ok { throw AXKitError.notApplied("step \(describe(element)) to \(number)") }
        return outcome
    }

    /// A page's date or time input takes only keys. Measured 09-28 in
    /// Chrome: the field and its parts (Day, Month, Year, Hours, Minutes)
    /// ignore AXValue, as a number or as text, and AXIncrement, focused or
    /// not, while every call returns success. So the first part is focused
    /// and the parts are typed in the order the field shows them.
    static func setPageDate(_ date: Date, on field: Element, keys: Bool) throws -> Outcome {
        let before = field.valueText
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let numbers: [String: Int] = ["Day": parts.day ?? 0, "Month": parts.month ?? 0, "Year": parts.year ?? 0,
                                      "Hours": parts.hour ?? 0, "Minutes": parts.minute ?? 0]
        var shown: [(Element, Int)] = []
        var queue = field.children
        while !queue.isEmpty {
            let element = queue.removeFirst()
            if element.role == kAXIncrementorRole,
               let label = numbers.keys.first(where: { (element.title ?? "").hasPrefix($0) }) {
                shown.append((element, numbers[label]!))
            } else {
                queue.insert(contentsOf: element.children, at: 0)
            }
        }
        guard let first = shown.first?.0, let pid = field.pid else {
            throw AXKitError.ax(.failure, "no parts in \(describe(field))")
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = field.role == "AXTimeField" ? "HH:mm"
            : shown.count > 3 ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
        let expected = format.string(from: date)

        guard keys else {
            throw AXKitError.notApplied("\(describe(field)) takes only keys: a page's date parts ignore "
                                        + "AXValue and AXIncrement, focused or not")
        }
        guard Input.prepare(first) else { throw AXKitError.ax(.cannotComplete, "focus \(describe(first))") }
        let route = Input.Route.process(pid)
        // A full day, month, hour or minute moves to the next part by itself;
        // a year does not, as it takes up to 6 digits.
        for (index, part) in shown.enumerated() {
            let isYear = (part.0.title ?? "").hasPrefix("Year")
            try Input.type(isYear ? String(part.1) : String(format: "%02d", part.1), to: route)
            if isYear && index < shown.count - 1 { try Input.press(.right, to: route) }
        }
        // The field's own value can lag behind; its parts are read instead.
        let partsHold = { shown.allSatisfy { Int($0.0.valueText ?? "") == $0.1 } }
        let ok = wait { field.valueText == expected || partsHold() }
        let partsNow = shown.map { "\($0.0.title?.split(separator: " ").first ?? "?")=\($0.0.valueText ?? "?")" }
        let outcome = Outcome(before: before, after: field.valueText, method: "keys, part by part", verified: ok)
        if !ok {
            throw AXKitError.notApplied("type the date of \(describe(field)): it shows \(field.valueText ?? "nothing"), "
                                        + "parts \(partsNow.joined(separator: " "))")
        }
        return outcome
    }

    /// The menu bar item whose shortcut is ⌘ plus `letter`, whatever the
    /// app's language: "Paste" and "Coller" are both ⌘V. Pressing it through
    /// accessibility needs no key and works with the app in the background.
    public static func menuItem(shortcut letter: Character, in app: App) -> Element? {
        guard let bar = app.element.element(kAXMenuBarAttribute) else { return nil }
        let wanted = String(letter).uppercased()
        return bar.first(budget: 3000) {
            $0.role == kAXMenuItemRole && $0.string(kAXMenuItemCmdCharAttribute)?.uppercased() == wanted
                // 0: ⌘ alone, with no Shift, Option or Control.
                && ($0.attribute(kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 0
        }
    }

    /// Inserts text at the caret, replacing the selection, as a paste would,
    /// through accessibility: no pasteboard and no key, so it works with the
    /// app in the background.
    @discardableResult
    public static func insert(_ text: String, into element: Element) throws -> Outcome {
        let before = element.valueText
        guard Input.prepare(element) else { throw AXKitError.ax(.cannotComplete, "focus \(describe(element))") }
        try element.set(kAXSelectedTextAttribute, to: text as NSString)
        let ok = wait { (element.valueText ?? "").contains(text) }
        let outcome = Outcome(before: before, after: element.valueText, method: "set AXSelectedText", verified: ok)
        if !ok { throw AXKitError.notApplied("insert into \(describe(element))") }
        return outcome
    }

    /// Pastes files into a field, as attachments in Slack, Teams and Gmail
    /// composers. No accessibility call inserts a file, and an app in the
    /// background does not enable its Paste item (measured 09-28), so this
    /// is a foreground step: the app comes in front for the ⌘V, then the
    /// app that was in front comes back. What the pasteboard held is put
    /// back. What the paste produces depends on the app: the caller checks.
    @discardableResult
    public static func paste(files: [URL], into element: Element) throws -> Outcome {
        guard let pid = element.pid else { throw AXKitError.ax(.invalidUIElement, "no process") }
        let app = App(pid: pid)
        let saved = Clipboard.save()
        let front = App.frontmost
        defer {
            // The app reads the pasteboard while it handles the paste.
            Thread.sleep(forTimeInterval: 0.3)
            Clipboard.restore(saved)
            if let front, front.pid != pid { front.activate() }
        }
        Clipboard.put(files: files)
        guard Input.prepare(element) else { throw AXKitError.ax(.cannotComplete, "focus \(describe(element))") }
        if let item = menuItem(shortcut: "v", in: app), item.isEnabled == true {
            try item.perform(kAXPressAction)
            return Outcome(before: nil, after: nil, method: "the ⌘V menu item", verified: nil)
        }
        guard app.activate() else { throw Input.Refusal.notFrontmost(expected: pid, actual: App.frontmost?.pid) }
        try Input.shortcut("v", .command, to: .frontmost(pid))
        return Outcome(before: nil, after: nil, method: "in front, ⌘V", verified: nil)
    }

    public enum DateOrder: String, Sendable {
        case dmy, mdy, ymd

        /// The order of this Mac's region, which is what a native picker
        /// without its own locale shows.
        public static var region: DateOrder {
            let format = DateFormatter.dateFormat(fromTemplate: "ddMMyyyy", options: 0, locale: .current) ?? ""
            let day = format.firstIndex(of: "d"), month = format.firstIndex(of: "M"),
                year = format.firstIndex(of: "y")
            guard let day, let month, let year else { return .dmy }
            if year < month { return .ymd }
            return day < month ? .dmy : .mdy
        }
    }

    /// The keyboard way into a native date or time picker, for when a value
    /// set is refused. Focus by accessibility lands on an arbitrary part (the
    /// year became 0012), so Left is pressed until the first part, then each
    /// part is typed with Right between. `clock24: false` types the hour on
    /// 12 hours and then A or P.
    @discardableResult
    public static func typeDate(_ date: Date, on element: Element, order: DateOrder = .region,
                                time: Bool = false, clock24: Bool = true,
                                route: Input.Route) throws -> Outcome {
        let area = element.role == "AXDateTimeArea" ? element
            : element.first(budget: 50) { $0.role == "AXDateTimeArea" } ?? element
        let before = area.value as? Date
        guard Input.prepare(area) else { throw AXKitError.ax(.cannotComplete, "focus \(describe(area))") }
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        var fields: [String]
        if time {
            let hour = parts.hour ?? 0
            fields = [two(clock24 ? hour : (hour % 12 == 0 ? 12 : hour % 12)), two(parts.minute)]
            if !clock24 { fields.append(hour < 12 ? "A" : "P") }
        } else {
            let (d, m, y) = (two(parts.day), two(parts.month), String(parts.year ?? 0))
            switch order {
            case .dmy: fields = [d, m, y]
            case .mdy: fields = [m, d, y]
            case .ymd: fields = [y, m, d]
            }
        }
        try Input.press(Array(repeating: .left, count: 6), to: route)
        for (index, field) in fields.enumerated() {
            if index > 0 { try Input.press(.right, to: route) }
            try Input.type(field, to: route)
        }
        try Input.press(.tab, to: route)
        let wanted: Set<Calendar.Component> = time ? [.hour, .minute] : [.year, .month, .day]
        let ok = wait {
            guard let now = area.value as? Date else { return false }
            return Calendar.current.dateComponents(wanted, from: now)
                == Calendar.current.dateComponents(wanted, from: date)
        }
        let outcome = Outcome(before: before.map(iso), after: (area.value as? Date).map(iso),
                              method: "keys \(fields.joined(separator: " → "))", verified: ok)
        if !ok { throw AXKitError.notApplied("type the \(time ? "time" : "date") of \(describe(area))") }
        return outcome
    }

    // MARK: -

    static func wait(_ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(settle)
        while Date() < end {
            if done() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return done()
    }

    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func describe(_ element: Element) -> String {
        "\(element.role ?? "?") \"\(element.name ?? element.identifier ?? "")\""
    }
}
