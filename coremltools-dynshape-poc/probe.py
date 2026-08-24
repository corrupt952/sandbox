"""Minimal probe: does coremltools' own PyTorch -> MLProgram conversion path
(torch.jit.trace + ct.RangeDim) trace/convert a dynamic-shape gather that
reproduces the pattern which killed onnxruntime's CoreML EP on
Style-Bert-VITS2's Stochastic Duration Predictor?

Failure reproduced there (via onnxruntime's CoreML EP, NOT coremltools):
    Input (/sdp/flows.3/GatherND_2_output_0) has a dynamic shape ({-1,-1})
    but the runtime shape ({0,10}) has zero elements. This is not supported
    by the CoreML EP.

This is the same module as coreai-dynshape-poc/probe.py, converted through a
different toolchain: coremltools's own converter (which targets the Core ML
runtime shipping on *current* OS versions, unlike coreai-torch which needs
macOS/iOS 27), instead of coreai-torch. If the original failure was specific
to the onnxruntime->CoreML EP bridge, coremltools's direct converter may
behave differently.
"""

import coremltools as ct
import torch
import torch.nn as nn


class DynGatherProbe(nn.Module):
    """Conv1d feature extractor -> gather along a dynamic, possibly-zero-length axis."""

    def __init__(self, channels: int = 8) -> None:
        super().__init__()
        self.channels = channels
        self.conv = nn.Conv1d(channels, channels, kernel_size=3, padding=1)

    def forward(self, x: torch.Tensor, indices: torch.Tensor) -> torch.Tensor:
        # x: (B, C, S) -- e.g. hidden states along the text sequence
        feat = self.conv(x)  # (B, C, S)
        feat = feat.transpose(1, 2)  # (B, S, C)
        # indices: (B, N) with N derived at runtime from a duration predictor;
        # N can be 0 (this is the exact shape that broke CoreML EP: {0, C}).
        # channels is a fixed constant here (not read off a traced dynamic
        # tensor), to avoid a JIT-tracing gotcha unrelated to the thing being
        # probed: `.shape[i]` on a dynamic-shape tensor traces as a symbolic
        # op, which coremltools' torch frontend chokes on when cast to int.
        gathered = torch.gather(
            feat,
            dim=1,
            index=indices.unsqueeze(-1).expand(-1, -1, self.channels),
        )
        return gathered


def run() -> None:
    model = DynGatherProbe().eval()

    batch, channels, seq_len = 1, 8, 20
    n_out = 5  # trace-time example; RangeDim below marks it dynamic, min=0

    x = torch.randn(batch, channels, seq_len)
    indices = torch.randint(0, seq_len, (batch, n_out), dtype=torch.int32)

    print("== torch.jit.trace ==")
    traced = torch.jit.trace(model, (x, indices))
    print("trace OK")

    print("== ct.convert (RangeDim seq_len, RangeDim n_out min=0) ==")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(
                name="x",
                shape=(batch, channels, ct.RangeDim(lower_bound=1, upper_bound=4096, default=seq_len)),
            ),
            ct.TensorType(
                name="indices",
                shape=(batch, ct.RangeDim(lower_bound=0, upper_bound=4096, default=n_out)),
                dtype=int,
            ),
        ],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
    )
    print("ct.convert OK")

    print("== save .mlpackage ==")
    mlmodel.save("probe_output.mlpackage")
    print("save OK")

    print("== inspect ops for gather_nd / gather ==")
    spec = mlmodel.get_spec()
    ops = spec.mlProgram.functions["main"].block_specializations[
        list(spec.mlProgram.functions["main"].block_specializations.keys())[0]
    ].operations
    op_types = sorted({op.type for op in ops})
    print(f"op types used: {op_types}")

    # The actual pathological case: n_out == 0 at runtime, through the compiled
    # model, across every compute-unit selection. This is the crux: does the
    # zero-length dynamic shape survive on Neural Engine / GPU, or only CPU?
    zero_indices = torch.zeros(batch, 0, dtype=torch.int32)
    for cu_name, cu in [
        ("CPU_ONLY", ct.ComputeUnit.CPU_ONLY),
        ("CPU_AND_GPU", ct.ComputeUnit.CPU_AND_GPU),
        ("CPU_AND_NE", ct.ComputeUnit.CPU_AND_NE),
        ("ALL", ct.ComputeUnit.ALL),
    ]:
        print(f"== zero-length runtime prediction (n_out=0), compute_units={cu_name} ==")
        cu_model = ct.convert(
            traced,
            inputs=[
                ct.TensorType(
                    name="x",
                    shape=(batch, channels, ct.RangeDim(lower_bound=1, upper_bound=4096, default=seq_len)),
                ),
                ct.TensorType(
                    name="indices",
                    shape=(batch, ct.RangeDim(lower_bound=0, upper_bound=4096, default=n_out)),
                    dtype=int,
                ),
            ],
            convert_to="mlprogram",
            minimum_deployment_target=ct.target.iOS17,
            compute_units=cu,
        )
        try:
            out = cu_model.predict({"x": x.numpy(), "indices": zero_indices.numpy()})
            k = next(iter(out))
            print(f"predict OK, shape={out[k].shape}")
        except Exception as e:  # noqa: BLE001 -- want to see and report the exact failure, not just crash
            print(f"predict FAILED: {type(e).__name__}: {e}")


if __name__ == "__main__":
    run()
