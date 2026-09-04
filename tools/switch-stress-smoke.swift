// switch-stress-smoke.swift — hammer instrument switching while the render
// thread is running, the way a host does. Regression test for the kernel's
// backend-swap race (destroy/create/prepare vs. render → OOB crash).
//
//   swift tools/switch-stress-smoke.swift

import AVFoundation

let desc = AudioComponentDescription(
    componentType: kAudioUnitType_MusicDevice,
    componentSubType: 0x55504969, componentManufacturer: 0x5550495f,
    componentFlags: 0, componentFlagsMask: 0)

func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data("SWITCH FAIL: \(m)\n".utf8)); exit(1)
}

let sr = 44_100.0                     // Logic's common rate
let frames: AVAudioFrameCount = 512
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!

AVAudioUnit.instantiate(with: desc, options: [.loadOutOfProcess]) { u, e in
    guard let u, e == nil else { fail("instantiate: \(e.map { "\($0)" } ?? "nil")") }
    let au = u.auAudioUnit
    try! au.outputBusses[0].setFormat(fmt)
    au.maximumFramesToRender = frames

    guard let presets = au.factoryPresets, presets.count >= 4 else { fail("no factory presets") }

    try! au.allocateRenderResources()
    let render = au.renderBlock
    let midi = au.scheduleMIDIEventBlock!

    let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
    pcm.frameLength = frames
    let abl = pcm.mutableAudioBufferList

    let stop = ManagedAtomicFlag()
    var nonFinite = false

    // render thread: never stops, holds a note down
    let renderThread = Thread {
        var ts = AudioTimeStamp(); ts.mSampleTime = 0; ts.mFlags = .sampleTimeValid
        midi(AUEventSampleTimeImmediate, 0, 3, [0x90, 60, 100])
        while !stop.value {
            var f = AudioUnitRenderActionFlags()
            let s = render(&f, &ts, frames, 0, abl, nil)
            if s != noErr { /* transient during teardown is ok */ }
            if let c = pcm.floatChannelData {
                for i in 0..<Int(frames) where !c[0][i].isFinite { nonFinite = true }
            }
            ts.mSampleTime += Double(frames)
        }
    }
    renderThread.stackSize = 512 * 1024
    renderThread.start()

    // main: churn the instrument selection
    var switches = 0
    for round in 0..<40 {
        for preset in presets {
            au.currentPreset = preset
            switches += 1
            usleep(3_000)          // ~3 ms between switches — well inside a render block
        }
        if round % 10 == 0 { FileHandle.standardOutput.write(Data("  round \(round)…\n".utf8)) }
    }

    stop.set()
    Thread.sleep(forTimeInterval: 0.1)

    if nonFinite { fail("render produced non-finite samples during switching") }
    print("SWITCH PASS — \(switches) live instrument switches, no crash, output finite")
    exit(0)
}

/// Tiny spin flag (no import Atomics dependency).
final class ManagedAtomicFlag {
    private let lock = NSLock()
    private var _v = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _v }
    func set() { lock.lock(); _v = true; lock.unlock() }
}

Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in fail("timed out") }
RunLoop.main.run()
