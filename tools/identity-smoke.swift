// identity-smoke.swift — Phase 1: proves the Identity Layer reaches the backend.
//
//   swift tools/identity-smoke.swift
//
// Loads the "chocolate-trumpet" pack (com.upi.backend.ddsp, one identity axis
// Trumpet↔Clarinet), plays one note at axis position 0.0 and again at 1.0, and
// checks that (a) both renders are non-silent and (b) the timbre actually
// changed — the two waveforms, RMS-normalised, differ materially. Needs the
// DDSP model weights (tools/ddsp-fetch-models.sh; smoke.sh fetches them).

import AVFoundation

let desc = AudioComponentDescription(
    componentType: kAudioUnitType_MusicDevice,
    componentSubType: 0x55504969, componentManufacturer: 0x5550495f,
    componentFlags: 0, componentFlagsMask: 0)

func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data("IDENTITY FAIL: \(m)\n".utf8)); exit(1)
}

let sr = 48_000.0
let frames: AVAudioFrameCount = 512

func renderNote(_ au: AUAudioUnit, identity: Float) -> [Float] {
    guard let axis = au.parameterTree?.allParameters
            .first(where: { $0.identifier == "idaxis_brass_reed" }) else {
        fail("no idaxis_brass_reed parameter — pack/axis not wired")
    }
    axis.value = identity

    if !au.renderResourcesAllocated { try! au.allocateRenderResources() }
    let render = au.renderBlock
    let midi = au.scheduleMIDIEventBlock!
    midi(AUEventSampleTimeImmediate, 0, 3, [0x90, 57, 100])   // A3 on

    let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
    pcm.frameLength = frames
    let abl = pcm.mutableAudioBufferList
    var ts = AudioTimeStamp(); ts.mSampleTime = 0; ts.mFlags = .sampleTimeValid

    var out: [Float] = []
    for block in 0..<90 {                      // ~1s
        var f = AudioUnitRenderActionFlags()
        guard render(&f, &ts, frames, 0, abl, nil) == noErr else { fail("render error") }
        if block > 20, let c = pcm.floatChannelData {   // skip attack + smoothing ramps
            out.append(contentsOf: UnsafeBufferPointer(start: c[0], count: Int(frames)))
        }
        ts.mSampleTime += Double(frames)
    }
    midi(AUEventSampleTimeImmediate, 0, 3, [0x80, 57, 0])
    au.deallocateRenderResources()
    return out
}

func rms(_ x: [Float]) -> Float {
    guard !x.isEmpty else { return 0 }
    return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
}

AVAudioUnit.instantiate(with: desc, options: [.loadOutOfProcess]) { u, e in
    guard let u, e == nil else { fail("instantiate: \(e.map { "\($0)" } ?? "nil")") }
    let au = u.auAudioUnit

    var state = au.fullState ?? [:]
    state["upi.packId"] = "com.upi.instrument.chocolate-trumpet"
    state.removeValue(forKey: "upi.preset")   // don't carry the previous pack's preset
    au.fullState = state

    let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
    try! au.outputBusses[0].setFormat(fmt)
    au.maximumFramesToRender = frames

    let trumpet = renderNote(au, identity: 0.0)
    let clarinet = renderNote(au, identity: 1.0)

    let rt = rms(trumpet), rc = rms(clarinet)
    if rt < 0.001 { fail("silent at identity 0.0") }
    if rc < 0.001 { fail("silent at identity 1.0") }

    // RMS-normalise both, compare
    let n = min(trumpet.count, clarinet.count)
    var diffSq: Float = 0
    for i in 0..<n {
        let a = trumpet[i] / rt, b = clarinet[i] / rc
        diffSq += (a - b) * (a - b)
    }
    let diff = (diffSq / Float(n)).squareRoot()

    print(String(format: "identity 0.0 rms %.4f, 1.0 rms %.4f, normalised Δrms %.2f (expect > 0.3)",
                 rt, rc, diff))
    if diff < 0.3 { fail("identity axis did not change the timbre") }
    print("IDENTITY PASS")
    exit(0)
}
Timer.scheduledTimer(withTimeInterval: 40, repeats: false) { _ in fail("timed out") }
RunLoop.main.run()
