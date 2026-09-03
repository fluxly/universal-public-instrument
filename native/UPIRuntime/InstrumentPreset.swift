import Foundation

/// A UPI preset. Carries the pack id so it travels with the instrument, plus
/// backend parameter values (by identifier) and extension-level controls.
/// See docs/upi-app-spec.md "Presets".
public struct InstrumentPreset: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var packId: String
    public var name: String
    /// Backend parameter identifier -> value.
    public var parameters: [String: Float]
    public var macros: [String: Float]
    public var mpeBendRange: Float

    public init(packId: String,
                name: String = "Init",
                parameters: [String: Float] = [:],
                macros: [String: Float] = [:],
                mpeBendRange: Float = 48) {
        self.schemaVersion = 1
        self.packId = packId
        self.name = name
        self.parameters = parameters
        self.macros = macros
        self.mpeBendRange = mpeBendRange
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public static func decoded(from data: Data) throws -> InstrumentPreset {
        try JSONDecoder().decode(InstrumentPreset.self, from: data)
    }
}
