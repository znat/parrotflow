import Foundation

/// `--seed-config` — write the files a first launch writes, and say which.
///
/// The app does this at startup and has always done it silently, which left
/// "what does a new install actually get" as a question you could only answer
/// by deleting your own config. It is now a folder rather than two loose files,
/// so the answer is worth being able to see, and worth a check script being
/// able to assert.
///
/// Nothing is ever overwritten — that is `createIfMissing`'s whole contract —
/// so running this against a config you already have is safe and does nothing.
/// Point it somewhere else with `PARROTFLOW_CONFIG_DIR` to see the full result.
enum SeedConfigCommand {

    static func run() -> Int32 {
        let directory = ConfigStore.directory
        print("config: \(directory.path)")

        let watched = [ConfigStore.fileURL] + ConfigStore.seededTransforms.flatMap { name, script in
            [ConfigStore.seededTransformScript(name, script),
             ConfigStore.seededTransformFolder(name).appendingPathComponent("cases.yaml")]
        }
        let fm = FileManager.default
        let before = Set(watched.filter { fm.fileExists(atPath: $0.path) }.map(\.path))

        do {
            try ConfigStore.createIfMissing()
        } catch {
            print("  ✗ \(error.localizedDescription)")
            return 1
        }

        for file in watched {
            let relative = file.path.hasPrefix(directory.path + "/")
                ? String(file.path.dropFirst(directory.path.count + 1)) : file.path
            if before.contains(file.path) {
                print("  · \(relative) — already there, left alone")
            } else if fm.fileExists(atPath: file.path) {
                print("  ✓ \(relative) — written")
            }
        }
        return 0
    }
}
