import Foundation
import os

/// The dashboard's ONE write seam (2026-08-05 scope revision): posting copy
/// revisions to STAGED sends from the correspondence view. Everything else in
/// the app remains strictly read-only through `SupabaseClient`.
///
/// Design constraints (security review contract):
/// - Uses its own Keychain item (`supabase_write_key`) — never the read key, so
///   granting reads never grants writes and the write capability can be
///   revoked by deleting one Keychain item.
/// - Exposes exactly one operation: update a single `send_queue` row's
///   `subject_override`/`body_override`, and only while that row is still
///   `pending` and unclaimed. There is no generic PATCH surface.
/// - PATCH is by PRIMARY KEY. PostgREST ignores `limit` on PATCH (measured,
///   pinned in ce-outbound's test_claim_batch.py) — a filter-only PATCH could
///   rewrite every matching row, so the id filter is mandatory, not stylistic.
struct SupabaseWriteClient {
    enum WriteError: Error, LocalizedError {
        case missingWriteKey
        case http(status: Int, body: String)
        case transport(String)
        /// The guarded PATCH matched no row — the send was claimed, sent, or
        /// removed since the timeline loaded.
        case rowNotEditable
        /// The queue id is not a UUID — a client bug, never a row state.
        case invalidQueueId
        /// 2xx but the representation was unreadable: the write LIKELY LANDED.
        /// Deliberately distinct from `.rowNotEditable` — a failure and a
        /// genuine negative must never share one output (house rule).
        case unconfirmed
        /// The draft failed the revision lint (sender-contract validation).
        case lint(String)

        var errorDescription: String? {
            switch self {
            case .missingWriteKey:
                // NOTE: -T binds the app ACL at item CREATION only; when
                // rotating an existing key, delete the item first (see below) —
                // `-U` alone leaves a stale ACL that prompts or fails.
                return "Revisions are read-only: no write key in the Keychain. To enable, store one with:\n"
                    + "  security add-generic-password -s \(SupabaseConfig.keychainService)"
                    + " -a \(SupabaseConfig.writeKeychainAccount) -w <SERVICE_KEY>"
                    + " -T /Applications/CECDashboard.app\n"
                    + "(Rotating? Delete first: security delete-generic-password -s \(SupabaseConfig.keychainService)"
                    + " -a \(SupabaseConfig.writeKeychainAccount))"
            case .http(let status, let body):
                #if DEBUG
                return "Supabase write failed (HTTP \(status)): \(body.prefix(200))"
                #else
                return "Supabase write failed (HTTP \(status))."
                #endif
            case .transport(let message):
                return "Network error: \(message)"
            case .rowNotEditable:
                return "This message is no longer editable — it was sent (or is sending) since the timeline loaded. Refresh to see its current state."
            case .invalidQueueId:
                return "Internal error: this card carries no valid queue id — refresh and retry."
            case .unconfirmed:
                return "The write was acknowledged but couldn't be confirmed — refresh to see what the database holds before retrying."
            case .lint(let message):
                return message
            }
        }
    }

    /// Audit trail for the app's one write (queue id hashed, never content).
    private static let auditLog = Logger(
        subsystem: "com.atlasautomates.cecdashboard", category: "staged-copy-write")

    /// The sender interpolates send_queue ids after `_UUID_RE.fullmatch` —
    /// mirror that allowlist here rather than the weaker strip-denylist.
    static let uuidPattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

