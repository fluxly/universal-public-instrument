// render-smoke.swift — offline proof that the AU turns MIDI into sound.
//
//   swift tools/render-smoke.swift
//
// Instantiates aumu/UPIi/UPI_, drives its render block directly with a
// note-on, and checks the output is non-silent.

import AVFoundation

let desc = AudioComponentDescription(
    componentType: kAudioUnitType_MusicDevice,
    componentSubType: 0x55504969,      // 'UPIi'
    componentManufacturer: 0x5550495f, // 'UPI_'
    componentFlags: 0, componentFlagsMask: 0)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("SMOKE FAIL: \(msg)\n".utf8))
    exit(1)
}

func run(_ au: AUAudioUnit) {
    let sr = 48_000.0
    let frames: AVAudioFrameCount = 512
    let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!

    do {
        try au.outputBusses[0].setFormat(format)
        au.maximumFramesToRender = frames
        try au.allocateRenderResources()
    } catch { fail("allocate: \(error)") }

    guard let render = Optional(au.renderBlock),
          let sendMIDI = au.scheduleMIDIEventBlock else { fail("no render/MIDI block") }

    sendMIDI(AUEventSampleTimeImmediate, 0, 3, [0x90, 60, 100])

    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    pcm.frameLength = frames
    let abl = pcm.mutableAudioBufferList

    var ts = AudioTimeStamp()
    ts.mSampleTime = 0
    ts.mFlags = .sampleTimeValid

    var peak: Float = 0
    let blocks = Int(sr / Double(frames))   // ~1 second
    for b in 0..<blocks {
        var flags = AudioUnitRenderActionFlags()
        let status = render(&flags, &ts, frames, 0, abl, nil)
        guard status == noErr else { fail("render status \(status)") }
        if let ch = pcm.floatChannelData {
            for i in 0..<Int(frames) { peak = max(peak, abs(ch[0][i])) }
        }
        ts.mSampleTime += Double(frames)
        if b == 0 { sendMIDI(AUEventSampleTimeImmediate, 0, 3, [0x80, 60, 0]) }
    }

    print(String(format: "peak amplitude over ~1s: %.4f", peak))
    if peak < 0.001 { fail("output was silent") }
    print("SMOKE PASS")
    exit(0)
}

AVAudioUnit.instantiate(with: desc, options: [.loadOutOfProcess]) { unit, error in
    guard let unit, error == nil else {
        fail("instantiate: \(error.map { String(describing: $0) } ?? "nil unit")")
    }
    run(unit.auAudioUnit)
}

Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in fail("timed out") }
RunLoop.main.run()
