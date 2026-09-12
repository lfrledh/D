# MRT2 small exported-runtime provenance

`d_mrt2_export.py` is a deliberately narrow adaptation of Google LLC's
Magenta RealTime SDK. It was prepared from these files at upstream revision
`694a545e4ba0b88bf1150137b129582166d3e07f`:

- `magenta_rt/mlx/system.py`
- `magenta_rt/musiccoca.py`
- `magenta_rt/config.py`
- `magenta_rt/mlx/model.py`

Upstream repository: <https://github.com/magenta/magenta-realtime>

The upstream source is licensed under Apache License 2.0. The adapter retains
the upstream copyright/license notice. The distribution must include the
LICENSE supplied by the Lead; this file is attribution and change documentation,
not a replacement for the license text.

## Adaptation boundary

The adapter independently implements only the official `mrt2_small` exported
path: lowercase SentencePiece text encoding, the text encoder, mapper with
seed 0, mapper normalization, 12-level RVQ, exported-graph argument assembly,
five-step isolated warmup, streaming state threading, and the graph's existing
int16-to-float32 `/ 32768` conversion. It does not copy or import the full
`magenta_rt` package and does not carry its JAX, Flax, `sequence_layers`,
librosa, audio-preprocessor, or music-encoder paths.

Changes from the SDK wrapper are intentional:

- Model and resources are resolved only below the caller-authorized root at
  `models/mrt2_small` and `resources/musiccoca`; there is no download, implicit
  home lookup, or fallback.
- The fixed model revision is
  `010aa0dcb0dfd27b24f0ad07b4dad63e8f9521cc`.
- The exact 165-leaf exported state and default `uint32 (1, 2)` sampling key
  `[0, 42]` are checked before execution. The request seed replaces that key
  only after warmup; later frames thread returned state without reseeding.
- Prompts producing more than 127 lowercase SentencePiece tokens are rejected
  instead of silently truncated.
- Absent note conditioning remains masked (`-1`), while an explicit all-zero
  frame remains a distinct off-note condition.
- Output/state shape, dtype, and finite-value guards are explicit. Close is
  synchronous, releases owned references, clears the MLX cache, and reports
  cleanup failures without claiming release.
- Runtime identity records actual installed runtime versions, fixed paths and
  revisions, the actual output conversion, and keeps graph-internal precision
  explicitly `unknown` because the exported artifact does not expose it.

Re-audit rather than silently adapting if the upstream revision, model
revision, state layout, graph signature, resource layout, or runtime APIs
change. Model weights remain governed by their CC-BY-4.0/model-card terms and
are not included in this source adaptation.
