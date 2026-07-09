import Foundation

/// Arbitrary JSON payload — the shape of the pipeline ledger's `input`/`output`
/// jsonb snapshot columns, which have no fixed schema by design (each stage
/// records what it consumed/produced). Decodable so snapshot rendering never
/// dictates what stages may write. Mirrors the tolerance philosophy of the row
/// models: unknown shapes render, they don't fail the decode.
indirect enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    /// Recursion guard for decode + render: snapshots are server-capped at
    /// ~8KB, but that invariant lives elsewhere — a local bound makes a
    /// pathological nesting a clean failure instead of a main-thread stack
    /// overflow (swift-semantics review). 64 levels dwarfs any real snapshot.
    static let maxDepth = 64

    init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= Self.maxDepth else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "JSON nesting exceeds \(Self.maxDepth) levels"))
        }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrecognized JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    /// Deterministic pretty-printed rendering (object keys sorted) for the lead
    /// inspector. Deterministic so SelfTest can pin it byte-for-byte.
    var prettyPrinted: String { render(indent: 0) }

    /// JSON-style string escaping so multi-line copy (openers, casualizations)
    /// renders on one visually-correct line and the output stays valid JSON
    /// (code review: quote-only escaping broke on newlines/backslashes).
    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case let c where c.value < 0x20:
                out += String(format: "\\u%04x", c.value)
            default:
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    private func render(indent: Int) -> String {
        guard indent <= Self.maxDepth else { return "…" }   // matches the decode bound
        let pad = String(repeating: "  ", count: indent)
        let padIn = String(repeating: "  ", count: indent + 1)
        switch self {
        case .string(let s): return "\"\(Self.escape(s))\""
        case .number(let d):
            // Integers render without the trailing .0 (counts, ids).
            return d == d.rounded() && abs(d) < 1e15
                ? String(Int64(d)) : String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let a):
            if a.isEmpty { return "[]" }
            let items = a.map { padIn + $0.render(indent: indent + 1) }
            return "[\n" + items.joined(separator: ",\n") + "\n\(pad)]"
        case .object(let o):
            if o.isEmpty { return "{}" }
            let items = o.keys.sorted().map { key in
                "\(padIn)\"\(key)\": " + (o[key] ?? .null).render(indent: indent + 1)
            }
            return "{\n" + items.joined(separator: ",\n") + "\n\(pad)}"
        }
    }
}
