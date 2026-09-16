"""Qixuan DiffSinger and original BigVGAN execution for SING-RENDER1/spec1.

This module deliberately imports no model framework at module-import time.  The
renderer validates all immutable material before constructing this engine.
"""

from __future__ import annotations

from collections import OrderedDict
from dataclasses import dataclass
from contextlib import redirect_stdout
import gc
import importlib
from importlib.machinery import PathFinder
import io
import json
import math
import os
from pathlib import Path
import sys
from typing import Any, Callable, Mapping, Sequence
import warnings

from d_audio_contract import ContractError
from d_singing_timing import DurationAlignment, DurationPlan, align_duration_predictions


SAMPLE_RATE = 44_100
HOP_SIZE = 512
CONTEXT_TICKS = 500_000
HEAD_FRAMES = 8
TAIL_FRAMES = 8
PITCH_STEPS = 10
VARIANCE_STEPS = 20
ACOUSTIC_STEPS = 20
ACOUSTIC_DEPTH = 0.6
MEL_BANDS = 128
PROJECTION_BLOCK_FRAMES = 32
PROJECTION_HISTORY = 10
PROJECTION_MAX_ITERATIONS = 200
PROJECTION_MAXIMUM_RELATIVE_RESIDUAL = 0.10


class QixuanRuntimeError(ContractError):
    """A model, dependency, shape, numeric, or lifecycle failure."""

    def __init__(self, message: str) -> None:
        super().__init__(message, "runtime")


class RenderCancelled(Exception):
    """Dedicated cooperative cancellation shared by renderer and model adapter."""


@dataclass(frozen=True, slots=True)
class AcousticConditions:
    alignment: DurationAlignment
    mel: Any


@dataclass(frozen=True, slots=True)
class VocoderOutput:
    samples: Any
    native_frame_count: int
    projection_relative_residual: float
    devices: Any | None = None


_MAX_RUNTIME_VERSION_LENGTH = 128
_MPS_FALLBACK_ADMITTED = False


def _runtime_version(value: Any, label: str) -> str:
    if type(value) is not str or not value or len(value) > _MAX_RUNTIME_VERSION_LENGTH:
        raise QixuanRuntimeError(
            f"{label} runtime version must be nonempty text no longer than "
            f"{_MAX_RUNTIME_VERSION_LENGTH} characters"
        )
    return value


def _normalized_device_type(device: Any, label: str) -> str:
    value = getattr(device, "type", None)
    if type(value) is not str or not value:
        raise QixuanRuntimeError(f"{label} has no observable device.type")
    normalized = value.strip().lower()
    if not normalized:
        raise QixuanRuntimeError(f"{label} has an empty device.type")
    return normalized


def _admit_mps_without_fallback() -> None:
    """Establish fallback=0 before this process imports torch for MPS work."""
    global _MPS_FALLBACK_ADMITTED
    configured = os.environ.get("PYTORCH_ENABLE_MPS_FALLBACK")
    torch_preloaded = "torch" in sys.modules
    if configured is None:
        if torch_preloaded:
            raise QixuanRuntimeError(
                "cannot prove MPS fallback was disabled before the preloaded torch runtime"
            )
        os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "0"
    elif configured != "0":
        raise QixuanRuntimeError("PYTORCH_ENABLE_MPS_FALLBACK must be exactly 0 for MPS")
    if torch_preloaded and not _MPS_FALLBACK_ADMITTED:
        raise QixuanRuntimeError(
            "cannot prove MPS fallback was disabled before the preloaded torch runtime"
        )
    _MPS_FALLBACK_ADMITTED = True


def _numpy() -> Any:
    try:
        return importlib.import_module("numpy")
    except Exception as exc:
        raise QixuanRuntimeError(f"NumPy is unavailable: {exc}") from exc


def _finite_array(value: Any, *, shape: tuple[int, ...], dtype: str, label: str) -> Any:
    np = _numpy()
    if type(value) is not np.ndarray:
        raise QixuanRuntimeError(f"{label} must be a NumPy array")
    if value.shape != shape:
        raise QixuanRuntimeError(f"{label} shape mismatch: expected {shape}, got {value.shape}")
    if value.dtype != np.dtype(dtype):
        raise QixuanRuntimeError(f"{label} dtype mismatch: expected {dtype}, got {value.dtype}")
    if value.dtype.kind == "f" and not bool(np.isfinite(value).all()):
        raise QixuanRuntimeError(f"{label} contains NaN or Infinity")
    return value


