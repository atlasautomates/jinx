import Foundation

/// Was this error a cancellation rather than a failure?
///
/// One definition, four call sites. URLSession surfaces task cancellation as a
/// wrapped `URLError.cancelled`, NOT as `CancellationError` — a fact this codebase
/// had already learned once (`LeadProfileModel.load`) and then re-lost in newer
/// code that guarded on `CancellationError` alone. Getting it wrong is not cosmetic:
/// a cancelled supplementary walk returns `ok: false`, which paints a red degraded
/// chip because a window closed.
///
/// `Task.isCancelled` is checked too, since the erasure can happen either way.
func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return Task.isCancelled
}

/// Thin, read-only PostgREST client over URLSession (no third-party dependency).
/// Only issues GETs. This app is READ-ONLY by design since 7.2 — it holds a
/// read-scoped credential (the arcane_read_cec JWT, SELECT on the v_cec_* views
/// only) — never add write methods here.
struct SupabaseClient {
    enum ClientError: Error, LocalizedError {
        case missingKey
        case http(status: Int, body: String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                // -T/-U grants the installed app trust on the item at creation, so a
                // headless App Intent (Siri/Shortcuts/Aris) can read it without an
                // "allow access" prompt. Otherwise open the app once and click
                // "Always Allow" before using voice.
                return "Supabase credentials missing from the Keychain (both items are "
                    + "required — the reader JWT rides the bearer, the anon key rides "
                    + "the apikey header). Store them with:\n"
                    + "  security add-generic-password -s \(SupabaseConfig.keychainService)"
                    + " -a \(SupabaseConfig.keychainAccount) -w <READER_JWT>"
                    + " -T /Applications/CECDashboard.app -U\n"
                    + "  security add-generic-password -s \(SupabaseConfig.keychainService)"
                    + " -a \(SupabaseConfig.anonKeychainAccount) -w <ANON_KEY>"
                    + " -T /Applications/CECDashboard.app -U"
            case .http(let status, let body):
                // Raw PostgREST body (column/constraint detail) only in debug builds.
                #if DEBUG
                return "Supabase HTTP \(status): \(body.prefix(200))"
                #else
                return "Supabase request failed (HTTP \(status))."
                #endif
            case .transport(let message):
                return "Network error: \(message)"
            }
        }
    }

    let baseURL: URL
    /// The gateway key (`apikey` header) — anon/publishable. Grants nothing.
    private let anonKey: String         // private: never surfaced/logged
    /// The read-scoped credential (`Authorization: Bearer`) — the reader JWT.
    private let bearerKey: String       // private: never surfaced/logged
    let session: URLSession

    /// Session with both a per-request (15s) and a hard whole-request (30s) ceiling,
    /// and fail-fast when offline (no queueing for an interactive dashboard).
    static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// TWO keys, deliberately (6.1 intel, learned live at the 7.2 install
    /// acceptance): the gateway validates `apikey` against KNOWN keys, so the
    /// reader JWT there is a hard 401 before PostgREST ever runs — the anon
    /// key must ride `apikey` while the scoped credential rides ONLY the
    /// bearer, exactly like `.claude/shared/supabase_client.py`'s factory.
    init(baseURL: URL, anonKey: String, bearerKey: String,
         session: URLSession = SupabaseClient.defaultSession) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.bearerKey = bearerKey
        self.session = session
    }

    /// Build a client from config; throws `.missingKey` when EITHER Keychain
    /// item is absent (fail closed — an anon-only client would silently read
    /// nothing through the views, a bearer-only one 401s at the gateway).
    static func make() throws -> SupabaseClient {
        guard let bearer = SupabaseConfig.apiKey(),
              let anon = SupabaseConfig.anonKey() else { throw ClientError.missingKey }
        return SupabaseClient(baseURL: SupabaseConfig.restURL, anonKey: anon, bearerKey: bearer)
    }

    /// Build a signed GET request for a table + query items. Shared by `get`/`count`.
    private func makeRequest(_ table: String, _ queryItems: [URLQueryItem]) throws -> URLRequest {
        guard var comps = URLComponents(
            url: baseURL.appendingPathComponent(table),
            resolvingAgainstBaseURL: false
        ) else { throw ClientError.transport("bad URL for table '\(table)'") }
        comps.queryItems = queryItems
        guard let url = comps.url else { throw ClientError.transport("bad query for table '\(table)'") }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(bearerKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        return req
    }

    /// Validate the HTTP response and surface a typed error on non-2xx.
    private func validate(_ data: Data, _ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.transport("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // PostgREST error bodies describe the query, not the key — safe to surface.
            throw ClientError.http(status: http.statusCode,
                                   body: String(data: data, encoding: .utf8) ?? "")
        }
        return http
    }

    /// Read-only GET against a PostgREST table. Returns the raw JSON body.
    func get(_ table: String, _ queryItems: [URLQueryItem]) async throws -> Data {
        let req = try makeRequest(table, queryItems)
        do {
            let (data, response) = try await session.data(for: req)
            _ = try validate(data, response)
            return data
        } catch let error as ClientError {
            throw error
        } catch {
            // Cancellation is not a transport failure. Erasing it into one made a
            // closed window write "Network error: cancelled" into a stale banner,
            // and made a cancelled paged walk report itself as a DEGRADED read —
            // which then hid the Lane menu on the way out. Only OUR cancellation is
            // erased (isCancellation checks Task.isCancelled), so a stray
            // URLError.cancelled from somewhere else still surfaces as an error
            // rather than leaving the first load spinning forever.
            if isCancellation(error) { throw CancellationError() }
            throw ClientError.transport(error.localizedDescription)
        }
    }

    /// Exact row count for a table (optionally filtered), via PostgREST's
    /// `Prefer: count=exact` + a 0-0 range — returns the total without pulling rows.
    /// Parsed from the `Content-Range: 0-0/<total>` header.
    func count(_ table: String, _ queryItems: [URLQueryItem] = []) async throws -> Int {
        var req = try makeRequest(table, [URLQueryItem(name: "select", value: "id")] + queryItems)
        req.setValue("count=exact", forHTTPHeaderField: "Prefer")
        req.setValue("0-0", forHTTPHeaderField: "Range")
        do {
            let (data, response) = try await session.data(for: req)
            let http = try validate(data, response)
            guard let range = http.value(forHTTPHeaderField: "Content-Range"),
                  let total = range.split(separator: "/").last,
                  let n = Int(total)
            else { throw ClientError.transport("missing Content-Range count header") }
            return n
        } catch let error as ClientError {
            throw error
        } catch {
            // Cancellation is not a transport failure. Erasing it into one made a
            // closed window write "Network error: cancelled" into a stale banner,
            // and made a cancelled paged walk report itself as a DEGRADED read —
            // which then hid the Lane menu on the way out. Only OUR cancellation is
            // erased (isCancellation checks Task.isCancelled), so a stray
            // URLError.cancelled from somewhere else still surfaces as an error
            // rather than leaving the first load spinning forever.
            if isCancellation(error) { throw CancellationError() }
            throw ClientError.transport(error.localizedDescription)
        }
    }
}
