import AppKit

/// Native AppKit controls in one window, for probing what accessibility can do
/// with each. `AXKitFixtures [seconds] [--state <path>]`.
///
/// Every control's value goes to a JSON file on each change. That file is the
/// ground truth, independent of what AX reports.
@MainActor
final class ControlsSurface: NSObject {
    let statePath: String
    private(set) var window: NSWindow!
    private var values: [String: Any] = [:]
    private var via: [String: String] = [:]
    private var pollers: [String: () -> Any] = [:]
    private var poll: Timer?
    private var counts: [String: Int] = [:]
    private var showGrid = false
    private var sheet: NSWindow?
    private var popover: NSPopover?
    private var popoverCheck = false

    private let outlineData: [(String, [String])] = [
        ("Fruits", ["Apple", "Pear"]),
        ("Tools", ["Hammer", "Saw"]),
    ]
    private let tableData: [(String, String)] = [
        ("alpha.txt", "12 KB"), ("beta.png", "340 KB"),
        ("gamma.pdf", "1.2 MB"), ("delta.csv", "8 KB"),
    ]
    private lazy var outlineChildren: [[NSString]] = outlineData.map { $0.1.map { $0 as NSString } }
    private var outline: NSOutlineView!
    private var table: NSTableView!

    static let timeZone = TimeZone(identifier: "Europe/Paris")!

    /// For layout checks: several windows by title, one with a minimum
    /// size, one that ignores moves as the Finder did.
    var title = "Controls"
    var minimum: NSSize?
    var refusesMoves = false

    init(statePath: String) {
        self.statePath = statePath
    }

