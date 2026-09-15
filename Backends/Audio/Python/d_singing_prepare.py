"""Strict SING1 phrase/pronunciation validation and DiffSinger input preparation."""

from __future__ import annotations

import copy
import errno
import os
from pathlib import Path
import secrets
import stat
import sys
from typing import Any, Sequence
import uuid

from d_audio_contract import (
    ContractError,
    checked_absolute_path,
    decode_strict_json,
    ensure_no_symlink_components,
    json_bytes,
    paths_overlap,
    read_regular_file,
)


SCHEMA_VERSION = 1
TICKS_PER_SECOND = 1_000_000
MAX_DURATION_TICKS = 600_000_000
MAX_ITEMS = 4_096
MAX_TEXT_BYTES = 4_096
MAX_TOTAL_TEXT_BYTES = 262_144
MAX_INVENTORY_BYTES = 256
MAX_SYMBOLS = 8_192
MAX_SYMBOL_BYTES = 128
MAX_PHONEMES = 8_192
MAX_INPUT_BYTES = 1024 * 1024
MAX_INT64 = 2**63 - 1
SILENCE_TOKEN = "SP"
ADAPTER_PROFILE = "diffsinger-variance-ds-v1"

_PHRASE_KEYS = {
    "schemaVersion", "id", "revision", "ticksPerSecond", "language",
    "durationTicks", "notes", "lyricUnits",
}
_NOTE_KEYS = {"id", "startTick", "endTick", "midiPitch"}
_LYRIC_UNIT_KEYS = {"id", "text", "noteIDs"}
_PRONUNCIATION_KEYS = {
    "schemaVersion", "phraseID", "phraseRevision", "language",
    "inventoryID", "inventoryRevision", "symbols", "silenceToken", "units",
}
_PRONUNCIATION_UNIT_KEYS = {"unitID", "phonemes"}
_OUTPUT_KEYS = {
    "schemaVersion", "status", "adapterProfile", "sourcePhrase",
    "pronunciations", "dsSegments",
}
_NOTE_NAMES = ("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")


