// upi_kernel.cpp — see upi_kernel.h

#import <CoreMIDI/CoreMIDI.h>

#include "upi_kernel.h"
#include "upi_registry.h"

#include <atomic>
#include <cmath>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr int   kMaxActiveVoices = (int)UPI_MAX_VOICES;
constexpr float kA4Hz = 440.0f;

inline float midiNoteToHz(float note) {
    return kA4Hz * std::pow(2.0f, (note - 69.0f) / 12.0f);
}

// Per-MIDI-channel running expression state (MPE member channels + plain MIDI).
struct ChannelState {
    float bend      = 0.0f;  // -1..1
    float pressure  = 0.0f;  // 0..1
    float slide     = 0.0f;  // 0..1 (CC74)
};

struct ActiveVoice {
    int32_t  noteId  = -1;
    uint8_t  channel = 0;
    uint8_t  note    = 0;
    uint8_t  held    = 0;
    float    velocity = 0.0f;
    double   startSampleTime = 0.0;
};

} // namespace

struct UPIKernel {
    // backend
    const UPIBackendVTable *vt = nullptr;
    UPIBackend             *backend = nullptr;
    std::string             backendId;
    std::string             instrumentJson;

    // resource resolver, retained from set_backend so re-prepare() can still
    // resolve pack resources (e.g. libpd needs its patch path every prepare).
    UPIResourceResolver     resolver = nullptr;
    void                   *resolverCtx = nullptr;

    // audio config
    double   sampleRate   = 48000.0;
    uint32_t maxFrames    = 512;
    uint32_t channelCount = 2;
    double   runningSampleTime = 0.0;

    // performance-stub state
    ChannelState channels[16];
    ActiveVoice  voices[kMaxActiveVoices];
    int32_t      nextNoteId = 1;
    std::atomic<float> mpeBendRange{ 48.0f };  // semitones for full-scale bend
    std::atomic<float> macros[UPI_MACRO_COUNT];

    // scratch buffers for planar render (channelCount * maxFrames)
    std::vector<float>  planar;
    std::vector<float*> planarPtrs;

    UPIControlFrame frame{};

    UPIKernel() {
        for (auto &m : macros) m.store(0.0f, std::memory_order_relaxed);
        std::memset(&frame, 0, sizeof(frame));
        frame.version = UPI_CONTROL_FRAME_VERSION;
    }

    void destroyBackend() {
        if (vt && backend) vt->destroy(backend);
        vt = nullptr;
        backend = nullptr;
        resolver = nullptr;
        resolverCtx = nullptr;
    }

    ActiveVoice *findVoice(uint8_t ch, uint8_t note) {
        for (auto &v : voices)
            if (v.noteId >= 0 && v.channel == ch && v.note == note) return &v;
        return nullptr;
    }
    ActiveVoice *allocVoice() {
        for (auto &v : voices) if (v.noteId < 0) return &v;
        // steal the oldest
        ActiveVoice *oldest = &voices[0];
        for (auto &v : voices)
            if (v.startSampleTime < oldest->startSampleTime) oldest = &v;
        return oldest;
    }

    void noteOn(uint8_t ch, uint8_t note, uint8_t vel) {
        if (vel == 0) { noteOff(ch, note); return; }
        ActiveVoice *v = findVoice(ch, note);
        if (!v) v = allocVoice();
        v->noteId   = nextNoteId++;
        v->channel  = ch;
        v->note     = note;
        v->held     = 1;
        v->velocity = vel / 127.0f;
        v->startSampleTime = runningSampleTime;
    }
    void noteOff(uint8_t ch, uint8_t note) {
        if (ActiveVoice *v = findVoice(ch, note)) v->held = 0;
    }
    void allNotesOff() {
        for (auto &v : voices) { v.held = 0; v.noteId = -1; }
    }

    void handleMidi1(const uint8_t *b, uint32_t len) {
        if (len == 0) return;
        const uint8_t status = b[0] & 0xF0u;
        const uint8_t ch     = b[0] & 0x0Fu;
        switch (status) {
            case 0x90: if (len >= 3) noteOn(ch, b[1], b[2]); break;
            case 0x80: if (len >= 3) noteOff(ch, b[1]);      break;
            case 0xE0: if (len >= 3) {                        // pitch bend
                const int v14 = ((int)b[2] << 7) | (int)b[1];
                channels[ch].bend = (float)(v14 - 8192) / 8192.0f;
            } break;
            case 0xD0: if (len >= 2)                          // channel pressure
                channels[ch].pressure = b[1] / 127.0f;
            break;
            case 0xB0: if (len >= 3) {                        // control change
                if (b[1] == 74) channels[ch].slide = b[2] / 127.0f;
                else if (b[1] == 120 || b[1] == 123) allNotesOff();
            } break;
            default: break;
        }
    }

