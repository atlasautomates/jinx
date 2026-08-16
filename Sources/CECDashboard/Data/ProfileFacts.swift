import Foundation

/// The label/value pairs behind the lead profile's fact grids.
///
/// Pure, and deliberately outside the view, for one reason: every fact is now
/// click-to-copy, so the string a user COPIES must be byte-identical to the one
/// they SEE. Keeping the list here lets `--selftest` assert that property
/// instead of trusting a view body — a display-side reformat (truncation, a
/// prettified phone number) would silently corrupt the clipboard otherwise.
enum ProfileFacts {
    /// `Hashable` so a row's SwiftUI identity is label+value, not label alone.
    struct Fact: Equatable, Hashable {
        let label: String
        let value: String
    }

    /// Contact facts in display order. Blank/absent fields are dropped — a
    /// labelled empty row is noise, and an empty copy target is a dead click.
    static func contact(_ lead: LeadDetailRow) -> [Fact] {
        present([
            ("Title", lead.jobTitle),
            ("Industry", lead.industry),
            ("Location", location(lead)),
            ("Phone", lead.phone),
            ("Website", lead.website),
            ("Email", lead.email),
        ])
    }

    /// Personalization facts in display order (same blank-drop rule).
    /// (`Source`/`Status`/`Tier` retired with the lead_enrichment table — 7.2.)
    /// A corrupt casualized payload (jsonb string-scalar where an object
    /// belongs) surfaces as its own fact — p7a5 exposes `casualized_shape`
    /// expressly so corruption is visible rather than rendering as "never
    /// casualized".
    static func personalization(_ e: LeadEnrichmentRow) -> [Fact] {
        present([
            ("Casual name", e.casualizedFirstName),
            ("Casual company", e.casualizedCompanyName),
            ("Casual city", e.casualizedCityName),
            ("Project ref", e.personalizationProject),
            ("Detail", e.personalizationDetail),
            ("Casualized data", e.casualizedCorrupt
                ? "corrupt (\(e.casualizedShape ?? "?") — expected object)" : nil),
        ])
    }

    /// The explicit `location` column when present, else "city, state" from
    /// whichever parts exist.
    static func location(_ lead: LeadDetailRow) -> String? {
        lead.location?.nilIfEmpty
            ?? [lead.city, lead.state].compactMap { $0?.nilIfEmpty }
                .joined(separator: ", ").nilIfEmpty
    }

    /// Sanitize once, here, so the cleaned string is both what renders and what
    /// gets copied — one string, never two.
    private static func present(_ raw: [(String, String?)]) -> [Fact] {
        raw.compactMap { label, value in
            value.flatMap(inlineValue).map { Fact(label: label, value: $0) }
        }
    }

    /// A one-line field value, stripped of characters that render as nothing.
    ///
    /// `nilIfEmpty` only trims edge whitespace, and `.whitespacesAndNewlines`
    /// excludes the format (Cf) category — so a scraped `\u{FEFF}team@acme.io`
    /// renders identically to the clean address but copies with a leading BOM,
    /// and a soft hyphen inside a word is invisible on screen yet rides into the
    /// paste. Both break exact-match search and dedup in a CRM, and both occur in
    /// real scraped/CSV-imported Supabase text. Line breaks collapse to spaces:
    /// a value presented on one line must paste as one line.
    static func inlineValue(_ raw: String) -> String? {
        clean(raw, keepNewlines: false)
    }

    /// Multi-line prose (opener/offer): same invisible-character strip, but line
    /// structure is meaningful here, so newlines survive.
    static func blockValue(_ raw: String) -> String? {
        clean(raw, keepNewlines: true)
    }

    /// One classifier for both paths — the only difference is whether a newline
    /// survives. Separate implementations drifted once already (tabs were
    /// collapsed on one path and deleted on the other, jamming words together).
    private static func clean(_ raw: String, keepNewlines: Bool) -> String? {
        var out = String.UnicodeScalarView()
        let scalars = Array(raw.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let u = scalars[i]
            if u == "\r" {
                // CRLF is ONE line break. Treating CR separately double-spaces
                // every line of Windows/CSV-sourced text — and blockValue feeds
                // the opener that gets pasted into an outgoing email.
                if i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                out.append(keepNewlines ? "\n" : " ")
            } else if u == "\n" || u == "\u{2028}" || u == "\u{2029}" {
                out.append(keepNewlines ? "\n" : " ")
            } else if u == "\t" {
                out.append(" ")          // never deleted: a tab is a word boundary
            } else if !isInvisible(u) {
                out.append(u)
            }
            i += 1
        }
        return String(out).nilIfEmpty
    }

    /// Renders as nothing AND carries no meaning: zero-width space, BOM, soft
    /// hyphen, bidi marks/overrides, interlinear annotation, tag characters.
    ///
    /// Deliberately NOT `isDefaultIgnorableCodePoint`: that property also covers
    /// ZWJ (U+200D), ZWNJ (U+200C) and the variation selectors, which are
    /// load-bearing — stripping them shatters emoji sequences (👨‍👩‍👧‍👦 → 👨👩👧👦,
    /// ⚡️ → ⚡) and corrupts Persian and Indic text (می‌روم → میروم). Scraped
    /// company names carry emoji routinely, and `blockValue` feeds the opener
    /// that gets pasted into an outgoing email — a sanitizer whose premise is
    /// "the copied string IS the value" must not rewrite the value.
    private static func isInvisible(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x00..<0x20, 0x7F...0x9F:      // C0 / C1 controls
            return true
        case 0x00AD:                        // soft hyphen
            return true
        case 0x034F:                        // combining grapheme joiner
            return true
        case 0x061C:                        // Arabic letter mark (LRM/RLM sibling)
            return true
        case 0x115F, 0x1160, 0x17B4, 0x17B5, 0x3164, 0xFFA0:
            // Hangul/Khmer fillers — the characters behind every "invisible
            // character" generator, and a real contaminant in scraped names.
            return true
        case 0x200B, 0x200E, 0x200F:        // zero-width space, LRM/RLM
            return true
        case 0x202A...0x202E:               // bidi embedding / override
            return true
        case 0x2060...0x2064, 0x206A...0x206F:  // word joiner, invisible ops, deprecated format
            return true
        case 0x180E:                        // Mongolian vowel separator
            // NOT 180B–180D: those are Mongolian free variation SELECTORS, the
            // same category as FE00–FE0F, which we deliberately preserve.
            return true
        case 0xFEFF:                        // BOM / zero-width no-break space
            return true
        case 0xFFF9...0xFFFB:               // interlinear annotation
            return true
        case 0xE0000...0xE007F:             // tag characters
            return true
        default:
            return false
        }
    }
}
