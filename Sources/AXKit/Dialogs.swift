import AppKit
import ApplicationServices

/// A dialog waiting for an answer: a sheet on a window, an alert window, or a
/// dialog inside a page. Its buttons are known by what they do, not by their
/// words, so "Save" and "Enregistrer" are both the default button.
public struct Dialog {
    public let element: Element
    /// "sheet", "alert" (a window of its own) or "page".
    public let kind: String
    /// The text it shows, message first.
    public let text: [String]
    public let buttons: [Element]
    /// The button Return presses.
    public let defaultButton: Element?
    /// The button Escape presses.
    public let cancelButton: Element?

    public enum Answer {
        case confirm, cancel
        /// Neither the default nor the cancel button: "Don't Save" in a save alert.
        case other
        case titled(String)
    }

    public var titles: [String] { buttons.map { $0.title ?? $0.name ?? "" } }
}

public enum Dialogs {
    /// The dialog the app shows now, if any: sheets first, then alert
    /// windows, then dialogs in pages.
    public static func current(in app: App) -> Dialog? {
        for window in app.windows {
            for sheet in window.children where sheet.role == kAXSheetRole {
                return dialog(sheet, kind: "sheet")
            }
        }
        for window in app.windows where ["AXDialog", "AXSystemDialog"].contains(window.subrole ?? "") {
            return dialog(window, kind: "alert")
        }
        for window in app.windows {
            if let page = window.first(budget: 5000, where: {
                $0.subrole == "AXApplicationDialog" || $0.subrole == "AXApplicationAlertDialog"
            }) {
                return dialog(page, kind: "page")
            }
        }
        return nil
    }

    /// A window read as a dialog: its text and its buttons.
    public static func dialogFor(_ window: Element) -> Dialog { dialog(window, kind: "alert") }

    static func dialog(_ element: Element, kind: String) -> Dialog {
        var texts: [String] = []
        var buttons: [Element] = []
        var queue = element.children
        var left = 2000
        while !queue.isEmpty, left > 0 {
            let child = queue.removeFirst()
            left -= 1
            if child.role == kAXButtonRole, child.subrole == nil || child.subrole == "AXDefaultButton" {
                buttons.append(child)
            } else if child.role == kAXStaticTextRole, let text = child.valueText, !text.isEmpty {
                texts.append(text)
            } else {
                queue.append(contentsOf: child.children)
            }
        }
        let host = kind == "sheet" || kind == "alert" ? element : element.window
        return Dialog(element: element, kind: kind, text: texts, buttons: buttons,
                      defaultButton: host?.element(kAXDefaultButtonAttribute),
                      cancelButton: host?.element(kAXCancelButtonAttribute))
    }

    /// Presses the button for `answer` and waits for the dialog to go.
    @discardableResult
    public static func answer(_ answer: Dialog.Answer, to dialog: Dialog, in app: App) throws -> Outcome {
        let button: Element?
        switch answer {
        case .confirm: button = dialog.defaultButton
        case .cancel: button = dialog.cancelButton
        case .other: button = dialog.buttons.first { $0 != dialog.defaultButton && $0 != dialog.cancelButton }
        case .titled(let title): button = dialog.buttons.first { Glob.matches(title, $0.title ?? $0.name ?? "") }
        }
        guard let button else {
            throw AXKitError.ax(.failure, "no button for \(answer) among \(dialog.titles)")
        }
        let name = button.title ?? button.name ?? "?"
        try button.perform(kAXPressAction)
        let gone = Wait.until(app, timeout: 2) {
            (try? dialog.element.read(kAXRoleAttribute)) == nil || dialog.element.role == nil
        }
        if !gone { throw AXKitError.notApplied("press \"\(name)\": the dialog is still there") }
        return Outcome(before: dialog.text.first, after: nil, method: "pressed \"\(name)\"", verified: true)
    }
}
