import Foundation

/// The persisted layout: a profile key paired with the plan generated for it.
struct CachedLayout: Codable, Equatable {
    let key: String
    let plan: LayoutPlan
}

/// Persists the last (profile key → layout plan) to Application Support so the layout
/// survives launches and the if-changed gate can detect "data character unchanged →
/// reuse". **Fail-open:** any read/write error is treated as a cache miss (the layout
/// simply regenerates), never a crash.
enum LayoutCache {
    static func directory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CECDashboard", isDirectory: true)
    }

    private static func fileURL(in dir: URL) -> URL {
        dir.appendingPathComponent("layout-cache.json")
    }

    static func load(from dir: URL = directory()) -> CachedLayout? {
        guard let data = try? Data(contentsOf: fileURL(in: dir)) else { return nil }
        return try? JSONDecoder().decode(CachedLayout.self, from: data)
    }

    @discardableResult
    static func save(_ cached: CachedLayout, to dir: URL = directory()) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(cached)
            try data.write(to: fileURL(in: dir), options: .atomic)
            return true
        } catch {
            return false   // fail-open: a write failure just means we regenerate next time
        }
    }

    static func clear(in dir: URL = directory()) {
        try? FileManager.default.removeItem(at: fileURL(in: dir))
    }
}
