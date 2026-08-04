import Foundation
import Yams

/// A case set, as it is written.
///
/// `input` and `expect` are the whole requirement; everything else is
/// optional. The prose at the top of the file is not parsed and is the most
/// important part of it — what counts as a case here and what is deliberately
/// out of scope is the thing you will disagree with yourself about in a week.
///
///     cases:
///       - probe: ambiguity_common
///         input:  mark it as resolved
///         expect: mark it as resolved
struct EvalCases {
    /// Which transform this scores, when the file is not inside its folder.
    var transform: String?
    /// What the speaker said, for a prompt reached by voice — "fix the grammar
    /// and punctuation". Left out for a prompt that runs as a pipeline stage,
    /// which is given nothing. The same prompt scores differently under the
    /// two, so a set that does not say which one it means is a number about a
    /// use nobody has.
    var instruction: String?
    /// A second way to do the same job, without a model — see `Control`.
    var control: String?
    var intermediate: Intermediate?
    /// A `transforms:` section of its own, so a set can state the transform it
    /// assumes instead of inheriting this machine's config. Decoded by `Config`
    /// rather than re-read here, the way a `--pipeline` fixture is.
    var transforms: [Config.Transform] = []
    var cases: [Case] = []

    /// What the first stage of a two-stage transform should return on its own.
    ///
    /// Scoring it separately is what says whether the prompt or the code is at
    /// fault. On the Slack mentions set the gap between the two ran 25 points,
    /// and without it every one of those points reads as "the prompt is bad".
    struct Intermediate {
        /// The per-case field holding the gold — `spans`, say.
        var field: String
        /// Produces it from the input. Optional: without it the gold is still
        /// checked against itself, which is the half that matters most.
        var produce: String?
        /// Turns the gold into what the user sees. Required, because it is
        /// what checks the gold against itself before anything is scored.
        var resolve: String
    }

    /// One case. Every field is read as a string and unknown ones are kept, so
    /// a set can carry `kind:` or `name:` for its own runner and the gold field
    /// can be called whatever `intermediate.field` says it is called.
    struct Case {
        var fields: [String: String]

        var input: String { fields["input"] ?? "" }
        /// Absent means "comes back exactly as it went in". Detected, never
        /// declared: a set that has to remember to say which half a case is in
        /// is a set that will eventually be wrong about one.
        var expect: String { fields["expect"] ?? input }
        /// `category:` is the same idea under the name the older sets in this
        /// repository use, and refusing to read it would mean editing four
        /// files to gain nothing.
        var probe: String { fields["probe"] ?? fields["category"] ?? "" }
        var name: String { fields["name"] ?? input }
        /// True when this case must come back byte for byte.
        var mustNotChange: Bool { expect == input }
    }

    /// What is wrong with the cases that are about to run, in words.
    ///
    /// Asked about a selection rather than the whole file, because `--probe` is
    /// a subset and a case nobody is scoring cannot make a scored one wrong. A
    /// bucket you have finished should not be unscoreable because the bucket
    /// you are still writing has no gold in it yet — and a run without
    /// `--probe` still asks about everything, so the half-written state is
    /// never invisible for long.
    ///
    /// The two whole-file faults stay whole-file: a set with no cases at all,
    /// and an `intermediate:` with no `resolve:`, which is the thing that
    /// checks a gold against itself and cannot be selected around.
    func problems(for cases: [Case]) -> [String] {
        var found: [String] = []
        if self.cases.isEmpty { found.append("no cases") }
        if let intermediate, intermediate.resolve.isEmpty {
            found.append("`intermediate:` needs a `resolve:` — it is what checks"
                + " the gold against itself")
        }
        for (index, one) in cases.enumerated() where one.input.isEmpty {
            found.append("case \(index + 1) has no `input`")
        }
        if let intermediate {
            for one in cases where one.fields[intermediate.field] == nil {
                found.append("case \"\(one.name)\" has no `\(intermediate.field)`")
            }
        }
        return found
    }
}

extension EvalCases: Decodable {
    enum CodingKeys: String, CodingKey {
        case transform, instruction, control, intermediate, transforms, cases
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transform = try c.decodeIfPresent(String.self, forKey: .transform)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        instruction = try c.decodeIfPresent(String.self, forKey: .instruction)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        control = try c.decodeIfPresent(String.self, forKey: .control)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        intermediate = try c.decodeIfPresent(Intermediate.self, forKey: .intermediate)
        if c.contains(.transforms) {
            transforms = try Config.transforms(from: try c.superDecoder(forKey: .transforms))
        }
        cases = try c.decodeIfPresent([Case].self, forKey: .cases) ?? []
    }
}

extension EvalCases.Intermediate: Decodable {
    enum CodingKeys: String, CodingKey { case field, produce, resolve }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decode(String.self, forKey: .field)
        produce = try c.decodeIfPresent(String.self, forKey: .produce)
        resolve = try c.decodeIfPresent(String.self, forKey: .resolve) ?? ""
    }
}

extension EvalCases.Case: Decodable {
    /// Any key at all, because the gold's name is the case file's to choose.
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        var fields: [String: String] = [:]
        for key in c.allKeys {
            // Only the string-valued ones. A set may carry a list or a flag for
            // a bespoke runner of its own — tests/…/email/cases.yaml carries
            // `require:` and `forbid:` — and refusing the whole file over a key
            // this does not read would be this runner deciding what a case set
            // is allowed to contain.
            guard let value = try? c.decode(String.self, forKey: key) else { continue }
            fields[key.stringValue] = value
        }
        self.fields = fields
    }
}
