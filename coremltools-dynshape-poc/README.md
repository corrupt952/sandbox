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

## First observation (probe.py), and why it was only half the story

`probe.py` converts the `Conv1d` + dynamic-shape `gather` module and runs
`predict()` with the pathological `n_out=0` case across every `ComputeUnit`.
Every selection returns the correct output — `shape=(1, 0, 8)` on all four —
and the first run also caught, on stderr, an Espresso exception under `ALL`:

```
Invalid blob shape: Data-dependent shapes were disabled: var_28_classic_cpu - [?, ?, ?], ...
```

The reading at the time was: `ALL` tries the Neural Engine, hits the
zero-element dynamic-shape wall, logs it, and **falls back to CPU**, returning
the right answer anyway — a graceful degradation where the onnxruntime CoreML
EP had hard-failed. That was a guess from a log line, and `probe2.py` shows two
places it was wrong.

**The log is no longer on stderr, and the "silent fallback" framing was
inference, not fact.** On this environment the `"Data-dependent shapes were
disabled"` text does not reach stderr at all — re-running `probe.py` produces
zero such lines — and coremltools is 9.0 in both the original run and now, so a
version bump does not explain it. An equivalent message *is* emitted, to
`os_log` rather than stderr, with different wording:

```
[com.apple.espresso] MIL program has non-constant (dynamic) shapes for external
input ... E5 function will be produced with unknown input shapes and cannot be
run without reshaping first.
```

"cannot be run without reshaping first" reads as a *planning* constraint — the
op is not put on that engine — rather than an attempt that failed at runtime.
`MLComputePlan` confirms this directly: the dynamic `gather` is simply never
placed on a device that cannot take it. There is no fallback because there was
no attempt.

## What the compute plan actually says (probe2.py)

`probe2.py` reads `MLComputePlan` (coremltools 9's per-op *anticipated* device
assignment) instead of guessing from a log, and varies the shape to find what
matters. `preferred` is useless here — every op prefers CPU on a model this
tiny — so the evidence is the **`supported`** list: whether the Neural Engine is
even an option for the gather.

**It is the gather's dynamic index length (and so its dynamic output length),
not the zero, that costs the Neural Engine.** Fixing `n_out=3` and varying only
which axis is dynamic:

```
shape_mode   CPU_AND_NE   ALL           gather can use...
static       CPU+NE       CPU+GPU+NE    NE  (positive control)
x-dyn        CPU+NE       CPU+GPU+NE    NE  (dynamic sequence length is fine)
idx-dyn      CPU          CPU+GPU       no NE
both         CPU          CPU+GPU       no NE
```

A fully static graph keeps the Neural Engine; making the *input sequence*
dynamic keeps it too; making the *gather index* dynamic drops it. The zero
length is a red herring — sweeping `n_out` over `{0, 3, 17}` (all axes dynamic)
leaves the gather's supported list unchanged (`CPU` under `CPU_AND_NE`, `CPU+GPU`
under `ALL`), and every prediction is correct to fp16. Raising the RangeDim
lower bound does not help either: at `lower_bound=1` the gather still has no NE,
and `n_out=0` is then rejected outright with `Size (0) of dimension (1) is not in
allowed range (1..4096)` — an input-validation error, not a graceful anything.

For Style-Bert-VITS2 this narrows the impact: the SDP's gather takes an index
whose length comes from the duration predictor and therefore varies, so that
gather will not run on the Neural Engine. It stays eligible for the GPU (the
`supported` list keeps `GPU` under `CPU_AND_GPU`/`ALL`), though on a model this
size nothing is actually *preferred* to an accelerator.

## Caveats

- `MLComputePlan` reports the *anticipated* plan, not a runtime measurement.
  The "not on the Neural Engine" claim rests on the op never appearing in an NE
  segment of the plan — a sound assumption under Core ML's model (a plan without
  an NE segment will not run there), but not a direct measurement. To see actual
  runtime device assignment, Instruments' Core ML template is the tool.
- The eight-cell axis split separates *input-data* dynamism from *index/output*
  dynamism, but not the gather's index count from its output length — in a
  gather they move together. It does not matter for the SDP conclusion (a
  variable duration moves the output length regardless), so it was left there.
- "E5" is read as an internal name for a Neural-Engine-related component (the
  `e5rt`/ANE-compiler symbol family), but Apple's definition is unconfirmed, and
  `com.apple.espresso` names the whole inference engine (CPU/GPU/ANE), not the
  ANE alone — so the os_log line is corroboration for the plan, not the primary
  evidence. The conclusion stands on the `supported` column.
- `supported` depends on the ComputeUnit and on graph segmentation, not on the
  op alone — so the claim is "this op, at this ComputeUnit, in this graph is not
  NE-eligible", not "gather is never NE-capable" (statically, it is).
- Single synthetic `gather`, not the full Stochastic Duration Predictor
  (coupling layers, splits, flips untested).
- `preferred` is CPU for every op because the model is a toy; a real model's
  preferred placement is a separate question.
- Measured on a Mac. The plan on a Mac is not guaranteed identical to the ANE on
  an iOS device.

## Environment

coremltools 9.0 (see `uv.lock`), macOS 26.6.2 (25G83), Apple M5 Max, measured
2026-08-31. The original stderr observation not reproducing on the same
coremltools version is itself the reason to pin the environment: this behavior
moves with the runtime, so a result without a recorded environment invites the
same trap.

## Run it

```bash
uv sync
uv run python probe2.py   # the compute-plan probe: Part A (n_out sweep), Part B (axis split)
uv run python probe.py    # the first observation, kept for the record (its reading is corrected above)
```

The Espresso message now goes to the unified log, not stderr. To see it, run a
cell while streaming:

```bash
log stream --predicate 'subsystem CONTAINS "espresso"' --style compact &
uv run python probe2.py --cell 0 ALL 0
```
