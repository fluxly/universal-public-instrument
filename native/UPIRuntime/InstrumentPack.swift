import Foundation

/// Decoded `instrument.json`. See docs/upi-app-spec.md "One Extension, Many
/// Instruments". Phase 0 keeps parameter definitions in the backend itself; a
/// macro just names the backend parameter identifier it drives.
public struct InstrumentManifest: Codable, Sendable, Equatable {

    public struct IdentityAxis: Codable, Sendable, Equatable {
        public let id: String
        public let label: String
    }

    public struct MacroDef: Codable, Sendable, Equatable {
        public let id: String
        public let label: String
        /// Backend parameter `identifier` this macro writes to. `nil` = inert
        /// in Phase 0 (e.g. "Identity" for the oscillator backend).
        public let parameter: String?
        public let min: Float?
        public let max: Float?
        public let defaultValue: Float?

        enum CodingKeys: String, CodingKey {
            case id, label, parameter, min, max
            case defaultValue = "default"
        }
    }

    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let version: String
    public let backend: String
    public let minExtensionVersion: String?
    public let identityAxes: [IdentityAxis]?
    public let macros: [MacroDef]
    public let resources: [String: String]?
}

/// A manifest plus the directory it was loaded from.
public struct InstrumentPack: Sendable, Equatable {
    public let manifest: InstrumentManifest
    public let root: URL

    public init(manifest: InstrumentManifest, root: URL) {
        self.manifest = manifest
        self.root = root
    }

    public var id: String { manifest.id }
    public var name: String { manifest.name }

    /// Absolute path for a logical resource key (`"weights"`, `"patch"`, …).
    public func resourcePath(forKey key: String) -> String? {
        guard let rel = manifest.resources?[key] else { return nil }
        return root.appendingPathComponent(rel).path
    }

    public var iconURL: URL? {
        let candidate = root.appendingPathComponent("art/icon.png")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Raw manifest text handed to the backend for backend-specific keys.
    public func manifestJSON() -> String {
        (try? String(contentsOf: root.appendingPathComponent("instrument.json"),
                     encoding: .utf8)) ?? ""
    }
}
