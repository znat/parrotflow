import Foundation

/// `--schema` — the JSON Schema of `config.yaml`, on stdout.
///
/// Refuses, naming the key, when the table and the parser disagree. Nothing
/// goes to stdout then, so a redirect never leaves half a schema behind.
enum SchemaCommand {
    static func run() -> Int32 {
        let drift = ConfigSchema.drift()
        guard drift.isEmpty else {
            let said = drift.map { "✗ \($0)" }.joined(separator: "\n")
                + "\nThe schema in ConfigSchema.swift is out of step with the parser.\n"
            FileHandle.standardError.write(Data(said.utf8))
            return 1
        }
        do {
            FileHandle.standardOutput.write(try ConfigSchema.rendered() + Data("\n".utf8))
            return 0
        } catch {
            FileHandle.standardError.write(Data("✗ \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
