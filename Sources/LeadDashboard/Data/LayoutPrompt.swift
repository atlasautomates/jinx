import Foundation

/// Builds the prompts for the Haiku layout call. The system prompt (rules + catalogs +
/// few-shot) fully REPLACES Claude Code's default prompt (`--system-prompt`) so Haiku's
/// context stays tiny and focused; the user prompt carries the data profile.
enum LayoutPrompt {

    /// Replaces the default system prompt — rules, the enum catalogs, and 2 examples.
    static let systemPrompt = """
    You are a dashboard layout planner. Given a coarse profile of available lead data, \
    you choose which widgets to show, their visual emphasis, and their order.

    Output ONLY a single JSON object, no prose and no markdown fences. Schema:
    {"widgets":[{"type":<type>,"bind":<bind>,"size":<size>,"priority":<int>}, ...]}

    Allowed "type": "kpi", "chart", "table", "status-board".
    Allowed "bind" (the data series; use each at most once):
      - "total-leads"  → a single headline count (use type "kpi")
      - "by-source"    → counts grouped by lead source (use type "status-board")
      - "added-weekly" → leads added per week, a time series (use type "chart")
      - "recent-leads" → a table of the most recent leads (use type "table")
    Allowed "size": "small", "medium", "large", "full" (width emphasis).
    "priority" is an integer; lower places earlier (top-left).

    Rules:
    - Use ONLY the binds listed above; never invent a bind. Each bind at most once.
    - Pair each bind with its natural type as noted above.
    - Always include "total-leads" and "recent-leads".
    - Include "by-source" and "added-weekly" when their profile strength is "medium" or \
    "high"; you may drop one whose strength is "none" or "low" (sparse data).
    - Pick sizes sensibly: a KPI is "small"; the recent-leads table is "full"; a board or \
    chart is "medium" or "large".
    - 2 to 4 widgets total.

    Example — profile {"total-leads":"high","by-source":"high","added-weekly":"high",\
    "recent-leads":"high","by-industry":"high","location":"high"} →
    {"widgets":[{"type":"kpi","bind":"total-leads","size":"small","priority":1},\
    {"type":"status-board","bind":"by-source","size":"medium","priority":2},\
    {"type":"chart","bind":"added-weekly","size":"large","priority":3},\
    {"type":"table","bind":"recent-leads","size":"full","priority":4}]}

    Example — profile {"total-leads":"low","by-source":"low","added-weekly":"none",\
    "recent-leads":"high","by-industry":"low","location":"low"} →
    {"widgets":[{"type":"kpi","bind":"total-leads","size":"small","priority":1},\
    {"type":"table","bind":"recent-leads","size":"full","priority":2}]}
    """

    /// The per-request prompt: just the profile. Keep it tiny.
    static func userPrompt(profile: DataProfile) -> String {
        let signals = profile.signals
            .sorted { $0.key < $1.key }
            .map { "\"\($0.key)\":\"\($0.value.rawValue)\"" }
            .joined(separator: ",")
        return "Data profile: {\(signals)}\nReturn the JSON layout plan."
    }
}
