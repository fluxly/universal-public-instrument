# Universal Public Instrument (UPI)
## Prototype Specification
### Revision 0.4

**Author:** Shawn Wallace (concept)
**Editors:** revision 0.2–0.4 structural pass

**Purpose:** Define a prototype architecture for a new generation of AI-powered
AUv3 instruments and the UPI ecosystem that hosts, explores, and distributes them.

The neural synthesis approach is deliberately **not** fixed. Magenta Realtime 2
is one candidate backend, not the foundation of the platform.

---

# Changelog

### 0.4

- **Major restructure: one generic AUv3 extension, instruments are data.**
  - `UPI.app` ships exactly one app extension, `UPIInstrument.appex`, embedded
    in `Contents/PlugIns/`.
  - Instruments (Chocolate Trumpet, Glass Clarinet, …) are **Instrument Packs** —
    downloadable data bundles (`instrument.json`, embeddings, model weights,
    Pd patches, presets, artwork, param defs), not executable extensions.
  - Rationale: nested executable code inside a signed `.app` cannot be added or
    replaced without re-signing the outer app. Data can. So new instruments ship
    without an app/binary update.
- **Build pipeline defined.** Tauri `beforeBundleCommand` → `tools/build-au.sh`
  (XcodeGen + `xcodebuild`) → `UPIInstrument.appex`; `tauri build --bundles app`
  builds + signs `UPI.app`; `tools/package.sh` then embeds the `.appex`, signs
  it with its **own** entitlements file (not `--deep`), re-signs `UPI.app`, and
  runs `productbuild` / `create-dmg` + notarize. One command: `npm run package`.
  Repo reorganized: `src-tauri/` (host), `web/` (UI), `native/` (XcodeGen
  project: extension + framework), `backends/`, `instrument-packs/`, `tools/`.
  Resolves the 0.3 "Tauri + Xcode integration" open question.
- **`ControlFrame` locked:** versioned C struct in `backends/include/`,
  additive-only within a major version.
- **Ravel:** the web build imports the `core-dist` bundle; `core` symlink is
  dev-only.
- **Backends are compiled into the single extension binary.** The set of backend
  *architectures* (oscillator, libpd, MRT2, DDSP, …) is fixed at app-release
  time; the set of *instruments* using them is open-ended (data). A libpd
  instrument ships a new `.pd` patch as data with no binary change.
- Added **App Group shared container** for the Instrument Pack library, readable
  by both the app and the sandboxed extension.
- DAW browser UX: the AU appears once as "Universal Public Instrument";
  instrument choice is in-plugin and part of saved state. Optional hybrid: a
  fixed set of marquee instruments also registered as separate `AudioComponents`
  plist entries at build time.

### 0.3

- **Native shell = Tauri.** Locked in.
- **Project generation = XcodeGen.** Locked in.
- **Backend ABI = C ABI / thin C++.** Locked in, to allow MLX / CoreML / ONNX
  and **libpd** (Pure Data patches) as backends.
- Added **libpd / Pure Data** as a first-class Neural Backend family — some AU
  plugins will be Pd patches wrapped by `libpd`.
- **AU codes**: manufacturer code `UPI_`, per-instrument 4-char subtypes.
- Added **MPE (MIDI Polyphonic Expression)** input support as a requirement:
  per-note pitch bend, pressure, and CC74 (slide) flow through `ControlFrame`
  as per-voice fields. Phase 0 is MPE-aware.
- Removed the "Example Code" section — the available reference code is a
  separate, older Pd-centric project and is not a dependency here.
- Reframed "Standalone Performer" as **Performance Mode** inside the app (a
  playing mode), not a separate helper product.
- Resolved Ravel vendoring: two symlinks, `third_party/ravel/core` and
  `third_party/ravel/core-dist`.
- **Ravel is Shawn's own framework.** Developed in tandem via the symlink; fix
  Ravel directly rather than working around it; take its quirks in stride.
- **`docs/raveling-style-guide.md` is authoritative for all web CSS** (dark
  theme, Silkscreen/Quantico, RavelColors accents, Fluoro status indicators).

### 0.2

- Generalized the "Neural Layer" into a pluggable **Neural Backend Interface**.
  An Audio Unit may use any architecture (MRT2, DDSP, RAVE, a physical model, a
  plain oscillator) as long as it conforms to the interface.
- Marked the **Performance Layer** as a stub. Its responsibilities are
  enumerated but its design is deferred.
- Added **Phase 0: Hello World Audio Unit** — a sine / wavetable tone instrument
  that proves the MIDI → audio → host path with no neural code.
- Added **Repository Structure** and **Third-Party Dependencies** sections
  (monorepo, Xcode, JUCE-free; web UI vendored via symlink under `third_party/`).
- Added **UI Architecture**: the app is a web app in a native shell; each AU
  plugin has its own distinct UI; the app can instantiate multiple AU plugins.
- Added **Open Questions**.
- Reframed "Chocolate Trumpet" as the reference instrument rather than the
  platform's reason for existing.

### 0.1

- Initial concept draft.

---

# Vision

UPI is not a collection of plugins.

UPI is a platform for exploring and performing with expressive neural
instruments.

The AUv3 plugin is only one client of the platform.

The standalone application becomes the user's instrument workshop, library,
identity explorer, updater, and marketplace.

The plugin becomes the low-latency performance surface.

---

# Goals

Build a prototype that demonstrates:

- Neural (or otherwise learned / model-driven) audio synthesis inside a
  production-quality AUv3.
- A standalone macOS application that manages and hosts those instruments.
- Separation of:
  - performance behavior
  - acoustic identity
  - synthesis backend
- A downloadable identity / instrument library.
- A future path toward many instruments sharing one runtime.

The prototype uses one reference instrument to keep scope contained:

> Chocolate Trumpet

Chocolate Trumpet is an example, not a dependency. The architecture must hold up
if the second instrument is a granular pad or a bowed-string model with nothing
in common with the first.

---

# Terminology

| Term | Meaning |
|---|---|
| **UPI App** | Standalone macOS application. Web UI (Ravel components) in a Tauri shell. Library, store, explorer, updater, Performance Mode. Produces the final `UPI.app` bundle. |
| **UPI Instrument Extension** | The single AUv3 app extension, `UPIInstrument.appex`, embedded in `UPI.app/Contents/PlugIns/`. Generic host for every instrument. Contains all backend implementations. Built by Xcode. |
| **UPI Runtime** | Shared native framework/static lib linked by both the app and the extension. Backend registry, Instrument Pack loader, model/resource cache, identity representation, preset database. |
| **Instrument Pack** | A downloadable **data** bundle that defines one instrument: `instrument.json` + identity embeddings, model weights and/or Pd patches, presets, artwork, sample sets, parameter definitions. No executable code. Lives in the App Group shared container. |
| **Instrument** | The user-facing musical object an Instrument Pack describes = a chosen Backend + Identity config + Performance config + presets + assets. |
| **Backend** | A synthesis engine *compiled into the extension binary* — oscillator, libpd, an MRT2/MLX runner, DDSP, a physical model. Conforms to the backend C ABI. An Instrument Pack names which backend it needs and supplies that backend's data. |
| **Identity** | A position in a learned acoustic space (e.g. "70% flugelhorn, 30% bass clarinet, bright, breathy"). |
| **MPE** | MIDI Polyphonic Expression — per-note pitch bend, pressure, and slide (CC74). Required input. |

