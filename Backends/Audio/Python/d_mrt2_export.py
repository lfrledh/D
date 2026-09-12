# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Minimal MRT2-small exported-graph runtime.

This is a narrow adaptation of the Apache-2.0 Magenta RealTime SDK.  It keeps
the exported MLX graph and the four text-conditioning assets, without importing
``magenta_rt`` or its JAX/Flax/audio dependency closure.  Importing this module
is stdlib-only; NumPy, MLX, LiteRT, and SentencePiece are loaded per instance.
"""

from __future__ import annotations

import gc
import importlib
from importlib import metadata
import pathlib
from typing import Any


SDK_REPOSITORY = "https://github.com/magenta/magenta-realtime"
SDK_REVISION = "694a545e4ba0b88bf1150137b129582166d3e07f"
MODEL_REVISION = "010aa0dcb0dfd27b24f0ad07b4dad63e8f9521cc"
MODEL_NAME = "mrt2_small"

GRAPH_RELATIVE_PATH = pathlib.PurePosixPath("models/mrt2_small/mrt2_small.mlxfn")
STATE_RELATIVE_PATH = pathlib.PurePosixPath(
    "models/mrt2_small/mrt2_small_state.safetensors"
)
RESOURCE_RELATIVE_PATHS = {
    "sentencepiece": pathlib.PurePosixPath("resources/musiccoca/spm.model"),
    "text_encoder": pathlib.PurePosixPath(
        "resources/musiccoca/text_encoder.tflite"
    ),
    "mapper": pathlib.PurePosixPath("resources/musiccoca/mapper.tflite"),
    "quantizer": pathlib.PurePosixPath(
        "resources/musiccoca/pretrained_vector_quantizer.tflite"
    ),
}

STATE_LEAF_COUNT = 165
SAMPLING_KEY_STATE_INDEX = 2
DEFAULT_SAMPLING_KEY = (0, 42)
MUSICCOCA_WIDTH = 12
NOTES_WIDTH = 128
DRUMS_WIDTH = 1
RVQ_DEPTH = 12
TOKEN_OFFSET = 7  # six reserved tokens plus the dropout token
FRAME_SAMPLES = 1920
CHANNELS = 2
WARMUP_STEPS = 5
TEMPERATURE = 1.3
TOP_K = 40
CFG_MUSICCOCA = 3.0
CFG_NOTES = 1.0
CFG_DRUMS = 1.0
MAPPER_SEED = 0
MAX_SENTENCEPIECE_TOKENS = 127


class MRT2ExportError(RuntimeError):
    """The fixed exported profile or a runtime result violated its contract."""


def _distribution_version(name: str, module: Any) -> str:
    try:
        return metadata.version(name)
    except metadata.PackageNotFoundError:
        return str(getattr(module, "__version__", "unknown"))


def _make_interpreter(interpreter_type: Any, path: pathlib.Path) -> Any:
    interpreter = interpreter_type(model_path=str(path))
    interpreter.allocate_tensors()
    return interpreter


class ExportedMRT2:
    """One-task owner for the pinned official MRT2-small exported graph."""

    def __init__(self, model_root: pathlib.Path, prompt: str, seed: int):
        if not isinstance(model_root, pathlib.Path):
            raise TypeError("model_root must be pathlib.Path")
        if (
            not isinstance(prompt, str)
            or not prompt.strip()
            or "\0" in prompt
            or len(prompt.encode("utf-8")) > 4096
        ):
            raise ValueError(
                "prompt must be nonblank, NUL-free, and at most 4096 UTF-8 bytes"
            )
        if isinstance(seed, bool) or not isinstance(seed, int) or not 0 <= seed < 2**32:
            raise ValueError("seed must be an integer in UInt32 range")

        self._closed = False
        self._released = False
        self._close_result: dict[str, Any] | None = None
        self._prompt = prompt
        self._seed = seed
        self._paths = self._resolve_paths(model_root)

        self._np: Any = None
        self._mx: Any = None
        self._fn: Any = None
        self._initial_state: list[Any] | None = None
        self._state: list[Any] | None = None
        self._vocab: Any = None
        self._text_encoder: Any = None
        self._mapper: Any = None
        self._quantizer: Any = None
        self._identity: dict[str, Any] = {}

        try:
            self._initialize()
        except Exception as initialization_error:
            cleanup_error = self._discard_runtime(clear_cache=True)
            if cleanup_error is not None:
                raise MRT2ExportError(
                    "MRT2 initialization failed and cleanup also failed: "
                    f"initialization={initialization_error!r}; cleanup={cleanup_error!r}"
                ) from initialization_error
            raise

    @staticmethod
    def _resolve_paths(model_root: pathlib.Path) -> dict[str, pathlib.Path]:
        try:
            root = model_root.resolve(strict=True)
        except (OSError, RuntimeError) as error:
            raise MRT2ExportError(f"model root is unavailable: {error}") from error
        if not root.is_dir():
            raise MRT2ExportError("model root is not a directory")

        relative_paths = {
            "graph": GRAPH_RELATIVE_PATH,
            "state": STATE_RELATIVE_PATH,
            **RESOURCE_RELATIVE_PATHS,
        }
        resolved = {"root": root}
        for label, relative in relative_paths.items():
            lexical = root.joinpath(*relative.parts)
            try:
                target = lexical.resolve(strict=True)
                target.relative_to(root)
            except (OSError, RuntimeError, ValueError) as error:
                raise MRT2ExportError(
                    f"required {label} asset is unavailable inside model root: {relative}"
                ) from error
            if lexical.is_symlink() or not target.is_file():
                raise MRT2ExportError(
                    f"required {label} asset is not a regular non-symlink file: {relative}"
                )
            resolved[label] = target
        return resolved

    def _initialize(self) -> None:
        np = importlib.import_module("numpy")
        mx = importlib.import_module("mlx.core")
        litert = importlib.import_module("ai_edge_litert.interpreter")
        sentencepiece = importlib.import_module("sentencepiece")
        self._np = np
        self._mx = mx

        vocab = sentencepiece.SentencePieceProcessor()
        loaded = vocab.Load(str(self._paths["sentencepiece"]))
        if loaded is False:
            raise MRT2ExportError("SentencePiece rejected the pinned vocabulary")
        labels = list(vocab.EncodeAsIds(self._prompt.lower()))
        if len(labels) > MAX_SENTENCEPIECE_TOKENS:
            raise ValueError(
                "prompt exceeds the fixed 127-token lowercase SentencePiece limit"
            )
        if any(isinstance(token, bool) or not isinstance(token, int) for token in labels):
            raise MRT2ExportError("SentencePiece returned non-integer token IDs")
        self._vocab = vocab

        interpreter_type = litert.Interpreter
        self._text_encoder = _make_interpreter(
            interpreter_type, self._paths["text_encoder"]
        )
        self._mapper = _make_interpreter(interpreter_type, self._paths["mapper"])
        self._quantizer = _make_interpreter(
            interpreter_type, self._paths["quantizer"]
        )
        style_tokens = self._encode_style(labels)

        self._fn = mx.import_function(str(self._paths["graph"]))
        state_dict = mx.load(str(self._paths["state"]))
        expected_keys = {f"state_{index}" for index in range(STATE_LEAF_COUNT)}
        if not isinstance(state_dict, dict) or set(state_dict) != expected_keys:
            actual = len(state_dict) if isinstance(state_dict, dict) else "non-dict"
            raise MRT2ExportError(
                f"export state must contain exactly 165 contiguous leaves; got {actual}"
            )
        initial_state = [state_dict[f"state_{index}"] for index in range(STATE_LEAF_COUNT)]
        self._validate_sampling_key(initial_state, expected=DEFAULT_SAMPLING_KEY)
        mx.eval(initial_state)
        self._initial_state = initial_state

        warmup_args = self._build_graph_args(
            [-1] * MUSICCOCA_WIDTH, [-1] * NOTES_WIDTH
        )
        warmup_state = list(initial_state)
        for _ in range(WARMUP_STEPS):
            outputs = self._fn(warmup_args + warmup_state)
            mx.eval(outputs)
            warmup_state = self._validated_output_state(outputs)

        task_state = list(initial_state)
        task_state[SAMPLING_KEY_STATE_INDEX] = mx.array(
            np.array([[0, self._seed]], dtype=np.uint32), dtype=mx.uint32
        )
        self._validate_sampling_key(task_state, expected=(0, self._seed))
        self._state = task_state
        self._style_tokens = tuple(int(value) for value in style_tokens)

        self._identity = {
            "profile": "mrt2-small-export-v1",
            "model_name": MODEL_NAME,
            "model_revision": MODEL_REVISION,
            "sdk_repository": SDK_REPOSITORY,
            "sdk_revision": SDK_REVISION,
            "sdk_source_files": [
                "magenta_rt/mlx/system.py",
                "magenta_rt/musiccoca.py",
                "magenta_rt/config.py",
                "magenta_rt/mlx/model.py",
            ],
            "model_root": str(self._paths["root"]),
            "graph_path": str(self._paths["graph"]),
            "state_path": str(self._paths["state"]),
            "resource_paths": {
                name: str(self._paths[name]) for name in RESOURCE_RELATIVE_PATHS
            },
            "graph_conversion": "official MLX export loaded with import_function",
            "graph_internal_precision": "unknown",
            "output_conversion": "graph int16 to float32 divided by 32768",
            "mlx_version": _distribution_version("mlx", mx),
            "numpy_version": _distribution_version("numpy", np),
            "litert_version": _distribution_version("ai-edge-litert", litert),
            "sentencepiece_version": _distribution_version(
                "sentencepiece", sentencepiece
            ),
            "prompt": self._prompt,
            "prompt_sentencepiece_tokens": len(labels),
            "mapper_seed": MAPPER_SEED,
            "sampling_seed": self._seed,
            "sampling_key_state_index": SAMPLING_KEY_STATE_INDEX,
            "state_leaf_count": STATE_LEAF_COUNT,
            "warmup_steps": WARMUP_STEPS,
            "temperature": TEMPERATURE,
            "top_k": TOP_K,
            "cfg_scales": {
                "musiccoca": CFG_MUSICCOCA,
                "notes": CFG_NOTES,
                "drums": CFG_DRUMS,
            },
        }

    def _encode_style(self, labels: list[int]) -> Any:
        np = self._np
        text_inputs = self._text_encoder.get_input_details()
        text_outputs = self._text_encoder.get_output_details()
        id_detail = next((item for item in text_inputs if item["dtype"] == np.int32), None)
        padding_detail = next(
            (item for item in text_inputs if item["dtype"] == np.float32), None
        )
        if id_detail is None or padding_detail is None or not text_outputs:
            raise MRT2ExportError("text encoder does not expose the fixed input layout")

        ids = np.array([1] + labels + [0] * (127 - len(labels)), dtype=np.int32)
        paddings = np.ones(128, dtype=np.float32)
        paddings[: len(labels) + 1] = 0.0
        self._text_encoder.set_tensor(
            id_detail["index"], ids.reshape(tuple(id_detail["shape"]))
        )
        self._text_encoder.set_tensor(
            padding_detail["index"],
            paddings.reshape(tuple(padding_detail["shape"])),
        )
        self._text_encoder.invoke()
        embedding = np.asarray(
            self._text_encoder.get_tensor(text_outputs[0]["index"])
        ).flatten().astype(np.float32)
        if embedding.shape != (768,) or not np.isfinite(embedding).all():
            raise MRT2ExportError("text encoder returned an invalid 768-value embedding")

        mapper_inputs = self._mapper.get_input_details()
        mapper_outputs = self._mapper.get_output_details()
        if len(mapper_inputs) != 2 or not mapper_outputs:
            raise MRT2ExportError("mapper does not expose the fixed two-input layout")
        noise = np.random.RandomState(MAPPER_SEED).randn(*embedding.shape).astype(
            np.float32
        )
        self._mapper.set_tensor(
            mapper_inputs[0]["index"],
            embedding.reshape(tuple(mapper_inputs[0]["shape"])),
        )
        self._mapper.set_tensor(
            mapper_inputs[1]["index"], noise.reshape(tuple(mapper_inputs[1]["shape"]))
        )
        self._mapper.invoke()
        embedding = np.asarray(
            self._mapper.get_tensor(mapper_outputs[0]["index"])
        ).flatten().astype(np.float32)
        norm = float(np.linalg.norm(embedding))
        if embedding.shape != (768,) or not np.isfinite(embedding).all() or not norm > 0:
            raise MRT2ExportError("mapper returned an invalid 768-value embedding")
        embedding = embedding / norm

        quantizer_inputs = self._quantizer.get_input_details()
        quantizer_outputs = self._quantizer.get_output_details()
        if len(quantizer_inputs) != 1 or not quantizer_outputs:
            raise MRT2ExportError("RVQ does not expose the fixed input layout")
        self._quantizer.set_tensor(
            quantizer_inputs[0]["index"],
            embedding.reshape(tuple(quantizer_inputs[0]["shape"])),
        )
        self._quantizer.invoke()
        tokens = np.asarray(
            self._quantizer.get_tensor(quantizer_outputs[0]["index"])
        ).flatten()[:RVQ_DEPTH]
        if tokens.shape != (RVQ_DEPTH,) or not np.issubdtype(tokens.dtype, np.integer):
            raise MRT2ExportError("RVQ returned an invalid 12-token result")
        if ((tokens < 0) | (tokens >= 1024)).any():
            raise MRT2ExportError("RVQ returned an out-of-range token")
        return tokens.astype(np.int32)

    def _build_graph_args(self, style_tokens: list[int], note_tokens: list[int]) -> list[Any]:
        np = self._np
        mx = self._mx
        drums = [-1] * DRUMS_WIDTH
        positive = style_tokens + note_tokens + drums
        negative_musiccoca = [-1] * MUSICCOCA_WIDTH + note_tokens + drums
        negative_notes = style_tokens + [-1] * NOTES_WIDTH + drums

        def condition(values: list[int]) -> Any:
            encoded = np.asarray(values, dtype=np.int32) + TOKEN_OFFSET
            return mx.array(encoded.reshape(1, 1, -1), dtype=mx.int32)

        return [
            condition(positive),
            mx.array([TEMPERATURE]),
            mx.array([TOP_K], dtype=mx.int32),
            mx.array([CFG_MUSICCOCA]),
            mx.array([CFG_NOTES]),
            mx.array([CFG_DRUMS]),
            condition(negative_musiccoca),
            condition(negative_notes),
            mx.zeros((1, 0, RVQ_DEPTH), dtype=mx.int32),
        ]

    def _validate_sampling_key(
        self, state: list[Any], *, expected: tuple[int, int] | None = None
    ) -> None:
        key = self._np.asarray(state[SAMPLING_KEY_STATE_INDEX])
        if key.shape != (1, 2) or key.dtype != self._np.dtype("uint32"):
            raise MRT2ExportError("sampling key state must be uint32 with shape (1, 2)")
        if expected is not None and tuple(int(value) for value in key[0]) != expected:
            if expected == DEFAULT_SAMPLING_KEY:
                raise MRT2ExportError("sampling key state does not contain default [0, 42]")
            raise MRT2ExportError("request seed was not installed in sampling key state")

    def _validated_output_state(self, outputs: Any) -> list[Any]:
        try:
            output_count = len(outputs)
        except TypeError as error:
            raise MRT2ExportError("export graph returned a non-sequence") from error
        if output_count != STATE_LEAF_COUNT + 1:
            raise MRT2ExportError(
                f"export graph must return audio plus 165 state leaves; got {output_count}"
            )
        state = list(outputs[1:])
        # A valid exported graph advances its PRNG key.  Preserve that returned
        # key for the next frame; only its structural contract remains fixed.
        self._validate_sampling_key(state)
        return state

    def generate_frame(self, note_frame: tuple[int, ...] | None) -> Any:
        if self._closed or self._state is None or self._fn is None:
            raise MRT2ExportError("MRT2 instance is closed")
        if note_frame is None:
            notes = [-1] * NOTES_WIDTH
        else:
            if not isinstance(note_frame, tuple) or len(note_frame) != NOTES_WIDTH:
                raise ValueError("note_frame must be None or a tuple of exactly 128 values")
            if any(
                isinstance(value, bool) or not isinstance(value, int) or value not in (0, 1, 2, 3)
                for value in note_frame
            ):
                raise ValueError("note_frame values must be integer note states 0...3")
            notes = list(note_frame)

        args = self._build_graph_args(list(self._style_tokens), notes)
        outputs = self._fn(args + self._state)
        self._mx.eval(outputs)
        new_state = self._validated_output_state(outputs)

        raw = self._np.asarray(outputs[0])
        if raw.shape != (1, CHANNELS, FRAME_SAMPLES) or raw.dtype != self._np.int16:
            raise MRT2ExportError(
                "export graph audio must have shape (1, 2, 1920) and dtype int16; "
                f"got {raw.shape} and {raw.dtype}"
            )
        samples = raw[0].T.astype(self._np.float32) / self._np.float32(32768.0)
        if samples.shape != (FRAME_SAMPLES, CHANNELS) or samples.dtype != self._np.float32:
            raise MRT2ExportError("converted frame has an invalid shape or dtype")
        if not self._np.isfinite(samples).all():
            raise MRT2ExportError("converted frame contains non-finite samples")

        self._state = new_state
        return samples

    def identity(self) -> dict[str, Any]:
        result = dict(self._identity)
        result["sdk_source_files"] = list(self._identity["sdk_source_files"])
        result["resource_paths"] = dict(self._identity["resource_paths"])
        result["cfg_scales"] = dict(self._identity["cfg_scales"])
        result["closed"] = self._closed
        result["released"] = self._released
        if self._close_result and "error" in self._close_result:
            result["close_error"] = self._close_result["error"]
        return result

    def _discard_runtime(self, *, clear_cache: bool) -> Exception | None:
        mx = self._mx
        self._fn = None
        self._state = None
        self._initial_state = None
        self._style_tokens = ()
        self._vocab = None
        self._text_encoder = None
        self._mapper = None
        self._quantizer = None
        gc.collect()
        if clear_cache and mx is not None:
            try:
                mx.clear_cache()
            except Exception as error:  # reported by close()/constructor, never hidden
                return error
        return None

    def close(self) -> dict[str, Any]:
        if self._close_result is not None:
            return dict(self._close_result)
        self._closed = True
        errors: list[str] = []
        mx = self._mx
        if mx is not None:
            try:
                mx.synchronize()
            except Exception as error:
                errors.append(f"synchronize failed: {error!r}")
        cleanup_error = self._discard_runtime(clear_cache=True)
        if cleanup_error is not None:
            errors.append(f"clear_cache failed: {cleanup_error!r}")
        self._mx = None
        self._np = None

        if errors:
            self._released = False
            self._close_result = {"released": False, "error": "; ".join(errors)}
        else:
            self._released = True
            self._close_result = {"released": True}
        return dict(self._close_result)
