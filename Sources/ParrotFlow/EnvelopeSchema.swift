import Foundation

/// One node of the JSON Schema `--envelope-schema` prints: what a
/// `returns: json` command reads on stdin, and what it may print back.
indirect enum EnvelopeSchema {
    case string
    case integer
    case number
    case boolean
    /// A `Scope.Value`.
    case scalar
    case base64
    case array(EnvelopeSchema)
    case map(EnvelopeSchema)
    case nullable(EnvelopeSchema)
    case type(any EnvelopeDescribed.Type)
}

struct EnvelopeField {
    let schema: EnvelopeSchema
    /// False for a key the encoder leaves out when it has nothing to say.
    let required: Bool

    static func required(_ schema: EnvelopeSchema) -> EnvelopeField { EnvelopeField(schema: schema, required: true) }
    static func optional(_ schema: EnvelopeSchema) -> EnvelopeField { EnvelopeField(schema: schema, required: false) }
}

/// A type that goes into the envelope or comes back in the reply.
///
/// `field(_:)` switches over the type's own `CodingKeys`, so a key added to
/// the type without a schema entry does not compile.
protocol EnvelopeDescribed {
    associatedtype CodingKeys: CodingKey & CaseIterable
    /// The `$defs` name, and the name of the `TypedDict` in `built-in/runner/envelope.py`.
    static var schemaName: String { get }
    static func field(_ key: CodingKeys) -> EnvelopeField
    /// What any key beyond `CodingKeys` holds. Nil: no other key.
    static var others: EnvelopeSchema? { get }
}

extension EnvelopeDescribed {
    static var others: EnvelopeSchema? { nil }

    static var properties: [(name: String, field: EnvelopeField)] {
        CodingKeys.allCases.map { ($0.stringValue, field($0)) }
    }
}

extension EnvelopeSchema {

    /// The whole document: `Envelope` at the root, every named type in `$defs`.
    /// Throws when two types claim one name.
    static func document(envelope: any EnvelopeDescribed.Type, reply: any EnvelopeDescribed.Type) throws -> [String: Any] {
        var defs: [String: Any] = [:]
        var owners: [String: ObjectIdentifier] = [:]

        func define(_ type: any EnvelopeDescribed.Type) throws {
            let name = type.schemaName
            if let owner = owners[name] {
                guard owner == ObjectIdentifier(type) else { throw Clash(name: name) }
                return
            }
            owners[name] = ObjectIdentifier(type)
            var properties: [String: Any] = [:]
            var required: [String] = []
            for (key, field) in type.properties {
                properties[key] = try json(field.schema)
                if field.required { required.append(key) }
            }
            defs[name] = [
                "title": name,
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": try type.others.map(json) ?? false,
            ]
        }

        func json(_ node: EnvelopeSchema) throws -> [String: Any] {
            switch node {
            case .string: return ["type": "string"]
            case .integer: return ["type": "integer"]
            case .number: return ["type": "number"]
            case .boolean: return ["type": "boolean"]
            case .scalar: return ["type": ["string", "number", "boolean"]]
            case .base64: return ["type": "string", "contentEncoding": "base64"]
            case .array(let item): return ["type": "array", "items": try json(item)]
            case .map(let value): return ["type": "object", "additionalProperties": try json(value)]
            case .nullable(let inner): return ["anyOf": [try json(inner), ["type": "null"]]]
            case .type(let type):
                try define(type)
                return ["$ref": "#/$defs/\(type.schemaName)"]
            }
        }

        try define(envelope)
        try define(reply)
        return [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "title": "ParrotFlow transform envelope",
            "description": "Written by `ParrotFlow --envelope-schema`. The root is what a `returns: json`"
                + " command reads on stdin; `$defs/Reply` is what it prints.",
            "$ref": "#/$defs/\(envelope.schemaName)",
            "$defs": defs,
        ]
    }

    struct Clash: LocalizedError {
        let name: String
        var errorDescription: String? { "two types are both called \(name) in the envelope schema" }
    }
}

/// `--envelope-schema`, on stdout.
enum EnvelopeSchemaCommand {
    static func run() -> Int32 {
        do {
            let document = try CommandRunner.envelopeSchema()
            let data = try JSONSerialization.data(
                withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            return 0
        } catch {
            FileHandle.standardError.write(Data("✗ \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
