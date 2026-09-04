# chocolate-trumpet backend resources

`trumpet.ddspw` / `clarinet.ddspw` are the DDSP `RnnFcDecoder` weights the
`com.upi.backend.ddsp` backend loads (`decoder_a` / `decoder_b` in
`../instrument.json`). `*.ref` are TFLite reference I/O used only by the
off-device decoder test.

These are **not checked in** (7.5 MB each, git-ignored). Reproduce them — this
populates every DDSP pack, chocolate-trumpet included:

```
bash tools/ddsp-fetch-models.sh
```

The pack **will not load without them** — its manifest declares the two
decoders as required resources and `InstrumentPack.validate` rejects a pack
with a missing resource. `tools/smoke.sh` fetches them automatically.

Same weights as `instrument-packs/hello-ddsp/backend/` (the minimal demo pack);
chocolate-trumpet is the Phase 1 product pack — name, presets, artwork.
