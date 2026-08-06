import Foundation

/// Save-time validation for staged-copy revisions, derived from the SENDER's
/// actual behavior (ce-outbound smtp_send.py) — not from what the editor hopes:
///
/// 1. Merge slots: substitution requires an exact `{{knownSlot}}` token, and the
///    sender's leftover-brace guard (`\{\{[a-zA-Z_]+\}\}`) misses spaced/digit
///    variants — a typo like `{{ greetingLine }}` or `{{step2}}` would ship
///    LITERAL BRACES to a real prospect with no error anywhere. We match
///    leniently (any `{{…}}`) and require every token to be a known slot.
/// 2. Links: the SMTP sink defangs every URL/bare domain except
///    atlasautomates.com (`_defang_links`). An operator-typed Calendly link
///    would silently vanish from the sent email while the dashboard forever
///    displays it as sent. Refuse instead.
///
/// The slot list mirrors MERGE_VAR_MAP + the derived vars in
/// ce-outbound/scripts/modal_app.py (build_merge_vars). If the sender grows a
/// slot, add it here — the SelfTest pin will remind whoever touches this.
enum RevisionLint {
    static let knownSlots: Set<String> = [
        "casualizedFirstName", "casualizedCompanyName", "casualizedCityName",
        "personalizedOpener", "personalizedOffer",
        "sendingAccountFirstName", "greetingLine", "magnetUrl",
    ]

    /// Lenient token detector: anything brace-wrapped, including malformed
    /// spacing — the point is to catch what the sender's strict regex misses.
    private static let slotPattern = "\\{\\{[^{}]*\\}\\}"

    /// URL / bare-domain detector approximating the sender's `_AUTOLINK_RE`:
    /// scheme'd URLs, www.-prefixed, or bare domain.tld tokens. TLD list
    /// mirrors the sender's (incl. biz — delta review).
    private static let linkPattern =
        "(?i)(https?://\\S+|www\\.\\S+|\\b[\\w][\\w-]*\\.(?:com|net|org|io|co|ai|dev|app|me|us|biz)\\b\\S*)"

    /// What the sender ACTUALLY leaves intact — a full-token mirror of
    /// `_OWN_LINK_RE` (smtp_send.py): https-only, apex-or-www only, restricted
    /// path charset. Anything looser passes the lint and is then silently
    /// stripped/mangled at the SMTP sink: `atlasautomates.com/work` sends as
    /// "/work", `http://…` and `www.…` forms are stripped entirely (delta
    /// review, verified by executing the sender's regexes).
    private static let allowedLinkPattern =
        "(?i)^https://(www\\.)?atlasautomates\\.com(/[A-Za-z0-9/_.~-]*)?$"

    /// nil = clean; otherwise a user-facing explanation of the FIRST problem.
    static func problem(subject: String?, body: String?) -> String? {
        for (label, text) in [("subject", subject ?? ""), ("body", body ?? "")] {
            if let bad = firstBadSlot(in: text) {
                return "The \(label) contains \(bad) — not a known merge slot, so the sender would email the braces literally. Known slots: \(knownSlots.sorted().joined(separator: ", "))."
            }
            if let link = firstForeignLink(in: text) {
                if link.lowercased().contains("atlasautomates.com") {
                    return "The \(label) contains \"\(link)\" — the sender only keeps first-party links in the exact form https://atlasautomates.com/… (https, no bare/www/http variants). Rewrite it that way."
                }
                return "The \(label) contains \"\(link)\" — the sender strips every link except https://atlasautomates.com/… before sending, so this would silently vanish from the email. Remove it (or use a magnet page link via {{magnetUrl}})."
            }
        }
        return nil
    }

    private static func firstBadSlot(in text: String) -> String? {
        matches(slotPattern, in: text).first { token in
            let name = token.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
            return token != "{{\(name)}}" || !knownSlots.contains(name)
        }
    }

    private static func firstForeignLink(in text: String) -> String? {
        matches(linkPattern, in: text).first { link in
            link.range(of: allowedLinkPattern, options: .regularExpression) == nil
        }
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}
