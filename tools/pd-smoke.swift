// pd-smoke.swift — Phase 0.5: proves a Pure Data patch shipped as Instrument
// Pack data renders through the libpd backend.
//
//   swift tools/pd-smoke.swift
//
// Loads the "hello-pd" pack (backend com.upi.backend.libpd, backend/hello.pd),
// plays a note, and checks the output is non-silent — at a non-64-multiple
// block size too, to exercise the ring-buffer reconciliation.

import AVFoundation

let desc = AudioComponentDescription(
    componentType: kAudioUnitType_MusicDevice,
    componentSubType: 0x55504969, componentManufacturer: 0x5550495f,
    componentFlags: 0, componentFlagsMask: 0)

func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data("PD FAIL: \(m)\n".utf8)); exit(1)
}

func run(_ au: AUAudioUnit) {
    // switch to hello-pd via AU full state
    var state = au.fullState ?? [:]
    state["upi.packId"] = "com.upi.instrument.hello-pd"
    au.fullState = state

    let sr = 48_000.0
    let frames: AVAudioFrameCount = 137          // deliberately not a multiple of 64
    let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
    do {
        try au.outputBusses[0].setFormat(fmt)
        au.maximumFramesToRender = 512
        try au.allocateRenderResources()
    } catch { fail("allocate: \(error)") }

    let render = au.renderBlock
    guard let midi = au.scheduleMIDIEventBlock else { fail("no MIDI block") }
    midi(AUEventSampleTimeImmediate, 0, 3, [0x90, 57, 100])   // A3

    let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
    pcm.frameLength = frames
    let abl = pcm.mutableAudioBufferList
    var ts = AudioTimeStamp(); ts.mSampleTime = 0; ts.mFlags = .sampleTimeValid

    var peak: Float = 0
    let blocks = Int(sr / Double(frames)) + 1     // ~1s
    for b in 0..<blocks {
        var f = AudioUnitRenderActionFlags()
        let st = render(&f, &ts, frames, 0, abl, nil)
        guard st == noErr else { fail("render status \(st)") }
        if b > 6, let ch = pcm.floatChannelData {   // skip lop~ ramp-up
            for i in 0..<Int(frames) { peak = max(peak, abs(ch[0][i])) }
        }
        ts.mSampleTime += Double(frames)
        if b == 0 { midi(AUEventSampleTimeImmediate, 0, 3, [0x80, 57, 0]) }
    }

    print(String(format: "hello-pd peak over ~1s @ 137-frame blocks: %.4f", peak))
    if peak < 0.001 { fail("libpd backend produced silence") }
    print("PD PASS")
    exit(0)
}

AVAudioUnit.instantiate(with: desc, options: [.loadOutOfProcess]) { u, e in
    guard let u, e == nil else { fail("instantiate: \(e.map { "\($0)" } ?? "nil")") }
    run(u.auAudioUnit)
}
Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in fail("timed out") }
RunLoop.main.run()