def _object(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if type(value) is not dict:
        raise ContractError(f"{label} must be an object")
    missing = keys - value.keys()
    unknown = value.keys() - keys
    if missing:
        raise ContractError(f"{label} is missing keys: {', '.join(sorted(missing))}")
    if unknown:
        raise ContractError(f"{label} has unknown keys: {', '.join(sorted(unknown))}")
    return value


def _array(value: Any, label: str, low: int, high: int) -> list[Any]:
    if type(value) is not list or not low <= len(value) <= high:
        raise ContractError(f"{label} must be an array with {low}...{high} items")
    return value


def _integer(value: Any, label: str, low: int, high: int) -> int:
    if type(value) is not int or not low <= value <= high:
        raise ContractError(f"{label} must be an integer in {low}...{high}")
    return value


def _utf8_size(value: Any, label: str) -> tuple[str, int]:
    if type(value) is not str:
        raise ContractError(f"{label} must be Unicode text")
    try:
        size = len(value.encode("utf-8", errors="strict"))
    except UnicodeEncodeError as exc:
        raise ContractError(f"{label} contains an invalid Unicode surrogate") from exc
    return value, size


def _uuid_identity(value: Any, label: str) -> int:
    text, _ = _utf8_size(value, label)
    try:
        parsed = uuid.UUID(text)
    except (ValueError, AttributeError):
        raise ContractError(f"{label} must be a canonical UUID") from None
    if len(text) != 36 or text.lower() != str(parsed):
        raise ContractError(f"{label} must be a hyphenated canonical UUID")
    return parsed.int


def _identifier(value: Any, label: str) -> str:
    text, size = _utf8_size(value, label)
    if not text or size > MAX_INVENTORY_BYTES or "\x00" in text or any(character.isspace() for character in text):
        raise ContractError(f"{label} must be a nonempty whitespace-free identifier of at most 256 UTF-8 bytes")
    return text


def _symbol(value: Any, label: str) -> str:
    text, size = _utf8_size(value, label)
    if not text or size > MAX_SYMBOL_BYTES or "\x00" in text or any(character.isspace() for character in text):
        raise ContractError(f"{label} must be a nonempty whitespace-free token of at most 128 UTF-8 bytes")
    return text


def _validate_phrase(phrase: Any) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[int], set[int]]:
    value = _object(phrase, _PHRASE_KEYS, "phrase")
    if _integer(value["schemaVersion"], "phrase.schemaVersion", 1, 1) != SCHEMA_VERSION:
        raise ContractError("phrase.schemaVersion must be integer 1")
    phrase_identity = _uuid_identity(value["id"], "phrase.id")
    _integer(value["revision"], "phrase.revision", 1, MAX_INT64)
    _integer(value["ticksPerSecond"], "phrase.ticksPerSecond", TICKS_PER_SECOND, TICKS_PER_SECOND)
    if value["language"] != "zh":
        raise ContractError("phrase.language must be 'zh'")
    duration = _integer(value["durationTicks"], "phrase.durationTicks", 1, MAX_DURATION_TICKS)

    notes_raw = _array(value["notes"], "phrase.notes", 1, MAX_ITEMS)
    notes: list[dict[str, Any]] = []
    note_identities: list[int] = []
    definition_identities = {phrase_identity}
    previous_end = 0
    for index, item in enumerate(notes_raw):
        note = _object(item, _NOTE_KEYS, f"phrase.notes[{index}]")
        identity = _uuid_identity(note["id"], f"phrase.notes[{index}].id")
        if identity in definition_identities:
            raise ContractError(f"phrase.notes[{index}].id duplicates another definition UUID")
        definition_identities.add(identity)
        note_identities.append(identity)
        start = _integer(note["startTick"], f"phrase.notes[{index}].startTick", 0, duration - 1)
        end = _integer(note["endTick"], f"phrase.notes[{index}].endTick", 1, duration)
        if start != previous_end:
            raise ContractError("phrase.notes must be ordered, contiguous, and start at zero")
        if end <= start:
            raise ContractError(f"phrase.notes[{index}] must have positive duration")
        pitch = note["midiPitch"]
        if pitch is not None:
            _integer(pitch, f"phrase.notes[{index}].midiPitch", 0, 127)
        notes.append(note)
        previous_end = end
    if previous_end != duration:
        raise ContractError("phrase.notes must end at phrase.durationTicks")

    units_raw = _array(value["lyricUnits"], "phrase.lyricUnits", 1, MAX_ITEMS)
    units: list[dict[str, Any]] = []
    referenced_notes: list[int] = []
    total_text_bytes = 0
    voiced_units = 0
    for index, item in enumerate(units_raw):
        unit = _object(item, _LYRIC_UNIT_KEYS, f"phrase.lyricUnits[{index}]")
        identity = _uuid_identity(unit["id"], f"phrase.lyricUnits[{index}].id")
        if identity in definition_identities:
            raise ContractError(f"phrase.lyricUnits[{index}].id duplicates another definition UUID")
        definition_identities.add(identity)
        text, text_bytes = _utf8_size(unit["text"], f"phrase.lyricUnits[{index}].text")
        if "\x00" in text or text_bytes > MAX_TEXT_BYTES:
            raise ContractError(f"phrase.lyricUnits[{index}].text is invalid or exceeds 4096 UTF-8 bytes")
        total_text_bytes += text_bytes
        if total_text_bytes > MAX_TOTAL_TEXT_BYTES:
            raise ContractError("phrase lyric text exceeds 262144 UTF-8 bytes")
        references = _array(unit["noteIDs"], f"phrase.lyricUnits[{index}].noteIDs", 1, MAX_ITEMS)
        identities = [
            _uuid_identity(reference, f"phrase.lyricUnits[{index}].noteIDs[{reference_index}]")
            for reference_index, reference in enumerate(references)
        ]
        referenced_notes.extend(identities)
        start = len(referenced_notes) - len(identities)
        if len(referenced_notes) > len(notes) or identities != note_identities[start:len(referenced_notes)]:
            raise ContractError("lyric unit noteIDs must follow the exact note definition order")
        grouped_notes = notes[start:len(referenced_notes)]
        rests = [note["midiPitch"] is None for note in grouped_notes]
        if any(rests) and not all(rests):
            raise ContractError("a lyric unit cannot mix rests and pitched notes")
        if all(rests):
            if len(grouped_notes) != 1 or text != "":
                raise ContractError("a rest lyric unit must contain one rest and empty text")
        else:
            if not text.strip():
                raise ContractError("a voiced lyric unit must have non-whitespace text")
            voiced_units += 1
        units.append(unit)
    if referenced_notes != note_identities:
        raise ContractError("every note must belong to exactly one lyric unit in note order")
    if voiced_units == 0:
        raise ContractError("phrase must contain at least one voiced lyric unit")
    return notes, units, note_identities, definition_identities


