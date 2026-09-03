import AppKit
import CoreAudioKit
import SwiftUI
import UPIRuntime

/// Principal class of the extension. Creates the audio unit and hosts the one
/// macro-strip UI (SwiftUI). Distinct from the app's UI by design.
public final class AudioUnitViewController: AUViewController, AUAudioUnitFactory {

    private(set) var instrument: UPIInstrumentAudioUnit?
    private var hosting: NSHostingController<AnyView>?

    // MARK: AUAudioUnitFactory

    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try UPIInstrumentAudioUnit(componentDescription: componentDescription, options: [])
        instrument = au
        DispatchQueue.main.async { [weak self] in self?.installUIIfPossible() }
        return au
    }

    // MARK: NSViewController

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 340))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.094, alpha: 1).cgColor // Ink Black
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        installUIIfPossible()
    }

    private func installUIIfPossible() {
        guard hosting == nil, let au = instrument else { return }
        let model = InstrumentModel(audioUnit: au)
        let root = AnyView(MacroStripView(model: model))
        let hc = NSHostingController(rootView: root)
        addChild(hc)
        hc.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hc.view)
        NSLayoutConstraint.activate([
            hc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hc.view.topAnchor.constraint(equalTo: view.topAnchor),
            hc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting = hc
    }
}
