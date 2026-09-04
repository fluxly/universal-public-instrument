# hello-ddsp backend resources

`trumpet.ddspw` / `clarinet.ddspw` are the DDSP `RnnFcDecoder` weights the
`com.upi.backend.ddsp` backend loads (`decoder_a` / `decoder_b` in
`../instrument.json`). `*.ref` are TFLite reference I/O used only by the
off-device decoder test (`tools/ddsp-decoder-smoke.cpp`).

These are **not checked in** (7.5 MB each, git-ignored). Reproduce them:

```
bash tools/ddsp-fetch-models.sh
```

That downloads Google's DDSP-VST model release
(`storage.googleapis.com/ddsp-vst/releases/DDSP-VST-Models.zip`, Apache-2.0),
extracts `Trumpet.tflite` / `Clarinet.tflite`, and converts each with
`tools/ddsp-convert.py`. The conversion is deterministic — the blobs are
bit-identical run to run.

The pack **will not load without them** — the manifest declares both decoders
as required resources and `InstrumentPack.validate` rejects a missing resource.
`tools/smoke.sh` runs the fetch automatically. (The backend does carry an
analytic trumpet/clarinet fallback for the case where a pack ships no decoders
at all — e.g. `tools/ddsp-render-smoke.cpp` with the files removed.)