def _validate_pronunciations(
    pronunciations: Any,
    phrase: dict[str, Any],
    lyric_units: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    value = _object(pronunciations, _PRONUNCIATION_KEYS, "pronunciations")
    _integer(value["schemaVersion"], "pronunciations.schemaVersion", 1, 1)
    if _uuid_identity(value["phraseID"], "pronunciations.phraseID") != _uuid_identity(phrase["id"], "phrase.id"):
        raise ContractError("pronunciations.phraseID does not match phrase.id")
    revision = _integer(value["phraseRevision"], "pronunciations.phraseRevision", 1, MAX_INT64)
    if revision != phrase["revision"]:
        raise ContractError("pronunciations.phraseRevision does not match phrase.revision")
    if value["language"] != phrase["language"]:
        raise ContractError("pronunciations.language does not match phrase.language")
    _identifier(value["inventoryID"], "pronunciations.inventoryID")
    _identifier(value["inventoryRevision"], "pronunciations.inventoryRevision")

    symbols_raw = _array(value["symbols"], "pronunciations.symbols", 1, MAX_SYMBOLS)
    symbols: set[str] = set()
    for index, item in enumerate(symbols_raw):
        token = _symbol(item, f"pronunciations.symbols[{index}]")
        if token in symbols:
            raise ContractError(f"pronunciations.symbols contains duplicate token {token!r}")
        symbols.add(token)
    if value["silenceToken"] != SILENCE_TOKEN or SILENCE_TOKEN not in symbols:
        raise ContractError("pronunciations.silenceToken must be 'SP' and present in symbols")

    units_raw = _array(value["units"], "pronunciations.units", len(lyric_units), len(lyric_units))
    units: list[dict[str, Any]] = []
    total_phonemes = 0
    for index, item in enumerate(units_raw):
        unit = _object(item, _PRONUNCIATION_UNIT_KEYS, f"pronunciations.units[{index}]")
        if _uuid_identity(unit["unitID"], f"pronunciations.units[{index}].unitID") != _uuid_identity(
            lyric_units[index]["id"], f"phrase.lyricUnits[{index}].id"
        ):
            raise ContractError("pronunciation units must match lyric units in exact order")
        phonemes_raw = _array(unit["phonemes"], f"pronunciations.units[{index}].phonemes", 1, MAX_PHONEMES)
        phonemes: list[str] = []
        for phoneme_index, item in enumerate(phonemes_raw):
            token = _symbol(item, f"pronunciations.units[{index}].phonemes[{phoneme_index}]")
            if token not in symbols:
                raise ContractError(f"unknown phoneme token {token!r}")
            phonemes.append(token)
        total_phonemes += len(phonemes)
        if total_phonemes > MAX_PHONEMES:
            raise ContractError("pronunciations contain more than 8192 phonemes")
        is_rest = lyric_units[index]["text"] == ""
        if is_rest and phonemes != [SILENCE_TOKEN]:
            raise ContractError("a rest unit must use exactly [SP]")
        if not is_rest and SILENCE_TOKEN in phonemes:
            raise ContractError("a voiced unit cannot contain SP")
        units.append(unit)
    return units


def _note_name(pitch: int | None) -> str:
    if pitch is None:
        return "rest"
    return f"{_NOTE_NAMES[pitch % 12]}{pitch // 12 - 1}"


def _duration_text(ticks: int) -> str:
    return f"{ticks // TICKS_PER_SECOND}.{ticks % TICKS_PER_SECOND:06d}"


def prepare_singing_plan(phrase: dict, pronunciations: dict) -> dict:
    """Validate immutable inputs and return a prepared DiffSinger variance mapping."""
    notes, lyric_units, _note_ids, _definition_ids = _validate_phrase(phrase)
    pronunciation_units = _validate_pronunciations(pronunciations, phrase, lyric_units)

    phonemes = [token for unit in pronunciation_units for token in unit["phonemes"]]
    phoneme_counts = [len(unit["phonemes"]) for unit in pronunciation_units]
    slurs: list[int] = []
    for unit in lyric_units:
        slurs.extend([0] + [1] * (len(unit["noteIDs"]) - 1))
    durations = [note["endTick"] - note["startTick"] for note in notes]
    segment = {
        "offset": 0.0,
        "text": " ".join(unit["text"] for unit in lyric_units if unit["text"] != ""),
        "lang": "zh",
        "ph_seq": " ".join(phonemes),
        "ph_num": " ".join(str(count) for count in phoneme_counts),
        "note_seq": " ".join(_note_name(note["midiPitch"]) for note in notes),
        "note_dur": " ".join(_duration_text(duration) for duration in durations),
        "note_slur": " ".join(str(value) for value in slurs),
    }
    if (
        sum(phoneme_counts) != len(phonemes)
        or len(phoneme_counts) != len(lyric_units)
        or len(phoneme_counts) != slurs.count(0)
        or len(notes) != len(durations)
        or len(notes) != len(slurs)
    ):
        raise ContractError("prepared segment consistency check failed")
    result = {
        "schemaVersion": SCHEMA_VERSION,
        "status": "prepared",
        "adapterProfile": ADAPTER_PROFILE,
        "sourcePhrase": copy.deepcopy(phrase),
        "pronunciations": copy.deepcopy(pronunciations),
        "dsSegments": [segment],
    }
    if set(result) != _OUTPUT_KEYS:
        raise ContractError("prepared wrapper consistency check failed")
    return result


def _parse_arguments(argv: Sequence[str]) -> dict[str, str]:
    if len(argv) != 6:
        raise ContractError("expected --phrase, --pronunciations, and --output", "configuration")
    values: dict[str, str] = {}
    allowed = {"--phrase", "--pronunciations", "--output"}
    for index in range(0, len(argv), 2):
        option = argv[index]
        if option not in allowed or option in values:
            raise ContractError("expected each of --phrase, --pronunciations, and --output once", "configuration")
        values[option] = argv[index + 1]
    if set(values) != allowed:
        raise ContractError("expected each of --phrase, --pronunciations, and --output once", "configuration")
    return values


def _validated_cli_paths(arguments: dict[str, str]) -> tuple[Path, Path, Path]:
    phrase_path = checked_absolute_path(arguments["--phrase"], label="phrase path")
    pronunciations_path = checked_absolute_path(arguments["--pronunciations"], label="pronunciations path")
    output_path = checked_absolute_path(arguments["--output"], label="output path")
    ensure_no_symlink_components(phrase_path, label="phrase path")
    ensure_no_symlink_components(pronunciations_path, label="pronunciations path")
    if not output_path.name:
        raise ContractError("output path must name a new file", "configuration")
    ensure_no_symlink_components(output_path, label="output path", allow_missing_leaf=True)
    ensure_no_symlink_components(output_path.parent, label="output parent")
    if not stat.S_ISDIR(os.lstat(output_path.parent).st_mode):
        raise ContractError("output parent must be a directory", "configuration")
    if os.path.lexists(output_path):
        raise ContractError("output target must not already exist", "output")
    if paths_overlap(phrase_path, output_path) or paths_overlap(pronunciations_path, output_path):
        raise ContractError("output path must not overlap either input", "configuration")
    return phrase_path, pronunciations_path, output_path


def _unlink_owned_partial(path: Path, identity: tuple[int, int] | None) -> None:
    if identity is None:
        return
    try:
        info = os.lstat(path)
    except OSError:
        return
    if not stat.S_ISREG(info.st_mode) or (info.st_dev, info.st_ino) != identity:
        return
    try:
        os.unlink(path)
    except OSError:
        pass


def _publish_prepared(parent: Path, filename: str, content: bytes) -> Path:
    """Exclusively publish content, cleaning only a partial inode created here."""
    if not filename or "/" in filename or filename in (".", ".."):
        raise ContractError("invalid output filename", "output")
    target = parent / filename
    if os.path.lexists(target):
        raise ContractError("refusing to overwrite output", "output")
    partial = parent / f".{filename}.{secrets.token_hex(8)}.partial"
    descriptor: int | None = None
    owned_identity: tuple[int, int] | None = None
    try:
        flags = (
            os.O_WRONLY | os.O_CREAT | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        )
        descriptor = os.open(partial, flags, 0o600)
        created = os.fstat(descriptor)
        if not stat.S_ISREG(created.st_mode):
            raise ContractError("created output partial is not a regular file", "output")
        owned_identity = (created.st_dev, created.st_ino)
        view = memoryview(content)
        written = 0
        while written < len(view):
            count = os.write(descriptor, view[written:])
            if count <= 0:
                raise OSError(errno.EIO, "short write")
            written += count
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        reread, reread_identity = read_regular_file(
            partial, max_bytes=len(content), label=f"partial {filename}"
        )
        if reread_identity[:2] != owned_identity or reread != content:
            raise ContractError("prepared output partial changed before publication", "output")
        decode_strict_json(reread, label="prepared output")
        os.link(partial, target, follow_symlinks=False)
        directory_descriptor = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
        os.unlink(partial)
        owned_identity = None
        return target
    except FileExistsError as exc:
        raise ContractError("refusing to overwrite existing output or temporary file", "output") from exc
    except ContractError:
        raise
    except OSError as exc:
        raise ContractError(f"failed to publish prepared output: {exc}", "output") from exc
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
        _unlink_owned_partial(partial, owned_identity)


def _execute_cli(argv: Sequence[str]) -> Path:
    arguments = _parse_arguments(argv)
    phrase_path, pronunciations_path, output_path = _validated_cli_paths(arguments)
    phrase_raw, _ = read_regular_file(phrase_path, max_bytes=MAX_INPUT_BYTES, label="phrase input")
    pronunciations_raw, _ = read_regular_file(
        pronunciations_path, max_bytes=MAX_INPUT_BYTES, label="pronunciations input"
    )
    phrase = decode_strict_json(phrase_raw, label="phrase")
    pronunciations = decode_strict_json(pronunciations_raw, label="pronunciations")
    result = prepare_singing_plan(phrase, pronunciations)
    encoded = json_bytes(result)
    return _publish_prepared(output_path.parent, output_path.name, encoded)


def _write_error(message: str) -> None:
    compact = " ".join(message.splitlines())[:1000]
    try:
        os.write(2, f"singing preparation failed: {compact}\n".encode("utf-8", errors="replace"))
    except OSError:
        pass


def main(argv: Sequence[str] | None = None) -> int:
    try:
        _execute_cli(sys.argv[1:] if argv is None else argv)
    except (ContractError, OSError) as exc:
        _write_error(str(exc))
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