    /// Pure URL-construction seam (SelfTest pins the guard triple on it —
    /// the id/status/claimed_at filters are the only barrier between this
    /// credential and a project-wide send_queue rewrite). nil for a non-UUID id.
    static func stagedCopyURL(base: URL, queueId: String) -> URL? {
        guard queueId.range(of: uuidPattern, options: .regularExpression) != nil,
              var comps = URLComponents(url: base.appendingPathComponent("send_queue"),
                                        resolvingAgainstBaseURL: false)
        else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(queueId)"),
            URLQueryItem(name: "status", value: "eq.pending"),
            URLQueryItem(name: "claimed_at", value: "is.null"),
            URLQueryItem(name: "select", value: "id"),
        ]
        return comps.url
    }

    /// Subject is a single SMTP header line: strip every control character.
    /// Python's email lib blocks classic CRLF+header injection but NOT a bare
    /// newline with a plain continuation — which malforms the header block and
    /// can bounce a legitimate lead or push X-CE-Queue-Id into the body
    /// (security review, verified against smtp_send.py by execution).
    static func sanitizedSubject(_ subject: String?) -> String? {
        subject?
            // CRLF splits into an empty middle component — drop empties so the
            // join can't produce a double space.
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .filter { ch in
                !ch.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private let baseURL: URL
    private let apiKey: String          // private: never surfaced/logged
    private let session: URLSession

    init(baseURL: URL, apiKey: String,
         session: URLSession = SupabaseClient.defaultSession) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    /// Build from config; throws `.missingWriteKey` when the write Keychain item
    /// is absent (the UI uses `isConfigured` to decide whether to offer editing).
    static func make() throws -> SupabaseWriteClient {
        guard let key = SupabaseConfig.writeKey() else { throw WriteError.missingWriteKey }
        return SupabaseWriteClient(baseURL: SupabaseConfig.restURL, apiKey: key)
    }

    /// Cheap capability probe for the UI: attributes-only Keychain check — no
    /// network, and the secret itself is never materialized just to test presence.
    static var isConfigured: Bool {
        Keychain.exists(service: SupabaseConfig.keychainService,
                        account: SupabaseConfig.writeKeychainAccount)
    }

    /// Revise one staged send's copy. Empty/whitespace strings clear the
    /// override (NULL → the sender falls back to the step's pool template).
    /// Both columns are always written together so a revision is one atomic,
    /// self-consistent statement of intent.
    ///
    /// Guards: `id=eq.` (primary key) + `status=eq.pending` + `claimed_at=is.null`
    /// — a row the sender claimed (`status='sending'`) or finished can never be
    /// rewritten. 0 matched rows → `.rowNotEditable`.
    func updateStagedCopy(queueId: String, subject: String?, body: String?) async throws {
        guard let url = Self.stagedCopyURL(base: baseURL, queueId: queueId) else {
            Self.auditLog.error("staged-copy revision REJECTED: non-UUID queue id")
            throw WriteError.invalidQueueId
        }

        // Sender-contract lint: refuse drafts the sender would corrupt or
        // silently rewrite (unknown {{slots}}, stripped links). Fail closed
        // BEFORE the network — a rejected save is recoverable, a sent typo isn't.
        if let problem = RevisionLint.problem(subject: subject, body: body) {
            throw WriteError.lint(problem)
        }

        // NSNull encodes JSON null — an explicit clear, distinct from omission.
        let payload: [String: Any] = [
            "subject_override": Self.sanitizedSubject(subject) as Any? ?? NSNull(),
            "body_override": body?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty as Any? ?? NSNull(),
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Representation (not minimal) so 0-matched is detectable: the guarded
        // filters make "row moved on" a first-class, user-visible outcome.
        req.setValue("return=representation", forHTTPHeaderField: "Prefer")
        req.timeoutInterval = 15
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw WriteError.transport("non-HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                Self.auditLog.error("staged-copy revision FAILED queue=\(queueId, privacy: .private(mask: .hash)) http=\(http.statusCode)")
                throw WriteError.http(status: http.statusCode,
                                      body: String(data: data, encoding: .utf8) ?? "")
            }
            // Three distinct outcomes — never conflate parse failure with
            // 0-matched (the write may have LANDED on an unreadable 2xx).
            guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
                Self.auditLog.warning("staged-copy revision UNCONFIRMED queue=\(queueId, privacy: .private(mask: .hash)) (2xx, unreadable representation)")
                throw WriteError.unconfirmed
            }
            guard !rows.isEmpty else {
                Self.auditLog.notice("staged-copy revision refused (row no longer pending) queue=\(queueId, privacy: .private(mask: .hash))")
                throw WriteError.rowNotEditable
            }
            Self.auditLog.notice("staged-copy revision applied queue=\(queueId, privacy: .private(mask: .hash)) subjectLen=\(Self.sanitizedSubject(subject)?.count ?? 0) bodyLen=\(body?.count ?? 0)")
        } catch let error as WriteError {
            throw error
        } catch {
            Self.auditLog.error("staged-copy revision transport failure queue=\(queueId, privacy: .private(mask: .hash))")
            throw WriteError.transport(error.localizedDescription)
        }
    }
}
