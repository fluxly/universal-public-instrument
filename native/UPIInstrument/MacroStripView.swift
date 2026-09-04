import AudioToolbox
import SwiftUI
import UPIRuntime

// MARK: - Model

@MainActor
final class InstrumentModel: ObservableObject {

    /// All packs in library order (groups A–Z, "Test Bench" last).
    @Published var packs: [InstrumentPack]
    /// The same list bucketed by group, for the sectioned instrument menu.
    @Published var catalog: [(group: String, packs: [InstrumentPack])]
    @Published var selectedPackId: String
    @Published var macroValues: [String: Double] = [:]
    @Published var params: [ParamRow] = []

    /// Display group of the loaded instrument ("Cryptid Garden", …).
    var selectedGroup: String { packs.first { $0.id == selectedPackId }?.group ?? "" }

    struct ParamRow: Identifiable {
        let id: AUParameterAddress
        let identifier: String
        let name: String
        let min: Double
        let max: Double
        var value: Double
    }

    private weak var audioUnit: UPIInstrumentAudioUnit?
    private var observerToken: AUParameterObserverToken?

    init(audioUnit: UPIInstrumentAudioUnit) {
        self.audioUnit = audioUnit
        self.packs = PackLibrary.shared.orderedForCatalog
        self.catalog = PackLibrary.shared.catalog
        self.selectedPackId = audioUnit.loadedPack?.id
            ?? PackLibrary.shared.orderedForCatalog.first?.id ?? ""
        refreshFromTree()
        observeTree()

        // Keep the picker in step when the instrument is changed from the host's
        // own preset menu (factory presets) rather than from this view.
        audioUnit.onInstrumentChange = { [weak self] packId in
            Task { @MainActor in
                guard let self, packId != self.selectedPackId else { return }
                self.selectedPackId = packId
                self.refreshFromTree()
                self.observeTree()
            }
        }
    }

    var manifest: InstrumentManifest? {
        packs.first { $0.id == selectedPackId }?.manifest
    }

    func selectPack(_ id: String) {
        guard id != selectedPackId, let au = audioUnit else { return }
        au.load(packId: id)
        selectedPackId = id
        refreshFromTree()
        observeTree()
    }

    func setMacro(_ macroId: String, _ value01: Double) {
        macroValues[macroId] = value01
        guard let def = manifest?.macros.first(where: { $0.id == macroId }) else { return }

        if let paramId = def.parameter, let param = parameter(withIdentifier: paramId) {
            // macro drives a backend parameter: scale 0..1 into its range
            let lo = Double(param.minValue), hi = Double(param.maxValue)
            param.setValue(AUValue(lo + value01 * (hi - lo)), originator: observerToken)
            syncParamRow(param)
        } else if let axisId = def.identityAxis,
                  let param = parameter(withIdentifier: "idaxis_\(axisId)") {
            param.setValue(AUValue(value01), originator: observerToken)   // 0..1 axis position
        } else if let param = parameter(withIdentifier: "macrobus_\(macroId)") {
            param.setValue(AUValue(value01), originator: observerToken)   // bare macro bus
        }
    }

    func setParam(_ address: AUParameterAddress, _ value: Double) {
        guard let param = audioUnit?.parameterTree?.parameter(withAddress: address) else { return }
        param.setValue(AUValue(value), originator: observerToken)
        if let idx = params.firstIndex(where: { $0.id == address }) { params[idx].value = value }
    }

    // MARK: private

    private func parameter(withIdentifier id: String) -> AUParameter? {
        audioUnit?.parameterTree?.allParameters.first { $0.identifier == id }
    }

