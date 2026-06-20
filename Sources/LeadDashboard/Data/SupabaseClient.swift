import Foundation

/// Thin, read-only PostgREST client over URLSession (no third-party dependency).
/// Only issues GETs — the dashboard never writes.
struct SupabaseClient {
    enum ClientError: Error, LocalizedError {
        case missingKey
        case http(status: Int, body: String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "No Supabase API key in the Keychain. Store it with:\n"
                    + "  security add-generic-password -s \(SupabaseConfig.keychainService)"
                    + " -a \(SupabaseConfig.keychainAccount) -w <YOUR_KEY>"
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
    private let apiKey: String          // private: never surfaced/logged
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

    init(baseURL: URL, apiKey: String, session: URLSession = SupabaseClient.defaultSession) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    /// Build a client from config; throws `.missingKey` if the Keychain has no key.
    static func make() throws -> SupabaseClient {
        guard let key = SupabaseConfig.apiKey() else { throw ClientError.missingKey }
        return SupabaseClient(baseURL: SupabaseConfig.restURL, apiKey: key)
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
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
            throw ClientError.transport(error.localizedDescription)
        }
    }
}