    // Minimal MIDI-1.0-in-UMP handling (message type 0x2, 32-bit words).
    void handleUmpWord(uint32_t w) {
        const uint8_t mt = (w >> 28) & 0xF;
        if (mt != 0x2) return;
        const uint8_t status = (w >> 20) & 0xF0;
        const uint8_t ch     = (w >> 16) & 0x0F;
        const uint8_t d1     = (w >> 8) & 0x7F;
        const uint8_t d2     = w & 0x7F;
        const uint8_t bytes[3] = { (uint8_t)(status | ch), d1, d2 };
        handleMidi1(bytes, 3);
    }

    void applyEvents(const AURenderEvent *e) {
        for (; e != nullptr; e = e->head.next) {
            switch (e->head.eventType) {
                case AURenderEventMIDI: {
                    const AUMIDIEvent &m = e->MIDI;
                    handleMidi1(m.data, m.length);
                    break;
                }
                case AURenderEventMIDIEventList: {
                    const MIDIEventList &list = e->MIDIEventsList.eventList;
                    const MIDIEventPacket *pkt = &list.packet[0];
                    for (uint32_t i = 0; i < list.numPackets; ++i) {
                        for (uint32_t w = 0; w < pkt->wordCount; ++w)
                            handleUmpWord(pkt->words[w]);
                        pkt = MIDIEventPacketNext(pkt);
                    }
                    break;
                }
                default: break;
            }
        }
    }

    void buildControlFrame(uint32_t frames) {
        frame.version          = UPI_CONTROL_FRAME_VERSION;
        frame.sample_rate      = sampleRate;
        frame.tempo_bpm        = 0.0;
        frame.host_sample_time = (uint64_t)runningSampleTime;
        frame.transport_playing = 0;

        for (uint32_t i = 0; i < UPI_MACRO_COUNT; ++i)
            frame.macros[i] = macros[i].load(std::memory_order_relaxed);
        for (uint32_t i = 0; i < UPI_IDENTITY_DIMS; ++i)
            frame.identity[i] = 0.0f;

        const float bendRange = mpeBendRange.load(std::memory_order_relaxed);

        uint32_t n = 0;
        for (auto &v : voices) {
            if (v.noteId < 0) continue;
            const ChannelState &cs = channels[v.channel];
            const float bendSemis = cs.bend * bendRange;
            UPIVoiceState &out = frame.voices[n++];
            out.note_id     = v.noteId;
            out.note        = v.note;
            out.gate        = v.held;
            out.velocity    = v.velocity;
            out.pitch_bend  = bendSemis;
            out.pitch_hz    = midiNoteToHz((float)v.note + bendSemis);
            out.pressure    = cs.pressure;
            out.slide       = cs.slide;
            out.age_seconds = (float)((runningSampleTime - v.startSampleTime) / sampleRate);
            if (n >= UPI_MAX_VOICES) break;
        }
        frame.voice_count = n;

        // retire fully-released voices once the backend has had a block to fade
        // them; simple version: drop note-off voices after they stop being held
        // and the backend reports nothing. For Phase 0 we drop on next block.
        for (auto &v : voices)
            if (v.noteId >= 0 && !v.held) v.noteId = -1;

        (void)frames;
    }

    void ensureScratch() {
        const size_t need = (size_t)channelCount * maxFrames;
        if (planar.size() < need) planar.resize(need);
        if (planarPtrs.size() < channelCount) planarPtrs.resize(channelCount);
        for (uint32_t ch = 0; ch < channelCount; ++ch)
            planarPtrs[ch] = planar.data() + (size_t)ch * maxFrames;
    }
};

// ---- C API ---------------------------------------------------------------

