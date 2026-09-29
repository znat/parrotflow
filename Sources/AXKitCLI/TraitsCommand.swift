import AXKit
import Foundation

/// `axkit traits`: the declared traits, as a table or JSON.
enum TraitsCommand {
    static func run(_ arguments: [String], bundle: String?, json: Bool) -> Int32 {
        var names = arguments.filter { !$0.hasPrefix("--") }
        if let bundle { names.removeAll { $0 == bundle } }
        var operations: [Gesture] = []
        for name in names {
            guard let operation = Gesture(rawValue: name) else {
                fail("no gesture \"\(name)\"; one of: \(Gesture.allCases.map(\.rawValue).joined(separator: ", "))", 2)
            }
            operations.append(operation)
        }
        let kind: App.Pages? = bundle.map { bundle in App.named(bundle).map(\.pages) ?? App.pages(bundle: bundle) }
        let pages = kind.map { $0 != .none }
        let listed = operations.isEmpty ? Gesture.allCases : operations
        let rows = listed.map { gesture in (gesture, kind.map { gesture.traits(for: $0) } ?? gesture.native, gesture.page) }
        if json {
            struct Row: Encodable { let gesture: String; let native: Traits; let page: Traits }
            struct Out: Encodable { let bundle: String?; let pages: Bool?; let gestures: [Row]; let together: Traits?
                                    let warnings: [String]? }
            let together = operations.isEmpty ? nil : Traits.combined(rows.map { $0.1 })
            printJSON(Out(bundle: bundle, pages: pages, gestures: rows.map { Row(gesture: $0.0.rawValue, native: $0.0.native, page: $0.2) },
                          together: together, warnings: together?.warnings))
            return 0
        }
        if let bundle { print("\(bundle): \(["all": "web pages", "some": "native, with web pages in it", "none": "native"][kind!.rawValue]!)") }
        let header = ["gesture", "front", "hands off", "clipboard", "retry", "reads back", "reversible", "stale after"]
        let table = rows.map { operation, traits, _ -> [String] in
            [operation.rawValue, traits.front.rawValue, traits.handsOff.rawValue, traits.borrowsClipboard ? "borrowed" : "-",
             traits.safeToRetry ? "safe" : "no", traits.readsBack ? "yes" : "no", traits.reversible.rawValue,
             traits.invalidatesElements ? "yes" : "-"]
        }
        let widths = header.indices.map { column in ([header] + table).map { $0[column].count }.max()! }
        for row in [header] + table {
            print(zip(row, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }.joined(separator: "  "))
        }
        if bundle == nil { print("-- native traits; --bundle <id> gives an app's, pages or not") }
        if !operations.isEmpty {
            let warnings = Traits.combined(rows.map { $0.1 }).warnings
            print("together: \(warnings.isEmpty ? "runs in the background, nothing asked of the user" : warnings.joined(separator: "; "))")
        }
        return 0
    }
}
