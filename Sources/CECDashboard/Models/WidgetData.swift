import Foundation

// MARK: - Shared value formatting enum

enum ValueFormat: String, Codable {
    case number
    case currency
    case percent
}

enum Trend: String, Codable {
    case up
    case down
    case flat
}

// MARK: - Per-widget data shapes (target output of the data layer)

struct KpiData: Codable {
    let title: String
    let value: Double
    var format: ValueFormat?
    var previousValue: Double?
    var trend: Trend?
    var trendLabel: String?
    var sparkline: [Double]?
}

struct ChartPoint: Codable, Identifiable {
    var id: String { x }
    let x: String
    let y: Double
}

enum ChartKind: String, Codable {
    case line
    case bar
}

struct ChartData: Codable {
    let title: String
    var kind: ChartKind?
    let points: [ChartPoint]
}

struct TableColumn: Codable, Identifiable {
    var id: String { key }
    let key: String
    let label: String
    var sortable: Bool?
    var format: ValueFormat?
    var variant: String?   // e.g. "badge"
}

struct TableData: Codable {
    let title: String
    let columns: [TableColumn]
    let rows: [[String: CellValue]]
}

struct StatusGroup: Codable, Identifiable {
    var id: String { label }
    let label: String
    let count: Int
    var status: String?
}

struct StatusBoardData: Codable {
    let title: String
    let groups: [StatusGroup]
}

/// Heterogeneous table cell value (string / number / bool / null).
enum CellValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }

    var doubleValue: Double? {
        if case .number(let d) = self { return d }
        return nil
    }

    var displayString: String {
        switch self {
        case .string(let s): return s
        case .number(let d): return formatValue(d, .number)
        case .bool(let b): return b ? "Yes" : "No"
        case .null: return "—"
        }
    }
}

// MARK: - Discriminated widget data

enum WidgetData: Decodable {
    case kpi(KpiData)
    case chart(ChartData)
    case table(TableData)
    case statusBoard(StatusBoardData)

    private enum CodingKeys: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(WidgetType.self, forKey: .type)
        switch type {
        case .kpi: self = .kpi(try KpiData(from: decoder))
        case .chart: self = .chart(try ChartData(from: decoder))
        case .table: self = .table(try TableData(from: decoder))
        case .statusBoard: self = .statusBoard(try StatusBoardData(from: decoder))
        }
    }
}
