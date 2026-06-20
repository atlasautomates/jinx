import Foundation

/// Supabase connection config. The REST URL is non-secret (the project ref is
/// already in `.mcp.json`); the API key lives only in the Keychain.
enum SupabaseConfig {
    /// PostgREST base for the leads project (matches SUPABASE_URL in .env).
    static let restURL = URL(string: "https://YOUR-PROJECT-REF.supabase.co/rest/v1")!

    /// Keychain coordinates for the API key (store via `security add-generic-password`).
    static let keychainService = "com.atlasautomates.lead-dashboard"
    static let keychainAccount = "supabase_api_key"

    /// The API key from the Keychain. nil → not configured; callers fail closed and
    /// surface a setup prompt rather than falling back to any hardcoded value.
    static func apiKey() -> String? {
        Keychain.read(service: keychainService, account: keychainAccount)
    }
}