---

# Product Architecture

```
                              UPI.app
   ┌───────────────────────────────────────────────────────────┐
   │  Contents/MacOS/UPI            ← Tauri host app            │
   │    · Library / Store / Explore / Presets                   │
   │    · Performance Mode  (hosts the extension via AVAudio…)  │
   │    · Downloads Instrument Packs into the shared container  │
   │                                                           │
   │  Contents/PlugIns/UPIInstrument.appex   ← the one AUv3     │
   │    ┌─────────────────────────────────────────────────┐    │
   │    │ Performance Layer (stub) → Identity Layer         │    │
   │    │              ↓ ControlFrame                       │    │
   │    │ Backend registry (all compiled in):              │    │
   │    │   oscillator · libpd · MRT2/MLX · DDSP · …       │    │
   │    │ Loads the selected Instrument Pack's data,       │    │
   │    │ instantiates the backend it names.              │    │
   │    └─────────────────────────────────────────────────┘    │
   └───────────────────────────┬───────────────────────────────┘
                               │  reads
   ┌───────────────────────────▼───────────────────────────────┐
   │  App Group shared container — Instrument Pack library      │
   │    chocolate-trumpet/   glass-clarinet/   forest-horn/     │
   │    (instrument.json, weights, .pd patches, presets, art)   │
   └───────────────────────────────────────────────────────────┘

   Both UPI.app's Performance Mode and any third-party DAW load the
   same UPIInstrument.appex. Instrument choice is plugin state.
```

The extension is a generic engine. Backends are compiled in; instruments are
data. Shipping "Chocolate Oboe" tomorrow means publishing an Instrument Pack —
no extension rebuild, no app re-sign, no re-distribution.

A genuinely new *backend architecture* (say, adding a CoreML runner where the
shipped binary only had oscillator + libpd) does require an app update. That is
expected to be rare.

---

# Why AUv3?

Unlike traditional plugin formats, AUv3 is packaged inside a normal macOS
application.

```
UPI.app

    Contents/
        MacOS/UPI
        PlugIns/
            UPIInstrument.appex
```

Installing the application automatically installs the Audio Unit extension.

Advantages:

- Mac App Store distribution
- Standalone application included
- Shared resources
- Automatic updates
- Better onboarding
- Opportunity for an integrated ecosystem

The application is no longer just an installer. It becomes part of the product.

Apple's AUv3 architecture is explicitly built around app extensions embedded in a
host application.

> Replace with a real link to Apple's Audio Unit v3 documentation.

### Why exactly one extension

An `.appex` is **nested executable code** inside the signed `.app`. Adding or
replacing it changes the app's signed contents and invalidates the outer
signature — you cannot drop a new instrument-as-extension into an app users have
already installed without shipping and re-signing the whole app.

So UPI ships **one** generic extension and treats instruments as data. See
**One Extension, Many Instruments** and **Build & Packaging Pipeline** below.

---

# One Extension, Many Instruments

`UPIInstrument.appex` is a generic instrument engine. It contains:

- the Performance Layer (stub) and Identity Layer,
- the **backend registry** — every backend implementation, compiled in
  (oscillator, libpd, MRT2/MLX runner, DDSP, …),
- an Instrument Pack loader,
- the plugin UI shell.

It contains **no instrument-specific content**. That lives in Instrument Packs.

### Instrument Pack

A directory (delivered as a signed archive) of pure data:

```
chocolate-trumpet/
├── instrument.json          ← manifest: name, backend id, params, identity axes
├── backend/                 ← data for the named backend
│   ├── weights.mlx          ←   (MRT2 example)
│   └── patch.pd             ←   (or a libpd example — a patch is data)
├── identity/
│   └── embeddings.bin
├── presets/
│   └── *.upipreset
├── params.json              ← parameter definitions + ranges + mappings
└── art/
    ├── icon.png
    └── hero.png
```

`instrument.json` sketch:

```jsonc
{
  "id": "com.upi.instrument.chocolate-trumpet",
  "name": "Chocolate Trumpet",
  "version": "1.0.0",
  "backend": "com.upi.backend.mrt2-small",   // must exist in the shipped binary
  "minExtensionVersion": "1.0",
  "identityAxes": [
    { "id": "brass_reed", "label": "Trumpet ↔ Clarinet" }
  ],
  "macros": ["Expression", "Identity", "Brightness", "Air", "Attack"],
  "resources": { "weights": "backend/weights.mlx", "embeddings": "identity/embeddings.bin" }
}
```

### Consequences

- **New instrument = new Instrument Pack.** No extension rebuild, no app
  re-sign, no re-distribution. A libpd instrument is especially cheap — the
  patch *is* the data.
- **New backend architecture = app update.** The binary carries the code. Rare
  by design; keep the backend set small and deliberate.
- `instrument.json.backend` is validated against the registry at load time; an
  unknown backend id → a clear "update UPI to use this instrument" message.
- `minExtensionVersion` lets a pack require a newer engine.

### Where the extension appears in a DAW

Default: one entry, **"Universal Public Instrument"** (`aumu UPIi UPI_`).
Instrument selection is inside the plugin and is saved as part of AU state (so a
project reopens with the right instrument).

Optional hybrid for marquee instruments: register a fixed handful of extra
`AudioComponents` in the extension's `Info.plist` at build time (e.g.
`aumu cht0 UPI_` → defaults to Chocolate Trumpet). They show as their own
browser entries but run the same binary. This list is frozen at release;
everything else is reached through the in-plugin picker.

> **Open question:** does hiding instruments behind one AU entry hurt
> discoverability enough to justify the hybrid from day one? (Leaning: ship the
> single entry for Phase 0–1, add marquee entries later.)

---

# Build & Packaging Pipeline

**Mental model: Tauri builds the host. `tools/package.sh` assembles the final
Apple product.**

Tauri's `beforeBundleCommand` runs *before* Tauri generates the `.app` — it is
good for producing the `.appex`, but **not** a window in which to inject code
into a finished `.app` before Tauri signs it. So the extension is built in the
hook and embedded + re-signed afterward. This is the pattern Tauri
app-extension projects use today.

