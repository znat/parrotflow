import Foundation

/// `--set-key <model>` — store an API key in the keychain, read from stdin.
///
///     printf '%s' "$KEY" | ParrotFlow --set-key gpt
///     ParrotFlow --set-key gpt          # prompts, and does not echo
///     ParrotFlow --set-key gpt --forget
///
/// The key never appears in an argument, so it stays out of `ps` and out of
/// shell history. Everything printed names the model and the outcome, never
/// the key.
enum SetKeyCommand {

    static func run(model name: String, forget: Bool) -> Int32 {
        let config = try? ConfigStore.load()
        guard let spec = config?.model(named: name) else {
            let known = (config?.modelsByName.keys.sorted() ?? []).joined(separator: ", ")
            print("no model named \(name) in models: — have: \(known)")
            return 2
        }
        // Refusing rather than storing a key nothing will read. A local model
        // sends no key at all, and `file:`/`env:` say where to look already; a
        // key written here would sit in the keychain unused, and the next
        // "why is it still saying no key" is unanswerable.
        guard spec.key.kind == .keychain else {
            if spec.api.isLocal {
                print("\(name) is an ollama model and needs no key.")
            } else {
                print("\(name) reads its key from \(spec.key.described)."
                    + " Drop `api_key:` from its entry in models: to use the keychain.")
            }
            return 2
        }
        let account = spec.key.value

        if forget {
            do {
                try Keychain.delete(account)
                print("forgot the key for \(name).")
                return 0
            } catch {
                print(error.localizedDescription)
                return 1
            }
        }

        guard let key = read() else {
            print("no key given.")
            return 2
        }
        do {
            try Keychain.write(key, account: account)
            print("stored a key for \(name) in the \(Keychain.service) keychain.")
            return 0
        } catch {
            print(error.localizedDescription)
            return 1
        }
    }

    /// The key from a pipe, or typed with no echo.
    ///
    /// `isatty` decides. Piped input has no prompt because there is nobody to
    /// read one, and printing it would land the word "key:" in whatever the
    /// caller captured.
    private static func read() -> String? {
        if isatty(FileHandle.standardInput.fileDescriptor) == 1 {
            guard let entered = String(
                validatingUTF8: getpass("key (not echoed): ")
            ) else { return nil }
            let key = entered.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : key
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let key = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}
