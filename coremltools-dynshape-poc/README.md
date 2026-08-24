# coremltools-dynshape-poc

Sibling probe to [`coreai-dynshape-poc`](../coreai-dynshape-poc/), same failure
pattern, different toolchain: [apple/coremltools](https://github.com/apple/coremltools)
(the established PyTorch → Core ML converter) instead of
[coreai-torch](https://github.com/apple/coreai-torch).

## Background

The original failure was in onnxruntime's CoreML execution provider, not
coremltools itself:

```
Input (/sdp/flows.3/GatherND_2_output_0) has a dynamic shape ({-1,-1}) but
the runtime shape ({0,10}) has zero elements. This is not supported by the
CoreML EP.
```

coreai-torch showed the *conversion* (torch.export → MLIR) survives this
exact shape (see the sibling PoC). But coreai-torch's compiled `.aimodel`
can't be executed from Python — running it needs Xcode 27 / macOS or iOS 27,
none of which exist yet. coremltools targets the Core ML runtime shipping on
*current* OS versions, and its `mlmodel.predict()` runs locally — so it's the
one toolchain that can answer "does this survive on real, current hardware"
right now, without waiting for OS 27.

## Result

`probe.py` converts the same `Conv1d` + dynamic-shape `gather` module via
`torch.jit.trace` + `ct.convert(..., inputs=[... ct.RangeDim(lower_bound=0, ...) ...])`,
then runs `predict()` with the pathological `n_out=0` case across every
`ComputeUnit` selection:

```
CPU_ONLY     -> predict OK, shape=(1, 0, 8)
CPU_AND_GPU  -> predict OK, shape=(1, 0, 8)
CPU_AND_NE   -> predict OK, shape=(1, 0, 8)
ALL          -> predict OK, shape=(1, 0, 8)
```

Every selection returns the correct output. But `ALL` also logs (to stderr,
non-fatal) an E5RT/Espresso exception:

```
Invalid blob shape: Data-dependent shapes were disabled: var_28_classic_cpu - [?, ?, ?], ...
```

Reading between the lines: when `ALL` lets the runtime pick a backend, it
tries compiling for Neural Engine / GPU internally, hits the same "data-
dependent / zero-element shape" wall the original CoreML EP hit, logs it —
then **falls back to CPU and returns the right answer anyway**. So:

- The op combination itself (`Conv1d` -> `gather_along_axis`, not `gather_nd`
  this time — coremltools picks a different lowering than coreai-torch did)
  is not a hard blocker in coremltools, at any compute unit.
- The underlying constraint that killed the ONNX CoreML EP path — Neural
  Engine (and likely GPU) genuinely can't execute a zero-element dynamic
  shape — still appears to hold here too. coremltools just **degrades
  gracefully** instead of hard-failing, which the onnxruntime CoreML EP did
  not do.

## Caveats

- Single synthetic `gather`, not the full Stochastic Duration Predictor
  (coupling layers, splits, flips untested).
- The graceful CPU fallback is convenient for correctness but defeats the
  point of accelerating on Neural Engine/GPU for the zero-length case
  specifically — if Style-Bert-VITS2's SDP hits `n_out=0` mid-inference,
  this suggests that step alone would silently run on CPU, not the intended
  accelerator, while everything else runs where you told it to.
- Not verified: whether the same silent-CPU-fallback behavior holds for a
  *non-zero* but still dynamic shape on Neural Engine, or whether it's
  specific to the zero-element case.

## Run it

```bash
uv sync
uv run python probe.py
```
