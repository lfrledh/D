"""Immutable, model-independent timing assembly for the R1 singing profile."""

from __future__ import annotations

from dataclasses import dataclass
from fractions import Fraction
import math
from typing import Any

from d_singing_prepare import ContractError, prepare_singing_plan


TICKS_PER_SECOND = 1_000_000
MAX_DURATION_TICKS = 600_000_000
MAX_INT32 = 2**31 - 1
MAX_INT64 = 2**63 - 1
SILENCE_TOKEN = "SP"


@dataclass(frozen=True, slots=True)
class DurationGroup:
    """One duration-model request, expressed only as immutable tuples."""

    symbols: tuple[str, ...]
    word_div: tuple[int, ...]
    word_dur: tuple[int, ...]
    ph_midi: tuple[int, ...]


@dataclass(frozen=True, slots=True)
class SourceInterval:
    """An exact interval on the source work axis."""

    phoneme: str
    start_tick: Fraction
    end_tick: Fraction
    unit_id: str | None


@dataclass(frozen=True, slots=True)
class _SourceNote:
    start_tick: int
    end_tick: int
    midi_pitch: int | None


@dataclass(frozen=True, slots=True)
class _UnitTiming:
    unit_id: str
    start_tick: int
    end_tick: int
    first_pitch: int | None
    phonemes: tuple[str, ...]
    vowel_index: int | None
    is_rest: bool


@dataclass(frozen=True, slots=True)
class _GroupTiming:
    available_start_tick: int
    start_tick: int
    end_tick: int
    symbol_unit_ids: tuple[str | None, ...]
    vowel_symbol_indices: tuple[int, ...]
    anchor_ticks: tuple[int, ...]


@dataclass(frozen=True, slots=True)
class DurationPlan:
    """A captured, immutable duration request and its source-axis mapping."""

    groups: tuple[DurationGroup, ...]
    source_id: str
    source_revision: int
    source_duration_ticks: int
    ticks_per_second: int
    sample_rate: int
    hop_size: int
    context_ticks: int
    _group_timings: tuple[_GroupTiming, ...]
    _notes: tuple[_SourceNote, ...]


@dataclass(frozen=True, slots=True)
class DurationAlignment:
    """Quantized durations plus their unquantized source intervals."""

    phonemes: tuple[str, ...]
    phoneme_durations: tuple[int, ...]
    note_durations: tuple[int, ...]
    note_midi: tuple[int | None, ...]
    frame_count: int
    source_duration_ticks: int
    source_intervals: tuple[SourceInterval, ...]


def _integer(value: Any, label: str, low: int, high: int) -> int:
    if type(value) is not int or not low <= value <= high:
        raise ContractError(f"{label} must be an integer in {low}...{high}")
    return value


def _truncating_frame_index(tick: int, sample_rate: int, hop_size: int) -> int:
    return int(Fraction(tick * sample_rate, TICKS_PER_SECOND * hop_size))


def _checked_frame_count(value: int, label: str) -> int:
    if not 0 <= value <= MAX_INT64:
        raise ContractError(f"{label} exceeds the Int64 frame-count range")
    return value


def _validated_vowel_indices(
    value: Any,
    units: list[dict[str, Any]],
    pronunciation_units: list[dict[str, Any]],
) -> tuple[int | None, ...]:
    if type(value) is not list or len(value) != len(units):
        raise ContractError("vowel_indices must be a list matching lyricUnits")
    result: list[int | None] = []
    for index, (candidate, unit, pronunciation) in enumerate(zip(value, units, pronunciation_units)):
        is_rest = unit["text"] == ""
        if is_rest:
            if candidate is not None:
                raise ContractError(f"vowel_indices[{index}] must be None for a rest unit")
            result.append(None)
            continue
        if type(candidate) is not int or not 0 <= candidate < len(pronunciation["phonemes"]):
            raise ContractError(
                f"vowel_indices[{index}] must be a non-bool integer indexing that unit's phonemes"
            )
        result.append(candidate)
    return tuple(result)


