from __future__ import annotations

import copy
from dataclasses import FrozenInstanceError
from fractions import Fraction
import json
from pathlib import Path
import sys
import unittest


PYTHON_DIR = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
FIXTURE = REPOSITORY_ROOT / "Backends" / "Audio" / "Fixtures" / "Singing" / "timing-v1.json"
if str(PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(PYTHON_DIR))

import d_singing_timing
from d_singing_prepare import ContractError


def _profile(
    *,
    phonemes: tuple[str, ...] = ("v",),
    vowel_index: int = 0,
    leading_rest: int = 0,
    voiced_duration: int = 1_000_000,
    pitch: int = 60,
) -> tuple[dict, dict, list[int | None]]:
    phrase_id = "20000000-0000-4000-8000-000000000001"
    rest_note_id = "20000000-0000-4000-8000-000000000010"
    voice_note_id = "20000000-0000-4000-8000-000000000011"
    rest_unit_id = "20000000-0000-4000-8000-000000000020"
    voice_unit_id = "20000000-0000-4000-8000-000000000021"
    notes = []
    lyric_units = []
    pronunciation_units = []
    vowel_indices: list[int | None] = []
    if leading_rest:
        notes.append({"id": rest_note_id, "startTick": 0, "endTick": leading_rest, "midiPitch": None})
        lyric_units.append({"id": rest_unit_id, "text": "", "noteIDs": [rest_note_id]})
        pronunciation_units.append({"unitID": rest_unit_id, "phonemes": ["SP"]})
        vowel_indices.append(None)
    notes.append({
        "id": voice_note_id,
        "startTick": leading_rest,
        "endTick": leading_rest + voiced_duration,
        "midiPitch": pitch,
    })
    lyric_units.append({"id": voice_unit_id, "text": "唱🙂", "noteIDs": [voice_note_id]})
    pronunciation_units.append({"unitID": voice_unit_id, "phonemes": list(phonemes)})
    vowel_indices.append(vowel_index)
    symbols = ["SP"]
    for phoneme in phonemes:
        if phoneme not in symbols:
            symbols.append(phoneme)
    phrase = {
        "schemaVersion": 1,
        "id": phrase_id,
        "revision": 1,
        "ticksPerSecond": 1_000_000,
        "language": "zh",
        "durationTicks": leading_rest + voiced_duration,
        "notes": notes,
        "lyricUnits": lyric_units,
    }
    pronunciations = {
        "schemaVersion": 1,
        "phraseID": phrase_id,
        "phraseRevision": 1,
        "language": "zh",
        "inventoryID": "test-explicit",
        "inventoryRevision": "1",
        "symbols": symbols,
        "silenceToken": "SP",
        "units": pronunciation_units,
    }
    return phrase, pronunciations, vowel_indices


class SingingTimingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        with FIXTURE.open("r", encoding="utf-8") as handle:
            cls.fixture = json.load(handle)

    def test_frozen_fixture_groups_and_alignment(self) -> None:
        fixture = copy.deepcopy(self.fixture)
        before = copy.deepcopy(fixture)
        plan = d_singing_timing.build_duration_groups(
            fixture["phrase"],
            fixture["pronunciations"],
            fixture["vowelIndices"],
            sample_rate=fixture["sampleRate"],
            hop_size=fixture["hopSize"],
            context_ticks=fixture["contextTicks"],
        )
        expected = fixture["expected"]
        self.assertEqual([list(group.symbols) for group in plan.groups], expected["groupSymbols"])
        self.assertEqual([list(group.word_div) for group in plan.groups], expected["wordDiv"])
        self.assertEqual([list(group.word_dur) for group in plan.groups], expected["wordDur"])
        self.assertEqual([list(group.ph_midi) for group in plan.groups], expected["phMidi"])

        result = d_singing_timing.align_duration_predictions(
            plan,
            fixture["predictions"],
            head_frames=fixture["headFrames"],
            tail_frames=fixture["tailFrames"],
        )
        self.assertEqual(list(result.phonemes), expected["phonemes"])
        self.assertEqual(list(result.phoneme_durations), expected["phonemeDurations"])
        self.assertEqual(list(result.note_durations), expected["noteDurations"])
        self.assertEqual(list(result.note_midi), expected["noteMidi"])
        self.assertEqual(result.frame_count, expected["frameCount"])
        self.assertEqual(result.source_duration_ticks, 6_000_000)
        self.assertEqual(result.source_intervals[0].start_tick, 0)
        self.assertEqual(result.source_intervals[-1].end_tick, 6_000_000)
        self.assertEqual(fixture, before)

    def test_plan_and_results_are_immutable_snapshots(self) -> None:
        fixture = copy.deepcopy(self.fixture)
        plan = d_singing_timing.build_duration_groups(
            fixture["phrase"], fixture["pronunciations"], fixture["vowelIndices"],
            sample_rate=fixture["sampleRate"], hop_size=fixture["hopSize"],
            context_ticks=fixture["contextTicks"],
        )
        fixture["phrase"]["id"] = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        fixture["pronunciations"]["units"][1]["phonemes"][0] = "changed"
        fixture["vowelIndices"][1] = 0
        result = d_singing_timing.align_duration_predictions(
            plan, self.fixture["predictions"], head_frames=8, tail_frames=8
        )
        self.assertEqual(result.frame_count, 533)
        self.assertEqual(plan.source_id, "10000000-0000-4000-8000-000000000001")
        with self.assertRaises(FrozenInstanceError):
            plan.source_revision = 2
        with self.assertRaises(FrozenInstanceError):
            result.frame_count = 0

    def test_context_truncates_toward_zero_and_does_not_create_source_rest(self) -> None:
        phrase, pronunciations, vowels = _profile()
        plan = d_singing_timing.build_duration_groups(
            phrase, pronunciations, vowels,
            sample_rate=3, hop_size=2, context_ticks=1_000_000,
        )
        self.assertEqual(plan.groups[0].word_dur, (1, 1))
        self.assertEqual(plan.groups[0].symbols, ("SP", "v"))
        result = d_singing_timing.align_duration_predictions(
            plan, [[1000, 1]], head_frames=0, tail_frames=0
        )
        self.assertEqual(result.phonemes, ("v",))
        self.assertTrue(all(interval.phoneme != "SP" for interval in result.source_intervals))

    def test_leading_consonant_requires_only_real_available_rest(self) -> None:
        phrase, pronunciations, vowels = _profile(phonemes=("c", "v"), vowel_index=1)
        plan = d_singing_timing.build_duration_groups(
            phrase, pronunciations, vowels,
            sample_rate=1_000_000, hop_size=1, context_ticks=1,
        )
        with self.assertRaisesRegex(ContractError, "available source rest"):
            d_singing_timing.align_duration_predictions(
                plan, [[1, 1, 1]], head_frames=0, tail_frames=0
            )

        phrase, pronunciations, vowels = _profile(
            phonemes=("c", "v"), vowel_index=1, leading_rest=10, voiced_duration=10
        )
        plan = d_singing_timing.build_duration_groups(
            phrase, pronunciations, vowels,
            sample_rate=1_000_000, hop_size=1, context_ticks=1,
        )
        exact = d_singing_timing.align_duration_predictions(
            plan, [[1, 10, 1]], head_frames=0, tail_frames=0
        )
        self.assertEqual(exact.source_intervals[0].phoneme, "c")
        self.assertEqual(exact.source_intervals[0].start_tick, 0)
        with self.assertRaisesRegex(ContractError, "available source rest"):
            d_singing_timing.align_duration_predictions(
                plan, [[1, 10.000000000000002, 1]], head_frames=0, tail_frames=0
            )

    def test_float_predictions_keep_their_binary_fraction(self) -> None:
        phrase, pronunciations, vowels = _profile(
            phonemes=("c", "v"), vowel_index=1, leading_rest=10, voiced_duration=10
        )
        plan = d_singing_timing.build_duration_groups(
            phrase, pronunciations, vowels,
            sample_rate=1_000_000, hop_size=1, context_ticks=1,
        )
        result = d_singing_timing.align_duration_predictions(
            plan, [[1, 1.1, 1]], head_frames=0, tail_frames=0
        )
        consonant = next(interval for interval in result.source_intervals if interval.phoneme == "c")
        self.assertEqual(consonant.end_tick - consonant.start_tick, Fraction(1.1))
        self.assertNotEqual(consonant.end_tick - consonant.start_tick, Fraction("1.1"))

    def test_head_tail_are_independent_and_long_48k_profile_is_supported(self) -> None:
        phrase, pronunciations, vowels = _profile(voiced_duration=7_000_000)
        plan = d_singing_timing.build_duration_groups(
            phrase, pronunciations, vowels,
            sample_rate=48_000, hop_size=480, context_ticks=500_000,
        )
        body = d_singing_timing.align_duration_predictions(
            plan, [[1, 1]], head_frames=0, tail_frames=0
        )
        padded = d_singing_timing.align_duration_predictions(
            plan, [[1, 1]], head_frames=3, tail_frames=5
        )
        self.assertEqual(body.frame_count, 700)
        self.assertEqual(padded.frame_count, body.frame_count + 8)
        self.assertEqual(padded.phoneme_durations[1:-1], body.phoneme_durations)
        self.assertEqual(padded.note_durations[1:-1], body.note_durations)
        self.assertEqual(padded.note_midi[0], None)
        self.assertEqual(padded.note_midi[-1], None)

    def test_zero_frame_phoneme_is_rejected_without_repair(self) -> None:
        phrase, pronunciations, vowels = _profile(phonemes=("v", "c"))
        plan = d_singing_timing.build_duration_groups(
            phrase, pronunciations, vowels,
            sample_rate=2, hop_size=1, context_ticks=1_000_000,
        )
        with self.assertRaisesRegex(ContractError, "source phoneme interval quantizes to zero"):
            d_singing_timing.align_duration_predictions(
                plan, [[1, 1, 1]], head_frames=0, tail_frames=0
            )

    def test_zero_frame_note_is_rejected_without_repair(self) -> None:
        phrase, pronunciations, vowels = _profile(voiced_duration=1_000_000, pitch=0)
        first_note = phrase["notes"][0]
        second_id = "20000000-0000-4000-8000-000000000012"
        first_note["endTick"] = 500_000
        phrase["notes"].append({
            "id": second_id, "startTick": 500_000, "endTick": 1_000_000, "midiPitch": 127
        })
        phrase["lyricUnits"][0]["noteIDs"].append(second_id)
        plan = d_singing_timing.build_duration_groups(
            phrase, pronunciations, vowels,
            sample_rate=2, hop_size=1, context_ticks=1_000_000,
        )
        with self.assertRaisesRegex(ContractError, "note interval quantizes to zero"):
            d_singing_timing.align_duration_predictions(
                plan, [[1, 1]], head_frames=0, tail_frames=0
            )

    def test_parameter_anchor_and_prediction_type_rejections(self) -> None:
        phrase, pronunciations, vowels = _profile()
        build_cases = (
            {"sample_rate": True, "hop_size": 1, "context_ticks": 1},
            {"sample_rate": 1.0, "hop_size": 1, "context_ticks": 1},
            {"sample_rate": 1, "hop_size": 0, "context_ticks": 1},
            {"sample_rate": 1, "hop_size": 1, "context_ticks": -1},
        )
        for arguments in build_cases:
            with self.subTest(arguments=arguments), self.assertRaises(ContractError):
                d_singing_timing.build_duration_groups(
                    phrase, pronunciations, vowels, **arguments
                )
        for bad_vowels in ([None], [True], [1], (0,)):
            with self.subTest(vowels=bad_vowels), self.assertRaises(ContractError):
                d_singing_timing.build_duration_groups(
                    phrase, pronunciations, bad_vowels,
                    sample_rate=100, hop_size=1, context_ticks=10_000,
                )

        plan = d_singing_timing.build_duration_groups(
            phrase, pronunciations, vowels,
            sample_rate=100, hop_size=1, context_ticks=10_000,
        )
        invalid_predictions = (
            [],
            [[1]],
            [[1, True]],
            [[1, 0]],
            [[1, -1]],
            [[1, float("nan")]],
            [[1, float("inf")]],
            ((1, 1),),
        )
        for predictions in invalid_predictions:
            with self.subTest(predictions=predictions), self.assertRaises(ContractError):
                d_singing_timing.align_duration_predictions(
                    plan, predictions, head_frames=0, tail_frames=0
                )
        for head, tail in ((True, 0), (0.0, 0), (-1, 0), (0, -1)):
            with self.subTest(head=head, tail=tail), self.assertRaises(ContractError):
                d_singing_timing.align_duration_predictions(
                    plan, [[1, 1]], head_frames=head, tail_frames=tail
                )

    def test_invalid_source_contract_is_still_rejected_by_prepare(self) -> None:
        phrase, pronunciations, vowels = _profile()
        phrase["revision"] = 2
        with self.assertRaises(ContractError):
            d_singing_timing.build_duration_groups(
                phrase, pronunciations, vowels,
                sample_rate=100, hop_size=1, context_ticks=10_000,
            )


if __name__ == "__main__":
    unittest.main()