def _load_mapping(path: Path, *, label: str) -> dict[str, int]:
    """Load an already hash-bound model inventory without accepting loose JSON."""
    try:
        raw = path.read_bytes()
        pairs = json.loads(
            raw.decode("utf-8-sig", errors="strict"),
            object_pairs_hook=lambda values: _unique_pairs(values, label),
            parse_constant=lambda value: (_ for _ in ()).throw(
                ValueError(f"non-finite number {value}")
            ),
        )
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        raise QixuanRuntimeError(f"cannot parse {label}: {exc}") from exc
    if type(pairs) is not dict or not pairs:
        raise QixuanRuntimeError(f"{label} must be a nonempty object")
    result: dict[str, int] = {}
    for key, value in pairs.items():
        if type(key) is not str or not key or type(value) is not int or value < 0:
            raise QixuanRuntimeError(f"{label} must map nonempty strings to nonnegative integers")
        result[key] = value
    return result


def _unique_pairs(values: list[tuple[str, Any]], label: str) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in values:
        if key in result:
            raise ValueError(f"duplicate key {key!r} in {label}")
        result[key] = value
    return result


def _module_locations(module: Any) -> tuple[Path, ...]:
    locations: list[Path] = []
    source = getattr(module, "__file__", None)
    if source:
        locations.append(Path(source).resolve(strict=True))
    package_paths = getattr(module, "__path__", None)
    if package_paths is not None:
        locations.extend(Path(item).resolve(strict=True) for item in package_paths)
    return tuple(locations)


def _within(root: Path, candidate: Path) -> bool:
    try:
        candidate.relative_to(root)
        return True
    except ValueError:
        return False


_VENDOR_MODULES = (
    "bigvgan",
    "activations",
    "env",
    "utils",
    "meldataset",
    "alias_free_activation",
    "alias_free_activation.torch",
    "alias_free_activation.torch.act",
    "alias_free_activation.torch.filter",
    "alias_free_activation.torch.resample",
)


def _resolved_unique_paths(values: Sequence[Any], label: str) -> tuple[Path, ...]:
    result: list[Path] = []
    try:
        for value in values:
            resolved = Path(value).resolve(strict=True)
            if resolved not in result:
                result.append(resolved)
    except OSError as exc:
        raise QixuanRuntimeError(f"cannot resolve {label}: {exc}") from exc
    return tuple(result)


def _expected_loaded_module(vendor_root: Path, name: str) -> tuple[Path | None, tuple[Path, ...]]:
    alias_root = vendor_root / "alias_free_activation"
    torch_root = alias_root / "torch"
    direct = {
        "bigvgan": vendor_root / "bigvgan.py",
        "activations": vendor_root / "activations.py",
        "env": vendor_root / "env.py",
        "utils": vendor_root / "utils.py",
        "meldataset": vendor_root / "meldataset.py",
        "alias_free_activation.torch": torch_root / "__init__.py",
        "alias_free_activation.torch.act": torch_root / "act.py",
        "alias_free_activation.torch.filter": torch_root / "filter.py",
        "alias_free_activation.torch.resample": torch_root / "resample.py",
    }
    if name == "alias_free_activation":
        return None, (_expected_origin(alias_root),)
    source = direct[name]
    package_paths = (_expected_origin(torch_root),) if name == "alias_free_activation.torch" else ()
    return _expected_origin(source), package_paths


def _validate_vendor_modules(vendor_root: Path) -> None:
    for name in _VENDOR_MODULES:
        module = sys.modules.get(name)
        if module is None:
            continue
        expected_file, expected_paths = _expected_loaded_module(vendor_root, name)
        source = getattr(module, "__file__", None)
        if expected_file is None:
            if source is not None:
                raise QixuanRuntimeError(
                    f"preloaded vendor namespace {name!r} has an unexpected source file"
                )
        else:
            if not source or _expected_origin(Path(source)) != expected_file:
                raise QixuanRuntimeError(
                    f"preloaded vendor module {name!r} is not its exact bound source"
                )
        actual_paths = _resolved_unique_paths(
            tuple(getattr(module, "__path__", ()) or ()), f"loaded vendor module {name} paths"
        )
        if actual_paths != expected_paths:
            raise QixuanRuntimeError(
                f"preloaded vendor module {name!r} has unexpected package search locations"
            )


def _expected_origin(path: Path) -> Path:
    try:
        return path.resolve(strict=True)
    except OSError as exc:
        raise QixuanRuntimeError(f"cannot resolve bound vendor source {path}: {exc}") from exc


def _validate_spec_origin(spec: Any, expected: Path, label: str) -> None:
    origin = getattr(spec, "origin", None)
    if spec is None or not origin:
        raise QixuanRuntimeError(f"bound vendor module {label!r} is not resolvable")
    try:
        actual = Path(origin).resolve(strict=True)
    except OSError as exc:
        raise QixuanRuntimeError(f"cannot resolve vendor module {label!r}: {exc}") from exc
    if actual != _expected_origin(expected):
        raise QixuanRuntimeError(f"vendor module {label!r} resolves outside its bound source")


