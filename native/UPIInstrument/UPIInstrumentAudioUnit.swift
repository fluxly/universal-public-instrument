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
    /// (0, 1, 2, …). Extension-owned parameters live above this base.
    private static let extensionParamBase: AUParameterAddress = 1 << 16
    private static let mpeBendRangeAddress: AUParameterAddress = extensionParamBase + 0

    private let kernel: OpaquePointer
    private var outputBus: AUAudioUnitBus
    private var _outputBusArray: AUAudioUnitBusArray!
    private var _parameterTree: AUParameterTree!

    /// backend parameter address -> identifier, for preset save/restore
    private var backendParamIdentifiers: [AUParameterAddress: String] = [:]
    private var mpeBendRange: Float = 48

    /// Retained while the current pack is loaded — the kernel keeps a C pointer
    /// to this for re-prepares (see `ResourceResolverBox`).
    private var resolverBox: ResourceResolverBox?

    public private(set) var loadedPack: InstrumentPack?

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
        Self.log.info("loaded pack \(pack.id, privacy: .public) backend \(pack.manifest.backend, privacy: .public)")
        return true
    }

    private func rebuildParameterTree(for pack: InstrumentPack) {
        backendParamIdentifiers.removeAll()
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
            if param.address == Self.mpeBendRangeAddress {
                self?.mpeBendRange = value
                upi_kernel_set_mpe_bend_range(kernel, value)
            } else {
                upi_kernel_set_parameter(kernel, UInt32(truncatingIfNeeded: param.address), value)
            }
        }
        tree.implementorValueProvider = { [kernel, weak self] param in
            if param.address == Self.mpeBendRangeAddress { return self?.mpeBendRange ?? 48 }
            return upi_kernel_get_parameter(kernel, UInt32(truncatingIfNeeded: param.address))
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
            if let data = newValue[Self.stateKeyPreset] as? Data,
               let preset = try? InstrumentPreset.decoded(from: data) {
                apply(preset)
            }
        }
    }

    // MARK: - presets

    public func currentPresetSnapshot(name: String) -> InstrumentPreset {
        var params: [String: Float] = [:]
        if let tree = _parameterTree {
            for (address, identifier) in backendParamIdentifiers {
                if let p = tree.parameter(withAddress: address) { params[identifier] = p.value }
            }
        }
        return InstrumentPreset(packId: loadedPack?.id ?? "",
                                name: name,
                                parameters: params,
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
        mpeBendRange = preset.mpeBendRange
        tree.parameter(withAddress: Self.mpeBendRangeAddress)?.value = preset.mpeBendRange
        upi_kernel_set_mpe_bend_range(kernel, preset.mpeBendRange)
    }
}
