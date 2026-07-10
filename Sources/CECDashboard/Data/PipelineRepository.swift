import Foundation

/// Read-only queries for the Pipeline tab. Mirrors `CampaignsRepository`: typed
/// rows via the shared `SupabaseClient` (GET-only, anon key), windowed reads
/// with a +1 probe row, essential-vs-fail-open split, and a pure `compose` for
/// SelfTest. READ-ONLY by product requirement — no mutation exists here.
struct PipelineRepository {
    let client: SupabaseClient

    // Windowed-read caps (+1 probe row detects truncation without false
    // partials on exactly-cap tables — same contract as CampaignsRepository).
    static let runsCap = 60           // recent runs listed
    static let stageRunsWindow = 15   // newest runs whose stages are fetched
    static let stagesCap = 600
    static let inspectorEventsCap = 300

    /// Fetch + compose. `pipeline_runs` is essential (a throw fails the load);
    /// stage rows fail-open so an RLS/network blip degrades to a runs-only view
    /// with `partial` set, never a blank tab.
    ///
    /// The stage window is taken from the VISIBLE (test-filtered) runs — the
    /// builder renders visible runs, so windowing the raw list would let a
    /// burst of `__` test runs push the latest real run out of its own funnel
    /// (code review).
    func fetch() async throws -> PipelineInputs {
        let runs = try await recentRuns()                          // essential
        let truncatedRuns = runs.count > Self.runsCap

        let windowIds = Self.visibleRuns(runs)
            .prefix(Self.stageRunsWindow).map(\.runId)
        let (stageRows, stagesOK) = await stageRuns(runIds: Array(windowIds))  // fail-open
        let truncatedStages = stageRows.count > Self.stagesCap

        let degraded = !stagesOK || truncatedRuns || truncatedStages
        if truncatedRuns || truncatedStages {
            NSLog("%@", "PipelineRepository: windowed read hit its cap (runs=\(runs.count), stages=\(stageRows.count)); view may under-report")
        }
        return Self.compose(runs: runs, stageRows: stageRows, partial: degraded)
    }

    /// The `__`-prefixed test/E2E verticals are hidden (reserved convention,
    /// same rule as `ce status`).
    static func visibleRuns(_ runs: [PipelineRunRow]) -> [PipelineRunRow] {
        runs.filter { !($0.vertical ?? "").hasPrefix("__") }
    }

    /// Pure composition of raw rows → tab inputs. No I/O (SelfTest-covered).
    static func compose(runs: [PipelineRunRow], stageRows: [PipelineStageRow],
                        partial: Bool) -> PipelineInputs {
        let visible = Array(visibleRuns(runs).prefix(runsCap))
        var byRun: [String: [PipelineStageRow]] = [:]
        for row in stageRows {
            guard let rid = row.runId else { continue }
            byRun[rid, default: []].append(row)
        }
        for key in byRun.keys {
            byRun[key]?.sort { ($0.seq ?? 0, $0.id ?? 0) < ($1.seq ?? 0, $1.id ?? 0) }
        }
        return PipelineInputs(runs: visible, stagesByRun: byRun, partial: partial)
    }

    // MARK: - Table reads (tab)

    /// Recent runs, newest first. Essential.
    func recentRuns() async throws -> [PipelineRunRow] {
        let data = try await client.get("pipeline_runs", [
            URLQueryItem(name: "select",
                         value: "run_id,kind,vertical,search_query,status,error,git_sha,started_at,finished_at"),
            URLQueryItem(name: "order", value: "started_at.desc"),
            URLQueryItem(name: "limit", value: "\(Self.runsCap + 1)"),   // +1 probe row
        ])
        return try JSONDecoder().decode([PipelineRunRow].self, from: data)
    }

    /// Stage rows for the given runs. Fail-open → (rows: [], ok: false).
    func stageRuns(runIds: [String]) async -> (rows: [PipelineStageRow], ok: Bool) {
        guard !runIds.isEmpty else { return ([], true) }
        return await failOpen {
            let data = try await client.get("pipeline_stage_runs", [
                URLQueryItem(name: "select",
                             value: "id,run_id,stage,seq,status,count_in,count_out,drops,spend,error,started_at,finished_at"),
                URLQueryItem(name: "run_id", value: "in.(\(runIds.joined(separator: ",")))"),
                // id.desc (monotonic bigserial): if the cap bites, truncation
                // sheds the OLDEST stage rows — never the newest run's funnel,
                // the widget being actively watched (reliability review:
                // run_id is a uuid, so ordering by it is arbitrary vs recency).
                // compose() re-sorts each run's group by seq for display.
                URLQueryItem(name: "order", value: "id.desc"),
                URLQueryItem(name: "limit", value: "\(Self.stagesCap + 1)"),   // +1 probe row
            ])
            return try JSONDecoder().decode([PipelineStageRow].self, from: data)
        }
    }