def _capture_units(
    phrase: dict[str, Any],
    pronunciations: dict[str, Any],
    vowel_indices: tuple[int | None, ...],
) -> tuple[tuple[_UnitTiming, ...], tuple[_SourceNote, ...]]:
    notes = phrase["notes"]
    units: list[_UnitTiming] = []
    note_cursor = 0
    for source_unit, pronunciation, vowel_index in zip(
        phrase["lyricUnits"], pronunciations["units"], vowel_indices
    ):
        unit_note_count = len(source_unit["noteIDs"])
        unit_notes = notes[note_cursor:note_cursor + unit_note_count]
        note_cursor += unit_note_count
        units.append(
            _UnitTiming(
                unit_id=source_unit["id"],
                start_tick=unit_notes[0]["startTick"],
                end_tick=unit_notes[-1]["endTick"],
                first_pitch=unit_notes[0]["midiPitch"],
                phonemes=tuple(pronunciation["phonemes"]),
                vowel_index=vowel_index,
                is_rest=source_unit["text"] == "",
            )
        )
    captured_notes = tuple(
        _SourceNote(note["startTick"], note["endTick"], note["midiPitch"])
        for note in notes
    )
    return tuple(units), captured_notes


def _make_group(
    units: tuple[_UnitTiming, ...],
    available_start_tick: int,
    sample_rate: int,
    hop_size: int,
    context_ticks: int,
) -> tuple[DurationGroup, _GroupTiming]:
    symbols: list[str] = [SILENCE_TOKEN]
    symbol_unit_ids: list[str | None] = [None]
    vowel_positions: list[int] = []
    anchors: list[int] = []
    pitches: list[int] = []
    for unit in units:
        if unit.is_rest or unit.vowel_index is None or unit.first_pitch is None:
            raise ContractError("duration group contains an invalid voiced unit")
        vowel_positions.append(len(symbols) + unit.vowel_index)
        anchors.append(unit.start_tick)
        pitches.append(unit.first_pitch)
        symbols.extend(unit.phonemes)
        symbol_unit_ids.extend([unit.unit_id] * len(unit.phonemes))

    divisions = tuple(
        right - left
        for left, right in zip((0, *vowel_positions), (*vowel_positions, len(symbols)))
    )
    endpoints = (units[0].start_tick - context_ticks, *anchors, units[-1].end_tick)
    frame_endpoints = tuple(
        _truncating_frame_index(tick, sample_rate, hop_size) for tick in endpoints
    )
    word_durations = tuple(
        right - left for left, right in zip(frame_endpoints, frame_endpoints[1:])
    )
    if any(value <= 0 for value in divisions):
        raise ContractError("duration group word_div entries must be positive")
    if any(value <= 0 for value in word_durations):
        raise ContractError("duration group word_dur entries must be positive")
    for value in word_durations:
        _checked_frame_count(value, "duration group word_dur")

    segment_pitches = (pitches[0], *pitches)
    ph_midi = tuple(
        pitch
        for division, pitch in zip(divisions, segment_pitches)
        for _ in range(division)
    )
    group = DurationGroup(tuple(symbols), divisions, word_durations, ph_midi)
    if not (len(group.symbols) == len(group.ph_midi) == sum(group.word_div)):
        raise ContractError("duration group consistency check failed")
    timing = _GroupTiming(
        available_start_tick=available_start_tick,
        start_tick=units[0].start_tick,
        end_tick=units[-1].end_tick,
        symbol_unit_ids=tuple(symbol_unit_ids),
        vowel_symbol_indices=tuple(vowel_positions),
        anchor_ticks=(*anchors, units[-1].end_tick),
    )
    return group, timing


def build_duration_groups(
    phrase: dict,
    pronunciations: dict,
    vowel_indices: list,
    *,
    sample_rate: int,
    hop_size: int,
    context_ticks: int,
) -> DurationPlan:
    """Validate and capture one immutable set of duration-model requests."""
    sample_rate = _integer(sample_rate, "sample_rate", 1, MAX_INT32)
    hop_size = _integer(hop_size, "hop_size", 1, MAX_INT32)
    context_ticks = _integer(context_ticks, "context_ticks", 1, MAX_DURATION_TICKS)

    prepared = prepare_singing_plan(phrase, pronunciations)
    source_phrase = prepared["sourcePhrase"]
    source_pronunciations = prepared["pronunciations"]
    captured_vowels = _validated_vowel_indices(
        vowel_indices, source_phrase["lyricUnits"], source_pronunciations["units"]
    )
    units, notes = _capture_units(source_phrase, source_pronunciations, captured_vowels)

    groups: list[DurationGroup] = []
    timings: list[_GroupTiming] = []
    previous_group_end = 0
    cursor = 0
    while cursor < len(units):
        if units[cursor].is_rest:
            cursor += 1
            continue
        group_start = cursor
        while cursor < len(units) and not units[cursor].is_rest:
            cursor += 1
        group, timing = _make_group(
            units[group_start:cursor],
            previous_group_end,
            sample_rate,
            hop_size,
            context_ticks,
        )
        groups.append(group)
        timings.append(timing)
        previous_group_end = timing.end_tick

    return DurationPlan(
        groups=tuple(groups),
        source_id=source_phrase["id"],
        source_revision=source_phrase["revision"],
        source_duration_ticks=source_phrase["durationTicks"],
        ticks_per_second=source_phrase["ticksPerSecond"],
        sample_rate=sample_rate,
        hop_size=hop_size,
        context_ticks=context_ticks,
        _group_timings=tuple(timings),
        _notes=notes,
    )


