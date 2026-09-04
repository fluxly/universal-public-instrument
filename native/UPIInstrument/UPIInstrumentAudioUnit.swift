import AVFoundation
import AudioToolbox
import os
import UPIRuntime

/// Turns a pack's logical resource keys ("patch", "weights", …) into absolute
/// filesystem paths for a backend's `prepare()`. Held by the AU for as long as
/// the pack is loaded — the kernel retains the C resolver for later re-prepares.
private final class ResourceResolverBox {
    let pack: InstrumentPack
    private var buffers: [UnsafeMutablePointer<CChar>] = []

    init(pack: InstrumentPack) { self.pack = pack }
    deinit { for b in buffers { b.deallocate() } }

    func resolve(_ key: String) -> UnsafePointer<CChar>? {
        guard let path = pack.resourcePath(forKey: key) else { return nil }
        let bytes = Array(path.utf8CString)
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        bytes.withUnsafeBufferPointer { buf.initialize(from: $0.baseAddress!, count: bytes.count) }
        buffers.append(buf)
        return UnsafePointer(buf)
    }
}

private let upiResourceResolver: @convention(c)
    (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>? = { ctx, key in
        guard let ctx, let key else { return nil }
        let box = Unmanaged<ResourceResolverBox>.fromOpaque(ctx).takeUnretainedValue()
        return box.resolve(String(cString: key))
    }

/// The one generic UPI instrument. Loads an Instrument Pack, instantiates the
/// backend it names (from the compiled-in registry), and drives it from
/// MIDI/MPE via the C++ kernel. See docs/upi-app-spec.md.
public final class UPIInstrumentAudioUnit: AUAudioUnit {

    private static let log = Logger(subsystem: "com.upi.instrument", category: "AudioUnit")

    /// Address space: backend parameters use their own small addresses
    /// (0, 1, 2, …). Extension-owned parameters live above this base:
    ///   base + 0            → MPE bend range
    ///   base + 1  .. + 8    → identity axes (one per `identityAxes` entry)
    ///   base + 256 .. + 263 → macro bus (index = position in `macros`)
    private static let extensionParamBase: AUParameterAddress = 1 << 16
    private static let mpeBendRangeAddress: AUParameterAddress = extensionParamBase + 0
    private static let identityAxisAddressBase: AUParameterAddress = extensionParamBase + 1
    private static let macroBusAddressBase: AUParameterAddress = extensionParamBase + 256

    private static func isIdentityAxisAddress(_ a: AUParameterAddress) -> Bool {
        a >= identityAxisAddressBase && a < identityAxisAddressBase + 8
    }
    private static func isMacroBusAddress(_ a: AUParameterAddress) -> Bool {
        a >= macroBusAddressBase && a < macroBusAddressBase + UInt64(InstrumentPack.maxMacros)
    }

    /// This build's engine version, for a pack's `minExtensionVersion` gate.
    private static let extensionVersion: String =
        (Bundle(for: UPIInstrumentAudioUnit.self).infoDictionary?["CFBundleShortVersionString"] as? String)
        ?? "0.0.0"

    private let kernel: OpaquePointer
    private var outputBus: AUAudioUnitBus
    private var _outputBusArray: AUAudioUnitBusArray!
    private var _parameterTree: AUParameterTree!

    /// backend parameter address -> identifier, for preset save/restore
    private var backendParamIdentifiers: [AUParameterAddress: String] = [:]
    private var mpeBendRange: Float = 48

    /// identity-axis id -> AU address, and macro-bus AU address -> macro id.
    /// Both feed the Identity Layer / macro bus, and round-trip in presets.
    private var identityAxisAddresses: [String: AUParameterAddress] = [:]
    private var macroBusIdentifiers: [AUParameterAddress: String] = [:]

    /// Last value written for each extension-owned param (identity axes, macro
    /// bus). The kernel has no getter for these, and the value provider must not
    /// read `param.value` (that re-enters the provider).
    private var extensionOwnedValues: [AUParameterAddress: Float] = [:]

    /// Retained while the current pack is loaded — the kernel keeps a C pointer
    /// to this for re-prepares (see `ResourceResolverBox`).
    private var resolverBox: ResourceResolverBox?

    public private(set) var loadedPack: InstrumentPack?

    /// Fired after a successful `load()` with the new pack id — lets a hosting
    /// view follow instrument changes driven from the host's own preset menu.
    public var onInstrumentChange: ((String) -> Void)?

    /// Instrument library in host-menu order, captured once. Factory-preset
    /// numbers index into this. (Runtime pack downloads are a later phase.)
    private lazy var catalogPacks: [InstrumentPack] = PackLibrary.shared.orderedForCatalog

    /// One factory preset per instrument, named "<Group> — <Instrument>". Hosts
    /// (Logic, MainStage, AU Lab) show these in the plug-in preset menu;
    /// selecting one loads that pack.
    private lazy var _factoryPresets: [AUAudioUnitPreset] = catalogPacks.enumerated().map {
        let p = AUAudioUnitPreset()
        p.number = $0.offset
        p.name = "\($0.element.group) — \($0.element.name)"
        return p
    }
    private var _currentPreset: AUAudioUnitPreset?

    // MARK: - init

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        guard let k = upi_kernel_create() else {
            throw NSError(domain: "com.upi.instrument", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "kernel alloc failed"])
        }
        kernel = k

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        outputBus = try AUAudioUnitBus(format: format)
        outputBus.maximumChannelCount = 2

        try super.init(componentDescription: componentDescription, options: options)

        _outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096

        let preferred = "com.upi.instrument.hello-sine"
        let defaultPackId = PackLibrary.shared.pack(id: preferred)?.id
            ?? PackLibrary.shared.packs.first?.id
            ?? preferred
        load(packId: defaultPackId)
    }

    deinit { upi_kernel_destroy(kernel) }

    // MARK: - pack loading

    /// Not realtime-safe. Call off the audio thread.
    @discardableResult
    public func load(packId: String) -> Bool {
        guard let pack = PackLibrary.shared.pack(id: packId) else {
            Self.log.error("no pack \(packId, privacy: .public)")
            return false
        }

        // Manifest validation (registry-independent) + backend availability.
        let issues = pack.validate(extensionVersion: Self.extensionVersion)
        for issue in issues {
            Self.log.error("pack \(pack.id, privacy: .public): \(issue.description, privacy: .public)")
        }
        guard issues.isEmpty else { return false }

        guard pack.manifest.backend.withCString({ upi_registry_lookup($0) }) != nil else {
            Self.log.error("""
                pack \(pack.id, privacy: .public) needs backend \
                '\(pack.manifest.backend, privacy: .public)', not in this build — update UPI
                """)
            return false
        }

        let json = pack.manifestJSON()
        let box = ResourceResolverBox(pack: pack)
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        let rc = json.withCString { jsonPtr in
            pack.manifest.backend.withCString { backendPtr in
                upi_kernel_set_backend(kernel, backendPtr, jsonPtr, upiResourceResolver, ctx)
            }
        }
        guard rc == 0 else {
            Self.log.error("backend '\(pack.manifest.backend, privacy: .public)' load failed rc=\(rc)")
            return false
        }
        resolverBox = box   // outlive this call; kernel holds `ctx` for re-prepares
        loadedPack = pack
        rebuildParameterTree(for: pack)

        // Voice the instrument to its shipped starting point. A saved project's
        // preset (from `fullState`) is applied afterwards and takes precedence.
        if let initPreset = pack.initPreset() { apply(initPreset) }
        syncCurrentPreset(for: pack.id)
        onInstrumentChange?(pack.id)

        Self.log.info("loaded pack \(pack.id, privacy: .public) backend \(pack.manifest.backend, privacy: .public)")
        return true
    }

    private func rebuildParameterTree(for pack: InstrumentPack) {
        backendParamIdentifiers.removeAll()
        identityAxisAddresses.removeAll()
        macroBusIdentifiers.removeAll()
        extensionOwnedValues.removeAll()
        var params: [AUParameterNode] = []

        let count = upi_kernel_parameter_count(kernel)
        for i in 0..<count {
            var info = UPIParameterInfo()
            upi_kernel_parameter_info(kernel, i, &info)
            guard let idC = info.identifier, let nameC = info.display_name else { continue }
            let address = AUParameterAddress(info.address)
            let identifier = String(cString: idC)

            let p = AUParameterTree.createParameter(
                withIdentifier: identifier,
                name: String(cString: nameC),
                address: address,
                min: info.min_value, max: info.max_value,
                unit: .generic, unitName: nil,
                flags: [.flag_IsReadable, .flag_IsWritable],
                valueStrings: nil, dependentParameters: nil)
            p.value = info.default_value
            params.append(p)
            backendParamIdentifiers[address] = identifier
            upi_kernel_set_parameter(kernel, info.address, info.default_value)
        }

        // Identity Layer: one 0..1 axis position per `identityAxes` entry.
        // dim = axis index; Phase 1 feeds it straight to ControlFrame.identity[dim].
        for (dim, axis) in (pack.manifest.identityAxes ?? []).prefix(8).enumerated() {
            let address = Self.identityAxisAddressBase + AUParameterAddress(dim)
            let initial = pack.manifest.macros
                .first(where: { $0.identityAxis == axis.id })?.defaultValue ?? 0
            let p = AUParameterTree.createParameter(
                withIdentifier: "idaxis_\(axis.id)", name: axis.label,
                address: address, min: 0, max: 1,
                unit: .generic, unitName: nil,
                flags: [.flag_IsReadable, .flag_IsWritable],
                valueStrings: nil, dependentParameters: nil)
            p.value = initial
            params.append(p)
            identityAxisAddresses[axis.id] = address
            extensionOwnedValues[address] = initial
            upi_kernel_set_identity(kernel, UInt32(dim), initial)
        }

        // Macro bus: bare macros (no parameter / identityAxis target) are still
        // automatable and published in ControlFrame.macros[position].
        for (index, macro) in pack.manifest.macros.enumerated() where macro.isBareMacroBus {
            guard index < InstrumentPack.maxMacros else { break }
            let address = Self.macroBusAddressBase + AUParameterAddress(index)
            let p = AUParameterTree.createParameter(
                withIdentifier: "macrobus_\(macro.id)", name: macro.label,
                address: address, min: 0, max: 1,
                unit: .generic, unitName: nil,
                flags: [.flag_IsReadable, .flag_IsWritable],
                valueStrings: nil, dependentParameters: nil)
            p.value = macro.defaultValue ?? 0
            params.append(p)
            macroBusIdentifiers[address] = macro.id
            extensionOwnedValues[address] = macro.defaultValue ?? 0
            upi_kernel_set_macro(kernel, UInt32(index), macro.defaultValue ?? 0)
        }

        let bend = AUParameterTree.createParameter(
            withIdentifier: "mpeBendRange", name: "MPE Bend Range",
            address: Self.mpeBendRangeAddress,
            min: 1, max: 96, unit: .cents, unitName: "semitones",
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: nil, dependentParameters: nil)
        bend.value = mpeBendRange
        params.append(bend)

        let tree = AUParameterTree.createTree(withChildren: params)

        tree.implementorValueObserver = { [kernel, weak self] param, value in
            let address = param.address
            if address == Self.mpeBendRangeAddress {
                self?.mpeBendRange = value
                upi_kernel_set_mpe_bend_range(kernel, value)
            } else if Self.isIdentityAxisAddress(address) {
                self?.extensionOwnedValues[address] = value
                upi_kernel_set_identity(kernel, UInt32(address - Self.identityAxisAddressBase), value)
            } else if Self.isMacroBusAddress(address) {
                self?.extensionOwnedValues[address] = value
                upi_kernel_set_macro(kernel, UInt32(address - Self.macroBusAddressBase), value)
            } else {
                upi_kernel_set_parameter(kernel, UInt32(truncatingIfNeeded: address), value)
            }
        }
        tree.implementorValueProvider = { [kernel, weak self] param in
            let address = param.address
            if address == Self.mpeBendRangeAddress { return self?.mpeBendRange ?? 48 }
            if Self.isIdentityAxisAddress(address) || Self.isMacroBusAddress(address) {
                return self?.extensionOwnedValues[address] ?? 0   // never read param.value here
            }
            return upi_kernel_get_parameter(kernel, UInt32(truncatingIfNeeded: address))
        }
        tree.implementorStringFromValueCallback = { param, valuePtr in
            let v = valuePtr?.pointee ?? param.value
            return String(format: "%.2f", v)
        }

        _parameterTree = tree
        upi_kernel_set_mpe_bend_range(kernel, mpeBendRange)
    }

    // MARK: - AUAudioUnit overrides

    public override var outputBusses: AUAudioUnitBusArray { _outputBusArray }

    public override var parameterTree: AUParameterTree? {
        get { _parameterTree }
        set { /* fixed, rebuilt on pack load */ }
    }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let sr = outputBus.format.sampleRate
        let ch = outputBus.format.channelCount
        let rc = upi_kernel_prepare(kernel, sr, UInt32(maximumFramesToRender), ch)
        if rc != 0 {
            Self.log.error("kernel prepare rc=\(rc)")
        }
    }

    public override func deallocateRenderResources() {
        upi_kernel_reset(kernel)
        super.deallocateRenderResources()
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = self.kernel
        return { _, timestamp, frameCount, _, outputData, realtimeEventListHead, _ in
            upi_kernel_render(kernel, timestamp, frameCount, outputData, realtimeEventListHead)
            return noErr
        }
    }

    // MARK: - factory presets (the instrument picker in a host)

    public override var factoryPresets: [AUAudioUnitPreset]? { _factoryPresets }

    public override var currentPreset: AUAudioUnitPreset? {
        get { _currentPreset }
        set {
            guard let newValue else { setCurrentPreset(nil); return }
            // number >= 0 → a factory preset (an instrument). number < 0 → a
            // host user preset; unsupported for now (the app owns preset mgmt).
            guard newValue.number >= 0, newValue.number < catalogPacks.count else { return }
            let pack = catalogPacks[newValue.number]
            if pack.id != loadedPack?.id {
                load(packId: pack.id)          // also calls syncCurrentPreset
            } else {
                setCurrentPreset(_factoryPresets[newValue.number])
            }
        }
    }

    private func setCurrentPreset(_ preset: AUAudioUnitPreset?) {
        guard preset?.number != _currentPreset?.number else { return }
        willChangeValue(forKey: "currentPreset")
        _currentPreset = preset
        didChangeValue(forKey: "currentPreset")
    }

    /// Point `currentPreset` at the factory preset for a pack id (or nil).
    private func syncCurrentPreset(for packId: String) {
        setCurrentPreset(catalogPacks.firstIndex { $0.id == packId }.map { _factoryPresets[$0] })
    }

    // MARK: - state (instrument choice must round-trip through a saved project)

    private static let stateKeyPack = "upi.packId"
    private static let stateKeyPreset = "upi.preset"

    public override var fullState: [String: Any]? {
        get {
            var state = super.fullState ?? [:]
            if let pack = loadedPack {
                state[Self.stateKeyPack] = pack.id
                if let data = try? currentPresetSnapshot(name: "State").encoded() {
                    state[Self.stateKeyPreset] = data
                }
            }
            return state
        }
        set {
            super.fullState = newValue
            guard let newValue else { return }
            if let packId = newValue[Self.stateKeyPack] as? String, packId != loadedPack?.id {
                load(packId: packId)
            }
            // Only restore a preset that belongs to the now-loaded pack — a
            // mismatched packId here would otherwise reload the wrong pack.
            if let data = newValue[Self.stateKeyPreset] as? Data,
               let preset = try? InstrumentPreset.decoded(from: data),
               preset.packId.isEmpty || preset.packId == loadedPack?.id {
                apply(preset)
            }
        }
    }

    // MARK: - presets

    public func currentPresetSnapshot(name: String) -> InstrumentPreset {
        var params: [String: Float] = [:]
        var macros: [String: Float] = [:]
        if let tree = _parameterTree {
            for (address, identifier) in backendParamIdentifiers {
                if let p = tree.parameter(withAddress: address) { params[identifier] = p.value }
            }
            // macros[] = macro-strip positions keyed by macro id (0..1),
            // whatever each one targets (backend param, identity axis, bus).
            for macro in loadedPack?.manifest.macros ?? [] {
                if let pos = macroPosition(macro, tree: tree) { macros[macro.id] = pos }
            }
        }
        return InstrumentPreset(packId: loadedPack?.id ?? "",
                                name: name,
                                parameters: params,
                                macros: macros,
                                mpeBendRange: mpeBendRange)
    }

    public func apply(_ preset: InstrumentPreset) {
        if !preset.packId.isEmpty, preset.packId != loadedPack?.id {
            load(packId: preset.packId)
        }
        guard let tree = _parameterTree else { return }
        for (identifier, value) in preset.parameters {
            if let address = backendParamIdentifiers.first(where: { $0.value == identifier })?.key,
               let p = tree.parameter(withAddress: address) {
                p.value = value
            }
        }
        for macro in loadedPack?.manifest.macros ?? [] {
            guard let pos = preset.macros[macro.id] else { continue }
            setMacroPosition(macro, pos, tree: tree)
        }
        mpeBendRange = preset.mpeBendRange
        tree.parameter(withAddress: Self.mpeBendRangeAddress)?.value = preset.mpeBendRange
        upi_kernel_set_mpe_bend_range(kernel, preset.mpeBendRange)
    }

    /// Current 0..1 position of a macro, read back from whatever it targets.
    private func macroPosition(_ macro: InstrumentManifest.MacroDef,
                               tree: AUParameterTree) -> Float? {
        if let pid = macro.parameter,
           let p = tree.allParameters.first(where: { $0.identifier == pid }) {
            let lo = p.minValue, hi = p.maxValue
            return hi > lo ? (p.value - lo) / (hi - lo) : 0
        }
        if let axisId = macro.identityAxis,
           let address = identityAxisAddresses[axisId] {
            return tree.parameter(withAddress: address)?.value
        }
        if let address = macroBusIdentifiers.first(where: { $0.value == macro.id })?.key {
            return tree.parameter(withAddress: address)?.value
        }
        return nil
    }

    /// Drive a macro to a 0..1 position; observer propagates to the kernel.
    private func setMacroPosition(_ macro: InstrumentManifest.MacroDef,
                                  _ pos: Float, tree: AUParameterTree) {
        if let pid = macro.parameter,
           let p = tree.allParameters.first(where: { $0.identifier == pid }) {
            p.value = p.minValue + pos * (p.maxValue - p.minValue)
        } else if let axisId = macro.identityAxis,
                  let address = identityAxisAddresses[axisId] {
            tree.parameter(withAddress: address)?.value = pos
        } else if let address = macroBusIdentifiers.first(where: { $0.value == macro.id })?.key {
            tree.parameter(withAddress: address)?.value = pos
        }
    }
}