extern "C" {

UPIKernel *upi_kernel_create(void) { return new (std::nothrow) UPIKernel(); }

void upi_kernel_destroy(UPIKernel *k) {
    if (!k) return;
    k->destroyBackend();
    delete k;
}

int32_t upi_kernel_set_backend(UPIKernel *k, const char *backend_id,
                               const char *instrument_json,
                               UPIResourceResolver resolver, void *ctx) {
    if (!k || !backend_id) return -1;
    const UPIBackendVTable *vt = upi_registry_lookup(backend_id);
    if (!vt) return -1;

    k->destroyBackend();
    k->vt = vt;
    k->backend = vt->create();
    if (!k->backend) { k->vt = nullptr; return 2; }
    k->backendId = backend_id;
    k->instrumentJson = instrument_json ? instrument_json : "";
    k->resolver = resolver;
    k->resolverCtx = ctx;

    UPIBackendConfig cfg{};
    cfg.sample_rate      = k->sampleRate;
    cfg.max_frames       = k->maxFrames;
    cfg.channel_count    = k->channelCount;
    cfg.resolve_resource = resolver;
    cfg.resolver_ctx     = ctx;
    cfg.instrument_json  = k->instrumentJson.c_str();
    if (k->vt->prepare(k->backend, &cfg) != 0) return 3;
    return 0;
}

int32_t upi_kernel_prepare(UPIKernel *k, double sample_rate,
                           uint32_t max_frames, uint32_t channel_count) {
    if (!k) return -1;
    k->sampleRate   = sample_rate > 0 ? sample_rate : 48000.0;
    k->maxFrames    = max_frames ? max_frames : 512;
    k->channelCount = channel_count ? channel_count : 2;
    k->ensureScratch();
    if (k->vt && k->backend) {
        UPIBackendConfig cfg{};
        cfg.sample_rate     = k->sampleRate;
        cfg.max_frames      = k->maxFrames;
        cfg.channel_count   = k->channelCount;
        cfg.resolve_resource = k->resolver;
        cfg.resolver_ctx     = k->resolverCtx;
        cfg.instrument_json = k->instrumentJson.c_str();
        return k->vt->prepare(k->backend, &cfg);
    }
    return 0;
}

void upi_kernel_reset(UPIKernel *k) {
    if (!k) return;
    k->allNotesOff();
    for (auto &c : k->channels) c = ChannelState{};
    if (k->vt && k->backend) k->vt->reset(k->backend);
}

uint32_t upi_kernel_parameter_count(UPIKernel *k) {
    return (k && k->vt && k->backend) ? k->vt->parameter_count(k->backend) : 0;
}

void upi_kernel_parameter_info(UPIKernel *k, uint32_t index, UPIParameterInfo *out) {
    if (k && k->vt && k->backend) k->vt->parameter_info(k->backend, index, out);
    else if (out) std::memset(out, 0, sizeof(*out));
}

void upi_kernel_set_parameter(UPIKernel *k, uint32_t address, float value) {
    if (k && k->vt && k->backend) k->vt->set_parameter(k->backend, address, value);
}

float upi_kernel_get_parameter(UPIKernel *k, uint32_t address) {
    return (k && k->vt && k->backend) ? k->vt->get_parameter(k->backend, address) : 0.0f;
}

void upi_kernel_set_mpe_bend_range(UPIKernel *k, float semitones) {
    if (k) k->mpeBendRange.store(semitones, std::memory_order_relaxed);
}

void upi_kernel_set_macro(UPIKernel *k, uint32_t i, float v) {
    if (k && i < UPI_MACRO_COUNT) k->macros[i].store(v, std::memory_order_relaxed);
}

void upi_kernel_render(UPIKernel *k,
                       const AudioTimeStamp *ts,
                       AUAudioFrameCount frameCount,
                       AudioBufferList *outABL,
                       const AURenderEvent *events) {
    if (!k || !outABL) return;

    const uint32_t frames = frameCount;
    const uint32_t chans  = outABL->mNumberBuffers;

    if (ts) k->runningSampleTime = ts->mSampleTime;
    if (events) k->applyEvents(events);
    k->buildControlFrame(frames);

    if (frames > k->maxFrames) { k->maxFrames = frames; k->ensureScratch(); }
    const uint32_t renderChans = k->channelCount ? k->channelCount : 1;

    // Render into our own planar scratch (always cleared first).
    for (uint32_t ch = 0; ch < renderChans; ++ch)
        std::memset(k->planarPtrs[ch], 0, sizeof(float) * frames);

    if (k->vt && k->backend && frames > 0)
        k->vt->render(k->backend, &k->frame, k->planarPtrs.data(), frames);

    // Deliver to the host's (non-interleaved) buffer list. When the host hands
    // us a null mData we may point it at our scratch (zero-copy); otherwise copy.
    for (uint32_t ch = 0; ch < chans; ++ch) {
        const uint32_t srcCh = ch < renderChans ? ch : renderChans - 1;
        float *src = k->planarPtrs[srcCh];
        if (outABL->mBuffers[ch].mData == nullptr) {
            outABL->mBuffers[ch].mData         = src;
            outABL->mBuffers[ch].mDataByteSize = frames * sizeof(float);
            outABL->mBuffers[ch].mNumberChannels = 1;
        } else {
            std::memcpy(outABL->mBuffers[ch].mData, src, sizeof(float) * frames);
        }
    }

    k->runningSampleTime += frames;
}

} // extern "C"
