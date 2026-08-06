import Foundation

/// Supabase connection config. The REST URL is non-secret (the project ref is
/// already in `.mcp.json`); the API key lives only in the Keychain.
enum SupabaseConfig {
    /// PostgREST base for the leads project (matches SUPABASE_URL in .env).
    static let restURL = URL(string: "https://YOUR-PROJECT-REF.supabase.co/rest/v1")!

    /// Keychain coordinates for the API key (store via `security add-generic-password`).
    static let keychainService = "com.atlasautomates.lead-dashboard"
    static let keychainAccount = "supabase_api_key"

    /// Separate Keychain item for the WRITE key (staged-copy revisions). Kept
    /// distinct from the read key so the read path stays anon/RLS-scoped and the
    /// write capability is grantable/revocable on its own. Absent → the editor
    /// degrades to read-only; nothing falls back to the read key.
    /// NOTE: items granted via `security add-generic-password` live in the
    /// file-based login keychain — ACL-bound to the signed app, but INCLUDED in
    /// disk backups (same profile as the .env copy of this key). The
    /// device-only accessibility class applies only to `Keychain.write`-created
    /// items (future in-app grant flow).
    static let writeKeychainAccount = "supabase_write_key"

    /// The API key from the Keychain. nil → not configured; callers fail closed and
    /// surface a setup prompt rather than falling back to any hardcoded value.
    static func apiKey() -> String? {
        Keychain.read(service: keychainService, account: keychainAccount)
    }

    /// The write key from the Keychain. nil → revisions read-only (fail closed).
    static func writeKey() -> String? {
        Keychain.read(service: keychainService, account: writeKeychainAccount)
    }
}