    // MARK: - Inspector reads (on-demand, P5-2)

    /// Search leads by company or email for the inspector. The user's text is
    /// embedded in a PostgREST `or=(...)` filter, so characters with filter
    /// syntax meaning are stripped — worst case a weird query matches nothing;
    /// it can never widen the filter (and the key is read-only anon anyway).
    func searchLeads(_ query: String) async throws -> [LeadSearchHit] {
        let cleaned = String(query.unicodeScalars.filter {
            !",()\"\\".unicodeScalars.contains($0)
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        let pattern = "*\(cleaned)*"
        let data = try await client.get("leads", [
            URLQueryItem(name: "select", value: "id,company_name,email"),
            URLQueryItem(name: "or",
                         value: "(company_name.ilike.\(pattern),email.ilike.\(pattern))"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "20"),
        ])
        return try JSONDecoder().decode([LeadSearchHit].self, from: data)
    }

    /// Full cross-run journey for one lead, displayed oldest-first. Fetched
    /// NEWEST-first then reversed: if the cap ever bites on a heavily
    /// reprocessed lead, it must shed the oldest history, not the recent
    /// journey the inspector exists to show (reliability review). Callers
    /// detect truncation as `count == inspectorEventsCap`.
    func leadEvents(leadId: String) async throws -> [PipelineLeadEventRow] {
        let data = try await client.get("pipeline_lead_events", [
            URLQueryItem(name: "select",
                         value: "id,run_id,stage,lead_id,status,drop_reason,input,output,created_at"),
            URLQueryItem(name: "lead_id", value: "eq.\(leadId)"),
            URLQueryItem(name: "order", value: "created_at.desc,id.desc"),
            URLQueryItem(name: "limit", value: "\(Self.inspectorEventsCap)"),
        ])
        return try JSONDecoder().decode([PipelineLeadEventRow].self, from: data).reversed()
    }

    /// Run rows for a set of ids — the inspector uses this to humanize event
    /// trailers ("biotech-europe · Jul 9" instead of a bare hex). Fail-open to
    /// [:]: the label lookup is cosmetic and every caller falls back to the
    /// hex prefix, so a miss must never fail the journey view.
    func runsByIds(_ ids: [String]) async -> [String: PipelineRunRow] {
        // Defense-in-depth: ids come from our own ledger rows, but they ride
        // into an in.(...) filter — strip filter-syntax chars like searchLeads.
        // prefix(200): kills the pathological 414 tail (300 distinct UUIDs ≈
        // 11 KB query string); overflow ids simply keep their hex fallback.
        let unique = Array(Set(ids.compactMap { id -> String? in
            let cleaned = String(id.unicodeScalars.filter {
                !",()\"\\ ".unicodeScalars.contains($0)
            })
            return cleaned.isEmpty ? nil : cleaned
        }).prefix(200))
        guard !unique.isEmpty else { return [:] }
        do {
            let data = try await client.get("pipeline_runs", [
                URLQueryItem(name: "select",
                             value: "run_id,kind,vertical,search_query,status,error,git_sha,started_at,finished_at"),
                URLQueryItem(name: "run_id", value: "in.(\(unique.joined(separator: ",")))"),
            ])
            let rows = try JSONDecoder().decode([PipelineRunRow].self, from: data)
            return Dictionary(rows.map { ($0.runId, $0) }) { first, _ in first }
        } catch {
            // Log like the sibling failOpen contract — a persistently failing
            // lookup would otherwise be invisible ("labels never humanize").
            NSLog("PipelineRepository.runsByIds failed (labels fall back to hex): %@",
                  error.localizedDescription)
            return [:]
        }
    }

    /// Run a supplementary read; any error logs + yields (rows: [], ok: false)
    /// so the caller can mark the load partial (same contract as Campaigns).
    private func failOpen<T>(_ body: () async throws -> [T]) async -> (rows: [T], ok: Bool) {
        do { return (try await body(), true) }
        catch {
            // Literal "%@" format: NSLog re-scans its format argument for %
            // specifiers, so interpolated content must never BE the format
            // (security review, CWE-134).
            NSLog("%@", "PipelineRepository: supplementary read failed (\(error.localizedDescription)); treating as empty")
            return ([], false)
        }
    }
}
