import Foundation

/// A fully-resolved dashboard: a layout spec plus the data for each widget id.
struct Dashboard {
    let layout: LayoutSpec
    let widgets: [String: WidgetData]   // widget id -> data

    /// Decode from raw JSON (layout spec + an { id: widgetData } map).
    ///
    /// Fail-closed only where it must: a missing/malformed layout returns nil (nothing
    /// to place). Widgets decode **independently** — one bad widget (unknown type,
    /// missing field) is dropped and logged, not allowed to blank the whole dashboard.
    /// This matters for the M2 `claude -p` source, where partial/imperfect output is
    /// the expected steady state; the grid already tolerates a widget with no data.
    static func decode(layoutJSON: String, widgetsJSON: String) -> Dashboard? {
        let decoder = JSONDecoder()
        guard let layout = try? decoder.decode(LayoutSpec.self, from: Data(layoutJSON.utf8)) else {
            return nil
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(widgetsJSON.utf8)),
            let map = object as? [String: Any]
        else { return nil }

        var widgets: [String: WidgetData] = [:]
        for (id, value) in map {
            if let data = try? JSONSerialization.data(withJSONObject: value),
               let widget = try? decoder.decode(WidgetData.self, from: data) {
                widgets[id] = widget
            } else {
                FileHandle.standardError.write(Data("Dashboard.decode: dropping unparseable widget '\(id)'\n".utf8))
            }
        }
        return Dashboard(layout: layout, widgets: widgets)
    }
}
