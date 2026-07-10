import Foundation

/// Hardcoded layout + widget data for the M0 spike (no Supabase).
/// Decoded through the same Codable contract the live dashboards use.
enum MockData {
    static let dashboard: Dashboard? = Dashboard.decode(
        layoutJSON: layoutJSON,
        widgetsJSON: widgetsJSON
    )

    static let layoutJSON = """
    {
      "breakpoints": { "lg": 1200, "md": 996, "sm": 768 },
      "cols": { "lg": 12, "md": 10, "sm": 6 },
      "rowHeight": 80,
      "widgets": [
        { "id": "total-leads", "type": "kpi",
          "layouts": { "lg": {"x":0,"y":0,"w":3,"h":2}, "md": {"x":0,"y":0,"w":5,"h":2}, "sm": {"x":0,"y":0,"w":3,"h":2} } },
        { "id": "enriched", "type": "kpi",
          "layouts": { "lg": {"x":3,"y":0,"w":3,"h":2}, "md": {"x":5,"y":0,"w":5,"h":2}, "sm": {"x":3,"y":0,"w":3,"h":2} } },
        { "id": "reply-rate", "type": "kpi",
          "layouts": { "lg": {"x":6,"y":0,"w":3,"h":2}, "md": {"x":0,"y":2,"w":5,"h":2}, "sm": {"x":0,"y":2,"w":3,"h":2} } },
        { "id": "by-campaign", "type": "status-board",
          "layouts": { "lg": {"x":9,"y":0,"w":3,"h":4}, "md": {"x":5,"y":2,"w":5,"h":4}, "sm": {"x":3,"y":2,"w":3,"h":4} } },
        { "id": "enriched-weekly", "type": "chart",
          "layouts": { "lg": {"x":0,"y":2,"w":9,"h":4}, "md": {"x":0,"y":4,"w":10,"h":4}, "sm": {"x":0,"y":6,"w":6,"h":3} } },
        { "id": "recent-leads", "type": "table",
          "layouts": { "lg": {"x":0,"y":6,"w":12,"h":4}, "md": {"x":0,"y":8,"w":10,"h":4}, "sm": {"x":0,"y":9,"w":6,"h":4} } }
      ]
    }
    """

    static let widgetsJSON = """
    {
      "total-leads": {
        "type": "kpi", "title": "Total Leads", "value": 1218, "format": "number",
        "trend": "up", "trendLabel": "+86 this wk",
        "sparkline": [980, 1010, 1064, 1102, 1150, 1218]
      },
      "enriched": {
        "type": "kpi", "title": "Enriched", "value": 320, "format": "number",
        "previousValue": 280, "trend": "up", "trendLabel": "+14%",
        "sparkline": [210, 240, 255, 280, 300, 320]
      },
      "reply-rate": {
        "type": "kpi", "title": "Reply Rate", "value": 4.2, "format": "percent",
        "trend": "down", "trendLabel": "-0.3%",
        "sparkline": [5.1, 4.8, 4.9, 4.5, 4.4, 4.2]
      },
      "by-campaign": {
        "type": "status-board", "title": "By Campaign",
        "groups": [
          { "label": "EV Dealers FL/CA", "count": 33, "status": "green" },
          { "label": "Biotech Europe", "count": 320, "status": "orange" },
          { "label": "Assisted Living FL", "count": 115, "status": "blue" },
          { "label": "Web Agencies TX", "count": 254, "status": "purple" }
        ]
      },
      "enriched-weekly": {
        "type": "chart", "title": "Leads Enriched / Week", "kind": "line",
        "points": [
          {"x":"W1","y":42}, {"x":"W2","y":58}, {"x":"W3","y":51}, {"x":"W4","y":67},
          {"x":"W5","y":73}, {"x":"W6","y":69}, {"x":"W7","y":88}, {"x":"W8","y":96}
        ]
      },
      "recent-leads": {
        "type": "table", "title": "Recent Leads",
        "columns": [
          { "key": "company", "label": "Company" },
          { "key": "industry", "label": "Industry" },
          { "key": "sentiment", "label": "Sentiment", "variant": "badge" },
          { "key": "campaign", "label": "Campaign" },
          { "key": "date", "label": "Added" }
        ],
        "rows": [
          { "company": "Ombrevale EV", "industry": "Automotive", "sentiment": "positive", "campaign": "EV Dealers FL/CA", "date": "2026-06-12" },
          { "company": "Varrowen Biotherapeutics", "industry": "Biotech", "sentiment": "neutral", "campaign": "Biotech Europe", "date": "2026-06-13" },
          { "company": "Dawnbrook Senior Living", "industry": "Senior Care", "sentiment": "positive", "campaign": "Assisted Living FL", "date": "2026-06-14" },
          { "company": "Quillstar Digital", "industry": "Marketing", "sentiment": "negative", "campaign": "Web Agencies TX", "date": "2026-06-15" },
          { "company": "Pellucid Coast Motors", "industry": "Automotive", "sentiment": "pending", "campaign": "EV Dealers FL/CA", "date": "2026-06-16" },
          { "company": "Skelmoor Genomics", "industry": "Biotech", "sentiment": "neutral", "campaign": "Biotech Europe", "date": "2026-06-17" }
        ]
      }
    }
    """
}
