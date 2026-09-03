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
        /// Backend parameter `identifier` this macro writes to. Mutually
        /// exclusive with `identityAxis`.
        public let parameter: String?
        /// Identity-axis `id` (from `identityAxes`) this macro navigates.
        /// Mutually exclusive with `parameter`.
        public let identityAxis: String?
        public let min: Float?
        public let max: Float?
        public let defaultValue: Float?

        enum CodingKeys: String, CodingKey {
            case id, label, parameter, identityAxis, min, max
            case defaultValue = "default"
        }

        /// A macro with neither target is still published on the macro bus
        /// (`ControlFrame.macros[]`) by its position in `macros`.
        public var isBareMacroBus: Bool { parameter == nil && identityAxis == nil }
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

    // MARK: - validation

    public enum ValidationIssue: Equatable, CustomStringConvertible {
        case unsupportedSchema(Int)
        case extensionTooOld(required: String, have: String)
        case missingResource(key: String, path: String)
        case macroTargetsBoth(macroId: String)
        case macroUnknownAxis(macroId: String, axis: String)
        case tooManyIdentityAxes(Int)
        case tooManyMacros(Int)

        public var description: String {
            switch self {
            case .unsupportedSchema(let v):
                return "instrument.json schemaVersion \(v) is newer than this build supports — update UPI"
            case .extensionTooOld(let req, let have):
                return "needs UPI \(req) or newer (this build is \(have)) — update UPI"
            case .missingResource(let key, let path):
                return "resource '\(key)' not found at \(path)"
            case .macroTargetsBoth(let id):
                return "macro '\(id)' sets both parameter and identityAxis"
            case .macroUnknownAxis(let id, let axis):
                return "macro '\(id)' references unknown identity axis '\(axis)'"
            case .tooManyIdentityAxes(let n):
                return "\(n) identity axes; this build supports \(InstrumentPack.maxIdentityDims)"
            case .tooManyMacros(let n):
                return "\(n) macros; this build supports \(InstrumentPack.maxMacros)"
            }
        }
    }

    /// Mirrors UPI_IDENTITY_DIMS / UPI_MACRO_COUNT in upi_control_frame.h.
    public static let maxIdentityDims = 8
    public static let maxMacros = 8
    public static let supportedSchemaVersion = 1

    /// Backend-registry-independent manifest checks. The extension additionally
    /// verifies `manifest.backend` against the compiled-in registry.
    public func validate(extensionVersion: String) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        if manifest.schemaVersion > Self.supportedSchemaVersion {
            issues.append(.unsupportedSchema(manifest.schemaVersion))
        }
        if let req = manifest.minExtensionVersion,
           Self.compareVersions(req, extensionVersion) == .orderedDescending {
            issues.append(.extensionTooOld(required: req, have: extensionVersion))
        }

        let axes = manifest.identityAxes ?? []
        if axes.count > Self.maxIdentityDims { issues.append(.tooManyIdentityAxes(axes.count)) }
        if manifest.macros.count > Self.maxMacros { issues.append(.tooManyMacros(manifest.macros.count)) }

        let axisIds = Set(axes.map(\.id))
        for macro in manifest.macros {
            if macro.parameter != nil, macro.identityAxis != nil {
                issues.append(.macroTargetsBoth(macroId: macro.id))
            }
            if let axis = macro.identityAxis, !axisIds.contains(axis) {
                issues.append(.macroUnknownAxis(macroId: macro.id, axis: axis))
            }
        }

        for (key, rel) in manifest.resources ?? [:] {
            let path = root.appendingPathComponent(rel).path
            if !FileManager.default.fileExists(atPath: path) {
                issues.append(.missingResource(key: key, path: path))
            }
        }
        return issues
    }

    /// Dotted numeric compare; missing components read as 0 ("1.0" == "1.0.0").
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