def _prediction_fraction(value: Any, label: str) -> Fraction:
    if type(value) is int:
        if value <= 0:
            raise ContractError(f"{label} must be strictly positive")
        return Fraction(value)
    if type(value) is float:
        if not math.isfinite(value) or value <= 0:
            raise ContractError(f"{label} must be finite and strictly positive")
        return Fraction(value)
    raise ContractError(f"{label} must be a Python int or float, excluding bool")


def _validated_predictions(
    plan: DurationPlan, predictions: Any
) -> tuple[tuple[Fraction, ...], ...]:
    if type(predictions) is not list or len(predictions) != len(plan.groups):
        raise ContractError("predictions must be a list matching duration groups")
    result: list[tuple[Fraction, ...]] = []
    for group_index, (group, raw_group) in enumerate(zip(plan.groups, predictions)):
        if type(raw_group) is not list or len(raw_group) != len(group.symbols):
            raise ContractError(
                f"predictions[{group_index}] must be a list matching group symbols"
            )
        result.append(
            tuple(
                _prediction_fraction(value, f"predictions[{group_index}][{index}]")
                for index, value in enumerate(raw_group)
            )
        )
    return tuple(result)


def _source_frame_boundary(tick: Fraction, sample_rate: int, hop_size: int) -> int:
    scaled = tick * sample_rate / (TICKS_PER_SECOND * hop_size) + Fraction(1, 2)
    return _checked_frame_count(round(scaled), "source frame boundary")


def _append_interval(
    intervals: list[SourceInterval],
    phoneme: str,
    start_tick: Fraction,
    end_tick: Fraction,
    unit_id: str | None,
) -> None:
    if end_tick <= start_tick:
        raise ContractError("a generated source interval is not strictly positive")
    if intervals and intervals[-1].end_tick != start_tick:
        raise ContractError("generated source intervals are not contiguous")
    intervals.append(SourceInterval(phoneme, start_tick, end_tick, unit_id))


def _build_source_intervals(
    plan: DurationPlan, predictions: tuple[tuple[Fraction, ...], ...]
) -> tuple[SourceInterval, ...]:
    intervals: list[SourceInterval] = []
    cursor = Fraction(0)
    ticks_per_prediction_frame = Fraction(
        TICKS_PER_SECOND * plan.hop_size, plan.sample_rate
    )

    for group, timing, group_predictions in zip(
        plan.groups, plan._group_timings, predictions
    ):
        if cursor != timing.available_start_tick:
            raise ContractError("duration plan source-window consistency check failed")
        first_vowel = timing.vowel_symbol_indices[0]
        consonant_durations = tuple(
            prediction * ticks_per_prediction_frame
            for prediction in group_predictions[1:first_vowel]
        )
        consonant_start = Fraction(timing.start_tick) - sum(
            consonant_durations, start=Fraction(0)
        )
        if consonant_start < timing.available_start_tick:
            raise ContractError("predicted leading consonants exceed the available source rest")
        if consonant_start > cursor:
            _append_interval(intervals, SILENCE_TOKEN, cursor, consonant_start, None)
        cursor = consonant_start
        for symbol_index, duration in zip(range(1, first_vowel), consonant_durations):
            boundary = cursor + duration
            _append_interval(
                intervals,
                group.symbols[symbol_index],
                cursor,
                boundary,
                timing.symbol_unit_ids[symbol_index],
            )
            cursor = boundary
        if cursor != timing.start_tick:
            raise ContractError("leading-consonant alignment consistency check failed")

        for anchor_index, symbol_start in enumerate(timing.vowel_symbol_indices):
            symbol_end = (
                timing.vowel_symbol_indices[anchor_index + 1]
                if anchor_index + 1 < len(timing.vowel_symbol_indices)
                else len(group.symbols)
            )
            source_start = Fraction(timing.anchor_ticks[anchor_index])
            source_end = Fraction(timing.anchor_ticks[anchor_index + 1])
            weights = group_predictions[symbol_start:symbol_end]
            total_weight = sum(weights, start=Fraction(0))
            cumulative = Fraction(0)
            cursor = source_start
            for offset, weight in enumerate(weights):
                cumulative += weight
                boundary = (
                    source_end
                    if offset + 1 == len(weights)
                    else source_start + (source_end - source_start) * cumulative / total_weight
                )
                symbol_index = symbol_start + offset
                _append_interval(
                    intervals,
                    group.symbols[symbol_index],
                    cursor,
                    boundary,
                    timing.symbol_unit_ids[symbol_index],
                )
                cursor = boundary
        if cursor != timing.end_tick:
            raise ContractError("duration group alignment consistency check failed")

    if cursor < plan.source_duration_ticks:
        _append_interval(
            intervals,
            SILENCE_TOKEN,
            cursor,
            Fraction(plan.source_duration_ticks),
            None,
        )
    if not intervals or intervals[0].start_tick != 0 or intervals[-1].end_tick != plan.source_duration_ticks:
        raise ContractError("source intervals do not cover the complete work axis")
    return tuple(intervals)