    static var defaultStatePath: String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("axkit-controls.json")
    }

    /// `background`: the window goes behind every other and the app does not
    /// take the focus, so a check can run while someone works.
    func show(background: Bool = false) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = menu()

        let left = NSStackView()
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 8
        let right = NSStackView()
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 8

        var start = DateComponents()
        start.calendar = Calendar(identifier: .gregorian)
        start.timeZone = Self.timeZone
        (start.year, start.month, start.day, start.hour, start.minute) = (2026, 10, 15, 14, 30)
        let initial = start.date!

        let pickers: [(String, String, NSDatePicker.ElementFlags, NSDatePicker.Style)] = [
            ("fr_date", "fr_FR", .yearMonthDay, .textFieldAndStepper),
            ("fr_time", "fr_FR", .hourMinute, .textFieldAndStepper),
            ("fr_datetime", "fr_FR", [.yearMonthDay, .hourMinute], .textFieldAndStepper),
            ("fr_date_field", "fr_FR", .yearMonthDay, .textField),
            ("fr_time_field", "fr_FR", .hourMinute, .textField),
            ("en_date", "en_US", .yearMonthDay, .textFieldAndStepper),
            ("en_time", "en_US", .hourMinute, .textFieldAndStepper),
            ("en_datetime_field", "en_US", [.yearMonthDay, .hourMinute], .textField),
        ]
        for (name, locale, elements, style) in pickers {
            let picker = NSDatePicker()
            picker.datePickerStyle = style
            picker.datePickerElements = elements
            picker.locale = Locale(identifier: locale)
            picker.calendar = Calendar(identifier: .gregorian)
            picker.timeZone = Self.timeZone
            picker.dateValue = initial
            picker.isBezeled = true
            picker.drawsBackground = true
            left.addArrangedSubview(row(name, picker) { [unowned picker] in Self.iso(picker.dateValue) })
        }

        let popup = NSPopUpButton()
        popup.addItems(withTitles: ["None", "5 minutes", "15 minutes", "1 hour"])
        popup.selectItem(at: 2)
        left.addArrangedSubview(row("reminder", popup) { [unowned popup] in popup.titleOfSelectedItem ?? "" })

        let combo = NSComboBox()
        combo.addItems(withObjectValues: ["Room A", "Room B", "Room C", "Online"])
        combo.stringValue = "Room A"
        combo.delegate = self
        combo.widthAnchor.constraint(equalToConstant: 160).isActive = true
        left.addArrangedSubview(row("room", combo) { [unowned combo] in combo.stringValue })

        let slider = NSSlider(value: 40, minValue: 0, maxValue: 100, target: nil, action: nil)
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        left.addArrangedSubview(row("volume", slider) { [unowned slider] in slider.doubleValue })

        let stepper = NSStepper()
        (stepper.minValue, stepper.maxValue, stepper.increment, stepper.integerValue) = (0, 10, 1, 3)
        let stepLabel = NSTextField(labelWithString: "3")
        let stepRow = row("guests", stepper, extra: stepLabel) { [unowned stepper] in stepper.integerValue }
        left.addArrangedSubview(stepRow)
        pollers["guests_label"] = { [unowned stepper, unowned stepLabel] in
            stepLabel.stringValue = "\(stepper.integerValue)"
            return stepLabel.stringValue
        }

        let toggle = NSSwitch()
        left.addArrangedSubview(row("online", toggle) { [unowned toggle] in toggle.state == .on })

        let check = NSButton(checkboxWithTitle: "Private", target: nil, action: nil)
        right.addArrangedSubview(row("private", check) { [unowned check] in check.state == .on })

        let radios = ["Busy", "Free", "Tentative"].map {
            NSButton(radioButtonWithTitle: $0, target: nil, action: nil)
        }
        radios[0].state = .on
        let radioStack = NSStackView(views: radios)
        radioStack.orientation = .horizontal
        for button in radios {
            button.target = self
            button.action = #selector(changed(_:))
            button.identifier = NSUserInterfaceItemIdentifier("show_as_\(button.title.lowercased())")
        }
        right.addArrangedSubview(labelled("show_as", radioStack))
        pollers["show_as"] = { radios.first { $0.state == .on }?.title ?? "" }

        let segments = NSSegmentedControl(labels: ["Day", "Week", "Month"],
                                          trackingMode: .selectOne, target: nil, action: nil)
        segments.selectedSegment = 1
        right.addArrangedSubview(row("view", segments) { [unowned segments] in
            segments.selectedSegment >= 0 ? segments.label(forSegment: segments.selectedSegment) ?? "" : ""
        })

        let notes = NSTextField(string: "")
        notes.placeholderString = "Stray keystrokes land here"
        notes.widthAnchor.constraint(equalToConstant: 220).isActive = true
        notes.delegate = self
        right.addArrangedSubview(row("notes", notes) { [unowned notes] in notes.stringValue })

        let zone = FileZone()
        zone.identifier = NSUserInterfaceItemIdentifier("file_zone")
        zone.setAccessibilityLabel("Attach files")
        zone.received = { [unowned self] how, names in self.set(how, names, via: "action") }
        var dragSeen: [String] = []
        zone.seen = { [unowned self] call in
            if dragSeen.last != call { dragSeen.append(call) }
            self.set("drag_seen", dragSeen, via: "action")
        }
        let zoneScroll = NSScrollView()
        zoneScroll.documentView = zone
        zoneScroll.hasVerticalScroller = true
        zoneScroll.borderType = .bezelBorder
        zoneScroll.widthAnchor.constraint(equalToConstant: 220).isActive = true
        zoneScroll.heightAnchor.constraint(equalToConstant: 44).isActive = true
        zone.autoresizingMask = [.width]
        zone.frame = NSRect(x: 0, y: 0, width: 220, height: 44)
        right.addArrangedSubview(labelled("file_zone", zoneScroll))

        outline = NSOutlineView()
        let outlineColumn = NSTableColumn(identifier: .init("name"))
        outlineColumn.title = "Name"
        outlineColumn.width = 200
        outline.addTableColumn(outlineColumn)
        outline.outlineTableColumn = outlineColumn
        outline.dataSource = self
        outline.delegate = self
        outline.identifier = NSUserInterfaceItemIdentifier("tree")
        outline.headerView = nil
        right.addArrangedSubview(labelled("tree", scrolled(outline, height: 130)))
        pollers["tree_expanded"] = { [unowned self] in
            outlineData.indices.filter { outline.isItemExpanded($0 as NSNumber) }.map { outlineData[$0].0 }
        }
        pollers["tree_selected"] = { [unowned self] in
            outline.selectedRow < 0 ? "" : title(outline.item(atRow: outline.selectedRow))
        }

        table = NSTableView()
        for (id, title) in [("name", "Name"), ("size", "Size")] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = 110
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.identifier = NSUserInterfaceItemIdentifier("files")
        right.addArrangedSubview(labelled("files", scrolled(table, height: 120)))
        pollers["files_selected"] = { [unowned self] in table.selectedRowIndexes.map { tableData[$0].0 } }

        let sheetButton = NSButton(title: "Open sheet…", target: self, action: #selector(openSheet))
        sheetButton.identifier = NSUserInterfaceItemIdentifier("open_sheet")
        let popoverButton = NSButton(title: "Open popover…", target: self, action: #selector(openPopover(_:)))
        popoverButton.identifier = NSUserInterfaceItemIdentifier("open_popover")
        let alertButton = NSButton(title: "Close draft…", target: self, action: #selector(openAlert))
        alertButton.identifier = NSUserInterfaceItemIdentifier("close_draft")
        let buttons = NSStackView(views: [sheetButton, popoverButton, alertButton])
        right.addArrangedSubview(buttons)

        let columns = NSStackView(views: [left, right])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 24
        columns.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let stubborn = StubbornWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                      backing: .buffered, defer: false)
        stubborn.refusesMoves = refusesMoves
        window = stubborn
        window.title = title
        if let minimum { window.contentMinSize = minimum }
        window.isReleasedWhenClosed = false
        window.contentView = columns
        window.center()
        if background {
            window.orderBack(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }

        values["sheet"] = "closed"
        values["popover"] = "closed"
        values["popover_check"] = false
        values["export_pdf"] = 0
        values["export_csv"] = 0
        values["show_grid"] = false
        values["alert"] = "closed"
        values["pasted_files"] = [String]()
        values["dropped_files"] = [String]()
        refresh(source: "start")
        poll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(source: "poll") }
        }
    }

    // MARK: layout

    private func row(_ name: String, _ control: NSControl, extra: NSView? = nil,
                     read: @escaping () -> Any) -> NSView {
        control.identifier = NSUserInterfaceItemIdentifier(name)
        control.target = self
        control.action = #selector(changed(_:))
        pollers[name] = read
        let views = extra.map { [control, $0] } ?? [control]
        let inner = NSStackView(views: views)
        inner.orientation = .horizontal
        return labelled(name, inner)
    }

    private func labelled(_ name: String, _ view: NSView) -> NSView {
        let label = NSTextField(labelWithString: name)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let stack = NSStackView(views: [label, view])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        return stack
    }

    private func scrolled(_ view: NSTableView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 240).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    private func menu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Controls", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let file = NSMenu(title: "File")
        let export = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        let exportMenu = NSMenu(title: "Export")
        let pdf = NSMenuItem(title: "PDF…", action: #selector(exportPDF), keyEquivalent: "")
        pdf.target = self
        exportMenu.addItem(pdf)
        let csv = NSMenuItem(title: "CSV…", action: #selector(exportCSV), keyEquivalent: "")
        csv.target = self
        exportMenu.addItem(csv)
        export.submenu = exportMenu
        file.addItem(export)
        let grid = NSMenuItem(title: "Show Grid", action: #selector(toggleGrid(_:)), keyEquivalent: "")
        grid.target = self
        file.addItem(grid)
        fileItem.submenu = file
        main.addItem(fileItem)

        // What every real app has: ⌘C and ⌘V are these items, not keys.
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    // MARK: actions

    @objc private func changed(_ sender: NSControl) {
        refresh(source: "action")
    }

    @objc private func exportPDF() { bump("export_pdf") }
    @objc private func exportCSV() { bump("export_csv") }

    private func bump(_ key: String) {
        counts[key, default: 0] += 1
        set(key, counts[key]!, via: "action")
    }

    @objc private func toggleGrid(_ item: NSMenuItem) {
        showGrid.toggle()
        item.state = showGrid ? .on : .off
        set("show_grid", showGrid, via: "action")
    }

    /// What closing an unsaved draft asks, in the words the Mac uses.
    @objc private func openAlert() {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to the draft?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        set("alert", "open", via: "action")
        alert.beginSheetModal(for: window) { [weak self] response in
            let answer = [NSApplication.ModalResponse.alertFirstButtonReturn: "save",
                          .alertSecondButtonReturn: "cancel", .alertThirdButtonReturn: "dont_save"][response] ?? "other"
            MainActor.assumeIsolated { self?.set("alert", answer, via: "action") }
        }
    }

    @objc private func openSheet() {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 110),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let text = NSTextField(labelWithString: "Apply the changes?")
        let ok = NSButton(title: "OK", target: self, action: #selector(sheetOK))
        ok.keyEquivalent = "\r"
        ok.identifier = NSUserInterfaceItemIdentifier("sheet_ok")
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(sheetCancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.identifier = NSUserInterfaceItemIdentifier("sheet_cancel")
        let buttons = NSStackView(views: [cancel, ok])
        let stack = NSStackView(views: [text, buttons])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        sheet.contentView = stack
        self.sheet = sheet
        window.beginSheet(sheet)
        set("sheet", "open", via: "action")
    }

    @objc private func sheetOK() { closeSheet("ok") }
    @objc private func sheetCancel() { closeSheet("cancel") }

    private func closeSheet(_ answer: String) {
        guard let sheet else { return }
        window.endSheet(sheet)
        self.sheet = nil
        set("sheet", answer, via: "action")
    }

    @objc private func openPopover(_ sender: NSButton) {
        let content = NSViewController()
        let check = NSButton(checkboxWithTitle: "Remind me", target: self, action: #selector(popoverToggled(_:)))
        check.identifier = NSUserInterfaceItemIdentifier("popover_check")
        check.state = popoverCheck ? .on : .off
        let stack = NSStackView(views: [NSTextField(labelWithString: "Popover"), check])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        content.view = stack
        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        set("popover", "shown", via: "action")
    }

    @objc private func popoverToggled(_ sender: NSButton) {
        popoverCheck = sender.state == .on
        set("popover_check", popoverCheck, via: "action")
    }

    // MARK: ground truth

    private func set(_ key: String, _ value: Any, via source: String) {
        values[key] = value
        via[key] = source
        write()
    }

    /// Reads every control and writes when anything differs. Polling catches a
    /// change that did not fire the control's action, which an AX set can do.
    private func refresh(source: String) {
        var changed = false
        for (key, read) in pollers {
            let value = read()
            if !Self.same(values[key], value) {
                values[key] = value
                via[key] = source
                changed = true
            }
        }
        if changed || source == "start" { write() }
    }

    private func write() {
        var object = values
        object["via"] = via
        object["timestamp"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        else { return }
        let url = URL(fileURLWithPath: statePath)
        try? data.write(to: url, options: .atomic)
    }

    private static func same(_ a: Any?, _ b: Any) -> Bool {
        guard let a else { return false }
        return (a as? NSObject)?.isEqual(b) ?? false
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    private func title(_ item: Any?) -> String {
        if let index = item as? NSNumber { return outlineData[index.intValue].0 }
        if let child = item as? NSString { return child as String }
        return ""
    }
}

extension ControlsSurface: NSComboBoxDelegate, NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        refresh(source: "action")
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        // The combo's string updates after this notification.
        DispatchQueue.main.async { self.refresh(source: "action") }
    }
}

extension ControlsSurface: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        set("popover", "closed", via: "action")
    }
}

extension ControlsSurface: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return outlineData.count }
        if let index = item as? NSNumber { return outlineData[index.intValue].1.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return NSNumber(value: index) }
        let parent = (item as! NSNumber).intValue
        return outlineChildren[parent][index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is NSNumber
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        NSTextField(labelWithString: title(item))
    }

    func outlineViewSelectionDidChange(_ notification: Notification) { refresh(source: "action") }
    func outlineViewItemDidExpand(_ notification: Notification) { refresh(source: "action") }
    func outlineViewItemDidCollapse(_ notification: Notification) { refresh(source: "action") }
}

