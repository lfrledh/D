from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock

import numpy as np


PYTHON_DIR = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
FIXTURE_DIR = REPOSITORY_ROOT / "Backends" / "Audio" / "Fixtures" / "Singing"
PROFILE = FIXTURE_DIR / "qixuan-bigvgan-profile-v1.json"
VENDOR = REPOSITORY_ROOT / "Backends" / "Audio" / "SingingVendor"
if str(PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(PYTHON_DIR))

import d_singing_render as singing_render
from d_singing_qixuan import VocoderOutput
from d_singing_timing import align_duration_predictions


with (FIXTURE_DIR / "timing-v1.json").open("r", encoding="utf-8") as handle:
    TIMING_FIXTURE = json.load(handle)
with PROFILE.open("r", encoding="utf-8") as handle:
    FIXED_PROFILE = json.load(handle)


def fixture_materials(request_seal, profile_seal, profile, bank, vocoder, vendor):
    """Unmistakable test seam: no fake digest is accepted by production parsing."""
    return singing_render.MaterialBundle(profile, (request_seal, profile_seal))


class FakeEngine:
    """Small deterministic orchestration fixture; it makes no model-quality claim."""

    def __init__(self, bank, vocoder, vendor):
        self.paths = (bank, vocoder, vendor)

    def duration(self, plan, checkpoint):
        checkpoint()
        return align_duration_predictions(
            plan, copy.deepcopy(TIMING_FIXTURE["predictions"]),
            head_frames=8, tail_frames=8,
        )

    def pitch(self, alignment, checkpoint):
        checkpoint()
        return np.full((1, alignment.frame_count), 60.0, dtype=np.float32)

    def variance(self, alignment, pitch, checkpoint):
        checkpoint()
        zeros = np.zeros((1, alignment.frame_count), dtype=np.float32)
        return zeros.copy(), zeros.copy()

    def acoustic(self, alignment, pitch, variance, checkpoint):
        checkpoint()
        return SimpleNamespace(
            alignment=alignment,
            mel=np.zeros((1, alignment.frame_count, 128), dtype=np.float32),
        )

    def vocoder(self, conditions, checkpoint):
        checkpoint()
        count = conditions.alignment.frame_count * 512
        phase = np.arange(count, dtype=np.float32)
        samples = (0.2 * np.sin(phase * np.float32(0.01))).astype(np.float32)
        return VocoderOutput(samples, count, 0.0125)


class SlowCancelEngine(FakeEngine):
    def duration(self, plan, checkpoint):
        for _ in range(1_000):
            checkpoint()
            time.sleep(0.005)
        return super().duration(plan, checkpoint)


class SingingRenderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp_root = Path(os.environ["D_TEST_TEMP_DIR"])

    def setUp(self) -> None:
        self.raw_temp = tempfile.TemporaryDirectory(prefix="render-test-", dir=self.temp_root)
        self.directory = Path(self.raw_temp.name)
        self.bank = self.directory / "bank"
        self.vocoder = self.directory / "vocoder"
        self.bank.mkdir()
        self.vocoder.mkdir()
        self.request_path = self.directory / "组合 e\u0301 请求.json"
        self.output = self.directory / "歌声 output"
        self.request = self._request()
        self._write_request()

    def tearDown(self) -> None:
        self.raw_temp.cleanup()

    def _request(self) -> dict:
        return {
            "schemaVersion": 1,
            "runID": "20000000-0000-4000-8000-000000000001",
            "profileID": FIXED_PROFILE["profileID"],
            "phrase": copy.deepcopy(TIMING_FIXTURE["phrase"]),
            "pronunciations": copy.deepcopy(TIMING_FIXTURE["pronunciations"]),
            "vowelIndices": copy.deepcopy(TIMING_FIXTURE["vowelIndices"]),
            "qualification": {
                "confirmedApplicable": True,
                "purpose": "internalDevelopment",
                "bankArchiveSHA256": FIXED_PROFILE["bankArchiveSHA256"],
                "bankTermsSHA256": FIXED_PROFILE["bankTermsSHA256"],
                "vocoderRevision": FIXED_PROFILE["vocoderRevision"],
                "vocoderLicenseSHA256": FIXED_PROFILE["vocoderLicenseSHA256"],
            },
        }

    def _write_request(self) -> None:
        self.request_path.write_text(
            json.dumps(self.request, ensure_ascii=False, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )

    def _render(self, *, output: Path | None = None, checkpoint=lambda: None):
        events = []
        with mock.patch.object(singing_render, "_validate_materials", fixture_materials), mock.patch.object(
            singing_render, "_ENGINE_CLASS", FakeEngine
        ):
            result = singing_render.render(
                str(self.request_path), str(self.bank), str(self.vocoder), str(VENDOR),
                str(PROFILE), str(self.output if output is None else output),
                progress=events.append, checkpoint=checkpoint,
            )
        return result, events

    def test_fake_golden_unicode_path_exact_result_and_source_preservation(self) -> None:
        before = hashlib.sha256(self.request_path.read_bytes()).hexdigest()
        result, events = self._render()
        self.assertEqual([item["stage"] for item in events], list(singing_render.STAGE_NAMES))
        self.assertEqual(set(path.name for path in self.output.iterdir()), {"output.wav", "result.json"})
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o700)
        self.assertEqual(hashlib.sha256(self.request_path.read_bytes()).hexdigest(), before)
        self.assertEqual(result, json.loads((self.output / "result.json").read_text(encoding="utf-8")))
        self.assertEqual(set(result), {"schemaVersion", "runID", "profileID", "status", "source", "model", "audio", "execution"})
        self.assertEqual(result["audio"]["frameCount"], 264_600)
        self.assertEqual(result["audio"]["channels"], 1)
        self.assertEqual(result["execution"]["nativeFrameCount"], 533 * 512)
        self.assertEqual(result["execution"]["trimHeadSamples"], 8 * 512)
        self.assertEqual(result["execution"]["seedControl"], "unsupported")
        self.assertEqual([stage["name"] for stage in result["execution"]["stages"]], list(singing_render.STAGE_NAMES))
        raw_wav = (self.output / "output.wav").read_bytes()
        self.assertEqual(
            singing_render.validate_mono_float32_wave(raw_wav, 264_600),
            result["audio"]["sha256"],
        )

    def test_input_directories_may_overlap_each_other_but_output_may_not(self) -> None:
        events = []
        with mock.patch.object(singing_render, "_validate_materials", fixture_materials), mock.patch.object(
            singing_render, "_ENGINE_CLASS", FakeEngine
        ):
            result = singing_render.render(
                str(self.request_path), str(self.bank), str(self.bank), str(VENDOR), str(PROFILE),
                str(self.output), progress=events.append, checkpoint=lambda: None,
            )
        self.assertEqual(result["status"], "rendered")

        second_request = self.directory / "request-2.json"
        second_request.write_bytes(self.request_path.read_bytes())
        forbidden_output = self.bank / "nested-output"
        with self.assertRaisesRegex(singing_render.RenderInputError, "disjoint"):
            singing_render.render(
                str(second_request), str(self.bank), str(self.vocoder), str(VENDOR), str(PROFILE),
                str(forbidden_output), progress=lambda _event: None, checkpoint=lambda: None,
            )

    def test_existing_output_symlink_and_missing_material_are_rejected_without_overwrite(self) -> None:
        self.output.mkdir()
        sentinel = self.output / "sentinel"
        sentinel.write_text("keep", encoding="utf-8")
        with self.assertRaises(singing_render.RenderInputError):
            self._render()
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")

        link = self.directory / "link-output"
        link.symlink_to(self.bank, target_is_directory=True)
        with self.assertRaises(singing_render.RenderInputError):
            self._render(output=link)

        absent = self.directory / "missing-material-output"
        with self.assertRaises(singing_render.RenderInputError):
            singing_render.render(
                str(self.request_path), str(self.bank), str(self.vocoder), str(VENDOR), str(PROFILE),
                str(absent), progress=lambda _event: None, checkpoint=lambda: None,
            )
        self.assertFalse(absent.exists())

    def test_request_versions_unknown_fields_uuid_qualification_and_material_identity(self) -> None:
        cases = []
        for version in (True, 1.0, 2):
            value = self._request()
            value["schemaVersion"] = version
            cases.append(value)
        value = self._request(); value["unknown"] = 1; cases.append(value)
        value = self._request(); value["runID"] = "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF"; cases.append(value)
        value = self._request(); value["qualification"]["confirmedApplicable"] = False; cases.append(value)
        value = self._request(); value["qualification"]["purpose"] = "distribution"; cases.append(value)
        value = self._request(); value["profileID"] = "expired"; cases.append(value)
        for candidate in cases:
            with self.subTest(candidate=candidate):
                with self.assertRaises(singing_render.RenderInputError):
                    singing_render._load_request(
                        (json.dumps(candidate, ensure_ascii=False) + "\n").encode("utf-8")
                    )

        mismatched = self._request()
        mismatched["qualification"]["bankArchiveSHA256"] = "0" * 64
        parsed = singing_render._load_request(
            (json.dumps(mismatched, ensure_ascii=False) + "\n").encode("utf-8")
        )
        with self.assertRaises(singing_render.RenderInputError):
            singing_render._validate_qualification(parsed, FIXED_PROFILE)

        material = self.directory / "sealed.bin"
        material.write_bytes(b"original")
        _, seal = singing_render._read_and_seal(material, label="fixture", retain=False)
        material.write_bytes(b"changed!")
        with self.assertRaises(singing_render.RenderRuntimeError):
            singing_render._verify_seal(seal)

    def test_prepare_rejects_unknown_empty_phoneme_bad_vowel_and_stale_revision(self) -> None:
        mutations = []
        value = self._request(); value["pronunciations"]["symbols"].append("unknown"); value["pronunciations"]["units"][1]["phonemes"] = ["unknown"]; mutations.append(value)
        value = self._request(); value["pronunciations"]["units"][1]["phonemes"] = []; mutations.append(value)
        value = self._request(); value["vowelIndices"][1] = 99; mutations.append(value)
        value = self._request(); value["pronunciations"]["phraseRevision"] = 0; mutations.append(value)
        for candidate in mutations:
            candidate_path = self.directory / f"invalid-{len(list(self.directory.glob('invalid-*')))}.json"
            candidate_path.write_text(json.dumps(candidate, ensure_ascii=False), encoding="utf-8")
            with self.subTest(candidate=candidate):
                with self.assertRaises(singing_render.RenderInputError):
                    singing_render.render(
                        str(candidate_path), str(self.bank), str(self.vocoder), str(VENDOR), str(PROFILE),
                        str(self.directory / f"out-{candidate_path.stem}"),
                        progress=lambda _event: None, checkpoint=lambda: None,
                    )

    def test_fixed_model_inventories_reject_unknown_phoneme_before_engine(self) -> None:
        bank = self.directory / "inventory-bank"
        bank.mkdir()
        entries = []
        models = (
            ("", "0101_qixuan_muon1_acoustic"),
            ("dsdur", "0102_qixuan_newdict_dur"),
            ("dspitch", "0102_qixuan_muon1_pitch"),
            ("dsvariance", "0102_qixuan_muon1_multivar"),
        )
        tokens = {name: index for index, name in enumerate(self.request["pronunciations"]["symbols"])}
        for folder, stem in models:
            root = bank / folder if folder else bank
            root.mkdir(exist_ok=True)
            for kind, value in (("phonemes", tokens), ("languages", {"zh": 1})):
                path = root / f"{stem}.{kind}.json"
                raw = ("\ufeff" + json.dumps(value, separators=(",", ":"))).encode("utf-8")
                path.write_bytes(raw)
                entries.append({
                    "path": str(path.relative_to(bank)), "byteCount": len(raw),
                    "sha256": hashlib.sha256(raw).hexdigest(),
                })
        profile = {"bankFiles": entries}
        singing_render._validate_fixed_inventories(self.request, profile, bank)
        unknown = copy.deepcopy(self.request)
        unknown["pronunciations"]["symbols"].append("zh/not-in-bank")
        unknown["pronunciations"]["units"][1]["phonemes"] = ["zh/not-in-bank"]
        with self.assertRaisesRegex(singing_render.RenderInputError, "does not contain"):
            singing_render._validate_fixed_inventories(unknown, profile, bank)

    def test_cancel_each_stage_preserves_no_result_and_can_rerun(self) -> None:
        for target in singing_render.STAGE_NAMES[:-1]:
            output = self.directory / f"cancel-{target}"
            seen = []

            def progress(event):
                seen.append(event["stage"])

            def checkpoint():
                if seen and seen[-1] == target:
                    raise singing_render.RenderCancelled(target)

            with self.subTest(stage=target), mock.patch.object(
                singing_render, "_validate_materials", fixture_materials
            ), mock.patch.object(singing_render, "_ENGINE_CLASS", FakeEngine):
                with self.assertRaises(singing_render.RenderCancelled):
                    singing_render.render(
                        str(self.request_path), str(self.bank), str(self.vocoder), str(VENDOR),
                        str(PROFILE), str(output), progress=progress, checkpoint=checkpoint,
                    )
                self.assertFalse((output / "result.json").exists())
        rerun, _ = self._render(output=self.directory / "rerun")
        self.assertEqual(rerun["status"], "rendered")

    def test_rounding_trimming_saturation_and_invalid_audio(self) -> None:
        self.assertEqual(singing_render._round_half_up_samples(5_000), 221)
        samples = np.zeros(8 * 512 + 221 + 1, dtype=np.float32)
        samples[8 * 512:8 * 512 + 221] = 0.25
        samples[8 * 512 + 4] = 1.0
        delivered, count, saturated = singing_render._prepare_delivery(
            VocoderOutput(samples, len(samples), 0.0), 5_000
        )
        self.assertEqual((len(delivered), count, saturated), (221, 221, 1))
        with self.assertRaises(singing_render.RenderRuntimeError):
            singing_render.encode_mono_float32_wave(np.zeros(4, dtype=np.float32), 4)
        bad = np.ones(4, dtype=np.float32); bad[0] = np.nan
        with self.assertRaises(singing_render.RenderRuntimeError):
            singing_render.encode_mono_float32_wave(bad, 4)

    def test_close_boundary_replacements_and_static_bad_digest_keep_real_seals(self) -> None:
        output = self.directory / "readback-output"
        output.mkdir(mode=0o700)
        output_identity = (output.stat().st_dev, output.stat().st_ino)
        target = output / "result.json"
        target.write_bytes(b'{"original":true}\n')
        original_identity = (target.stat().st_dev, target.stat().st_ino)
        original_close = singing_render.os.close
        injected = False

        def replace_final_on_close(descriptor):
            nonlocal injected
            current = os.fstat(descriptor)
            if not injected and (current.st_dev, current.st_ino) == original_identity:
                injected = True
                replacement = output / "replacement.json"
                replacement.write_bytes(b'{"tampered":true}\n')
                os.replace(replacement, target)
            return original_close(descriptor)

        with mock.patch.object(singing_render.os, "close", side_effect=replace_final_on_close):
            with self.assertRaisesRegex(singing_render.RenderRuntimeError, "named path changed"):
                singing_render._readback_owned_target(
                    output, output_identity, "result.json", maximum_bytes=256
                )
        self.assertTrue(injected)
        self.assertEqual(target.read_bytes(), b'{"tampered":true}\n')

        source = self.directory / "sealed-source.bin"
        source.write_bytes(b"original source")
        source_identity = (source.stat().st_dev, source.stat().st_ino)
        injected = False

        def replace_source_on_close(descriptor):
            nonlocal injected
            current = os.fstat(descriptor)
            if not injected and (current.st_dev, current.st_ino) == source_identity:
                injected = True
                replacement = self.directory / "source-replacement.bin"
                replacement.write_bytes(b"changed source!")
                os.replace(replacement, source)
            return original_close(descriptor)

        with mock.patch.object(singing_render.os, "close", side_effect=replace_source_on_close):
            with self.assertRaisesRegex(singing_render.RenderRuntimeError, "named path changed"):
                singing_render._read_and_seal(source, label="source fixture", retain=False)
        self.assertTrue(injected)

        protected = self.directory / "protected-source.bin"
        protected.write_bytes(b"protected")
        _, seal = singing_render._read_and_seal(protected, label="protected fixture", retain=False)
        protected_identity = (protected.stat().st_dev, protected.stat().st_ino)
        injected = False

        def replace_protected_on_close(descriptor):
            nonlocal injected
            current = os.fstat(descriptor)
            if not injected and (current.st_dev, current.st_ino) == protected_identity:
                injected = True
                replacement = self.directory / "protected-replacement.bin"
                replacement.write_bytes(b"protected")
                os.replace(replacement, protected)
            return original_close(descriptor)

        with mock.patch.object(singing_render.os, "close", side_effect=replace_protected_on_close):
            with self.assertRaisesRegex(singing_render.RenderRuntimeError, "named path changed"):
                singing_render._verify_seal(seal)
        self.assertTrue(injected)

        wrong = self.directory / "static-wrong-sha.bin"
        wrong.write_bytes(b"fully stable but unexpected")
        ledger = []
        token = singing_render._ACTIVE_SEALS.set(ledger)
        try:
            with self.assertRaises(singing_render.RenderInputError) as caught:
                singing_render._read_and_seal(
                    wrong, label="static wrong digest", expected_sha256="0" * 64, retain=False
                )
        finally:
            singing_render._ACTIVE_SEALS.reset(token)
        self.assertEqual(len(ledger), 1)
        self.assertEqual(ledger[0].sha256, hashlib.sha256(wrong.read_bytes()).hexdigest())
        wrong.write_bytes(b"changed after the input failure")
        with self.assertRaises(singing_render.RenderRuntimeError) as protected_error:
            singing_render._protect_primary(ledger, caught.exception)
        self.assertTrue(any("SHA-256 mismatch" in note for note in protected_error.exception.__notes__))

    def _runner(
        self, *, slow: bool = False, fail_result: bool = False,
        fail_final_stdout: bool = False, case: str = "normal",
        python_dir: Path = PYTHON_DIR,
    ) -> Path:
        runner = self.directory / f"fixture-runner-{slow}-{fail_result}-{fail_final_stdout}-{case}.py"
        lines = [
            "import sys",
            f"sys.path[:0]=[{str(python_dir)!r},{str(Path(__file__).resolve().parent)!r}]",
            "import d_singing_render as r",
            "from test_singing_render import FakeEngine,SlowCancelEngine,fixture_materials",
            "r._validate_materials=fixture_materials",
            f"r._ENGINE_CLASS={'SlowCancelEngine' if slow else 'FakeEngine'}",
            f"fixture_case={case!r}",
            "if fixture_case=='inner-cancel':",
            "    class InnerCancelEngine(FakeEngine):",
            "        def vocoder(self,conditions,checkpoint): raise r.RenderCancelled('fixture inner cancellation')",
            "    r._ENGINE_CLASS=InnerCancelEngine",
            "observed_write=r._write_descriptor",
            "def fixture_observed_write(descriptor,payload):",
            "    if descriptor==1:",
            "        event=__import__('json').loads(payload)",
            "        if fixture_case=='late-cancel' and event.get('type')=='result':",
            "            __import__('os').kill(__import__('os').getpid(),__import__('signal').SIGTERM)",
            "        if fixture_case=='early-protection' and event.get('stage')=='validation':",
            "            with open(r._fixture_request,'a') as handle: handle.write('\\n')",
            "            __import__('os').kill(__import__('os').getpid(),__import__('signal').SIGTERM)",
            "        if fixture_case=='runtime-replacement' and event.get('stage')=='publish':",
            "            runtime=r._fixture_output/'.runtime'",
            "            runtime.rename(r._fixture_root/'retained-runtime')",
            "            runtime.mkdir()",
            "            (runtime/'sentinel').write_text('not-owned')",
            "    return observed_write(descriptor,payload)",
            "r._write_descriptor=fixture_observed_write",
        ]
        if fail_result:
            lines.extend([
                "original_publish=r.publish_exclusive",
                "def fixture_publish(job,filename,content,validate=None):",
                "    if filename=='result.json': raise OSError('fixture result report failure')",
                "    return original_publish(job,filename,content,validate=validate)",
                "r.publish_exclusive=fixture_publish",
            ])
        if fail_final_stdout:
            lines.extend([
                "original_write=r._write_descriptor",
                "fixture_count=[0]",
                "def fixture_write(descriptor,payload):",
                "    if descriptor==1:",
                "        fixture_count[0]+=1",
                "        if fixture_count[0]==8: raise OSError('fixture final notification failure')",
                "    return original_write(descriptor,payload)",
                "r._write_descriptor=fixture_write",
            ])
        if case in {"result-readback", "wav-symlink"}:
            lines.extend([
                "original_altered_publish=r.publish_exclusive",
                "def fixture_altered_publish(*args,**kwargs):",
                "    target=original_altered_publish(*args,**kwargs)",
                "    parent,name=args[:2]",
                "    if fixture_case=='result-readback' and name=='result.json': (parent/name).write_text('{\\\"broken\\\":true}\\n')",
                "    if fixture_case=='wav-symlink' and name=='output.wav':",
                "        original=parent/name",
                "        original.rename(r._fixture_root/'retained.wav')",
                "        original.symlink_to(r._fixture_root/'retained.wav')",
                "    return target",
                "r.publish_exclusive=fixture_altered_publish",
            ])
        if case == "output-io":
            lines.extend([
                "original_mkdir=r.os.mkdir",
                "def fixture_mkdir(path,*args,**kwargs):",
                "    if __import__('pathlib').Path(path)==r._fixture_output: raise OSError(28,'fixture full')",
                "    return original_mkdir(path,*args,**kwargs)",
                "r.os.mkdir=fixture_mkdir",
            ])
        lines.extend([
            "argv=sys.argv[1:]",
            "if '--request' in argv and '--output-directory' in argv:",
            "    r._fixture_request=__import__('pathlib').Path(argv[argv.index('--request')+1])",
            "    r._fixture_output=__import__('pathlib').Path(argv[argv.index('--output-directory')+1])",
            "    r._fixture_root=r._fixture_output.parent",
        ])
        lines.append("raise SystemExit(r.main())")
        runner.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return runner

    def _cli_arguments(self, output: Path, *, vendor: Path = VENDOR) -> list[str]:
        return [
            "--request", str(self.request_path), "--bank-directory", str(self.bank),
            "--vocoder-directory", str(self.vocoder), "--vendor-directory", str(vendor),
            "--profile", str(PROFILE), "--output-directory", str(output),
        ]

    def _run_child(self, runner: Path, arguments: list[str], *, preexec_fn=None, timeout=20):
        job_tmp = self.directory / "job.tmp"
        job_tmp.mkdir(exist_ok=True)
        environment = os.environ.copy()
        environment.update({
            "TMPDIR": str(job_tmp), "XDG_CACHE_HOME": str(job_tmp / "xdg"),
            "MPLCONFIGDIR": str(job_tmp / "mpl"), "NUMBA_CACHE_DIR": str(job_tmp / "numba"),
            "PYTHONDONTWRITEBYTECODE": "1",
        })
        process = subprocess.Popen(
            [sys.executable, "-B", str(runner), *arguments],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, preexec_fn=preexec_fn,
        )
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = process.communicate(timeout=5)
            self.fail(f"fixture CLI timed out: stdout={stdout!r}, stderr={stderr!r}")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
        return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)

    def test_full_cli_success_report_failure_and_final_notification_failure(self) -> None:
        success_output = self.directory / "cli-success"
        result = self._run_child(self._runner(), self._cli_arguments(success_output))
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([line["type"] for line in lines], ["progress"] * 7 + ["result"])
        self.assertEqual(lines[-1]["resultPath"], "result.json")

        report_output = self.directory / "cli-report-failure"
        result = self._run_child(
            self._runner(fail_result=True), self._cli_arguments(report_output)
        )
        self.assertEqual(result.returncode, 1)
        self.assertTrue((report_output / "output.wav").is_file())
        self.assertFalse((report_output / "result.json").exists())

        notify_output = self.directory / "cli-notify-failure"
        result = self._run_child(
            self._runner(fail_final_stdout=True), self._cli_arguments(notify_output)
        )
        self.assertEqual(result.returncode, 1)
        self.assertTrue((notify_output / "output.wav").is_file())
        self.assertTrue((notify_output / "result.json").is_file())

    def test_full_cli_signal_and_closed_descriptors_have_exact_exit_classes(self) -> None:
        cancel_output = self.directory / "cli-cancel"
        runner = self._runner(slow=True)
        job_tmp = self.directory / "job.tmp"
        job_tmp.mkdir()
        environment = os.environ.copy()
        environment.update({"TMPDIR": str(job_tmp), "PYTHONDONTWRITEBYTECODE": "1"})
        process = subprocess.Popen(
            [sys.executable, "-B", str(runner), *self._cli_arguments(cancel_output)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment,
        )
        try:
            readable, _, _ = select.select([process.stdout], [], [], 10)
            self.assertTrue(readable, "cancel fixture did not reach its first progress checkpoint")
            first_line = process.stdout.readline()
            self.assertTrue(first_line, "cancel fixture exited before its first progress checkpoint")
            process.send_signal(signal.SIGTERM)
            remaining_stdout, stderr = process.communicate(timeout=20)
            stdout = first_line + remaining_stdout
        except subprocess.TimeoutExpired:
            process.kill(); stdout, stderr = process.communicate(timeout=5)
            self.fail(f"cancel CLI timed out: {stdout!r} {stderr!r}")
        finally:
            if process.poll() is None:
                process.kill(); process.wait(timeout=5)
        self.assertEqual(process.returncode, 130, (stdout, stderr))
        self.assertFalse((cancel_output / "result.json").exists())

        closed_stdout_output = self.directory / "closed-stdout"
        result = self._run_child(
            self._runner(), self._cli_arguments(closed_stdout_output),
            preexec_fn=lambda: os.close(1),
        )
        self.assertEqual(result.returncode, 1)

        result = self._run_child(
            self._runner(), ["--bad"], preexec_fn=lambda: os.close(2),
        )
        self.assertEqual(result.returncode, 2)

    def test_full_cli_persists_lead_protection_and_commit_regressions(self) -> None:
        cases = {
            "inner-cancel": 130,
            "late-cancel": 0,
            "early-protection": 1,
            "runtime-replacement": 1,
            "result-readback": 1,
            "wav-symlink": 1,
            "output-io": 1,
        }
        for case, expected in cases.items():
            output = self.directory / f"lead-{case}"
            with self.subTest(case=case):
                result = self._run_child(
                    self._runner(case=case), self._cli_arguments(output)
                )
                self.assertEqual(result.returncode, expected, (result.stdout, result.stderr))
                if case == "late-cancel":
                    self.assertTrue((output / "result.json").is_file())
                if case == "early-protection":
                    self.assertIn(b"identity changed", result.stderr)
                    self.assertIn(b"primary failure", result.stderr)
                if case == "runtime-replacement":
                    sentinel = output / ".runtime" / "sentinel"
                    self.assertTrue(sentinel.is_file())
                    self.assertEqual(sentinel.read_text(encoding="utf-8"), "not-owned")
                if case == "result-readback":
                    self.assertEqual(
                        json.loads((output / "result.json").read_text(encoding="utf-8")),
                        {"broken": True},
                    )
                if case == "wav-symlink":
                    self.assertTrue((output / "output.wav").is_symlink())
                    self.assertFalse((output / "result.json").exists())
                if case == "output-io":
                    self.assertFalse(output.exists())

    def test_no_bytecode_or_cache_in_owned_cli_source_and_vendor_copies(self) -> None:
        source_copy = self.directory / "source-copy"
        source_copy.mkdir()
        for name in (
            "d_singing_render.py", "d_singing_qixuan.py", "d_audio_contract.py",
            "d_singing_prepare.py", "d_singing_timing.py",
        ):
            shutil.copy2(PYTHON_DIR / name, source_copy / name)
        vendor_copy = self.directory / "vendor-copy"
        shutil.copytree(VENDOR, vendor_copy)

        no_b_tmp = self.directory / "no-b-tmp"
        no_b_tmp.mkdir()
        environment = os.environ.copy()
        for name in ("PYTHONDONTWRITEBYTECODE", "PYTHONPYCACHEPREFIX", "PYTHONPATH"):
            environment.pop(name, None)
        environment["TMPDIR"] = str(no_b_tmp)
        process = subprocess.Popen(
            [sys.executable, str(source_copy / "d_singing_render.py")],
            cwd=self.directory, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=environment,
        )
        try:
            stdout, stderr = process.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill(); stdout, stderr = process.communicate(timeout=5)
            self.fail(f"no-B copied CLI timed out: {stdout!r} {stderr!r}")
        finally:
            if process.poll() is None:
                process.kill(); process.wait(timeout=5)
        self.assertEqual(process.returncode, 2, (stdout, stderr))
        early_bytecode = [
            path for path in source_copy.rglob("*")
            if path.name == "__pycache__" or path.suffix in {".pyc", ".pyo"}
        ]
        self.assertEqual(early_bytecode, [])

        output = self.directory / "copy-output"
        result = self._run_child(
            self._runner(case="normal", python_dir=source_copy),
            self._cli_arguments(output, vendor=vendor_copy),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        forbidden = []
        for root in (source_copy, vendor_copy, output):
            forbidden.extend(path for path in root.rglob("*") if path.name == "__pycache__" or path.suffix in {".pyc", ".pyo"})
        self.assertEqual(forbidden, [])
        self.assertEqual({path.name for path in output.iterdir()}, {"output.wav", "result.json"})


if __name__ == "__main__":
    unittest.main()