def align_duration_predictions(
    plan: DurationPlan,
    predictions: list,
    *,
    head_frames: int,
    tail_frames: int,
) -> DurationAlignment:
    """Align duration predictions and quantize cumulative source boundaries."""
    if type(plan) is not DurationPlan:
        raise ContractError("plan must be a DurationPlan returned by build_duration_groups")
    head_frames = _integer(head_frames, "head_frames", 0, MAX_INT64)
    tail_frames = _integer(tail_frames, "tail_frames", 0, MAX_INT64)
    captured_predictions = _validated_predictions(plan, predictions)
    source_intervals = _build_source_intervals(plan, captured_predictions)

    phonemes: list[str] = []
    phoneme_durations: list[int] = []
    if head_frames:
        phonemes.append(SILENCE_TOKEN)
        phoneme_durations.append(head_frames)
    for interval in source_intervals:
        start_frame = _source_frame_boundary(interval.start_tick, plan.sample_rate, plan.hop_size)
        end_frame = _source_frame_boundary(interval.end_tick, plan.sample_rate, plan.hop_size)
        duration = end_frame - start_frame
        if duration <= 0:
            raise ContractError("a positive source phoneme interval quantizes to zero frames")
        phonemes.append(interval.phoneme)
        phoneme_durations.append(duration)
    if tail_frames:
        phonemes.append(SILENCE_TOKEN)
        phoneme_durations.append(tail_frames)

    note_midi: list[int | None] = []
    note_durations: list[int] = []
    if head_frames:
        note_midi.append(None)
        note_durations.append(head_frames)
    for note in plan._notes:
        start_frame = _source_frame_boundary(Fraction(note.start_tick), plan.sample_rate, plan.hop_size)
        end_frame = _source_frame_boundary(Fraction(note.end_tick), plan.sample_rate, plan.hop_size)
        duration = end_frame - start_frame
        if duration <= 0:
            raise ContractError("a positive source note interval quantizes to zero frames")
        note_midi.append(note.midi_pitch)
        note_durations.append(duration)
    if tail_frames:
        note_midi.append(None)
        note_durations.append(tail_frames)

    body_frames = _source_frame_boundary(
        Fraction(plan.source_duration_ticks), plan.sample_rate, plan.hop_size
    )
    frame_count = _checked_frame_count(
        head_frames + body_frames + tail_frames, "total frame count"
    )
    if sum(phoneme_durations) != frame_count or sum(note_durations) != frame_count:
        raise ContractError("quantized duration totals do not match the complete frame count")
    return DurationAlignment(
        phonemes=tuple(phonemes),
        phoneme_durations=tuple(phoneme_durations),
        note_durations=tuple(note_durations),
        note_midi=tuple(note_midi),
        frame_count=frame_count,
        source_duration_ticks=plan.source_duration_ticks,
        source_intervals=source_intervals,
    )
