import Foundation
import os

/// Discovers Instrument Packs. Phase 0 sources:
///   1. `BundledPacks/` inside whatever bundle this framework is embedded in
///      (the extension), and
///   2. the App Group container / Application Support fallback (forward-compat,
///      normally empty in Phase 0).
public final class PackLibrary {

    public static let shared = PackLibrary()

    private static let log = Logger(subsystem: "com.upi.runtime", category: "PackLibrary")

    public private(set) var packs: [InstrumentPack] = []

    public init() { reload() }

    public func reload() {
        var byId: [String: InstrumentPack] = [:]
        for dir in Self.searchDirectories() {
            for pack in Self.scan(dir) {
                byId[pack.id] = pack   // later directories win (downloads override bundled)
            }
        }
        packs = byId.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        Self.log.info("loaded \(self.packs.count, privacy: .public) instrument pack(s)")
    }

    public func pack(id: String) -> InstrumentPack? {
        packs.first { $0.id == id }
    }

    /// Packs in library / host-menu order: groups alphabetically, "Test Bench"
    /// always last, packs by name within a group. Stable — factory-preset
    /// numbers index into this.
    public var orderedForCatalog: [InstrumentPack] {
        packs.sorted { a, b in
            let ga = a.group, gb = b.group
            if ga != gb {
                if ga == InstrumentPack.testBenchGroup { return false }
                if gb == InstrumentPack.testBenchGroup { return true }
                return ga.localizedCaseInsensitiveCompare(gb) == .orderedAscending
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// `orderedForCatalog` bucketed by group, groups in the same order.
    public var catalog: [(group: String, packs: [InstrumentPack])] {
        var order: [String] = []
        var byGroup: [String: [InstrumentPack]] = [:]
        for pack in orderedForCatalog {
            if byGroup[pack.group] == nil { order.append(pack.group) }
            byGroup[pack.group, default: []].append(pack)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    // MARK: - internals

    static func searchDirectories() -> [URL] {
        var dirs: [URL] = []

        // Packs bundled inside the running bundle (the .appex, or the app).
        // Each immediate subdirectory that contains instrument.json is a pack.
        if let res = Bundle.main.resourceURL { dirs.append(res) }
        if let res = Bundle(for: PackLibrary.self).resourceURL { dirs.append(res) }

        // Downloaded packs (Phase 1) — normally empty in Phase 0.
        if let shared = AppGroup.instrumentPacksURL {
            dirs.append(shared)
        }
        dirs.append(AppGroup.applicationSupportPacksURL)
        return dirs
    }

    static func scan(_ dir: URL) -> [InstrumentPack] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }

        var result: [InstrumentPack] = []
        for entry in entries {
            let manifestURL = entry.appendingPathComponent("instrument.json")
            guard let data = try? Data(contentsOf: manifestURL) else { continue }
            do {
                let manifest = try JSONDecoder().decode(InstrumentManifest.self, from: data)
                result.append(InstrumentPack(manifest: manifest, root: entry))
            } catch {
                log.error("bad manifest at \(manifestURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return result
    }
}
