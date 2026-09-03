// state-smoke.swift — proves instrument choice + parameters round-trip through
// AU full state (i.e. survive a host saving and reopening a project).
//
//   swift tools/state-smoke.swift

import AVFoundation

let desc = AudioComponentDescription(
    componentType: kAudioUnitType_MusicDevice,
    componentSubType: 0x55504969,      // 'UPIi'
    componentManufacturer: 0x5550495f, // 'UPI_'
    componentFlags: 0, componentFlagsMask: 0)

func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data("STATE FAIL: \(m)\n".utf8)); exit(1)
}

func makeAU(_ done: @escaping (AUAudioUnit) -> Void) {
    AVAudioUnit.instantiate(with: desc, options: [.loadInProcess]) { u, e in
        guard let u, e == nil else { fail("instantiate: \(e.map { "\($0)" } ?? "nil")") }
        done(u.auAudioUnit)
    }
}

makeAU { first in
    guard let tree = first.parameterTree,
          let gain = tree.allParameters.first(where: { $0.identifier == "gain" }),
          let wave = tree.allParameters.first(where: { $0.identifier == "waveform" }) else {
        fail("no parameter tree / params")
    }
    gain.value = 0.33
    wave.value = 2   // saw

    guard let state = first.fullState else { fail("nil fullState") }
    guard state["upi.packId"] as? String == "com.upi.instrument.hello-sine" else {
        fail("packId missing from state: \(state.keys.sorted())")
    }

    makeAU { second in
        second.fullState = state
        guard let tree2 = second.parameterTree,
              let gain2 = tree2.allParameters.first(where: { $0.identifier == "gain" }),
              let wave2 = tree2.allParameters.first(where: { $0.identifier == "waveform" }) else {
            fail("second AU has no params after restore")
        }
        let dg = abs(gain2.value - 0.33), dw = abs(wave2.value - 2)
        print(String(format: "restored gain=%.3f (want 0.330), waveform=%.1f (want 2.0)",
                     gain2.value, wave2.value))
        if dg > 0.01 || dw > 0.01 { fail("parameters did not round-trip") }
        print("STATE PASS")
        exit(0)
    }
}

Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in fail("timed out") }
RunLoop.main.run()