```
  src-tauri/tauri.conf.json
     beforeBundleCommand: bash tools/build-au.sh
              │
              ▼
   tools/build-au.sh
     xcodegen generate  (native/project.yml)
     xcodebuild          → build/UPIInstrument.appex     [unsigned]
              │
              ▼
   tauri build --bundles app
     bundles the web UI + Rust host
     produces AND signs  UPI.app   (extension not yet inside)
              │
              ▼
   tools/package.sh                         ← owns all Apple-specific assembly
     1. locate UPI.app
     2. cp build/UPIInstrument.appex → UPI.app/Contents/PlugIns/
     3. codesign the .appex  with its OWN entitlements file
            (native/UPIInstrument/UPIInstrument.entitlements)
            — explicit, NOT relying on --deep / recursive signing
     4. codesign UPI.app  (outer, over final contents)
     5. productbuild  UPI.app → UPI.pkg      (App Store / installer)
        and / or  create-dmg → UPI.dmg       (direct distribution)
     6. notarize + staple  (direct-distribution path)
              │
              ▼
        UPI.pkg  /  UPI.dmg   (shippable)
```

Driven by one npm script:

```
npm run package   =   tauri build --bundles app  &&  ./tools/package.sh
```

Rules this encodes (Apple's model):

- The extension is a **separate signed bundle** embedded in the app; it carries
  **its own entitlements** (App Group, sandbox, `com.apple.security.…` inherit),
  signed explicitly with `--entitlements` — recent Tauri issues show `.appex`
  entitlements not surviving `--deep` / recursive signing, so we never rely on
  it.
- **Nested code is signed before the outer bundle** — the app must be signed
  last, over the final bundle contents (so step 4 re-signs after the `.appex`
  lands, even though `tauri build` already signed once).
- The host app's own entitlements live in `src-tauri/Entitlements.plist`
  (App Group, sandbox, hardened runtime); the two targets share a signing
  identity and the same App Group id.
- App Store submission uses `productbuild` to make the signed installer `.pkg`
  with the extension already inside — matches Tauri's App Store guidance.

> **Open question:** exact `codesign` flag set and ordering for the re-sign in
> step 4 (resource rules, `--preserve-metadata`), and whether `productbuild`
> vs. `xcrun altool`/`notarytool` + Transporter is the smoother MAS path. To be
> nailed down when the pipeline is first built.

---

# Neural Backend Interface

The single most important architectural idea (introduced in 0.2, refined in 0.4).

> The model is NOT the instrument.
> The model is also NOT a fixed choice.
> Backends are code (compiled into the extension); instruments are data.

An instrument's synthesis is provided by a **Backend** — a component compiled
into `UPIInstrument.appex` that conforms to a small, stable interface. The
Runtime, the app, and the plugin host code never reference a specific model
architecture; they look a backend up in the **registry** by the id an Instrument
Pack names.

**ABI decision:** the contract is a **C ABI** (a struct of function pointers /
vtable), with a thin C++ base class provided for convenience. This is what lets
MLX, CoreML, ONNX, Torch, and **libpd** all sit behind the same interface
regardless of their implementation language or runtime.

The backend receives its instrument-specific data (weights, `.pd` patch,
embeddings) through `load(resources:)` — pointing at files in the selected
Instrument Pack. The backend *code* ships with the app; the backend *data* ships
with the pack.

Conceptual interface (names illustrative, final API TBD), shown here in
pseudo-Swift for readability — the real header is C:

```
protocol NeuralBackend {

    // Identity / lifecycle
    static var identifier: String            // e.g. "com.upi.backend.mrt2-small"
    static var capabilities: BackendCapabilities

    func load(resources: ResourceBundle) throws
    func prepare(sampleRate: Double, maxFrames: Int)
    func reset()

    // Per-block render
    //   control: expression, identity vector, per-note (MPE) state from the
    //            Performance + Identity layers (opaque struct, versioned)
    //   output:  interleaved or planar float buffers
    func render(control: ControlFrame, output: AudioBufferList, frames: Int)

    // Introspection for UI / automation
    var parameters: [BackendParameter] { get }
    var latencyFrames: Int { get }
    var tailFrames: Int { get }
}
```

`BackendCapabilities` declares things the rest of the system needs to know
without caring how they are implemented, e.g.:

- realtime vs. lookahead / block-latency
- monophonic vs. polyphonic vs. paraphonic
- runs on audio thread vs. requires a render thread + ring buffer
- accepts continuous identity morphing vs. discrete identity switching
- resource footprint (RAM, disk, warm-up time)

### Candidate backends

| Backend | Notes |
|---|---|
| **Oscillator / wavetable** | Phase 0. No model. Proves the path. |
| **libpd / Pure Data patch** | A `.pd` patch driven by `libpd`. Audio-thread capable. Lets patches authored in Pd ship as instruments. First-class, planned for real use. |
| **Magenta Realtime 2 Small** | ~450 MB MLX model. Realtime-capable on Apple Silicon. Likely needs a render thread + ring buffer, not pure audio-thread. |
| **DDSP-style** | Lightweight, audio-thread friendly, good for breath/brass. |
| **RAVE / other autoencoders** | Fast, timbre-transfer oriented. |
| **Physical model** | Deterministic, tiny, no ML at all — still a valid backend. |

### libpd backend notes

- `libpd` is single-instance-per-process by default; running multiple Pd-backed
  AU instances needs either the multi-instance build of libpd or one Pd instance
  per `.appex` process (out-of-process AU hosting makes this clean).
- Pd patches receive control via `libpd_float` / `libpd_message` sends mapped
  from `ControlFrame` fields; audio via `libpd_process_float`.
- Patch + abstractions + externals ship inside the plugin's resource bundle.
- Block size: Pd's internal 64-sample block must be reconciled with the host
  render block (accumulate / ring buffer).

### Threading reality

Large models will not run on the audio render thread. The interface must support
a backend that:

1. receives `ControlFrame`s on the audio thread (lock-free),
2. renders audio on its own thread,
3. returns audio through a ring buffer with a declared latency.

Phase 0's oscillator backend runs directly on the audio thread and reports zero
latency — this is the degenerate case of the same interface. A libpd backend
also runs on the audio thread (with internal block reconciliation) and reports
zero or small latency.

---

# Layered Design

```
MIDI / MPE in
        ↓
Performance Layer   (STUB — deferred)
        ↓
Identity Layer
        ↓  ControlFrame (versioned)
Backend             (compiled in; selected + fed by the loaded Instrument Pack)
        ↓
audio out
```

Data flows down as a versioned `ControlFrame`. Each layer is independently
replaceable. All three layers live inside `UPIInstrument.appex`; only the
backend's *data* comes from the pack.

---

# Performance Layer  *(STUB — design deferred)*

> **Status:** enumerated, not designed. Phase 0 and the early Phase 1 work
> should treat this layer as a thin pass-through: MIDI in → normalized
> note/expression events → `ControlFrame`. Everything below is a placeholder
> for a later revision.

This is where the instrument becomes musical.

Intended responsibilities (future):

- Breath model
- Embouchure model
- Attack modeling
- Release behavior
- Vibrato
- Instability
- Phrase memory
- Persistent hidden state
- MIDI interpretation

This layer is intended to survive note boundaries so the instrument feels like
one continuous physical object rather than independent note generation.

Minimum viable stub for now:

```
struct PerformanceStub {
    // MIDI (incl. MPE) note on/off, velocity, per-note pitch bend,
    // per-note pressure, per-note CC74 (slide), channel CCs
    //   → normalized per-voice fields in ControlFrame
    // No memory, no physical modeling, no hidden state.
    func process(_ midi: MIDIEventList) -> [ControlFrame]
}
```

### MPE (MIDI Polyphonic Expression)

MPE input is a **requirement**, not a later add-on.

- The stub parses the MPE lower/upper zone configuration (RPN 6) or accepts a
  fixed zone from settings.
- Per active voice it tracks: pitch bend (→ pitch, respecting the zone bend
  range), channel pressure (→ pressure), CC74 (→ slide / "timbre" Y).
- These land in `ControlFrame` as a per-voice array, not global values.
- Backends that are monophonic or ignore per-note data collapse the array;
  polyphonic expressive backends (MRT2, Pd patches, DDSP) read it per voice.
- Non-MPE input still works: a single channel maps to one voice's expression
  fields.

`ControlFrame` therefore carries, per block:

```
global:   tempo, transport, global identity vector, macro params
perVoice: [ { noteId, pitchHz, gate, velocity,
              pitchBend, pressure, slideY, age } ]
```

---

# Identity Layer

Responsible for navigating acoustic space.

Input:

```
Trumpet <-------> Clarinet
```

Internally:

- style embeddings
- interpolation
- identity curves
- brightness
- airiness
- age
- breathiness

Roadmap:

- Initially: one-dimensional interpolation.
- Later: 2D identity manifold.
- Eventually: global acoustic map.

The Identity Layer emits an opaque identity vector inside the `ControlFrame`.
Backends that only support discrete identity switching quantize it; backends that
support continuous morphing use it directly (declared via
`BackendCapabilities`).

For Phase 0 the identity vector is present but ignored by the oscillator
backend.

---

# Backend Layer

See **Neural Backend Interface** above. Backends are compiled into the
extension; each Instrument Pack names one and supplies its data.

Responsibilities:

- synthesis
- decoding
- audio generation

For the reference instrument, no user prompting and no free-text conditioning.
The backend is a rendering engine driven by the layers above it, not a
generative toy.

---

# Reference Instrument: Chocolate Trumpet

Ships as the `chocolate-trumpet` Instrument Pack. A continuously morphable
expressive instrument positioned between:

- Trumpet
- Flugelhorn
- Cornet
- Clarinet
- Bass Clarinet

The prototype intentionally limits itself to one acoustic neighborhood rather
than becoming a universal instrument on day one.

Chocolate Trumpet exercises the hard cases: continuous identity morphing, a
large realtime model, breath-driven expression. If the architecture serves it,
simpler instruments fall out easily.

---

# UI Architecture

Two distinct UI surfaces, deliberately not shared:

### 1. UPI App — web app in a native shell

- HTML / CSS / JS UI built with **Ravel web components**
  (vendored via symlink — see Third-Party Dependencies).
- Hosted in a **Tauri** shell (macOS first; keeps the door open for other
  platforms later).
- Rich, exploratory, unhurried. The identity manifold, the store, docs,
  preset search, Performance Mode all live here.
- Talks to the UPI Runtime through Tauri commands / a native bridge into the
  `UPIRuntime` framework (see Open Questions for the exact mechanism).
- **All CSS decisions follow `docs/raveling-style-guide.md`** — dark theme
  (`#181818` page / `#303030` surface / `#222222` well), Silkscreen for UI text
  and Quantico (`.text`) for prose, accents only from `core/utilities/RavelColors.ts`,
  status indicators only from the Fluoro palette, 10px decorative rules. Deviate
  only with explicit sign-off.
- Ravel is **Shawn's own framework**, developed in tandem via the symlink. Take
  its quirks in stride: work around rough edges in app code, and when the fix
  belongs in Ravel, change Ravel directly rather than papering over it. The
  framework and the app move together.

### 2. Extension UI — one shell, instrument-skinned, minimal

- `UPIInstrument.appex` ships **one** `AUViewController`, not a UI per
  instrument.
- It has two regions:
  1. an **instrument picker** (which Instrument Pack is loaded), and
  2. the **macro strip** for the loaded instrument, driven by
     `instrument.json.macros`:

```
Expression   Identity   Brightness   Air   Attack
```

- The pack supplies labels, ranges, artwork, and identity-axis names; the shell
  renders them. No per-instrument view code.
- No pages of synthesizer controls.
- Implementation: native (`AUViewController` + SwiftUI) is the default; a small
  embedded webview is allowed if it buys us the Ravel component set.
- If the shell uses a webview it follows `docs/raveling-style-guide.md`. A
  native SwiftUI shell still borrows the palette (Ink Black surfaces, Fluoro
  status colors) so the app and the plugin feel like one product.

> **Rationale:** the extension runs in a DAW under tight latency and resource
> constraints and needs a focused performance surface. The app is the workshop.
> Forcing one UI to serve both compromises both — so the app UI (rich, Ravel)
> and the extension shell (minimal, macro strip) stay separate even though both
> follow the same style guide.

There is exactly **one** `.appex`. "Many instruments" is data loaded into it,
not many extensions.

---

# Standalone Application

The application should feel like a modern creative tool.

Primary pages:

- **Library** — installed Instrument Packs
- **Explore** — identity manifold
- **Store** — download Instrument Packs
- **Presets** — searchable
- **Performance Mode** — play an instrument directly in the app (see below)
- **Performance Recorder** — capture gestures *(Phase 2)*
- **Settings** — storage, backend/model management, updates

---

# Performance Mode

Performance Mode is a **playing mode inside the app**, not a separate product.
(Revision 0.1's "Standalone Performer" was this — a mode, not an AU helper.)

In Performance Mode the app:

- loads one installed Instrument Pack and plays it,
- drives it from a MIDI/MPE controller, an on-screen keyboard/XY surface, or the
  Performance Recorder,
- renders to the default output device,
- shows the extension's macro strip plus larger performance surfaces.

### How it renders sound

The app hosts `UPIInstrument.appex` through `AUAudioUnit` / `AVAudioEngine` —
i.e. the app is also a minimal AU host — and tells it which Instrument Pack to
load. Same code path as a DAW loading the extension. This is an implementation
detail of Performance Mode, not a user-facing "host" feature.

> **Open question:** in-process vs. out-of-process AU hosting. Out-of-process is
> safer (crash isolation), is the modern AUv3 default, and makes multi-instance
> libpd tractable. Leaning out-of-process.

---

# Instrument Store

The store sells **Instrument Packs** — data, not plugins:

```
UPI  →  Install  →  Download Instrument Pack

    Chocolate Trumpet     (backend: mrt2-small)
    Irish Yeti            (backend: libpd)
    Forest Horn           (backend: ddsp)
    Glass Clarinet        (backend: mrt2-small)
    Future instruments
```

Each pack is a signed archive downloaded into the App Group shared container,
verified, unpacked, and registered in the Runtime's library index. Model weights
and Pd patches are just files inside the pack. No new executable code crosses
the wire, so a purchase never requires an app update (unless the pack's backend
id isn't in the installed binary — then the store prompts to update UPI first).

---

# Shared Container & Runtime

### Where packs live

```
~/Library/Group Containers/<AppGroupID>/InstrumentPacks/
    chocolate-trumpet/
    glass-clarinet/
    forest-horn/
```

Both `UPI.app` (writes, on download) and `UPIInstrument.appex` (reads, on load)
reach this directory via the shared App Group entitlement. The extension never
downloads; the app never renders audio.

### Shared model objective

Long-term:

```
One extension  →  one MRT2 runtime  →  many identities (packs)
```

Instead of a separate model per instrument. Benefits: reduced memory, faster
loading, shared cache, faster updates.

Caveat: sharing only applies **within a backend**. Two packs that both name
`mrt2-small` can share the loaded runtime and (where identical) weights; an
`mrt2-small` pack and a `ddsp` pack cannot. The Runtime's cache is keyed by
backend id + resource hash.

---

# Presets

A preset stores:

```
Instrument Pack id (+ min version)
Identity position
Performance parameters
Expression defaults
Controller mappings
Backend parameter overrides
```

Not hundreds of unrelated parameters. Factory presets ship inside the pack
(`presets/*.upipreset`); user presets are stored by the app and reference the
pack id so they travel with the instrument.

---

# Extension Responsibilities

- Low latency
- MIDI, including **MPE** (per-note pitch / pressure / slide)
- Audio rendering
- Automation
- Host synchronization
- Loading the selected Instrument Pack from the shared container
- Preset loading
- The one macro-strip UI shell

Nothing more. No downloading, no marketplace, no instrument-specific code.

---

# Application Responsibilities

- Downloads
- Updates
- Marketplace
- Exploration
- Documentation
- Identity editing
- Community features
- Licensing
- Performance Mode (hosting an instrument for direct playback)

---

# Repository Structure

Monorepo. Native. **XcodeGen**-generated project. **No JUCE.** Swift + C/C++
where needed.

```
_universal-public-instrument-2/
├── docs/
│   └── upi-app-spec.md            ← this file
├── package.json                  ← npm scripts (dev, package, …)
│
├── src-tauri/                     ← the Tauri host  → produces UPI.app
│   ├── tauri.conf.json            ←   beforeBundleCommand: bash tools/build-au.sh
│   ├── Entitlements.plist         ←   host app: sandbox, network.client (+ App Group later)
│   ├── capabilities/default.json  ←   Tauri v2 permission set for the main window
│   ├── icons/                     ←   generated icon set (macOS subset)
│   └── src/{main,lib}.rs          ←   Rust shell; app_status command (FFI bridge: later)
├── web/                           ← web UI (Phase 0 stub; Ravel dist bundle later)
│   └── index.html · styles.css · main.js
│
├── native/                       ← everything Xcode/XcodeGen builds
│   ├── project.yml                ←   XcodeGen spec: extension + framework only
│   ├── UPI.xcodeproj              ←   generated, git-ignored
│   ├── UPIInstrument/             ←   the single AUv3 app extension (com.upi.app.UPIInstrument)
│   │   ├── Kernel/upi_kernel.{h,mm}   ← RT core: MIDI/MPE → ControlFrame → backend
│   │   ├── *AudioUnit.swift · *ViewController.swift · MacroStripView.swift
│   │   ├── UPIInstrument-Bridging.h
│   │   ├── Info.plist
│   │   └── UPIInstrument.entitlements  ← .appex: sandbox + get-task-allow (+ App Group later)
│   ├── UPIRuntime/                ←   framework: InstrumentPack / PackLibrary / InstrumentPreset
│   └── Local.xcconfig.example     ←   copy → Local.xcconfig for a signed build
│
├── backends/                     ← C ABI backends, compiled INTO the extension
│   ├── include/upi_backend.h · upi_control_frame.h   ← the contract (v1)
│   ├── OscillatorBackend/         ←   Phase 0
│   ├── registry/upi_registry.{h,c}←   backend id → entry point
│   ├── PdBackend/                 ←   libpd wrapper (Phase 0.5)
│   └── MRT2Backend/               ←   later
│
├── instrument-packs/             ← data only, no code
│   ├── hello-sine/                ←   Phase 0 built-in pack (instrument.json + preset)
│   ├── hello-pd/                  ←   Phase 0.5 built-in pack
│   └── chocolate-trumpet/         ←   Phase 1
│
├── third_party/
│   ├── ravel/{core,core-dist}     → symlinks into a local Ravel checkout
│   └── libpd/                     → symlink or submodule
│
└── tools/
    ├── build-au.sh               ← xcodegen generate + xcodebuild → build/UPIInstrument.appex
    ├── package.sh                ← embed .appex → UPI.app, sign inside-out, verify, dmg/pkg, notarize
    ├── smoke.sh                  ← Phase 0 gate: build + install + register + auval + render/state/MPE
    ├── unregister.sh             ← clear stale AU registrations
    ├── {render,state,mpe}-smoke.swift
    ├── link-third-party.sh + third-party.config
```

`native/project.yml` covers the **extension and the shared framework** — the
shipping host is Tauri. `tools/build-au.sh` runs `xcodegen generate` +
`xcodebuild` and drops `build/UPIInstrument.appex` (self-contained: it embeds
`UPIRuntime.framework`); Tauri's `beforeBundleCommand` invokes it, then
`tools/package.sh` embeds that `.appex` into the Tauri-built `UPI.app`.

> **Naming note:** an earlier sketch called the extension target `UPIAudioUnit`.
> Standardized on **`UPIInstrument`** everywhere (matches the `.appex` name and
> the `UPIi` AU subtype). Adjust if you prefer the other.

A few built-in Instrument Packs ship inside `UPI.app` (in the app's Resources or
seeded into the container on first run) so the product works offline out of the
box; everything else is downloaded.

---

# Third-Party Dependencies

### Ravel web components

- **Shawn's own framework**, not a third party in the usual sense — vendored by
  symlink so UPI and Ravel evolve together. When something in Ravel is wrong for
  UPI, the right move is often to fix Ravel, not to work around it in app code.
  Expect quirks; take them in stride.
- Used for the **UPI App** web UI only. Not used in native AU plugin UIs.
- Brought in as **two symlinks** into a local Ravel checkout:

```
third_party/ravel/core       → <local ravel checkout>/core
third_party/ravel/core-dist  → <local ravel checkout>/core-dist
```

- `core` is the component source (custom-element registrations, utilities,
  `libs/`); `core-dist` is the **built distribution — this is what the web UI
  imports.** `core` is kept symlinked for local development / debugging only.
- The style guide's import rules imply the dev server serves the Ravel bundle at
  web root `/core/` (e.g. `<script src="/core/libs/p5.min.js">`) with a root
  `./index.ts` entry — never import `./core/index.ts` directly (it only
  re-exports utilities, not element registrations). Map `/core/` → `core-dist`.
- The web build must fail with a clear, actionable error when the symlinks are
  absent (fresh clone / CI), pointing at `tools/link-third-party.sh`.

### Ravel style guide

`docs/raveling-style-guide.md` is **authoritative for all CSS** in the app's web
UI (and any webview-based plugin UI). Key non-negotiables:

- Dark only: `#181818` page, `#303030` card/section, `#222222` component well.
  The light palette (`#E6E2D3`, `#FFFFFF`) is text-only.
- Silkscreen on `body` for all UI text at weight 400 (never 700); Quantico via a
  `.text` class for prose only.
- Accents only from `core/utilities/RavelColors.ts`; status indicators
  (dots, LEDs, rings, badges) exclusively from the Fluoro palette.
- Decorative rules / underlines: 10px.
- No off-system hex, no inline styles that could be a class, no `<style>` in
  `<body>`, no light backgrounds.

> **Still needed:** the Ravel repo URL / canonical local path so
> `tools/third-party.config` can document the default checkout location, and
> confirmation of the web toolchain (Vite? plain ESM + `index.ts`?).

### libpd

- Vendored under `third_party/libpd` (submodule or symlink).
- Build the **multi-instance** variant if we want more than one Pd-backed
  instrument alive in a single process; otherwise rely on out-of-process AU
  hosting for isolation.
- Statically linked into `PdBackend`; each Pd instrument's patch + externals
  ship as data inside its Instrument Pack.

### Symlink tooling

`tools/link-third-party.sh` reads `tools/third-party.config` (lines of
`symlink-path <TAB> local-source-path`) and creates the symlinks, so a fresh
clone is one command away from building. The config file is checked in with
sensible defaults; contributors override paths locally.

---

# Phase 0 — Hello World   *(built — see below)*

**Goal:** the smallest thing that proves the whole pipeline, including the
one-extension / instrument-as-data shape and the two-toolchain build. No neural
code.

### Deliverable

`UPIInstrument.appex` (generic engine), for now embedded in a small XcodeGen
host app, loading a bundled **`hello-sine` Instrument Pack**.

- AU identity: `aumu UPIi UPI_`, name "UPI: Universal Public Instrument".
- Ships one built-in pack, `hello-sine` (`instrument.json` → `backend:
  com.upi.backend.oscillator`, 5 macro defs).
- The extension finds the pack in its own bundle Resources, validates the
  backend id against the registry, instantiates `OscillatorBackend`, plays it.
- Responds to MIDI note on/off + velocity **and MPE** (member-channel per-note
  pitch bend → pitch, channel pressure → pressure, CC74 → slide).
- 8-voice poly, PolyBLEP oscillator per voice, per-voice ADSR, glide.
- AU parameters come from the backend (`waveform`, `attack`, `decay`,
  `sustain`, `release`, `gain`, `glide`, `cutoff`, `noise`) plus one
  extension-owned param, `mpeBendRange`.
- One native SwiftUI macro-strip `AUViewController` + an instrument picker.
- Instrument selection + parameters stored in AU `fullState` (round-trips
  through a saved project).
- Validates with `auval`.

### Structured through the real interfaces (thin)

- `OscillatorBackend` implements the backend C ABI (`backends/include/upi_backend.h`,
  audio-thread, zero latency, poly), listed in `backends/registry/upi_registry.c`.
- `ControlFrame` = the versioned C struct in `backends/include/upi_control_frame.h`.
- The kernel (`native/UPIInstrument/Kernel/upi_kernel.mm`) is the Performance
  Layer stub: parses MIDI/MPE (legacy + UMP) into per-voice state, builds the
  `ControlFrame` each block, calls `backend->render` on the audio thread.
- `UPIRuntime` (framework) = `InstrumentPack` model + `PackLibrary` loader +
  `InstrumentPreset`.
- `tools/build-au.sh` → `.appex`; `tools/package.sh` embeds it and signs
  inside-out (frameworks → `.appex` with its own entitlements, never `--deep` →
  app last), then verifies.

### Build pipeline — wired & green (Debug + Release)

- `src-tauri/` builds `UPI.app` (Tauri 2, Rust shell, static `web/` stub UI,
  ad-hoc signed). `beforeBundleCommand: bash tools/build-au.sh` builds the
  `.appex` (XcodeGen scheme `UPIInstrument`, standalone — it carries its own
  `UPIRuntime.framework`); `tools/package.sh` then embeds it into
  `UPI.app/Contents/PlugIns/`, signs inside-out (nested framework → `.appex`
  with its own entitlements, never `--deep` → app last). `codesign --verify
  --strict` passes.
- `npm run package` = `cargo tauri build --bundles app && bash tools/package.sh`.
- `tools/smoke.sh` is the gate: build → embed → sign → **install to
  `~/Applications/UPI.app`** → register → `auval -v aumu UPIi UPI_` → render /
  state / MPE Swift smokes. All green in both Debug and Release.
- Two macOS gotchas learned and handled:
  - **`pkd` only trusts app extensions under `/Applications` or
    `~/Applications`** — not a build/`target/` dir ("plug-ins outside
    containing apps must be protected by SIP"). `smoke.sh` copies the bundle
    there before registering.
  - **Ad-hoc-signed extensions need `com.apple.security.get-task-allow`** in
    their entitlements or AMFI refuses to load them (`-423`). It's in both
    entitlements files, flagged as local-dev-only.
  - **Release strips Swift reflection metadata** that ExtensionKit/ViewBridge
    needs to bootstrap the AU view controller → `SWIFT_REFLECTION_METADATA_LEVEL:
    all` + `STRIP_SWIFT_SYMBOLS: NO` on the extension target.

### Deviations from the spec's ideal (tracked)

- `native/` builds only the extension + framework (no dev host target); the
  `.appex` builds standalone and is embedded by `package.sh`.
- **No App Group yet.** Phase 0 packs are bundled in the `.appex`, so no shared
  container / entitlement is needed. `AppGroup.swift` + `PackLibrary` already
  handle the container path for when the Store lands.
- **Ad-hoc signing** + `get-task-allow` (local-dev). No Developer ID /
  notarization yet — needs a distribution identity; `package.sh` takes a real
  `SIGN_IDENTITY` and should then also strip `get-task-allow`.
- **Web UI is a static stub** (`web/index.html`) — Ravel is not symlinked in
  yet (repo URL is Open Question #6). `tools/link-third-party.sh` +
  `third-party.config` are in place for when it is.
- The Tauri↔`UPIRuntime` FFI bridge is not built — the app shell only reports
  extension status via an `app_status` command. (Open Question #1.)
- Parameter defs live in the backend, not a separate `params.json`; a macro in
  `instrument.json` just names the backend parameter it drives.

### Explicitly out of scope for Phase 0

- Any ML model, MLX, network downloads, the store.
- Real Performance Layer (breath, embouchure, memory).
- Identity manifold UI. Licensing, community. The web app.

### Phase 0 done =

`auval -v aumu UPIi UPI_` passes (Debug **and** Release); the AU renders sound
from MIDI and from MPE per-note bend; instrument choice + parameters round-trip
through AU state; `npm run package` produces a `codesign --verify --strict`
-clean `UPI.app`. **All green via `tools/smoke.sh` in both configs.**

Remaining before Phase 0 is fully closed: manual check in a real DAW
(Logic/Live) — the automated gate covers instantiation + render + MIDI/MPE +
state but not a human listening in a host UI; a notarized Developer-ID build;
swap the `web/` stub for the real Ravel UI when the repo is available.

### Phase 0.5 — de-risk libpd   *(code complete, runtime verification pending)*

A second built-in pack, `hello-pd` (`backend: com.upi.backend.libpd`),
`backend/hello.pd` = `[r pitch]→osc~`, `[r gate]→sig~→lop~ 20→*~` → `dac~`.

**Done:**

- **libpd** is a git submodule at `third_party/libpd` (+ its `pure-data`
  submodule). `tools/build-libpd.sh` builds it via CMake as a static,
  **multi-instance** (`PD_MULTI`) `libpd.a` for the host arch (cached).
- **`backends/PdBackend/`** implements the backend C ABI over libpd:
  `libpd_new_instance` per backend instance, `libpd_openfile` on the pack's
  `patch` resource, `ControlFrame` voice 0 → `libpd_float("pitch"/"gate"/"vel")`,
  and an **output ring buffer** reconciling libpd's 64-sample tick to arbitrary
  host block sizes (`pd-smoke.swift` renders at a deliberate 137-frame block).
- Registered as `com.upi.backend.libpd` in `backends/registry/upi_registry.c`;
  compiled into the extension; `hello-pd` bundled alongside `hello-sine`.
- `tools/build-au.sh` runs `build-libpd.sh` first. **The full extension builds
  and links clean** (`nm` shows `_upi_pd_backend_entry`, libpd statically
  linked, no dylib dependency).

**Resolved (2026-09-03, after reboot):** `tools/smoke.sh` is fully green in
Debug + Release — `auval` SUCCEEDED plus render / state / MPE / **Pd** smokes.
One real bug surfaced on the first green run: the Swift AU never passed a
resource resolver into `upi_kernel_set_backend`, so `PdBackend::prepare()`
couldn't locate its patch and rendered silence. Fixed: `ResourceResolverBox` in
`UPIInstrumentAudioUnit` maps pack resource keys → absolute paths; the kernel
retains the resolver + ctx so re-`prepare()` (from `allocateRenderResources`)
still resolves; `pd_prepare` keeps an already-open patch when re-prepared
without a resolver.

---

# Phase 1 Deliverables

> **Progress (2026-09-03):** backend decision = **Pd patch first** (libpd), not
> MRT2 — Magenta RT is a generative loop model (≈2 s latency, no note input, no
> MLX artifact) and belongs in Phase 2/3 as the distillation *teacher*, not the
> Phase 1 playable instrument. DDSP-style is slated as the first *neural*
> backend after this. This pass = extension + pack only (App Store UI / App↔
> Runtime bridge deferred — still blocked on the Ravel repo URL + web toolchain).
>
> **Done, `tools/smoke.sh` green (adds `identity-smoke`):**
> - **Identity Layer** (1-D pass-through): `ControlFrame.identity[]` /
>   `macros[]` populated from kernel atomics; `upi_kernel_set_identity` added,
>   `upi_kernel_set_macro` wired. `MacroDef` gains `identityAxis` (a macro
>   targets a backend param, an identity axis, or the bare macro bus). Swift AU
>   publishes one AU parameter per identity axis + per bare macro
>   (`idaxis_<id>` / `macrobus_<id>` — no dots: `AUParameterNode` rejects them);
>   presets round-trip macro positions by id.
> - **Pack loader hardening**: `InstrumentPack.validate(extensionVersion:)` —
>   schema version, `minExtensionVersion` gate (engine now `1.0.0`), macro/axis
>   sanity, resource existence; unknown-backend → "update UPI". Bad packs refuse
>   to load with a logged reason.
> - **`PdBackend`** also sends `[r identity]` + `[r macro0..N]` (positional).
> - **`chocolate-trumpet` pack**: `com.upi.backend.libpd`, one identity axis
>   `brass_reed` (Trumpet↔Clarinet), 5 macros. `backend/chocolate-trumpet.pd` =
>   saw↔square morph on identity, brightness→lowpass, air→noise, attack→env
>   slew, expression→gain. Bundled alongside the hello packs.
>
> **Not yet:** the real "learned acoustic identity" (that's the DDSP/neural
> pass); App library/store UI; Runtime bridge; artwork; DAW listen test.

## Extension

- Backend registry with at least: `oscillator`, `libpd`, and one real neural
  backend (MRT2-Small or a lighter DDSP-style model — see Open Questions).
- Pack loader: validation, `minExtensionVersion` check, clear errors.
- Macro strip driven fully by `instrument.json` / `params.json`.
- MIDI + MPE, automation, host sync, AU-state persistence of instrument choice.

## Instrument Pack — Chocolate Trumpet

- `chocolate-trumpet/` pack: manifest, backend data (weights or patch),
  identity embeddings, presets, artwork.
- One identity axis (Trumpet ↔ Clarinet), 5 macros.

## App

- Library (installed packs) + Store (download packs into the container)
- Instrument management (verify, update, remove packs)
- Performance Mode
- Settings (storage, backend/model management, updates)

## Runtime

- Backend registry + capability negotiation (C ABI)
- Instrument Pack loader + signed-archive verification
- Model / resource cache (keyed by backend id + hash)
- Shared identity representation
- Preset management

---

# Phase 2

- Identity manifold editor (2D) — authors Instrument Pack identity data
- Many packs across several backends
- Shared runtime optimization (within-backend weight sharing across packs)
- Full downloadable-content pipeline (CDN, signing, licensing, updates)
- Community preset sharing
- Performance recorder
- Optional marquee `AudioComponents` plist entries for flagship instruments
- **Performance Layer v1** (breath, embouchure, phrase memory) — currently a stub

---

# Phase 3

Distillation.

```
Teacher:  a large foundation model (e.g. Magenta Realtime 2)
              ↓
Student:  a dedicated Chocolate Trumpet backend
```

Target: a dedicated neural instrument significantly smaller than the original
foundation model while preserving the expressive capabilities of the chosen
acoustic neighborhood.

A distilled model ships as a new **Instrument Pack** if it runs on an existing
backend (e.g. a smaller MLX graph on the `mrt2` runtime), or as a **new backend
in an app update** if it needs a new runner. Either way the user experience is
unchanged.

---

# Long-Term Vision

The end goal is not to build another plugin.

The goal is to create a new category of software instrument.

Traditional software instruments simulate existing synthesis methods.

UPI instruments expose navigable regions of learned acoustic identity.

Each instrument represents a curated exploration of a small region within a much
larger acoustic manifold.

The standalone application becomes the atlas.

The AUv3 plugin becomes the instrument used to perform inside a DAW.

Together they form an extensible ecosystem where new instruments are **data** —
identities, not products or plugins — dropped into one runtime, and where future
distilled models can replace larger foundation models without changing the user
experience.

The result should feel less like launching a plugin and more like opening a
living collection of musical organisms.

---

# Decisions (locked)

- **One generic AUv3 extension** (`UPIInstrument.appex`) embedded in `UPI.app`.
  Instruments are **Instrument Packs** = downloadable data, not extensions.
- **Backends are code compiled into the extension; instruments are data.** New
  instrument → new pack (no rebuild). New backend architecture → app update.
- **Build:** `tools/build-au.sh` (XcodeGen + `xcodebuild`, run from Tauri's
  `beforeBundleCommand`) → `UPIInstrument.appex`; `tauri build --bundles app` →
  signed `UPI.app`; then `tools/package.sh` embeds the `.appex`, signs it with
  its **own** entitlements file (not `--deep`), re-signs `UPI.app`, then
  `productbuild`/`create-dmg` + notarize. One script: `npm run package`.
- **App Group shared container** holds the pack library; app writes, extension
  reads. Host entitlements in `src-tauri/Entitlements.plist`, extension
  entitlements in `native/UPIInstrument/UPIInstrument.entitlements`, same App
  Group id + signing identity.
- Backend ABI: **C ABI** + thin C++ base class. Synthesis architecture is not
  fixed (oscillator, libpd, MRT2/MLX, DDSP, …).
- **`ControlFrame`** is a versioned C struct defined in `backends/include/`,
  `version` field, additive-only changes within a major version.
- Native shell: **Tauri** (builds the host only). Project generation:
  **XcodeGen** (`native/project.yml`, extension + framework only). No JUCE.
  Monorepo. Swift + C/C++.
- Web UI framework: **Ravel** — Shawn's own; fix it directly, take quirks in
  stride. The web build imports the **`core-dist`** bundle (`core` symlink is
  dev-only). CSS governed by `docs/raveling-style-guide.md` (authoritative).
- **libpd / Pure Data patches** are a supported backend (the patch is pack data).
- **MPE** input is required; per-voice expression in `ControlFrame`.
- AU identity: type `aumu`, manufacturer `UPI_`, subtype `UPIi`, name
  "Universal Public Instrument". Instrument choice is in-plugin + saved in AU
  state. (Optional later: fixed marquee `AudioComponents` entries.)
- Performance Layer is a **stub** until Phase 2.
- "Standalone Performer" = **Performance Mode** in the app, not a separate app.
- Phase 0 = the generic extension + a built-in `hello-sine` MPE pack.

---

# Open Questions

### Architecture

1. **App ↔ Runtime bridge.** Tauri commands into `UPIRuntime` via a
   Rust↔C/Swift FFI shim, or a local socket? Control/library/preset only —
   audio-thread data never crosses it.
2. **AU hosting in Performance Mode.** In-process vs. out-of-process (leaning
   out-of-process for crash isolation + multi-instance libpd).
3. **`libpd` multi-instance.** Multiple Pd-backed packs alive in one extension
   process (→ multi-instance libpd build), or serialize / one-at-a-time?
4. **Instrument-choice persistence.** AU full-state chunk is the obvious home,
   but some hosts are flaky with large state — do we also need a
   user-preset / factory-preset representation per pack?
5. **Pack format + signing.** Archive format (a signed zip? a notarized
   bundle?), signature scheme, and how the extension trusts a pack the app
   downloaded (the App Group boundary is the trust anchor?).

### Build / repo

6. **Ravel repo URL / canonical local path** for `tools/third-party.config`,
   plus the exact web toolchain (Vite? plain ESM?) that maps `/core/` →
   `core-dist`.
7. **`codesign` re-sign details.** The exact flag set / ordering for step 4 of
   `package.sh` (resource rules, `--preserve-metadata`, timestamp), and whether
   `productbuild` or `notarytool` + Transporter is the smoother MAS path.
   Settle when the pipeline is first built.

### Product

8. **Phase 1 Chocolate Trumpet backend.** MRT2-Small, a lighter DDSP-style
   model, or a hand-built Pd patch first (proves the expressive layering with
   far less infra)?
9. **DAW discoverability.** Is one "Universal Public Instrument" entry
   acceptable for Phase 1, or do we need marquee `AudioComponents` entries
   sooner?
10. **Distribution.** Mac App Store from the start, or direct (Developer ID)
    first?
11. **Chocolate Trumpet identity data.** Where do style embeddings /
    interpolation targets come from with no custom training in Phase 1?

### Deferred (tracked, not urgent)

12. Performance Layer design (Phase 2).
13. Licensing / entitlement model (per-pack).
14. Windows / cross-platform — Tauri keeps the app portable, but the AUv3
    extension is macOS-only; is cross-platform a goal?