def _preflight_vendor_imports(vendor_root: Path) -> None:
    """Resolve the exact original module graph without executing vendor code."""
    root = _expected_origin(vendor_root)
    alias_root = root / "alias_free_activation"
    unexpected_initializer = alias_root / "__init__.py"
    if os.path.lexists(unexpected_initializer):
        raise QixuanRuntimeError("alias_free_activation must remain the fixed namespace without __init__.py")
    _validate_vendor_modules(root)
    direct = {
        "bigvgan": root / "bigvgan.py",
        "activations": root / "activations.py",
        "env": root / "env.py",
        "utils": root / "utils.py",
        "meldataset": root / "meldataset.py",
    }
    for name, expected in direct.items():
        _validate_spec_origin(PathFinder.find_spec(name, [str(root)]), expected, name)

    # A namespace portion can otherwise be displaced by a regular package later
    # on sys.path.  Resolve against the exact future search order and reject any
    # external portion before import has a chance to execute it.
    search_path = [str(root), *(item for item in sys.path if item != str(root))]
    alias_spec = PathFinder.find_spec("alias_free_activation", search_path)
    if alias_spec is None or alias_spec.origin is not None:
        raise QixuanRuntimeError("alias_free_activation resolves as an external regular package")
    locations = getattr(alias_spec, "submodule_search_locations", None)
    try:
        resolved_locations = _resolved_unique_paths(tuple(locations or ()), "alias_free_activation namespace")
    except OSError as exc:
        raise QixuanRuntimeError(f"cannot resolve alias_free_activation namespace: {exc}") from exc
    if resolved_locations != (_expected_origin(alias_root),):
        raise QixuanRuntimeError("alias_free_activation namespace has an external search location")

    torch_root = alias_root / "torch"
    _validate_spec_origin(
        PathFinder.find_spec("alias_free_activation.torch", [str(alias_root)]),
        torch_root / "__init__.py", "alias_free_activation.torch",
    )
    for leaf in ("act", "filter", "resample"):
        name = f"alias_free_activation.torch.{leaf}"
        _validate_spec_origin(
            PathFinder.find_spec(name, [str(torch_root)]), torch_root / f"{leaf}.py", name,
        )


def _import_bigvgan(vendor_root: Path) -> tuple[Any, Any, Any]:
    """Import bound upstream modules while restoring the caller's sys.path."""
    resolved = vendor_root.resolve(strict=True)
    _preflight_vendor_imports(resolved)
    original_path = list(sys.path)
    try:
        sys.path.insert(0, str(resolved))
        env_module = importlib.import_module("env")
        bigvgan_module = importlib.import_module("bigvgan")
        _validate_vendor_modules(resolved)
        torch = importlib.import_module("torch")
    except QixuanRuntimeError:
        raise
    except Exception as exc:
        raise QixuanRuntimeError(f"cannot import bound BigVGAN runtime: {exc}") from exc
    finally:
        sys.path[:] = original_path
    return torch, env_module.AttrDict, bigvgan_module.BigVGAN


def _compatible_metadata_shape(metadata: Sequence[Any], actual: tuple[int, ...]) -> bool:
    if len(metadata) != len(actual):
        return False
    for expected, observed in zip(metadata, actual):
        if isinstance(expected, int) and expected != observed:
            return False
    return True


_ONNX_TYPES = {
    "float32": "tensor(float)",
    "int64": "tensor(int64)",
    "bool": "tensor(bool)",
}


