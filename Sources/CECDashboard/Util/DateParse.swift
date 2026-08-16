import Foundation

/// Tolerant ISO-8601 timestamp parsing for Postgres `timestamptz` (with/without
/// fractional seconds).
///
/// Built on `Date.ISO8601FormatStyle` — a VALUE type, `Sendable`, no shared
/// state — because this is called concurrently from two executors (the
/// main-actor snapshot derivation and the off-main profile/lead walks), and
/// the previous shared `ISO8601DateFormatter` statics rested on a thread-safety
/// guarantee Foundation documents for `DateFormatter` but NOT for
/// `ISO8601DateFormatter` (Swift 6 rejects the old shape outright —
/// swift-semantics review, 7.2). Both live wire forms parse: `…+00:00` offsets
/// and `Z`, 0–6 fractional digits (pinned by the selftest's mixed-format cases).
enum DateParse {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    static func iso(_ string: String?) -> Date? {
        guard let s = string?.nilIfEmpty else { return nil }
        return (try? withFraction.parse(s)) ?? (try? plain.parse(s))
    }
}

extension String {
    /// Self unless it's empty after trimming, in which case nil.
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
