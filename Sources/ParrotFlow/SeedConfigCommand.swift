import Foundation

/// `--seed-config` — write the files a first launch writes, and say which.
///
/// The app does this at startup and has always done it silently, which left
/// "what does a new install actually get" as a question you could only answer
/// by deleting your own config. It is now worth being able to see, and worth
/// a check script being able to assert.
///
/// `config.yaml` and `vocabulary.yaml` are written once and never touched
/// again. `transforms/examples/` is refreshed every time this runs, the same
/// as every launch — that folder is the app's, not yours. Point it somewhere
/// else with `PARROTFLOW_CONFIG_DIR` to see the full result.
enum SeedConfigCommand {

    static func run() -> Int32 {
        let directory = ConfigStore.directory
        print("config: \(directory.path)")

        let fm = FileManager.default
        let relatives = ConfigStore.exampleTransformFiles()
        let before = Set(relatives.filter {
            fm.fileExists(atPath: ConfigStore.installedExamplesDirectory
                .appendingPathComponent($0).path)
        })
        let configExisted = fm.fileExists(atPath: ConfigStore.fileURL.path)
        let vocabularyExisted = fm.fileExists(atPath: ConfigStore.vocabularyURL.path)

        do {
            try ConfigStore.createIfMissing()
        } catch {
            print("  ✗ \(error.localizedDescription)")
            return 1
        }

        if configExisted {
            print("  · config.yaml — already there, left alone")
        } else {
            print("  ✓ config.yaml — written")
        }
        if vocabularyExisted {
            print("  · vocabulary.yaml — already there, left alone")
        } else {
            print("  ✓ vocabulary.yaml — written")
        }

        var written = 0
        var refreshed = 0
        for relative in relatives {
            let label = "transforms/examples/\(relative)"
            if before.contains(relative) {
                print("  · \(label) — refreshed")
                refreshed += 1
            } else {
                print("  ✓ \(label) — written")
                written += 1
            }
        }

        print("")
        print("  \(written) example file(s) written, \(refreshed) refreshed.")
        print("  transforms/examples/ is the app's; edits there do not survive the next launch.")
        print("  transforms/<name>/ is yours — copy a file out of examples/ before editing it.")
        return 0
    }
}
