# Universal Public Instrument (UPI)

A macOS platform for model/patch-driven AUv3 instruments. One generic Audio Unit
extension; instruments are **data** (Instrument Packs), not plugins.

See [`docs/upi-app-spec.md`](docs/upi-app-spec.md) for the architecture.

---

## Status — Phase 0 (Hello World)

The generic AUv3 extension builds, validates (Debug **and** Release), and makes
sound. `tools/smoke.sh` is green end to end.

| Check | State |
|---|---|
| `auval -v aumu UPIi UPI_` (Debug + Release) | ✅ AU VALIDATION SUCCEEDED |
| MIDI → audio (offline render smoke) | ✅ |
| MPE per-note pitch bend (262 Hz → 4185 Hz at full ±48 st) | ✅ |
| Instrument choice + params round-trip via AU state | ✅ |
| Bundled `hello-sine` Instrument Pack (oscillator backend, data-only) | ✅ |
| **Tauri `UPI.app`** — `beforeBundleCommand` builds the `.appex`, `package.sh` embeds + inside-out signs | ✅ ad-hoc |
| Notarized Developer-ID build | ⏳ needs a distribution identity |
| Real web UI (Ravel) | ⏳ stub — Ravel repo not yet symlinked |
| Human listen in a real DAW (Logic/Live) | ⏳ |
| **Phase 0.5** — `PdBackend` + libpd + `hello-pd` pack | ✅ builds & links · ⏳ runtime re-verify after reboot* |

<sub>*A long debugging session wedged this machine's ad-hoc-extension hosting
(`lsregister -kill`, repeated `killall -9 pkd`); `auval` on our extension now
`-10863`s while third-party notarized AUv3s validate fine. Re-run `tools/smoke.sh`
after a logout/reboot.</sub>

### Try it

```bash
brew install xcodegen                 # one-time
cargo install tauri-cli --version ^2  # one-time

tools/smoke.sh          # build → embed → sign → install → auval → render/state/MPE
npm run package         # cargo tauri build --bundles app && tools/package.sh
```

`smoke.sh` installs to `~/Applications/UPI.app` (macOS only trusts app
extensions under `/Applications` or `~/Applications`). The AU then shows up in
any AUv3 host as **“UPI: Universal Public Instrument.”**

---

## Layout

```
backends/          C ABI (upi_backend.h) + registry + OscillatorBackend + PdBackend   [C/C++]
native/            XcodeGen project (extension + framework only)
  UPIInstrument/     the one AUv3 extension  (Swift + Kernel/*.mm)
  UPIRuntime/        shared framework: Instrument Pack loader, presets
instrument-packs/  instruments as data (instrument.json + resources)
tools/             build-au.sh, package.sh, smoke.sh, *-smoke.swift, link-third-party.sh
src-tauri/         Tauri 2 shell → UPI.app  (Rust; app_status command)
web/               stub UI (style-guide palette; Ravel components later)
```

## Build details

- **`tools/build-au.sh`** — `xcodegen generate` + `xcodebuild` → `build/UPIInstrument.appex`.
  Meant to run from Tauri's `beforeBundleCommand`.
- **`tools/package.sh`** — embeds the `.appex` into the host `.app`, signs
  inside-out (frameworks → `.appex` with its own entitlements, never `--deep` →
  app last), verifies, optionally builds `.dmg` / `.pkg` and notarizes.
- Phase 0 signs ad-hoc (`CODE_SIGN_IDENTITY=-`); no team or provisioning needed
  to build, run `auval`, or load in a local DAW. Set `SIGN_IDENTITY=` for
  `package.sh` to use a real identity.

## Adding an instrument (no rebuild)

Drop a directory under `instrument-packs/` with an `instrument.json` naming a
backend that exists in the build (`tools`/`backends/registry/upi_registry.c`),
add it to the `for pack in …` line in `native/project.yml`, rebuild once. Later
(Phase 1) packs are downloaded into the App Group container with no rebuild at
all.
