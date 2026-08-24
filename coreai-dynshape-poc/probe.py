"""Minimal probe: does coreai-torch trace/convert a dynamic-shape gather_nd
that reproduces the pattern which killed onnxruntime's CoreML EP on
Style-Bert-VITS2's Stochastic Duration Predictor?

Failure reproduced there:
    Input (/sdp/flows.3/GatherND_2_output_0) has a dynamic shape ({-1,-1})
    but the runtime shape ({0,10}) has zero elements. This is not supported
    by the CoreML EP.

Shape of the bug: a Conv1d-derived feature map is gathered along a sequence
dimension whose length is data-dependent (duration-predictor output) and can
be zero for some inputs. This script isolates exactly that combination —
nothing else from VITS2 is touched.
"""

import torch
import torch.nn as nn
from coreai_torch import TorchConverter, get_decomp_table


class DynGatherProbe(nn.Module):
    """Conv1d feature extractor -> gather along a dynamic, possibly-zero-length axis."""

    def __init__(self, channels: int = 8) -> None:
        super().__init__()
        self.conv = nn.Conv1d(channels, channels, kernel_size=3, padding=1)

    def forward(self, x: torch.Tensor, indices: torch.Tensor) -> torch.Tensor:
        # x: (B, C, S) -- e.g. hidden states along the text sequence
        feat = self.conv(x)  # (B, C, S)
        feat = feat.transpose(1, 2)  # (B, S, C)
        # indices: (B, N) with N derived at runtime from a duration predictor;
        # N can be 0 (this is the exact shape that broke CoreML EP: {0, C}).
        gathered = torch.gather(
            feat,
            dim=1,
            index=indices.unsqueeze(-1).expand(-1, -1, feat.shape[-1]),
        )
        return gathered


def run() -> None:
    model = DynGatherProbe().eval()

    batch, channels, seq_len = 1, 8, 20
    n_out = 5  # will be marked dynamic; 0 is the pathological case we care about

    x = torch.randn(batch, channels, seq_len)
    indices = torch.randint(0, seq_len, (batch, n_out))

    seq_dim = torch.export.Dim("seq_len", min=1, max=4096)
    out_dim = torch.export.Dim("n_out", min=0, max=4096)  # note: min=0, the crux

    print("== torch.export (dynamic shapes, out dim allows zero) ==")
    exported = torch.export.export(
        model,
        args=(x, indices),
        dynamic_shapes={
            "x": {2: seq_dim},
            "indices": {1: out_dim},
        },
    )
    print("export OK")

    print("== run_decompositions ==")
    exported = exported.run_decompositions(get_decomp_table())
    print("decompositions OK")

    print("== TorchConverter -> to_coreai() ==")
    converter = TorchConverter().add_exported_program(
        exported, input_names=["x", "indices"], output_names=["out"]
    )
    program = converter.to_coreai()
    print("to_coreai() OK")

    print("== optimize() ==")
    program.optimize()
    print("optimize() OK")

    # The actual pathological case: n_out == 0 at runtime.
    print("== zero-length runtime check (n_out=0) ==")
    zero_indices = torch.zeros(batch, 0, dtype=torch.long)
    with torch.no_grad():
        out = model(x, zero_indices)
    print(f"eager forward with n_out=0 OK, output shape={tuple(out.shape)}")


if __name__ == "__main__":
    run()
