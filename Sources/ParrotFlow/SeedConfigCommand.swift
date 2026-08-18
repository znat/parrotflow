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
/// It does say when a file you own is no longer the copy that ships, which is
/// the only thing an upgrade can honestly do about a file that is yours.
/// Point it somewhere else with `PARROTFLOW_CONFIG_DIR` to see the full result.
enum SeedConfigCommand {

    static func run() -> Int32 {
        let directory = ConfigStore.directory
        print("config: \(directory.path)")

        // Each seeded file, paired with the copy that ships now. `config.yaml`
        // has no pair: it is written once from a template and then edited, so
        // "differs" would be true for everyone and mean nothing.
        var watched: [(file: URL, shipped: URL?)] = [(ConfigStore.fileURL, nil)]
        for (name, _) in ConfigStore.seededTransforms {
            let folder = ConfigStore.seededTransformFolder(name)
            let source = ConfigStore.exampleTransformsDirectory
                .appendingPathComponent(name, isDirectory: true)
            for filename in ConfigStore.seededTransformFiles(name) {
                watched.append((folder.appendingPathComponent(filename),
                                source.appendingPathComponent(filename)))
            }
        }

        let fm = FileManager.default
        let before = Set(watched.map(\.file).filter { fm.fileExists(atPath: $0.path) }.map(\.path))

        do {
            try ConfigStore.createIfMissing()
        } catch {
            print("  ✗ \(error.localizedDescription)")
            return 1
        }

        var differing = 0
        for (file, shipped) in watched {
            let relative = file.path.hasPrefix(directory.path + "/")
                ? String(file.path.dropFirst(directory.path.count + 1)) : file.path
            if before.contains(file.path) {
                if let shipped, ConfigStore.differsFromShipped(file, shipped) {
                    print("  · \(relative) — yours, and not the copy that ships now")
                    differing += 1
                } else {
                    print("  · \(relative) — already there, left alone")
                }
            } else if fm.fileExists(atPath: file.path) {
                print("  ✓ \(relative) — written")
            }
        }

        if differing > 0 {
            print("")
            let noun = differing == 1 ? "file is" : "files are"
            print("  \(differing) \(noun) yours, and older or edited. Nothing was overwritten.")
            print("  The copies that ship are in \(ConfigStore.exampleTransformsDirectory.path)")
            print("  Diff against them, or move yours aside and run this again.")
        }
        return 0
    }
}
