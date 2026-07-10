import Foundation
import Observation

/// Pinned leads (P5): a small Codable JSON file in Application Support —
/// modeled on the old LayoutCache seam (atomic write, injectable directory,
/// SelfTest-able with a temp dir). Local-only; never written to Supabase.
enum PinsStore {
    static let filename = "pinned-leads.json"

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CECDashboard", isDirectory: true)
    }

    /// Corrupt/absent file → empty list, never a crash (the pins are
    /// reconstructible by re-pinning; failing the app over them is absurd).
    static func load(from dir: URL) -> [LeadRef] {
        let url = dir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let refs = try? JSONDecoder().decode([LeadRef].self, from: data)
        else { return [] }
        return refs
    }

    /// Best-effort atomic save; returns success for the caller's log line.
    @discardableResult
    static func save(_ refs: [LeadRef], to dir: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(refs)
            try data.write(to: dir.appendingPathComponent(filename),
                           options: .atomic)
            return true
        } catch {
            NSLog("PinsStore: save failed (pins won't survive relaunch): %@",
                  error.localizedDescription)
            return false
        }
    }

    /// Pure toggle seam (SelfTest target): dedupe by lead id; pinning an
    /// already-pinned lead unpins it; order = pin recency (newest first).
    static func toggled(_ pins: [LeadRef], with ref: LeadRef) -> [LeadRef] {
        if pins.contains(where: { $0.id == ref.id }) {
            return pins.filter { $0.id != ref.id }
        }
        return [ref] + pins
    }
}

/// Observable wrapper the UI binds to. Loaded once at startup; every
/// mutation persists immediately (pins are tiny).
@MainActor
@Observable
final class PinsModel {
    private(set) var pins: [LeadRef]
    private let directory: URL

    init(directory: URL = PinsStore.defaultDirectory()) {
        self.directory = directory
        self.pins = PinsStore.load(from: directory)
    }

    func isPinned(_ id: String) -> Bool {
        pins.contains { $0.id == id }
    }

    func toggle(_ ref: LeadRef) {
        pins = PinsStore.toggled(pins, with: ref)
        PinsStore.save(pins, to: directory)
    }
}
