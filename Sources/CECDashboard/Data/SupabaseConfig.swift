import Foundation

/// Supabase connection config. The REST URL is non-secret (the project ref is
/// already in `.mcp.json`); the API key lives only in the Keychain.
enum SupabaseConfig {
    /// PostgREST base for the leads project (matches SUPABASE_URL in .env).
    static let restURL = URL(string: "https://YOUR-PROJECT-REF.supabase.co/rest/v1")!

    /// Keychain coordinates (store via `security add-generic-password`). Since
    /// the 7.2 remap the app needs TWO values, exactly like the Python
    /// writer-class factory (6.1 intel, learned at install acceptance):
    /// Supabase's gateway validates the `apikey` HEADER against KNOWN keys —
    /// a class JWT there is rejected outright with a 401 before PostgREST ever
    /// sees the request. So `supabase_api_key` holds the `arcane_read_cec`
    /// reader JWT (rides ONLY the Authorization bearer; SELECT on the v_cec_*
    /// views) and `supabase_anon_key` holds the project's anon/publishable key
    /// (rides ONLY `apikey`; grants nothing by itself — reads are the
    /// reader's). The retired `supabase_write_key` item was deleted at 7.2.
    static let keychainService = "com.atlasautomates.lead-dashboard"
    static let keychainAccount = "supabase_api_key"
    static let anonKeychainAccount = "supabase_anon_key"

    /// The reader JWT from the Keychain. nil → not configured; callers fail
    /// closed and surface a setup prompt rather than falling back.
    static func apiKey() -> String? {
        Keychain.read(service: keychainService, account: keychainAccount)
    }

    /// The anon (gateway) key from the Keychain. nil → not configured.
    static func anonKey() -> String? {
        Keychain.read(service: keychainService, account: anonKeychainAccount)
    }

    /// The credential's `exp` claim, decoded LOCALLY over an ALREADY-READ
    /// token (no signature check, no network — the same approach as ce
    /// doctor's class-JWT expiry check). The reader JWT lives ~360 days; on
    /// expiry every read 401s at once with a message that cannot distinguish
    /// "expired" from "grant revoked", and `ce doctor` deliberately only
    /// WARNs on the env copy this app doesn't use — so the app's own copy
    /// must be measured HERE or nothing measures it (reliability review,
    /// 7.2). Takes the token rather than reading it: callers already hold
    /// the key (SupabaseCheck reads it once for both the client and this),
    /// and a second `SecItemCopyMatching` is unbounded and can prompt
    /// (contention lens). nil = not a JWT / no exp claim.
    static func keyExpiry(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var seg = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        seg += String(repeating: "=", count: (4 - seg.count % 4) % 4)
        guard let data = Data(base64Encoded: seg),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
