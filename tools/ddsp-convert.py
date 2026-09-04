#!/usr/bin/env python3
# ddsp-convert.py — extract a DDSP-VST RnnFcDecoder from a .tflite into a flat
# weight blob (.ddspw) the UPI DdspBackend reads, plus a reference I/O file for
# the C++ port's correctness test.
#
# Normally you don't run this directly — `tools/ddsp-fetch-models.sh` downloads
# the DDSP-VST release and calls it in an ephemeral uv env. Standalone:
#
#   Needs: pip install 'numpy<2' tflite ai-edge-litert   (Python 3.11, in a venv)
#
#   python tools/ddsp-convert.py Trumpet.tflite instrument-packs/hello-ddsp/backend/trumpet
#     -> writes trumpet.ddspw  and  trumpet.ref
#
# Model (verified against Trumpet/Clarinet.tflite, DDSP-VST v3.4.3):
#   inputs : f0_scaled = midi/127  (0..1),  pw_scaled = loudness (0..1),  gru_state[512]
#   fc_pw  : dense(1->256) + LayerNorm(eps 1e-3) + LeakyReLU(0.2)      [processes pw]
#   fc_f0  : dense(1->256) + LayerNorm + LeakyReLU(0.2)                [processes f0]
#   concat(fc_pw, fc_f0) -> GRU(512, reset_after=True, gates [z,r,h])
#   concat(fc_pw, fc_f0, gru_out) -> dense(1024->256) + LayerNorm + LeakyReLU(0.2)
#   dense(256->126) -> split [1, 60, 65]
#   exp_sigmoid(x) = 2.0 * sigmoid(x)**ln(10) + 1e-7   (noise: x-5.0 first)
#   harmonics: Nyquist-mask at f0*n >= 8000 Hz, renormalise to sum 1

import sys, struct
import numpy as np
import tflite
from ai_edge_litert.interpreter import Interpreter

MAGIC = b"DDSPW1\0\0"

def const(m, gi, ti):
    g = m.Subgraphs(gi); t = g.Tensors(ti); b = m.Buffers(t.Buffer())
    a = np.frombuffer(b.DataAsNumpy().tobytes(), dtype=np.float32)
    sh = list(int(x) for x in t.ShapeAsNumpy()) if t.ShapeLength() > 0 else []
    return a.reshape(sh) if sh else a

def main():
    tflite_path, out_base = sys.argv[1], sys.argv[2]
    buf = open(tflite_path, "rb").read()
    m = tflite.Model.GetRootAs(buf, 0)

    # --- weights (tensor indices verified from the op graph) ---
    W = dict(
        fc_pw_W=const(m, 0, 40), fc_pw_b=const(m, 0, 20),
        ln_pw_g=const(m, 0, 18), ln_pw_b=const(m, 0, 19),
        fc_f0_W=const(m, 0, 43), fc_f0_b=const(m, 0, 17),
        ln_f0_g=const(m, 0, 15), ln_f0_b=const(m, 0, 16),
        gru_Wx=const(m, 2, 13), gru_bx=const(m, 2, 7),    # input kernel + bias
        gru_Wh=const(m, 2, 12), gru_bh=const(m, 2, 8),    # recurrent kernel + bias
        fc_out_W=const(m, 0, 46), fc_out_b=const(m, 0, 14),
        ln_out_g=const(m, 0, 12), ln_out_b=const(m, 0, 13),
        dense_W=const(m, 0, 47), dense_b=const(m, 0, 21),
    )
    shapes = {
        "fc_pw_W": (256, 1), "fc_pw_b": (256,), "ln_pw_g": (256,), "ln_pw_b": (256,),
        "fc_f0_W": (256, 1), "fc_f0_b": (256,), "ln_f0_g": (256,), "ln_f0_b": (256,),
        "gru_Wx": (1536, 512), "gru_bx": (1536,), "gru_Wh": (1536, 512), "gru_bh": (1536,),
        "fc_out_W": (256, 1024), "fc_out_b": (256,), "ln_out_g": (256,), "ln_out_b": (256,),
        "dense_W": (126, 256), "dense_b": (126,),
    }
    order = ["fc_pw_W", "fc_pw_b", "ln_pw_g", "ln_pw_b",
             "fc_f0_W", "fc_f0_b", "ln_f0_g", "ln_f0_b",
             "gru_Wx", "gru_bx", "gru_Wh", "gru_bh",
             "fc_out_W", "fc_out_b", "ln_out_g", "ln_out_b",
             "dense_W", "dense_b"]
    for k in order:
        assert tuple(W[k].shape) == shapes[k], f"{k}: {W[k].shape} != {shapes[k]}"

    with open(out_base + ".ddspw", "wb") as f:
        f.write(MAGIC)
        for k in order:
            f.write(np.ascontiguousarray(W[k], dtype="<f4").tobytes())
    print(f"wrote {out_base}.ddspw  ({sum(W[k].size for k in order)} floats)")

    # --- reference I/O: run the tflite over a plausible note trajectory ---
    it = Interpreter(model_path=tflite_path); it.allocate_tensors()
    ins = {d['name']: d['index'] for d in it.get_input_details()}
    outs = {d['name']: d['index'] for d in it.get_output_details()}
    st = np.zeros(512, np.float32)
    rows = []
    rng = np.random.default_rng(0)
    # a couple of held notes at different pitch / loudness, plus noise
    traj = []
    for midi, pw, n in [(52, 0.7, 25), (67, 0.9, 25), (60, 0.4, 20), (72, 1.0, 15)]:
        for k in range(n):
            env = min(1.0, k / 6.0) * pw
            traj.append((midi / 127.0, float(env)))
    for f0s, pws in traj:
        f0 = np.array([f0s], np.float32); pw = np.array([pws], np.float32)
        it.set_tensor(ins['call_f0_scaled:0'], f0)
        it.set_tensor(ins['call_pw_scaled:0'], pw)
        it.set_tensor(ins['call_state:0'], st)
        it.invoke()
        amp = float(it.get_tensor(outs['StatefulPartitionedCall:0'])[0])
        harm = it.get_tensor(outs['StatefulPartitionedCall:1']).astype(np.float32)
        noi = it.get_tensor(outs['StatefulPartitionedCall:2']).astype(np.float32)
        st = it.get_tensor(outs['StatefulPartitionedCall:3']).astype(np.float32)
        rows.append((f0s, pws, amp, harm, noi))

    with open(out_base + ".ref", "wb") as f:
        f.write(b"DREF1\0\0\0")
        f.write(struct.pack("<I", len(rows)))
        for f0s, pws, amp, harm, noi in rows:
            f.write(struct.pack("<fff", f0s, pws, amp))
            f.write(harm.tobytes()); f.write(noi.tobytes())
    print(f"wrote {out_base}.ref  ({len(rows)} hops)")

if __name__ == "__main__":
    main()
