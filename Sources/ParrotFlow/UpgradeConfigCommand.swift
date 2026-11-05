import Foundation

/// `--upgrade-config [path] [--write]` — what `ConfigMigration` would change in
/// a config, as a diff. `--write` makes the change, after a backup.
///
/// The app runs the same upgrade at launch. This is the way to see it first,
/// or to run it on a file the app does not read.
enum UpgradeConfigCommand {

    static func run(path: String?, write: Bool) -> Int32 {
        let url = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? ConfigStore.fileURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("✗ \(url.path) could not be read")
            return 1
        }
        let plan: ConfigMigration.Plan
        do {
            plan = try ConfigMigration.plan(text, directory: url.deletingLastPathComponent())
        } catch ConfigMigration.Failure.newer(let version) {
            print("· \(url.path) is version \(version), newer than this app"
                + " (\(ConfigMigration.current)). Left as it is")
            return 0
        } catch {
            print("✗ \(url.path) was not upgraded — \(error.localizedDescription)")
            return 1
        }
        guard plan.changes else {
            print("✓ \(url.path) is version \(plan.from). Nothing to upgrade")
            return 0
        }
        print("\(url.path): version \(plan.from) -> \(plan.to)")
        for step in plan.steps { print("  \(step.version)  \(step.summary)") }
        print("--- \(url.lastPathComponent)")
        print("+++ \(url.lastPathComponent)")
        ConfigMigration.diff(ConfigMigration.lines(plan.before), ConfigMigration.lines(plan.after))
            .forEach { print($0) }
        guard write else {
            print("· not written. Add --write to make the change")
            return 0
        }
        do {
            guard let written = try ConfigMigration.upgrade(at: url) else { return 0 }
            print("✓ written. The old file is \(written.backup.path)")
            return 0
        } catch {
            print("✗ not written — \(error.localizedDescription)")
            return 1
        }
    }
}