extension ControlsSurface: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { tableData.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = tableData[row]
        return NSTextField(labelWithString: tableColumn?.identifier.rawValue == "size" ? entry.1 : entry.0)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refresh(source: "action") }
}


/// Takes files pasted into it or dropped on it, like a composer that turns
/// them into attachments, and says which.
final class FileZone: NSTextView {
    var received: ((String, [String]) -> Void)?
    /// Which drag calls reached the view, for a check to read.
    var seen: ((String) -> Void)?

    convenience init() {
        self.init(frame: .zero)
        updateDragTypeRegistration()
    }

    private func files(_ board: NSPasteboard) -> [String] {
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).map(\.lastPathComponent)
    }

    override func paste(_ sender: Any?) {
        let names = files(.general)
        if names.isEmpty { super.paste(sender) } else { received?("pasted_files", names) }
    }

    // A plain-text view does not take file URLs, and answers each move
    // over it itself: all three must say yes to a file.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL]
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        seen?("entered")
        return files(sender.draggingPasteboard).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        seen?("updated")
        return files(sender.draggingPasteboard).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        seen?("prepare")
        return files(sender.draggingPasteboard).isEmpty ? super.prepareForDragOperation(sender) : true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        seen?("perform")
        let names = files(sender.draggingPasteboard)
        guard !names.isEmpty else { return super.performDragOperation(sender) }
        received?("dropped_files", names)
        return true
    }
}


/// A window that keeps its place when told to move, as the Finder did on
/// 09-28, while taking a new size.
final class StubbornWindow: NSWindow {
    var refusesMoves = false

    override func setFrameOrigin(_ point: NSPoint) {
        if !refusesMoves { super.setFrameOrigin(point) }
    }

    override func setFrame(_ rect: NSRect, display: Bool) {
        guard refusesMoves, isVisible else { return super.setFrame(rect, display: display) }
        super.setFrame(NSRect(x: frame.minX, y: frame.maxY - rect.height, width: rect.width, height: rect.height),
                       display: display)
    }
}
