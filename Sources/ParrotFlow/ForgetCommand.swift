import Foundation

/// `--forget <term>` — everything learnt about how one name sounds, gone.
///
/// Three places hold it, and until now none of them had a way out:
/// `vocabulary.yaml` holds the renderings, `voice/observations.jsonl` holds
/// every time one was seen, and `voice/samples/<Term>/` holds the audio. Data
/// that only accumulates is data nobody can correct — a rendering learnt from
/// one bad clip goes on shaping the search forever, and the only remedy was to
/// edit a file the header tells you not to edit.
///
/// The term itself stays. Forgetting is about the learnt half; somebody who
/// wants the name gone deletes the name.
enum ForgetCommand {
    static func run(term: String) -> Int32 {
        let name = term.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            print("usage: ParrotFlow --forget <term>")
            return 2
        }
        do {
            let renderings = try ConfigWriter.forgetPronunciations(of: name)
            let gone = try VoiceStore.forget(name)
            if renderings == 0, gone.observations == 0, gone.samples == 0 {
                print("· nothing recorded for \(name)")
                return 0
            }
            print("✓ forgot \(name)")
            print("  \(renderings) pronunciation(s) from"
                + " \(ConfigStore.vocabularyURL.lastPathComponent)")
            print("  \(gone.observations) observation(s) from voice/observations.jsonl")
            print("  \(gone.samples) sample(s) from voice/samples/\(name)/")
            Log.write("forget: \(name) — \(renderings) pronunciation(s),"
                + " \(gone.observations) observation(s), \(gone.samples) sample(s)")
            return 0
        } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }
    }
}