class QixuanEngine:
    """One-shot execution owner.  Instances retain no global model."""

    def __init__(
        self,
        bank_directory: Path,
        vocoder_directory: Path,
        vendor_directory: Path,
        *,
        vocoder_device: str = "cpu",
    ) -> None:
        if type(vocoder_device) is not str or vocoder_device not in {"cpu", "mps"}:
            raise QixuanRuntimeError("vocoder_device must be exactly 'cpu' or 'mps'")
        self.bank_directory = bank_directory
        self.vocoder_directory = vocoder_directory
        self.vendor_directory = vendor_directory
        self.vocoder_device = vocoder_device
        self._onnx_devices: dict[str, str] | None = None

    def _record_onnx_devices(self, ort: Any, providers: Any) -> None:
        if type(providers) is not list or providers != ["CPUExecutionProvider"]:
            raise QixuanRuntimeError("ONNX session did not remain CPU-only")
        observation = {
            "requested": "cpu",
            "actual": "cpu",
            "provider": providers[0],
            "runtime": "onnxruntime",
            "version": _runtime_version(getattr(ort, "__version__", None), "ONNX"),
            "precision": "FP32-original",
            "fallback": "forbidden",
        }
        if self._onnx_devices is not None and self._onnx_devices != observation:
            raise QixuanRuntimeError("ONNX runtime observation changed between sessions")
        self._onnx_devices = observation

    def _ids(self, folder: str, stem: str, symbols: tuple[str, ...]) -> dict[str, Any]:
        np = _numpy()
        base = self.bank_directory / folder if folder else self.bank_directory
        tokens = _load_mapping(base / f"{stem}.phonemes.json", label=f"{stem} phonemes")
        languages = _load_mapping(base / f"{stem}.languages.json", label=f"{stem} languages")
        if "zh" not in languages:
            raise QixuanRuntimeError(f"{stem} languages has no zh entry")
        token_values: list[int] = []
        language_values: list[int] = []
        for symbol in symbols:
            try:
                token_values.append(tokens[symbol])
            except KeyError as exc:
                raise QixuanRuntimeError(f"{stem} has no token for {symbol!r}") from exc
            language_values.append(languages["zh"] if symbol.startswith("zh/") else 0)
        return {
            "tokens": np.asarray([token_values], dtype=np.int64),
            "languages": np.asarray([language_values], dtype=np.int64),
        }

    def _session_options(self, ort: Any) -> Any:
        options = ort.SessionOptions()
        options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
        options.intra_op_num_threads = 1
        options.inter_op_num_threads = 1
        options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
        options.enable_mem_pattern = False
        options.enable_cpu_mem_arena = False
        options.enable_profiling = False
        options.log_severity_level = 3
        return options

    def _run_onnx(
        self,
        relative_path: str,
        feeds: Mapping[str, Any],
        outputs: Mapping[str, tuple[tuple[int, ...], str]],
    ) -> dict[str, Any]:
        np = _numpy()
        try:
            ort = importlib.import_module("onnxruntime")
        except Exception as exc:
            raise QixuanRuntimeError(f"ONNX Runtime is unavailable: {exc}") from exc
        if _runtime_version(getattr(ort, "__version__", None), "ONNX") != "1.22.1":
            raise QixuanRuntimeError("ONNX Runtime 1.22.1 is required")
        session: Any = None
        try:
            session = ort.InferenceSession(
                str(self.bank_directory / relative_path),
                sess_options=self._session_options(ort),
                providers=["CPUExecutionProvider"],
            )
            session.disable_fallback()
            self._record_onnx_devices(ort, session.get_providers())
            inputs = session.get_inputs()
            if {item.name for item in inputs} != set(feeds):
                raise QixuanRuntimeError(f"{relative_path} input names do not match the fixed interface")
            for item in inputs:
                value = feeds[item.name]
                if type(value) is not np.ndarray:
                    raise QixuanRuntimeError(f"{relative_path}:{item.name} is not a NumPy array")
                expected_type = _ONNX_TYPES.get(value.dtype.name)
                if expected_type is None or item.type != expected_type:
                    raise QixuanRuntimeError(f"{relative_path}:{item.name} dtype metadata mismatch")
                if not _compatible_metadata_shape(item.shape, value.shape):
                    raise QixuanRuntimeError(f"{relative_path}:{item.name} shape metadata mismatch")
                if value.dtype.kind == "f" and not bool(np.isfinite(value).all()):
                    raise QixuanRuntimeError(f"{relative_path}:{item.name} contains NaN or Infinity")
            metadata = session.get_outputs()
            if {item.name for item in metadata} != set(outputs):
                raise QixuanRuntimeError(f"{relative_path} output names do not match the fixed interface")
            for item in metadata:
                shape, dtype = outputs[item.name]
                if item.type != _ONNX_TYPES[dtype] or not _compatible_metadata_shape(item.shape, shape):
                    raise QixuanRuntimeError(f"{relative_path}:{item.name} output metadata mismatch")
            names = [item.name for item in metadata]
            values = session.run(names, dict(feeds))
            if len(values) != len(names):
                raise QixuanRuntimeError(f"{relative_path} returned the wrong output count")
            result = dict(zip(names, values))
            for name, (shape, dtype) in outputs.items():
                _finite_array(result[name], shape=shape, dtype=dtype, label=f"{relative_path}:{name}")
            return result
        except QixuanRuntimeError:
            raise
        except Exception as exc:
            raise QixuanRuntimeError(f"ONNX execution failed for {relative_path}: {exc}") from exc
        finally:
            session = None
            gc.collect()

    def duration(self, plan: DurationPlan, checkpoint: Callable[[], None]) -> DurationAlignment:
        np = _numpy()
        predictions: list[list[float]] = []
        for index, group in enumerate(plan.groups):
            checkpoint()
            count = len(group.symbols)
            encoded = self._run_onnx(
                "dsdur/0102_qixuan_newdict_dur.qixuan.linguistic.onnx",
                {
                    **self._ids("dsdur", "0102_qixuan_newdict_dur", group.symbols),
                    "word_div": np.asarray([group.word_div], dtype=np.int64),
                    "word_dur": np.asarray([group.word_dur], dtype=np.int64),
                },
                {"encoder_out": ((1, count, 256), "float32"), "x_masks": ((1, count), "bool")},
            )
            checkpoint()
            prediction = self._run_onnx(
                "dsdur/0102_qixuan_newdict_dur.qixuan.dur.onnx",
                {
                    **encoded,
                    "ph_midi": np.asarray([group.ph_midi], dtype=np.int64),
                },
                {"ph_dur_pred": ((1, count), "float32")},
            )["ph_dur_pred"][0]
            if not bool(np.isfinite(prediction).all()) or not bool((prediction > 0).all()):
                raise QixuanRuntimeError(f"duration prediction {index} is not finite and strictly positive")
            predictions.append(prediction.astype(np.float64, copy=False).tolist())
            checkpoint()
        try:
            return align_duration_predictions(
                plan, predictions, head_frames=HEAD_FRAMES, tail_frames=TAIL_FRAMES
            )
        except ContractError as exc:
            raise QixuanRuntimeError(f"duration alignment failed: {exc}") from exc

    @staticmethod
    def _note_arrays(alignment: DurationAlignment) -> tuple[Any, Any, Any]:
        np = _numpy()
        voiced = [value for value in alignment.note_midi if value is not None]
        if not voiced:
            raise QixuanRuntimeError("the aligned phrase has no voiced MIDI note")
        first = voiced[0]
        previous = first
        filled: list[int] = []
        rests: list[bool] = []
        for value in alignment.note_midi:
            rests.append(value is None)
            if value is not None:
                previous = value
            filled.append(previous)
        return (
            np.asarray([filled], dtype=np.float32),
            np.asarray([rests], dtype=np.bool_),
            np.asarray(first, dtype=np.float32),
        )

    def _encoder(self, folder: str, stem: str, alignment: DurationAlignment) -> dict[str, Any]:
        np = _numpy()
        count = len(alignment.phonemes)
        return self._run_onnx(
            f"{folder}/{stem}.qixuan.linguistic.onnx",
            {
                **self._ids(folder, stem, alignment.phonemes),
                "ph_dur": np.asarray([alignment.phoneme_durations], dtype=np.int64),
            },
            {"encoder_out": ((1, count, 256), "float32"), "x_masks": ((1, count), "bool")},
        )

    def pitch(self, alignment: DurationAlignment, checkpoint: Callable[[], None]) -> Any:
        np = _numpy()
        checkpoint()
        encoded = self._encoder("dspitch", "0102_qixuan_muon1_pitch", alignment)
        checkpoint()
        note_midi, note_rest, first = self._note_arrays(alignment)
        frames = alignment.frame_count
        return self._run_onnx(
            "dspitch/0102_qixuan_muon1_pitch.qixuan.pitch.onnx",
            {
                "encoder_out": encoded["encoder_out"],
                "ph_dur": np.asarray([alignment.phoneme_durations], dtype=np.int64),
                "note_midi": note_midi,
                "note_rest": note_rest,
                "note_dur": np.asarray([alignment.note_durations], dtype=np.int64),
                "pitch": np.full((1, frames), first.item(), dtype=np.float32),
                "expr": np.ones((1, frames), dtype=np.float32),
                "retake": np.ones((1, frames), dtype=np.bool_),
                "steps": np.asarray(PITCH_STEPS, dtype=np.int64),
            },
            {"pitch_pred": ((1, frames), "float32")},
        )["pitch_pred"]

    def variance(
        self, alignment: DurationAlignment, pitch: Any, checkpoint: Callable[[], None]
    ) -> tuple[Any, Any]:
        np = _numpy()
        checkpoint()
        encoded = self._encoder("dsvariance", "0102_qixuan_muon1_multivar", alignment)
        checkpoint()
        frames = alignment.frame_count
        result = self._run_onnx(
            "dsvariance/0102_qixuan_muon1_multivar.qixuan.variance.onnx",
            {
                "encoder_out": encoded["encoder_out"],
                "ph_dur": np.asarray([alignment.phoneme_durations], dtype=np.int64),
                "pitch": _finite_array(pitch, shape=(1, frames), dtype="float32", label="pitch"),
                "breathiness": np.zeros((1, frames), dtype=np.float32),
                "voicing": np.zeros((1, frames), dtype=np.float32),
                "retake": np.ones((1, frames, 2), dtype=np.bool_),
                "steps": np.asarray(VARIANCE_STEPS, dtype=np.int64),
            },
            {
                "breathiness_pred": ((1, frames), "float32"),
                "voicing_pred": ((1, frames), "float32"),
            },
        )
        return (
            np.clip(result["breathiness_pred"], -96.0, 0.0).astype(np.float32, copy=False),
            np.clip(result["voicing_pred"], -96.0, 0.0).astype(np.float32, copy=False),
        )

    def acoustic(
        self,
        alignment: DurationAlignment,
        pitch: Any,
        variance: tuple[Any, Any],
        checkpoint: Callable[[], None],
    ) -> AcousticConditions:
        np = _numpy()
        checkpoint()
        frames = alignment.frame_count
        pitch = _finite_array(pitch, shape=(1, frames), dtype="float32", label="pitch")
        with np.errstate(over="ignore", invalid="ignore"):
            f0 = (440.0 * np.power(2.0, (pitch - 69.0) / 12.0)).astype(np.float32)
        if not bool(np.isfinite(f0).all()) or not bool((f0 > 0).all()):
            raise QixuanRuntimeError("pitch-to-Hz conversion is not finite and strictly positive")
        breathiness = _finite_array(
            variance[0], shape=(1, frames), dtype="float32", label="breathiness"
        )
        voicing = _finite_array(
            variance[1], shape=(1, frames), dtype="float32", label="voicing"
        )
        mel = self._run_onnx(
            "0101_qixuan_muon1_acoustic.qixuan.onnx",
            {
                **self._ids("", "0101_qixuan_muon1_acoustic", alignment.phonemes),
                "durations": np.asarray([alignment.phoneme_durations], dtype=np.int64),
                "f0": f0,
                "breathiness": breathiness,
                "voicing": voicing,
                "gender": np.zeros((1, frames), dtype=np.float32),
                "velocity": np.ones((1, frames), dtype=np.float32),
                "depth": np.asarray(ACOUSTIC_DEPTH, dtype=np.float32),
                "steps": np.asarray(ACOUSTIC_STEPS, dtype=np.int64),
            },
            {"mel": ((1, frames, MEL_BANDS), "float32")},
        )["mel"]
        return AcousticConditions(alignment=alignment, mel=mel)

    def vocoder(
        self, conditions: AcousticConditions, checkpoint: Callable[[], None]
    ) -> VocoderOutput:
        np = _numpy()
        frames = conditions.alignment.frame_count
        source = _finite_array(
            conditions.mel, shape=(1, frames, MEL_BANDS), dtype="float32", label="acoustic mel"
        )
        checkpoint()
        mapped, residual = project_log_mel(source[0].T, checkpoint=checkpoint)
        checkpoint()
        torch: Any = None
        model: Any = None
        state: Any = None
        generator_state: Any = None
        input_tensor: Any = None
        generated: Any = None
        mps_runtime: Any = None
        devices: dict[str, dict[str, str]] | None = None
        parameters: tuple[Any, ...] = ()
        buffers: tuple[Any, ...] = ()
        loaded_tensor: Any = None
        try:
            if self.vocoder_device == "mps":
                _admit_mps_without_fallback()
            torch, AttrDict, BigVGAN = _import_bigvgan(self.vendor_directory / "bigvgan")
            if self.vocoder_device == "mps":
                backend = getattr(getattr(torch, "backends", None), "mps", None)
                if backend is None or getattr(backend, "is_available", None) is None:
                    raise QixuanRuntimeError("torch does not expose MPS availability")
                if backend.is_available() is not True:
                    raise QixuanRuntimeError("MPS is unavailable for the requested vocoder")
                _runtime_version(getattr(torch, "__version__", None), "torch")
                mps_runtime = torch
            config_path = self.vocoder_directory / "config.json"
            try:
                config = json.loads(config_path.read_text(encoding="utf-8"))
            except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
                raise QixuanRuntimeError(f"cannot read BigVGAN config: {exc}") from exc
            if type(config) is not dict:
                raise QixuanRuntimeError("BigVGAN config must be an object")
            expected = (config.get("sampling_rate"), config.get("n_fft"), config.get("hop_size"), config.get("num_mels"))
            if expected != (SAMPLE_RATE, 2048, HOP_SIZE, MEL_BANDS):
                raise QixuanRuntimeError("BigVGAN config does not match the fixed 44.1 kHz profile")
            checkpoint()
            with torch.inference_mode():
                original_dtype = torch.get_default_dtype()
                try:
                    torch.set_default_dtype(torch.float32)
                    with torch.device("cpu"):
                        model = BigVGAN(AttrDict(config), use_cuda_kernel=False)
                finally:
                    torch.set_default_dtype(original_dtype)
                model = model.to(device=torch.device("cpu"), dtype=torch.float32)
                state = torch.load(
                    self.vocoder_directory / "bigvgan_generator.pt",
                    map_location=torch.device("cpu"),
                    weights_only=True,
                )
                if type(state) is not dict or set(state) != {"generator"}:
                    raise QixuanRuntimeError("BigVGAN checkpoint is not the strict generator state wrapper")
                generator_state = state["generator"]
                if type(generator_state) not in (dict, OrderedDict) or not generator_state:
                    raise QixuanRuntimeError("BigVGAN generator state must be a nonempty safe mapping")
                for name, state_tensor in generator_state.items():
                    if type(name) is not str or not name or not torch.is_tensor(state_tensor):
                        raise QixuanRuntimeError("BigVGAN generator state contains an invalid entry")
                    if state_tensor.device.type != "cpu" or state_tensor.dtype != torch.float32:
                        raise QixuanRuntimeError("BigVGAN generator state must be CPU float32")
                model.load_state_dict(generator_state, strict=True)
                state_tensor = None
                generator_state = None
                state = None
                # Upstream prints a status line here; product stdout is reserved for JSON Lines.
                with redirect_stdout(io.StringIO()):
                    model.remove_weight_norm()
                model.eval().requires_grad_(False)
                for loaded_tensor in (*tuple(model.parameters()), *tuple(model.buffers())):
                    if loaded_tensor.device.type != "cpu" or loaded_tensor.dtype != torch.float32:
                        raise QixuanRuntimeError("loaded BigVGAN model is not entirely CPU float32")
                loaded_tensor = None
                checkpoint()
                requested_device = torch.device(self.vocoder_device)
                actual_requested = _normalized_device_type(
                    requested_device, "requested BigVGAN device"
                )
                if actual_requested != self.vocoder_device:
                    raise QixuanRuntimeError("torch normalized the requested vocoder device unexpectedly")
                if self.vocoder_device == "mps":
                    model = model.to(device=requested_device, dtype=torch.float32)
                    parameters = tuple(model.parameters())
                    buffers = tuple(model.buffers())
                    if not parameters or not buffers:
                        raise QixuanRuntimeError(
                            "BigVGAN MPS parameter and buffer devices must both be observable"
                        )
                    for loaded_tensor in parameters:
                        if (
                            _normalized_device_type(
                                loaded_tensor.device, "BigVGAN parameter"
                            ) != "mps"
                            or loaded_tensor.dtype != torch.float32
                        ):
                            raise QixuanRuntimeError("BigVGAN parameters are not entirely MPS FP32")
                    loaded_tensor = None
                    for loaded_tensor in buffers:
                        if (
                            _normalized_device_type(loaded_tensor.device, "BigVGAN buffer") != "mps"
                            or loaded_tensor.dtype != torch.float32
                        ):
                            raise QixuanRuntimeError("BigVGAN buffers are not entirely MPS FP32")
                    loaded_tensor = None
                input_tensor = torch.from_numpy(mapped).to(
                    device=requested_device, dtype=torch.float32
                )[None]
                input_device = _normalized_device_type(input_tensor.device, "BigVGAN input")
                if input_device != self.vocoder_device or input_tensor.dtype != torch.float32:
                    raise QixuanRuntimeError("BigVGAN input is on the wrong device or precision")
                generated = model(input_tensor)
                output_device = _normalized_device_type(generated.device, "BigVGAN output")
                if output_device != self.vocoder_device or generated.dtype != torch.float32:
                    raise QixuanRuntimeError("BigVGAN output is on the wrong device or precision")
                if self.vocoder_device == "mps":
                    if self._onnx_devices is None:
                        raise QixuanRuntimeError("MPS result has no complete ONNX device observation")
                    devices = {
                        "onnx": dict(self._onnx_devices),
                        "vocoder": {
                            "requested": "mps",
                            "actual": "mps",
                            "runtime": "torch",
                            "version": _runtime_version(
                                getattr(torch, "__version__", None), "torch"
                            ),
                            "precision": "FP32",
                            "fallback": "forbidden",
                            "parameterDevice": "mps",
                            "bufferDevice": "mps",
                            "inputDevice": input_device,
                            "outputDevice": output_device,
                        },
                    }
                generated = generated.cpu().numpy()
            output = _finite_array(
                generated, shape=(1, 1, frames * HOP_SIZE), dtype="float32", label="BigVGAN output"
            )[0, 0].copy()
            checkpoint()
            return VocoderOutput(
                samples=output,
                native_frame_count=frames * HOP_SIZE,
                projection_relative_residual=residual,
                devices=devices,
            )
        except RenderCancelled:
            raise
        except QixuanRuntimeError:
            raise
        except Exception as exc:
            raise QixuanRuntimeError(f"BigVGAN execution failed: {exc}") from exc
        finally:
            generated = None
            input_tensor = None
            generator_state = None
            state = None
            model = None
            parameters = ()
            buffers = ()
            loaded_tensor = None
            mapped = None
            source = None
            gc.collect()
            if mps_runtime is not None:
                try:
                    mps_runtime.mps.synchronize()
                    mps_runtime.mps.empty_cache()
                    mps_runtime.mps.synchronize()
                except Exception as exc:
                    raise QixuanRuntimeError(f"cannot synchronize and release MPS vocoder: {exc}") from exc
            torch = None


