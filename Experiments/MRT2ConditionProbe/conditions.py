"""Strict, standard-library-only request and note conditioning support.

Importing this module deliberately does not import NumPy, MLX, or Magenta RT.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from typing import Any


SCHEMA_VERSION = 1
FRAME_RATE = 25
MAX_DURATION_FRAMES = 400
MAX_NOTES = 512
MAX_PROMPT_BYTES = 4096
PIANO_ROLL_SIZE = 128


class RequestError(ValueError):
    """A stable, user-facing request validation error."""


@dataclass(frozen=True)
class Note:
    pitch: int
    start_frame: int
    end_frame: int

    def as_json(self) -> dict[str, int]:
        return {
            "pitch": self.pitch,
            "startFrame": self.start_frame,
            "endFrame": self.end_frame,
        }


@dataclass(frozen=True)
class ProbeRequest:
    schema_version: int
    frame_rate: int
    duration_frames: int
    prompt: str
    seed: int
    # None means no note condition. An empty tuple is an explicit all-zero
    # note condition, and the distinction must survive every layer.
    notes: tuple[Note, ...] | None
    source_sha256: str
    condition_sha256: str

    @property
    def notes_mode(self) -> str:
        return "absent" if self.notes is None else "explicit"

    def normalized_condition(self) -> dict[str, Any]:
        return normalized_condition_document(
            self.frame_rate, self.duration_frames, self.notes
        )

    def executed_snapshot(self) -> dict[str, Any]:
        """Return the bounded, immutable validated request as JSON data."""
        return {
            "schemaVersion": self.schema_version,
            "frameRate": self.frame_rate,
            "durationFrames": self.duration_frames,
            "prompt": self.prompt,
            "seed": self.seed,
            "notesMode": self.notes_mode,
            "notes": None if self.notes is None else [note.as_json() for note in self.notes],
        }


def _object_without_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise RequestError(f"JSON 字段重复：{key}")
        result[key] = value
    return result


def _reject_nonfinite(token: str) -> None:
    raise RequestError(f"JSON 不允许非有限数值：{token}")


def _integer(value: Any, field: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise RequestError(f"{field} 必须是整数，布尔值不被接受")
    if not minimum <= value <= maximum:
        raise RequestError(f"{field} 必须在 {minimum}..{maximum} 范围内")
    return value


def _exact_fields(
    value: Any, *, required: set[str], optional: set[str], context: str
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise RequestError(f"{context} 必须是 JSON 对象")
    keys = set(value)
    unknown = keys - required - optional
    missing = required - keys
    if unknown:
        raise RequestError(f"{context} 含未知字段：{', '.join(sorted(unknown))}")
    if missing:
        raise RequestError(f"{context} 缺少字段：{', '.join(sorted(missing))}")
    return value


def canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def normalized_condition_document(
    frame_rate: int,
    duration_frames: int,
    notes: tuple[Note, ...] | None,
) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "frameRate": frame_rate,
        "durationFrames": duration_frames,
        "notesMode": "absent" if notes is None else "explicit",
        "notes": None if notes is None else [note.as_json() for note in notes],
    }


def parse_request(raw: bytes) -> ProbeRequest:
    """Decode and validate one schemaVersion=1 request."""
    source_sha = hashlib.sha256(raw).hexdigest()
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise RequestError("请求文件必须是严格 UTF-8") from error
    try:
        decoded = json.loads(
            text,
            object_pairs_hook=_object_without_duplicate_keys,
            parse_constant=_reject_nonfinite,
        )
    except RequestError:
        raise
    except (json.JSONDecodeError, RecursionError) as error:
        raise RequestError(f"请求不是有效 JSON：{error}") from error

    document = _exact_fields(
        decoded,
        required={"schemaVersion", "frameRate", "durationFrames", "prompt", "seed"},
        optional={"notes"},
        context="请求",
    )
    schema_version = _integer(document["schemaVersion"], "schemaVersion", 1, 1)
    frame_rate = _integer(document["frameRate"], "frameRate", FRAME_RATE, FRAME_RATE)
    duration_frames = _integer(
        document["durationFrames"], "durationFrames", 1, MAX_DURATION_FRAMES
    )
    seed = _integer(document["seed"], "seed", 0, (1 << 32) - 1)

    prompt = document["prompt"]
    if not isinstance(prompt, str) or not prompt:
        raise RequestError("prompt 必须是非空字符串")
    if "\x00" in prompt:
        raise RequestError("prompt 不允许 NUL")
    try:
        prompt_bytes = prompt.encode("utf-8", errors="strict")
    except UnicodeEncodeError as error:
        raise RequestError("prompt 必须只包含可编码为 UTF-8 的 Unicode 标量值") from error
    if len(prompt_bytes) > MAX_PROMPT_BYTES:
        raise RequestError(f"prompt 的 UTF-8 长度不得超过 {MAX_PROMPT_BYTES} bytes")

    notes: tuple[Note, ...] | None
    if "notes" not in document:
        notes = None
    else:
        raw_notes = document["notes"]
        if not isinstance(raw_notes, list):
            raise RequestError("notes 必须是数组")
        if len(raw_notes) > MAX_NOTES:
            raise RequestError(f"notes 最多 {MAX_NOTES} 项")
        parsed_notes: list[Note] = []
        for index, raw_note in enumerate(raw_notes):
            note = _exact_fields(
                raw_note,
                required={"pitch", "startFrame", "endFrame"},
                optional=set(),
                context=f"notes[{index}]",
            )
            pitch = _integer(note["pitch"], f"notes[{index}].pitch", 0, 127)
            start = _integer(
                note["startFrame"],
                f"notes[{index}].startFrame",
                0,
                duration_frames - 1,
            )
            end = _integer(
                note["endFrame"],
                f"notes[{index}].endFrame",
                1,
                duration_frames,
            )
            if start >= end:
                raise RequestError(f"notes[{index}] 必须满足 startFrame < endFrame")
            parsed_notes.append(Note(pitch, start, end))

        parsed_notes.sort(key=lambda note: (note.pitch, note.start_frame, note.end_frame))
        previous_by_pitch: dict[int, Note] = {}
        for note in parsed_notes:
            previous = previous_by_pitch.get(note.pitch)
            if previous is not None and note.start_frame < previous.end_frame:
                raise RequestError(f"音高 {note.pitch} 的音符区间重叠")
            previous_by_pitch[note.pitch] = note
        notes = tuple(parsed_notes)

    condition_document = normalized_condition_document(
        frame_rate, duration_frames, notes
    )
    condition_sha = hashlib.sha256(canonical_json_bytes(condition_document)).hexdigest()
    return ProbeRequest(
        schema_version=schema_version,
        frame_rate=frame_rate,
        duration_frames=duration_frames,
        prompt=prompt,
        seed=seed,
        notes=notes,
        source_sha256=source_sha,
        condition_sha256=condition_sha,
    )


def build_note_frames(request: ProbeRequest) -> tuple[tuple[int, ...], ...] | None:
    """Return exact 128-value frames, or None for unsupported/absent notes."""
    if request.notes is None:
        return None
    frames = [[0] * PIANO_ROLL_SIZE for _ in range(request.duration_frames)]
    for note in request.notes:
        frames[note.start_frame][note.pitch] = 2
        for frame_index in range(note.start_frame + 1, note.end_frame):
            frames[frame_index][note.pitch] = 1
    return tuple(tuple(frame) for frame in frames)


def condition_summary(request: ProbeRequest) -> dict[str, Any]:
    notes = request.notes
    if notes is None:
        return {
            "mode": "absent",
            "noteCount": 0,
            "nonzeroFramePitchValues": 0,
            "normalizedNotes": None,
        }
    return {
        "mode": "explicit",
        "noteCount": len(notes),
        "nonzeroFramePitchValues": sum(
            note.end_frame - note.start_frame for note in notes
        ),
        "normalizedNotes": [note.as_json() for note in notes],
    }
