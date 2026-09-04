// instrument-picker-smoke.swift — Phase 1: the AU exposes its instrument
// library as factory presets, and selecting one loads that pack.
//
//   swift tools/instrument-picker-smoke.swift
//
// Instantiates the AU, checks `factoryPresets` lists every bundled instrument
// as "<Group> — <Name>" with "Test Bench" last, then walks the two real groups
// (Cryptid Garden, Apocabilly Pawn Shop): set `currentPreset`, play a note,
// assert it's audible and that switching actually changed the timbre.

import AVFoundation

let desc = AudioComponentDescription(
    componentType: kAudioUnitType_MusicDevice,
    componentSubType: 0x55504969, componentManufacturer: 0x5550495f,
    componentFlags: 0, componentFlagsMask: 0)

func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data("PICKER FAIL: \(m)\n".utf8)); exit(1)
}

let sr = 48_000.0
let frames: AVAudioFrameCount = 512
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!

func renderNote(_ au: AUAudioUnit) -> [Float] {
    try! au.allocateRenderResources()
    defer { au.deallocateRenderResources() }
    let render = au.renderBlock
    let midi = au.scheduleMIDIEventBlock!
    midi(AUEventSampleTimeImmediate, 0, 3, [0x90, 57, 100])

    let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
    pcm.frameLength = frames
    let abl = pcm.mutableAudioBufferList
    var ts = AudioTimeStamp(); ts.mSampleTime = 0; ts.mFlags = .sampleTimeValid

    var out: [Float] = []
    for block in 0..<70 {
        var f = AudioUnitRenderActionFlags()
        guard render(&f, &ts, frames, 0, abl, nil) == noErr else { fail("render error") }
        if block > 12, let c = pcm.floatChannelData {
            out.append(contentsOf: UnsafeBufferPointer(start: c[0], count: Int(frames)))
        }
        ts.mSampleTime += Double(frames)
    }
    midi(AUEventSampleTimeImmediate, 0, 3, [0x80, 57, 0])
    return out
}

func rms(_ x: [Float]) -> Float {
    x.isEmpty ? 0 : (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
}
func tilt(_ x: [Float]) -> Float {
    guard x.count > 1 else { return 0 }
    var d = [Float](repeating: 0, count: x.count - 1)
    for i in 1..<x.count { d[i - 1] = x[i] - x[i - 1] }
    let r = rms(x); return r > 0 ? rms(d) / r : 0
}

AVAudioUnit.instantiate(with: desc, options: [.loadOutOfProcess]) { u, e in
    guard let u, e == nil else { fail("instantiate: \(e.map { "\($0)" } ?? "nil")") }
    let au = u.auAudioUnit
    try! au.outputBusses[0].setFormat(fmt)
    au.maximumFramesToRender = frames

    guard let presets = au.factoryPresets, !presets.isEmpty else {
        fail("no factoryPresets — the picker isn't wired")
    }
    let names = presets.map(\.name)
    print("factory presets (\(names.count)):")
    names.forEach { print("  · \($0)") }

    guard names.allSatisfy({ $0.contains(" — ") }) else { fail("preset names not grouped") }
    let groups = names.map { String($0.split(separator: " — ")[0]) }
    if let firstTB = groups.firstIndex(of: "Test Bench"),
       !groups[firstTB...].allSatisfy({ $0 == "Test Bench" }) {
        fail("Test Bench group is not last")
    }
    for required in ["Apocabilly Pawn Shop — Chocolate Trumpet",
                     "Apocabilly Pawn Shop — Urdyhay Urddygay",
                     "Cryptid Garden — Gigafoot",
                     "Cryptid Garden — Nessie"] where !names.contains(required) {
        fail("missing instrument: \(required)")
    }

    var prev: [Float] = []
    var prevName = ""
    for preset in presets where !preset.name.hasPrefix("Test Bench — ") {
        au.currentPreset = preset
        guard au.currentPreset?.number == preset.number else {
            fail("currentPreset did not stick for \(preset.name)")
        }
        let sig = renderNote(au)
        let r = rms(sig)
        print(String(format: "  → %@  rms %.4f  tilt %.3f", preset.name, r, tilt(sig)))
        if r < 0.001 { fail("\(preset.name) was silent") }
        if !prev.isEmpty {
            let n = min(prev.count, sig.count), rp = rms(prev)
            var d: Float = 0
            for i in 0..<n {
                let a = rp > 0 ? prev[i] / rp : 0, b = r > 0 ? sig[i] / r : 0
                d += (a - b) * (a - b)
            }
            let diff = (d / Float(n)).squareRoot()
            if diff < 0.2 { fail("\(prevName) and \(preset.name) sound identical (Δrms \(diff))") }
        }
        prev = sig; prevName = preset.name
    }

    print("PICKER PASS")
    exit(0)
}
Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in fail("timed out") }
RunLoop.main.run()
