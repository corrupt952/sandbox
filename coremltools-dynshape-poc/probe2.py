"""Follow-up probe: turn the stderr-only evidence of a silent CPU fallback into
something checked, and find out whether it is the *zero* length or the *dynamic*
length that triggers it.

probe.py established that a Conv1d + dynamic-shape gather with n_out=0 predicts
correctly on every ComputeUnit while ALL also logs an E5RT/Espresso
"Data-dependent shapes were disabled" exception to stderr. That left two things
open, and this answers both:

  1. Where each op is actually planned to run — via MLComputePlan, which reports
     the *anticipated* device assignment (a plan made before execution, not a
     runtime measurement — so "fell back" is established by pairing the plan's
     preferred device with the presence of the E5RT log, not by the plan alone).
  2. Whether the fallback is specific to n_out=0 or happens for any dynamic
     length. n_out=3 and n_out=17 are non-zero but still dynamic; if they log the
     same exception, the whole variable-length path avoids the Neural Engine, not
     just the pathological empty case.

Each cell (one n_out x one ComputeUnit x one RangeDim lower bound) runs in its
own subprocess. That is the only reliable way to capture the exception, which is
emitted from the C++ Espresso layer where Python's redirect_stderr does not
reach, and it also pins down whether the log fires at load or at predict, since
a fresh process does exactly one of each.

Usage:
    python probe2.py                       # drive every cell, print the table
    python probe2.py --cell N_OUT CU LOWER # run one cell, print its JSON result
"""

import json
import subprocess
import sys

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn

BATCH, CHANNELS, SEQ_LEN = 1, 8, 20
CU_NAMES = ["CPU_ONLY", "CPU_AND_GPU", "CPU_AND_NE", "ALL"]
N_OUTS = [0, 3, 17]
LOWERS = [0, 1]


class DynGatherProbe(nn.Module):
    """Same module probe.py uses: Conv1d then a gather along a dynamic axis."""

    def __init__(self, channels: int = CHANNELS) -> None:
        super().__init__()
        self.channels = channels
        self.conv = nn.Conv1d(channels, channels, kernel_size=3, padding=1)

    def forward(self, x: torch.Tensor, indices: torch.Tensor) -> torch.Tensor:
        feat = self.conv(x)
        feat = feat.transpose(1, 2)
        gathered = torch.gather(
            feat, dim=1, index=indices.unsqueeze(-1).expand(-1, -1, self.channels)
        )
        return gathered


def device_kind(dev) -> str:
    from coremltools.models.compute_device import (
        MLCPUComputeDevice,
        MLGPUComputeDevice,
        MLNeuralEngineComputeDevice,
    )

    if isinstance(dev, MLCPUComputeDevice):
        return "CPU"
    if isinstance(dev, MLGPUComputeDevice):
        return "GPU"
    if isinstance(dev, MLNeuralEngineComputeDevice):
        return "NE"
    return type(dev).__name__


def compute_plan(mlmodel, cu) -> list:
    """Per-op anticipated device assignment, or a reason it could not be read."""
    from coremltools.models.compute_plan import MLComputePlan

    try:
        path = mlmodel.get_compiled_model_path()
        plan = MLComputePlan.load_from_path(path, compute_units=cu)
    except Exception as e:  # noqa: BLE001
        return [{"error": f"{type(e).__name__}: {e}"}]

    program = plan.model_structure.program
    if program is None:
        return [{"error": "not an mlprogram structure"}]
    try:
        main_fn = program.functions["main"]
    except TypeError:
        main_fn = program["main"]

    rows = []
    for op in main_fn.block.operations:
        usage = plan.get_compute_device_usage_for_mlprogram_operation(op)
        if usage is None:
            rows.append({"op": op.operator_name, "preferred": None, "supported": []})
            continue
        rows.append(
            {
                "op": op.operator_name,
                "preferred": device_kind(usage.preferred_compute_device),
                "supported": [device_kind(d) for d in usage.supported_compute_devices],
            }
        )
    return rows


