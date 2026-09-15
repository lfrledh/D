from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PYTHON_DIR = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
FIXTURE_DIR = REPOSITORY_ROOT / "Backends" / "Audio" / "Fixtures" / "Singing"
SCRIPT = PYTHON_DIR / "d_singing_prepare.py"
if str(PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(PYTHON_DIR))

import d_audio_contract
import d_singing_prepare
from d_audio_contract import ContractError


def _load_fixture(name: str):
    with (FIXTURE_DIR / name).open("r", encoding="utf-8") as handle:
        return json.load(handle)


class SingingPreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture_phrase = _load_fixture("phrase-v1.json")
        cls.fixture_pronunciations = _load_fixture("pronunciations-v1.json")
        cls.fixture_segments = _load_fixture("expected-ds.json")
        cls.temp_root = Path(os.environ["D_TEST_TEMP_DIR"])

    def setUp(self) -> None:
        self.phrase = copy.deepcopy(self.fixture_phrase)
        self.pronunciations = copy.deepcopy(self.fixture_pronunciations)

    def assert_rejected(self, phrase=None, pronunciations=None) -> None:
        with self.assertRaises(ContractError):
            d_singing_prepare.prepare_singing_plan(
                self.phrase if phrase is None else phrase,
                self.pronunciations if pronunciations is None else pronunciations,
            )

    def test_golden_segments_and_exact_wrapper(self) -> None:
        before_phrase = copy.deepcopy(self.phrase)
        before_pronunciations = copy.deepcopy(self.pronunciations)
        result = d_singing_prepare.prepare_singing_plan(self.phrase, self.pronunciations)
        self.assertEqual(result["dsSegments"], self.fixture_segments)
        self.assertEqual(
            set(result),
            {"schemaVersion", "status", "adapterProfile", "sourcePhrase", "pronunciations", "dsSegments"},
        )
        self.assertEqual(result["schemaVersion"], 1)
        self.assertEqual(result["status"], "prepared")
        self.assertEqual(result["adapterProfile"], "diffsinger-variance-ds-v1")
        self.assertEqual(result["sourcePhrase"], before_phrase)
        self.assertEqual(result["pronunciations"], before_pronunciations)
        self.assertEqual(self.phrase, before_phrase)
        self.assertEqual(self.pronunciations, before_pronunciations)
        self.assertIsNot(result["sourcePhrase"], self.phrase)
        self.assertIsNot(result["pronunciations"], self.pronunciations)

    def test_uuid_identity_is_case_insensitive_but_spelling_is_preserved(self) -> None:
        upper = self.phrase["notes"][0]["id"].upper()
        self.phrase["notes"][0]["id"] = upper
        result = d_singing_prepare.prepare_singing_plan(self.phrase, self.pronunciations)
        self.assertEqual(result["sourcePhrase"]["notes"][0]["id"], upper)
        duplicate = copy.deepcopy(self.phrase)
        duplicate["lyricUnits"][0]["id"] = duplicate["id"].upper()
        self.assert_rejected(phrase=duplicate)

    def test_unicode_and_pitch_boundaries_are_not_rewritten(self) -> None:
        text = "唱e\u0301🙂"
        self.phrase["lyricUnits"][0]["text"] = text
        self.phrase["notes"][0]["midiPitch"] = 0
        self.phrase["notes"][1]["midiPitch"] = 127
        result = d_singing_prepare.prepare_singing_plan(self.phrase, self.pronunciations)
        segment = result["dsSegments"][0]
        self.assertEqual(segment["text"], f"{text} 呀")
        self.assertEqual(segment["note_seq"], "C-1 G9 rest E4")
        self.assertNotIn("seed", result)

    def test_phrase_contract_rejections(self) -> None:
        mutations = []
        mutations.append(lambda value: value.update(schemaVersion=True))
        mutations.append(lambda value: value.update(revision=1.0))
        mutations.append(lambda value: value.update(extra=True))
        mutations.append(lambda value: value.pop("language"))
        mutations.append(lambda value: value["notes"][1].update(startTick=499999))
        mutations.append(lambda value: value["notes"][-1].update(endTick=1249999))
        mutations.append(lambda value: value["notes"][0].update(midiPitch=128))
        mutations.append(lambda value: value["lyricUnits"][0].update(text=" \t"))
        mutations.append(lambda value: value["lyricUnits"][1].update(text="rest"))
        mutations.append(lambda value: value["lyricUnits"][0]["noteIDs"].reverse())
        mutations.append(lambda value: value["lyricUnits"][0].update(id=value["id"].upper()))
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                candidate = copy.deepcopy(self.phrase)
                mutate(candidate)
                self.assert_rejected(phrase=candidate)

        all_rest = copy.deepcopy(self.phrase)
        for note in all_rest["notes"]:
            note["midiPitch"] = None
        all_rest["lyricUnits"] = []
        for index, note in enumerate(all_rest["notes"]):
            all_rest["lyricUnits"].append({
                "id": f"10000000-0000-4000-8000-{index + 1:012d}",
                "text": "",
                "noteIDs": [note["id"]],
            })
        all_rest_pronunciations = copy.deepcopy(self.pronunciations)
        all_rest_pronunciations["units"] = [
            {"unitID": unit["id"], "phonemes": ["SP"]} for unit in all_rest["lyricUnits"]
        ]
        self.assert_rejected(all_rest, all_rest_pronunciations)

    def test_pronunciation_contract_rejections(self) -> None:
        mutations = []
        mutations.append(lambda value: value.update(schemaVersion=1.0))
        mutations.append(lambda value: value.update(phraseRevision=True))
        mutations.append(lambda value: value.update(language="en"))
        mutations.append(lambda value: value.update(inventoryID="has space"))
        mutations.append(lambda value: value["symbols"].append("a"))
        mutations.append(lambda value: value["units"][0]["phonemes"].append("unknown"))
        mutations.append(lambda value: value["units"][0]["phonemes"].append("SP"))
        mutations.append(lambda value: value["units"][1].update(phonemes=["a"]))
        mutations.append(lambda value: value["units"].reverse())
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                candidate = copy.deepcopy(self.pronunciations)
                mutate(candidate)
                self.assert_rejected(pronunciations=candidate)

    def _write_json(self, path: Path, value) -> None:
        path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")

    def _run_cli(self, arguments: list[str], *, close_stderr: bool = False) -> subprocess.CompletedProcess:
        command = [sys.executable, "-B", str(SCRIPT), *arguments]
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            preexec_fn=(lambda: os.close(2)) if close_stderr else None,
        )
        try:
            stdout, stderr = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = process.communicate(timeout=5)
            self.fail(f"CLI timed out; stdout={stdout!r}, stderr={stderr!r}")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)

    def test_full_process_cli_golden_unicode_directory_and_source_preservation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="歌声 space ", dir=self.temp_root) as raw_directory:
            directory = Path(raw_directory)
            phrase_path = directory / "乐句 input.json"
            pronunciations_path = directory / "发音 input.json"
            output_path = directory / "准备 output.json"
            self._write_json(phrase_path, self.phrase)
            self._write_json(pronunciations_path, self.pronunciations)
            before = {
                phrase_path: hashlib.sha256(phrase_path.read_bytes()).hexdigest(),
                pronunciations_path: hashlib.sha256(pronunciations_path.read_bytes()).hexdigest(),
            }
            result = self._run_cli([
                "--phrase", str(phrase_path),
                "--pronunciations", str(pronunciations_path),
                "--output", str(output_path),
            ])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, b"")
            self.assertEqual(result.stderr, b"")
            prepared = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(prepared["dsSegments"], self.fixture_segments)
            self.assertEqual(set(prepared), {
                "schemaVersion", "status", "adapterProfile", "sourcePhrase", "pronunciations", "dsSegments"
            })
            for path, digest in before.items():
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), digest)

    def test_full_process_cli_rejects_malformed_deep_oversize_and_existing_target(self) -> None:
        with tempfile.TemporaryDirectory(prefix="singing-invalid-", dir=self.temp_root) as raw_directory:
            directory = Path(raw_directory)
            valid_phrase = directory / "phrase.json"
            valid_pronunciations = directory / "pronunciations.json"
            self._write_json(valid_phrase, self.phrase)
            self._write_json(valid_pronunciations, self.pronunciations)
            invalid_payloads = {
                "duplicate.json": b'{"schemaVersion":1,"schemaVersion":1}',
                "nan.json": b'{"schemaVersion":NaN}',
                "deep.json": (b'{"schemaVersion":1,"x":' + b'[' * 34 + b'0' + b']' * 34 + b'}'),
                "oversize.json": b" " * (1024 * 1024 + 1),
            }
            for name, payload in invalid_payloads.items():
                with self.subTest(name=name):
                    invalid = directory / name
                    invalid.write_bytes(payload)
                    output = directory / f"{name}.out"
                    result = self._run_cli([
                        "--phrase", str(invalid),
                        "--pronunciations", str(valid_pronunciations),
                        "--output", str(output),
                    ])
                    self.assertEqual(result.returncode, 2)
                    self.assertEqual(result.stdout, b"")
                    self.assertNotEqual(result.stderr, b"")
                    self.assertFalse(output.exists())

            sentinel = directory / "sentinel.json"
            sentinel.write_bytes(b"preserve")
            result = self._run_cli([
                "--phrase", str(valid_phrase),
                "--pronunciations", str(valid_pronunciations),
                "--output", str(sentinel),
            ])
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, b"")
            self.assertEqual(sentinel.read_bytes(), b"preserve")

    def test_full_process_cli_rejects_symlinks_and_same_output(self) -> None:
        with tempfile.TemporaryDirectory(prefix="singing-links-", dir=self.temp_root) as raw_directory:
            directory = Path(raw_directory)
            phrase_path = directory / "phrase.json"
            pronunciations_path = directory / "pronunciations.json"
            self._write_json(phrase_path, self.phrase)
            self._write_json(pronunciations_path, self.pronunciations)
            linked_phrase = directory / "linked.json"
            linked_phrase.symlink_to(phrase_path)
            for source, output in (
                (linked_phrase, directory / "linked.out"),
                (phrase_path, phrase_path),
            ):
                with self.subTest(source=source, output=output):
                    before = phrase_path.read_bytes()
                    result = self._run_cli([
                        "--phrase", str(source),
                        "--pronunciations", str(pronunciations_path),
                        "--output", str(output),
                    ])
                    self.assertEqual(result.returncode, 2)
                    self.assertEqual(result.stdout, b"")
                    self.assertEqual(phrase_path.read_bytes(), before)
            self.assertFalse((directory / "linked.out").exists())

    def test_invalid_cli_with_closed_stderr_still_exits_two(self) -> None:
        result = self._run_cli(["--invalid"], close_stderr=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"")

    def test_directory_fsync_failure_preserves_published_target(self) -> None:
        with tempfile.TemporaryDirectory(prefix="singing-fsync-", dir=self.temp_root) as raw_directory:
            directory = Path(raw_directory)
            phrase_path = directory / "phrase.json"
            pronunciations_path = directory / "pronunciations.json"
            output_path = directory / "output.json"
            self._write_json(phrase_path, self.phrase)
            self._write_json(pronunciations_path, self.pronunciations)
            real_fsync = os.fsync

            def fail_directory_fsync(descriptor: int) -> None:
                if stat.S_ISDIR(os.fstat(descriptor).st_mode):
                    raise OSError("injected directory fsync failure")
                real_fsync(descriptor)

            arguments = [
                "--phrase", str(phrase_path),
                "--pronunciations", str(pronunciations_path),
                "--output", str(output_path),
            ]
            with mock.patch.object(d_audio_contract.os, "fsync", side_effect=fail_directory_fsync):
                with self.assertRaises(ContractError):
                    d_singing_prepare._execute_cli(arguments)
            self.assertTrue(output_path.is_file())
            self.assertEqual(json.loads(output_path.read_text(encoding="utf-8"))["dsSegments"], self.fixture_segments)
            self.assertEqual(list(directory.glob(".*.partial")), [])


if __name__ == "__main__":
    unittest.main()