def project_log_mel(
    log_mel: Any,
    *,
    checkpoint: Callable[[], None],
    source_filter: Any | None = None,
    target_filter: Any | None = None,
    solver: Callable[..., Any] | None = None,
) -> tuple[Any, float]:
    """Apply the frozen nonnegative amplitude reprojection in bounded blocks."""
    np = _numpy()
    if type(log_mel) is not np.ndarray or log_mel.ndim != 2 or log_mel.shape[0] != MEL_BANDS:
        raise QixuanRuntimeError("projection input must have shape [128, frames]")
    if log_mel.dtype.kind != "f" or not bool(np.isfinite(log_mel).all()) or log_mel.shape[1] <= 0:
        raise QixuanRuntimeError("projection input must be nonempty and finite floating point")
    if source_filter is None or target_filter is None or solver is None:
        try:
            librosa = importlib.import_module("librosa")
        except Exception as exc:
            raise QixuanRuntimeError(f"librosa is unavailable: {exc}") from exc
        source_filter = librosa.filters.mel(
            sr=SAMPLE_RATE, n_fft=2048, n_mels=MEL_BANDS,
            fmin=40, fmax=16_000, htk=False, norm="slaney",
        )
        target_filter = librosa.filters.mel(
            sr=SAMPLE_RATE, n_fft=2048, n_mels=MEL_BANDS,
            fmin=0, fmax=22_050, htk=False, norm="slaney",
        )
        solver = librosa.util.nnls
    source_filter = np.asarray(source_filter)
    target_filter = np.asarray(target_filter)
    expected_filter_shape = (MEL_BANDS, 1025)
    if source_filter.shape != expected_filter_shape or target_filter.shape != expected_filter_shape:
        raise QixuanRuntimeError("projection mel filters have an unexpected shape")
    if not bool(np.isfinite(source_filter).all()) or not bool(np.isfinite(target_filter).all()):
        raise QixuanRuntimeError("projection mel filters contain NaN or Infinity")
    unsupported = source_filter.sum(axis=0) == 0
    try:
        with np.errstate(over="raise", invalid="raise"):
            target = np.exp(log_mel.astype(np.float64, copy=False))
    except FloatingPointError as exc:
        raise QixuanRuntimeError(f"projection exponential overflow: {exc}") from exc
    if not bool(np.isfinite(target).all()):
        raise QixuanRuntimeError("projection target contains NaN or Infinity")

    chunks: list[Any] = []
    residual_squared = 0.0
    target_squared = 0.0
    for offset in range(0, target.shape[1], PROJECTION_BLOCK_FRAMES):
        checkpoint()
        block = target[:, offset:offset + PROJECTION_BLOCK_FRAMES]
        try:
            with warnings.catch_warnings(record=True) as caught:
                warnings.simplefilter("always")
                recovered = solver(
                    source_filter,
                    block,
                    m=PROJECTION_HISTORY,
                    maxiter=PROJECTION_MAX_ITERATIONS,
                )
            if caught:
                raise QixuanRuntimeError(f"NNLS emitted a warning: {caught[0].message}")
        except QixuanRuntimeError:
            raise
        except Exception as exc:
            raise QixuanRuntimeError(f"NNLS projection failed: {exc}") from exc
        recovered = np.asarray(recovered)
        if recovered.shape != (1025, block.shape[1]):
            raise QixuanRuntimeError("NNLS projection returned an unexpected shape")
        if not bool(np.isfinite(recovered).all()) or bool((recovered < 0).any()):
            raise QixuanRuntimeError("NNLS projection returned invalid amplitudes")
        recovered = recovered.astype(np.float64, copy=False)
        recovered[unsupported, :] = 0.0
        difference = source_filter @ recovered - block
        residual_squared += float(np.sum(difference * difference, dtype=np.float64))
        target_squared += float(np.sum(block * block, dtype=np.float64))
        chunks.append(recovered)
        checkpoint()
    spectrum = np.concatenate(chunks, axis=1)
    denominator = max(math.sqrt(target_squared), 1e-20)
    residual = math.sqrt(residual_squared) / denominator
    if not math.isfinite(residual):
        raise QixuanRuntimeError("projection relative residual is not finite")
    if residual > PROJECTION_MAXIMUM_RELATIVE_RESIDUAL:
        raise QixuanRuntimeError(
            f"projection relative residual {residual:.9g} exceeds {PROJECTION_MAXIMUM_RELATIVE_RESIDUAL}"
        )
    mapped_amplitude = target_filter @ np.sqrt(spectrum * spectrum + 1e-9)
    mapped = np.log(np.maximum(mapped_amplitude, 1e-5))
    if mapped.shape != (MEL_BANDS, log_mel.shape[1]) or not bool(np.isfinite(mapped).all()):
        raise QixuanRuntimeError("projected BigVGAN conditioning is invalid")
    return mapped.astype(np.float32), float(residual)
