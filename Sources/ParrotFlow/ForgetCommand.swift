import Foundation

/// `--forget <term>` — everything learnt about how one name sounds, gone.
///
/// Four places hold it, and until now none of them had a way out:
/// `vocabulary.yaml` holds the renderings, `voice/observations.jsonl` holds
/// every time one was seen, `voice/samples/<Term>/` holds the audio, and
/// `vocabulary-uses.yaml` holds the sentences it was confirmed in. Data
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
        // What the decoder can see before and after, not what the text edit
        // thinks it did. The edit is text-level — it has to be, or the file
        // loses the header that explains it — and a YAML shape it does not
        // recognise makes it a no-op. That failure is the dangerous one: the
        // audio and the observations go, the pronunciations stay, and the
        // command says it worked. So the check is the same question the app
        // asks, which no writing trick can answer wrongly.
        let before = pronunciations(of: name)
        do {
            let renderings = try ConfigWriter.forgetPronunciations(of: name)
            let after = pronunciations(of: name)
            if after > 0 {
                // Said precisely, because the two cases want different things
                // of the reader: nothing came out, or some did and the rest is
                // written in a shape the edit cannot reach.
                print("✗ \(name) still has \(after) pronunciation(s) in"
                    + " \(ConfigStore.vocabularyURL.lastPathComponent)"
                    + (renderings > 0
                        ? ", and \(renderings) came out — the rest is written in a shape"
                            + " this cannot edit."
                        : " and none came out.")
                    + " voice/ was left alone."
                    + " Edit the entry by hand, or report the shape of it.")
                Log.write("forget: \(name) — \(after) pronunciation(s) survived the"
                    + " edit (\(before) before, \(renderings) reported removed);"
                    + " voice/ left alone")
                return 1
            }
            let gone = try VoiceStore.forget(name)
            // A fourth place, and the same rule: what was learnt goes. Left
            // behind, the sentences would go on describing a term whose
            // renderings have all been thrown away.
            var uses = 0
            var stayed: Error?
            do {
                uses = try TermUses.forget(name)
            } catch {
                stayed = error
            }
            if renderings == 0, gone.observations == 0, gone.samples == 0, uses == 0,
               stayed == nil {
                print("· nothing recorded for \(name)")
                return 0
            }
            // The rest is already deleted, so the tally still prints. What it
            // must not say is that the term was forgotten when its sentences
            // can still rebuild the portrait.
            print(stayed == nil
                ? "✓ forgot \(name)"
                : "✗ \(name) was only partly forgotten")
            print("  \(renderings) pronunciation(s) from"
                + " \(ConfigStore.vocabularyURL.lastPathComponent)")
            print("  \(gone.observations) observation(s) from voice/observations.jsonl")
            // The folder as it is spelled on disk, not as it was typed. The
            // match is case-insensitive, so `--forget praisy` has to be told
            // that `samples/Praisy/` is what went.
            let from = gone.folders.isEmpty
                ? "voice/samples/" : gone.folders.map { "voice/samples/\($0)/" }.joined(separator: ", ")
            print("  \(gone.samples) sample(s) from \(from)")
            if let stayed {
                print("  the confirmed sentences in"
                    + " \(TermUses.url.lastPathComponent) stayed:"
                    + " \(stayed.localizedDescription)")
                Log.write("forget: \(name) — \(renderings) pronunciation(s),"
                    + " \(gone.observations) observation(s), \(gone.samples) sample(s);"
                    + " the uses stayed (\(stayed.localizedDescription))")
                return 1
            }
            print("  \(uses) confirmed sentence(s) from \(TermUses.url.lastPathComponent)")
            Log.write("forget: \(name) — \(renderings) pronunciation(s),"
                + " \(gone.observations) observation(s), \(gone.samples) sample(s),"
                + " \(uses) confirmed sentence(s)")
            return 0
        } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }
    }

    /// How many renderings the app would load for this term right now.
    ///
    /// Case-insensitive, like everything else here: somebody typing
    /// `--forget praisy` means the term.
    private static func pronunciations(of term: String) -> Int {
        ConfigStore.loadVocabulary().terms
            .filter { $0.key.caseInsensitiveCompare(term) == .orderedSame }
            .values.reduce(0) { $0 + $1.pronunciations.count }
    }
}
