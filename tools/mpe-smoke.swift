// mpe-smoke.swift — proves per-note (MPE) pitch bend reaches the backend.
//
//   swift tools/mpe-smoke.swift
//
// Plays MIDI note 60 on a member channel, once flat and once with a full
// +12-semitone per-note pitch bend, and checks the rendered pitch roughly
// doubles (estimated by zero-crossing rate).

import AVFoundation

let desc = AudioComponentDescription(
    componentType: kAudioUnitType_MusicDevice,
    componentSubType: 0x55504969, componentManufacturer: 0x5550495f,
    componentFlags: 0, componentFlagsMask: 0)

func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data("MPE FAIL: \(m)\n".utf8)); exit(1)
}

func estimateHz(_ au: AUAudioUnit, bend14: Int) -> Double {
    let sr = 48_000.0
    let frames: AVAudioFrameCount = 512
    let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
    try! au.outputBusses[0].setFormat(fmt)
    au.maximumFramesToRender = frames
    if !au.renderResourcesAllocated { try! au.allocateRenderResources() }
    let render = au.renderBlock
    let midi = au.scheduleMIDIEventBlock!

    let ch: UInt8 = 2                     // MPE member channel
    let lsb = UInt8(bend14 & 0x7F), msb = UInt8((bend14 >> 7) & 0x7F)
    midi(AUEventSampleTimeImmediate, 0, 3, [0xE0 | ch, lsb, msb])   // per-note bend
    midi(AUEventSampleTimeImmediate, 0, 3, [0x90 | ch, 60, 100])    // note on

    let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
    pcm.frameLength = frames
    let abl = pcm.mutableAudioBufferList
    var ts = AudioTimeStamp(); ts.mSampleTime = 0; ts.mFlags = .sampleTimeValid

    var crossings = 0, counted = 0
    var prev: Float = 0
    for block in 0..<80 {
        var f = AudioUnitRenderActionFlags()
        guard render(&f, &ts, frames, 0, abl, nil) == noErr else { fail("render error") }
        if block > 15, let c = pcm.floatChannelData {   // skip attack transient
            for i in 0..<Int(frames) {
                let s = c[0][i]
                if (prev <= 0 && s > 0) { crossings += 1 }
                prev = s; counted += 1
            }
        }
        ts.mSampleTime += Double(frames)
    }
    midi(AUEventSampleTimeImmediate, 0, 3, [0x80 | ch, 60, 0])
    au.deallocateRenderResources()
    return Double(crossings) * sr / Double(counted)
}

AVAudioUnit.instantiate(with: desc, options: [.loadInProcess]) { u, e in
    guard let u, e == nil else { fail("instantiate: \(e.map { "\($0)" } ?? "nil")") }
    let au = u.auAudioUnit
    let flat = estimateHz(au, bend14: 8192)          // centre = no bend
    let bent = estimateHz(au, bend14: 16383)         // max = +full range
    let ratio = bent / max(flat, 1)
    // Default MPE bend range is ±48 semitones, so a full-scale member-channel
    // bend should lift note 60 (~262 Hz) by ~4 octaves (~16x).
    print(String(format: "flat ≈ %.0f Hz, bent ≈ %.0f Hz, ratio %.1f (expect ~16)", flat, bent, ratio))
    if ratio < 4 { fail("per-note bend did not raise pitch") }
    print("MPE PASS")
    exit(0)
}
Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in fail("timed out") }
RunLoop.main.run()
