# coreai-dynshape-poc

Isolates the exact failure pattern that killed an earlier attempt to run
Style-Bert-VITS2 through onnxruntime's CoreML execution provider, and checks
whether [coreai-torch](https://github.com/apple/coreai-models) (Apple's
PyTorch → Core AI conversion toolchain) handles it.

## Background

The CoreML EP attempt failed on the Stochastic Duration Predictor's
Normalizing Flow with:

```
Input (/sdp/flows.3/GatherND_2_output_0) has a dynamic shape ({-1,-1}) but
the runtime shape ({0,10}) has zero elements. This is not supported by the
CoreML EP.
```

i.e. a `gather` along a sequence dimension whose length is data-dependent
(driven by a duration predictor) and can be **zero**.

Rather than porting any of Style-Bert-VITS2, `probe.py` reproduces just that
shape: a `Conv1d` feature map gathered along a `torch.export.Dim(min=0, ...)`
axis.

## Result

On coreai-torch `0.4.1` / torch `2.9.0`, every stage passes, including the
`n_out=0` case:

```
torch.export (dynamic shapes, out dim allows zero)  -> OK
run_decompositions                                   -> OK
TorchConverter -> to_coreai()                         -> OK
optimize()                                            -> OK
save_asset() -> .aimodel bundle                        -> OK
eager forward with n_out=0                            -> OK, output shape=(1, 0, 8)
```

The compiled IR (`main.mlirb`) lowers `Conv1d` to `primitive.conv2d_v1` and
`gather` to `primitive.gather_along_axis_v1` — matching the op mapping in the
[supported ATen ops reference](https://apple.github.io/coreai-torch/main/api/) —
and both survive the zero-length dynamic-shape case that broke the CoreML EP.

## Caveats

- This only exercises the Python-side conversion pipeline (`torch.export` →
  decompose → `TorchConverter` → `optimize()` → `save_asset()`). It does
  **not** verify on-device execution of the compiled `.aimodel` — the Core AI
  runtime / CLI tools require Xcode 27 / macOS or iOS 27, which weren't
  available for this check.
- A single synthetic `gather` isn't the whole Stochastic Duration Predictor —
  the full Normalizing Flow has more structure (coupling layers, splits,
  flips) that isn't tested here.
- Conclusion is scoped to: **the specific op combination that broke the
  ONNX Runtime CoreML EP is not, by itself, a blocker for coreai-torch.**
  This lowers the risk on the "port Style-Bert-VITS2 via a thin wrapper"
  hypothesis but doesn't confirm it end-to-end.

## Run it

```bash
uv sync
uv run python probe.py
```