    private func refreshFromTree() {
        guard let tree = audioUnit?.parameterTree else { params = []; return }
        params = tree.allParameters
            .filter { $0.identifier != "mpeBendRange" }
            .map {
                ParamRow(id: $0.address, identifier: $0.identifier, name: $0.displayName,
                         min: Double($0.minValue), max: Double($0.maxValue), value: Double($0.value))
            }
        // seed macro positions from their mapped parameters / axes
        var seeded: [String: Double] = [:]
        for def in manifest?.macros ?? [] {
            if let pid = def.parameter, let p = parameter(withIdentifier: pid) {
                let lo = Double(p.minValue), hi = Double(p.maxValue)
                seeded[def.id] = hi > lo ? (Double(p.value) - lo) / (hi - lo) : 0
            } else if let axisId = def.identityAxis, let p = parameter(withIdentifier: "idaxis_\(axisId)") {
                seeded[def.id] = Double(p.value)
            } else if let p = parameter(withIdentifier: "macrobus_\(def.id)") {
                seeded[def.id] = Double(p.value)
            } else {
                seeded[def.id] = Double(def.defaultValue ?? 0)
            }
        }
        macroValues = seeded
    }

    private func observeTree() {
        guard let tree = audioUnit?.parameterTree else { return }
        observerToken = tree.token(byAddingParameterObserver: { [weak self] address, value in
            Task { @MainActor in
                guard let self else { return }
                if let idx = self.params.firstIndex(where: { $0.id == address }) {
                    self.params[idx].value = Double(value)
                }
            }
        })
    }

    private func syncParamRow(_ param: AUParameter) {
        if let idx = params.firstIndex(where: { $0.id == param.address }) {
            params[idx].value = Double(param.value)
        }
    }
}

// MARK: - View

struct MacroStripView: View {
    @ObservedObject var model: InstrumentModel
    @State private var showParams = false

    private let ink       = Color(red: 0.094, green: 0.094, blue: 0.094)
    private let surface   = Color(red: 0.188, green: 0.188, blue: 0.188)
    private let paper     = Color(red: 0.902, green: 0.886, blue: 0.827)
    private let pencil    = Color(red: 0.40, green: 0.40, blue: 0.40)
    private let fluoroCyan = Color(red: 0.0, green: 0.94, blue: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("UNIVERSAL PUBLIC INSTRUMENT")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(pencil)
                    if !model.selectedGroup.isEmpty {
                        Text(model.selectedGroup.uppercased())
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .foregroundStyle(fluoroCyan)
                    }
                }
                Spacer()
                Picker("", selection: Binding(
                    get: { model.selectedPackId },
                    set: { model.selectPack($0) })) {
                    ForEach(model.catalog, id: \.group) { section in
                        Section(section.group) {
                            ForEach(section.packs, id: \.id) { pack in
                                Text(pack.name).tag(pack.id)
                            }
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }

            ForEach(model.manifest?.macros ?? [], id: \.id) { macro in
                macroRow(macro)
            }

            DisclosureGroup(isExpanded: $showParams) {
                VStack(spacing: 8) {
                    ForEach(model.params) { row in
                        HStack {
                            Text(row.name)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(pencil)
                                .frame(width: 90, alignment: .leading)
                            Slider(value: Binding(
                                get: { row.value },
                                set: { model.setParam(row.id, $0) }),
                                in: row.min...row.max)
                            Text(String(format: "%.2f", row.value))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(paper)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("PARAMETERS")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(pencil)
            }
            .tint(fluoroCyan)

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(minWidth: 420, minHeight: 340)
        .background(ink)
    }

    private func macroRow(_ macro: InstrumentManifest.MacroDef) -> some View {
        let value = model.macroValues[macro.id] ?? 0
        // Every macro now routes somewhere: a backend param, an identity axis,
        // or the macro bus (ControlFrame.macros[]). None are inert.
        let inert = false
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(macro.label.uppercased())
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(inert ? pencil : paper)
                Spacer()
                Text(inert ? "—" : String(format: "%.0f%%", value * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(pencil)
            }
            Slider(value: Binding(
                get: { value },
                set: { model.setMacro(macro.id, $0) }),
                in: 0...1)
            .disabled(inert)
            .tint(fluoroCyan)
        }
        .padding(10)
        .background(surface)
        .cornerRadius(4)
    }
}
