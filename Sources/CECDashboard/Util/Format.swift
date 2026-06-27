import Foundation

/// Format a numeric value per the widget's declared format.
///
/// Contract: `.percent` expects a whole-number percentage (4.2 → "4.2%"), NOT a
/// 0–1 fraction. `.currency`/`.number` round to whole units (no fractional digits).
func formatValue(_ value: Double, _ format: ValueFormat?) -> String {
    switch format ?? .number {
    case .currency:
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        f.currencySymbol = "$"
        return f.string(from: NSNumber(value: value)) ?? "$\(Int(value))"
    case .percent:
        return String(format: "%.1f%%", value)
    case .number:
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? "\(Int(value))"
    }
}
