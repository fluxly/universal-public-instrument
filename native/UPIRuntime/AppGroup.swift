import Foundation

/// Where Instrument Packs live. In Phase 0 packs are bundled inside the
/// extension; the App Group container and Application Support fallback are here
/// for Phase 1 (the app downloads packs for the extension to read).
public enum AppGroup {

    /// Keep in sync with:
    ///   native/UPIInstrument/UPIInstrument.entitlements
    ///   src-tauri/Entitlements.plist
    public static let identifier = "group.com.upi.shared"

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    public static var instrumentPacksURL: URL? {
        containerURL?.appendingPathComponent("InstrumentPacks", isDirectory: true)
    }

    /// Fallback used when the App Group container is unavailable (e.g. running
    /// unsigned / without the entitlement during early development).
    public static var applicationSupportPacksURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("UPI/InstrumentPacks", isDirectory: true)
    }
}
