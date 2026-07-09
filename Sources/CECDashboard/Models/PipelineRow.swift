import Foundation

/// Rows from the pipeline ledger (anon SELECT-only RLS, P0 of the ce-pipeline
/// overhaul). Same tolerance philosophy as `CampaignRow`: every field the UI
/// can live without is optional — the dashboard renders gaps rather than
/// failing a decode. Timestamps stay `String?` (parsed downstream via
/// `DateParse`, the house pattern).

/// One orchestrated run — `pipeline_runs`.
struct PipelineRunRow: Codable, Identifiable {
    let runId: String
    let kind: String?
    let vertical: String?
    let searchQuery: String?
    let status: String?
    let error: String?
    let gitSha: String?
    let startedAt: String?
    let finishedAt: String?

    var id: String { runId }

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case kind, vertical, status, error
        case searchQuery = "search_query"
        case gitSha = "git_sha"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}

/// One stage of a run — `pipeline_stage_runs`. `drops`/`spend` are free-form
/// jsonb tallies ({"no_email": 4} / {"claude_calls": 34, "apify_usd": 1.4});
/// Double absorbs both int and fractional values.
struct PipelineStageRow: Codable {
    let id: Int?
    let runId: String?
    let stage: String?
    let seq: Int?
    let status: String?
    let countIn: Int?
    let countOut: Int?
    let drops: [String: Double]?
    let spend: [String: Double]?
    let error: String?
    let startedAt: String?
    let finishedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, stage, seq, status, error, drops, spend
        case runId = "run_id"
        case countIn = "count_in"
        case countOut = "count_out"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}

/// One per-lead event — `pipeline_lead_events`. `input`/`output` are the capped
/// I/O snapshots (research JSON, casualization before→after, opener/offer copy)
/// the inspector renders — arbitrary shape by design, hence `JSONValue`.
struct PipelineLeadEventRow: Codable {
    let id: Int?
    let runId: String?
    let stage: String?
    let leadId: String?
    let status: String?
    let dropReason: String?
    let input: JSONValue?
    let output: JSONValue?
    let createdAt: String?

    /// ForEach identity. NOT `Identifiable` on the optional `id` — N nil-id
    /// rows would share one SwiftUI identity and collapse to a single rendered
    /// card (swift-semantics review). The composite is unique in practice;
    /// the only residual collision (nil PK + same run+stage+createdAt) needs
    /// a dropped bigserial NOT NULL PK AND duplicate timestamps — accepted.
    var stableKey: String {
        "\(id.map(String.init) ?? "?")|\(runId ?? "")|\(stage ?? "")|\(createdAt ?? "")"
    }

    enum CodingKeys: String, CodingKey {
        case id, stage, status, input, output
        case runId = "run_id"
        case leadId = "lead_id"
        case dropReason = "drop_reason"
        case createdAt = "created_at"
    }
}

/// A lead hit in the inspector's search box (reads `leads`, already anon-readable).
struct LeadSearchHit: Codable, Identifiable {
    let id: String
    let companyName: String?
    let email: String?

    enum CodingKeys: String, CodingKey {
        case id, email
        case companyName = "company_name"
    }
}

/// Composed inputs for the Pipeline tab (mirrors `CampaignInputs`).
struct PipelineInputs {
    let runs: [PipelineRunRow]                       // newest first, test runs filtered
    let stagesByRun: [String: [PipelineStageRow]]    // seq-ordered per run
    let partial: Bool
}