def run_cell(n_out: int, cu_name: str, lower: int, shape_mode: str = "both") -> dict:
    cu = getattr(ct.ComputeUnit, cu_name)
    result = {"n_out": n_out, "cu": cu_name, "lower": lower, "shape_mode": shape_mode}

    # An empty length cannot be declared valid under a lower bound of 1: predicting
    # it should be refused, and that refusal is the finding for that cell.
    if lower == 1 and n_out == 0:
        result["skipped"] = "n_out=0 is invalid when the dynamic axis lower bound is 1"

    model = DynGatherProbe().eval()
    x = torch.randn(BATCH, CHANNELS, SEQ_LEN)
    # Trace with a non-zero, non-empty example; the input specs below decide which
    # axes are dynamic. The gather is length-independent, so one traced graph serves
    # every length.
    trace_indices = torch.randint(0, SEQ_LEN, (BATCH, 5), dtype=torch.int32)
    traced = torch.jit.trace(model, (x, trace_indices))

    # shape_mode isolates which dynamic axis matters: "both" is the original probe,
    # "static" fixes everything (the positive control — gather should regain NE),
    # "x-dyn"/"idx-dyn" make exactly one axis dynamic to see which one drops NE.
    seq_axis = (
        ct.RangeDim(lower_bound=1, upper_bound=4096, default=SEQ_LEN)
        if shape_mode in ("both", "x-dyn")
        else SEQ_LEN
    )
    if shape_mode in ("both", "idx-dyn"):
        indices_shape = (BATCH, ct.RangeDim(lower_bound=lower, upper_bound=4096, default=5))
    else:
        indices_shape = (BATCH, n_out)  # fixed length equal to the runtime length
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="x", shape=(BATCH, CHANNELS, seq_axis)),
            ct.TensorType(name="indices", shape=indices_shape, dtype=int),
        ],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_units=cu,
    )

    # The runtime input for this cell.
    if n_out == 0:
        indices = torch.zeros(BATCH, 0, dtype=torch.int32)
    else:
        indices = torch.randint(0, SEQ_LEN, (BATCH, n_out), dtype=torch.int32)

    try:
        out = mlmodel.predict({"x": x.numpy(), "indices": indices.numpy()})
        key = next(iter(out))
        got = out[key]
        result["predict"] = "ok"
        result["shape"] = list(got.shape)
        expected = model(x, indices).detach().numpy()
        # Core ML computes in fp16 by default at this deployment target while torch
        # is fp32, so the two agree only to ~1e-3. The question here is whether the
        # result is correct, not bit-identical, so the tolerance is fp16-sized.
        result["matches_torch"] = bool(
            got.shape == expected.shape
            and (got.size == 0 or np.allclose(got, expected, atol=1e-2))
        )
    except Exception as e:  # noqa: BLE001
        result["predict"] = "failed"
        result["error"] = f"{type(e).__name__}: {e}"

    result["plan"] = compute_plan(mlmodel, cu)
    return result


def run_subprocess(n_out: int, cu_name: str, lower: int, shape_mode: str) -> dict:
    proc = subprocess.run(
        [sys.executable, __file__, "--cell", str(n_out), cu_name, str(lower), shape_mode],
        capture_output=True,
        text=True,
    )
    # The old "Data-dependent shapes were disabled" text no longer reaches stderr on
    # coremltools 9; the Espresso runtime logs an equivalent dynamic-shape message to
    # os_log instead. This flags either the historical stderr text or the current one.
    e5rt = any(
        marker in proc.stderr
        for marker in ("Data-dependent shapes were disabled", "E5RT", "Espresso", "E5 function")
    )
    cell = {"n_out": n_out, "cu": cu_name, "lower": lower, "shape_mode": shape_mode, "e5rt": e5rt}
    for line in reversed(proc.stdout.strip().splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                cell.update(json.loads(line))
                break
            except json.JSONDecodeError:
                continue
    else:
        cell["child_error"] = proc.stderr[-500:] or "no JSON on stdout"
    return cell


def gather_supported(cell: dict) -> str:
    """The gather op's *supported* devices — the evidence. `preferred` is useless
    here because every op prefers CPU on a model this small; whether NE is even an
    option is what the supported list shows."""
    gather = next(
        (r for r in cell.get("plan", []) if isinstance(r, dict) and "gather" in (r.get("op") or "")),
        None,
    )
    if not gather or "supported" not in gather:
        return "-"
    return "+".join(gather["supported"]) or "none"


def drive() -> None:
    # Part A: the original sweep — is it the zero length or the dynamic length that
    # matters? n_out varies, everything is dynamic ("both").
    part_a = [
        run_subprocess(n_out, cu, lower, "both")
        for n_out in N_OUTS
        for cu in CU_NAMES
        for lower in LOWERS
    ]
    print("\n== Part A: does n_out (0 vs 3 vs 17) change anything? (all axes dynamic) ==")
    print(f"{'n_out':>5} {'cu':<12} {'low':>3} {'predict':>8} {'shape':>10} {'match':>6} {'gather supp':>12}")
    for c in part_a:
        pred = c.get("predict", c.get("skipped", "-"))
        print(
            f"{c['n_out']:>5} {c['cu']:<12} {c['lower']:>3} {pred:>8} "
            f"{str(c.get('shape', '-')):>10} {str(c.get('matches_torch', '-')):>6} "
            f"{gather_supported(c):>12}"
        )
    # The refusal under lower=1, n_out=0 — is it a shape validation error (the
    # expected one) or something else? Raising the lower bound is a tempting "fix", so
    # its exact failure is worth pinning.
    for c in part_a:
        if c["lower"] == 1 and c["n_out"] == 0 and c.get("error"):
            print(f"   lower=1 n_out=0 refusal: {c['error'][:160]}")
            break

    # Part B: which dynamic axis drops NE, and does a fully static graph get it back?
    # Fixed n_out=3, lower=0; vary only the shape mode, on the two cu that admit NE.
    part_b = [
        run_subprocess(3, cu, 0, mode)
        for mode in ("both", "static", "x-dyn", "idx-dyn")
        for cu in ("CPU_AND_NE", "ALL")
    ]
    print("\n== Part B: which dynamic axis costs the Neural Engine? (n_out=3) ==")
    print(f"{'shape_mode':<10} {'cu':<12} {'gather supported':>18}")
    for c in part_b:
        print(f"{c['shape_mode']:<10} {c['cu']:<12} {gather_supported(c):>18}")
    print(
        "   static should list NE (positive control); whichever single-axis mode drops"
        " it names the culprit"
    )


if __name__ == "__main__":
    if len(sys.argv) >= 5 and sys.argv[1] == "--cell":
        mode = sys.argv[5] if len(sys.argv) >= 6 else "both"
        res = run_cell(int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), mode)
        print(json.dumps(res))
    else:
        drive()
