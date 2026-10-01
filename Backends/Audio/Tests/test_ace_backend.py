from __future__ import annotations

import hashlib
import contextlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Python"))
import d_audio_ace_backend as backend
import d_audio_ace_contract as contract
import d_ace_offline_runtime as runtime


def sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def wave(frames: int) -> bytes:
    pcm = b"\0" * (frames * 4)
    fmt = struct.pack("<HHIIHH", 1, 2, 48000, 192000, 4, 16)
    return (b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt "
            + struct.pack("<I", 16) + fmt + b"data"
            + struct.pack("<I", len(pcm)) + pcm)


class ACEBackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        self.root = Path(self.temp.name)
        self.run = self.root / "run"
        self.run.mkdir()
        self.job = self.run / "job"
        self.job.mkdir()
        self.model = self.root / "model"
        self.model.mkdir()
        self.vendor = self.root / "vendor"
        self.vendor.mkdir()
        self.manifest = {
            "schemaVersion": 1, "profile": contract.PROFILE,
            "modelRepository": contract.MODEL_REPOSITORY,
            "modelRevision": contract.MODEL_REVISION,
            "sharedRepository": contract.SHARED_REPOSITORY,
            "sharedRevision": contract.SHARED_REVISION,
            "sourceRevision": contract.SOURCE_REVISION,
            "files": [], "sourceFiles": [],
        }
        index = {"metadata": {"total_size": 4},
                 "weight_map": {f"layer{number}.weight": f"model-{number:05d}-of-00004.safetensors"
                                for number in range(1, 5)}}
        for relative in sorted(contract.REQUIRED_MODEL_FILES):
            role = ("xl" if relative.startswith(contract.XL_ROOT) else
                    "vae" if relative.startswith("checkpoints/vae/") else "embedding")
            raw = (json.dumps(index).encode() if relative.endswith("model.safetensors.index.json")
                   else ("fixture " + relative).encode())
            self.add_file(self.model, "files", relative, raw, role)
        for relative in ("acestep/handler.py", "acestep/model_downloader.py",
                         "acestep/models/xl_sft/modeling_acestep_v15_xl_base.py",
                         "acestep/models/xl_sft/configuration_acestep_v15.py",
                         "acestep/models/xl_sft/apg_guidance.py",
                         *(path for path, _ in contract.SOURCE_PATCHES)):
            self.add_file(self.vendor, "sourceFiles", relative, b"# pinned " + relative.encode())
        source_by_path = {item["path"]: item for item in self.manifest["sourceFiles"]}
        self.manifest["sourcePatches"] = [
            {"path": path, "baseSHA256": base,
             "patchedSHA256": source_by_path[path]["sha256"]}
            for path, base in contract.SOURCE_PATCHES]
        self.manifest_path = self.root / "manifest.json"
        self.save_manifest()
        self.request = {
            "schemaVersion": 1, "runID": "12345678-1234-4234-9234-123456789abc",
            "operation": "generate", "prompt": "rain song", "durationSeconds": 1.0,
            "seed": 7, "parameters": {"kind": "aceStep15", "ace": {
                "executionProfile": contract.PROFILE,
                "vocal": {"kind": "instrumental"}, "steps": 50, "guidanceScale": 7,
            }},
        }
        self.request_path = self.run / "request.json"
        self.save_request()

    def tearDown(self):
        self.temp.cleanup()

    def add_file(self, root, key, relative, raw, role=None):
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        item = {"path": relative, "size": len(raw), "sha256": sha(raw)}
        if role: item["role"] = role
        self.manifest[key].append(item)
        return path

    def save_manifest(self):
        self.manifest_path.write_text(json.dumps(self.manifest))

    def save_request(self):
        self.request_path.write_text(json.dumps(self.request))

    def source(self, frames=480001):
        path = self.run / "source.wav"
        raw = wave(frames)
        path.write_bytes(raw)
        return {"url": path.as_uri(), "sha256": sha(raw), "frameCount": frames,
                "sampleRate": 48000, "channels": 2}

    def test_manifest_and_private_view_pin_source_and_weights(self):
        self.add_file(self.vendor, "sourceFiles", "acestep/models/xl_sft/__init__.py", b"")
        contract.validate_manifest(self.manifest)
        view = runtime.prepare_runtime_view(self.run, self.model, self.vendor, self.manifest)
        weight_path = contract.XL_ROOT + "model-00001-of-00004.safetensors"
        weight = view / weight_path
        self.assertTrue(weight.is_symlink())
        self.assertEqual(weight.readlink(), self.model / weight_path)
        self.assertFalse((view / "checkpoints/acestep-v15-xl-sft/modeling_acestep_v15_xl_base.py").is_symlink())
        self.assertFalse((view / "checkpoints/acestep-v15-xl-sft/__init__.py").exists())
        runtime.verify_runtime_view(view, self.model, self.vendor, self.manifest)
        (self.vendor / "acestep/handler.py").write_bytes(b"changed")
        with self.assertRaises(contract.ACEContractError):
            runtime.verify_runtime_view(view, self.model, self.vendor, self.manifest)

    def test_manifest_rejects_missing_source_and_unknown_fields(self):
        bad = dict(self.manifest)
        del bad["sourceFiles"]
        with self.assertRaises(contract.ACEContractError): contract.validate_manifest(bad)
        bad = dict(self.manifest, sourceFiles=self.manifest["sourceFiles"][:-1])
        with self.assertRaises(contract.ACEContractError): contract.validate_manifest(bad)
        bad = dict(self.manifest, surprise=True)
        with self.assertRaises(contract.ACEContractError): contract.validate_manifest(bad)
        (self.vendor / "acestep/extra.py").write_text("# unpinned")
        with self.assertRaises(contract.ACEContractError):
            contract.verify_source_files(self.manifest, self.vendor)

    def test_required_resources_and_index_shards(self):
        for missing in ("checkpoints/vae/config.json",
                        "checkpoints/Qwen3-Embedding-0.6B/tokenizer.json",
                        contract.XL_ROOT + "model.safetensors.index.json"):
            bad = dict(self.manifest, files=[item for item in self.manifest["files"]
                                             if item["path"] != missing])
            with self.subTest(missing=missing), self.assertRaises(contract.ACEContractError):
                contract.validate_manifest(bad)
        index = self.model / contract.XL_ROOT / "model.safetensors.index.json"
        original = index.read_bytes()
        for name in ("missing.safetensors", "../vae/diffusion_pytorch_model.safetensors"):
            changed = {"metadata": {}, "weight_map": {"layer.weight": name}}
            raw = json.dumps(changed).encode()
            index.write_bytes(raw)
            for item in self.manifest["files"]:
                if item["path"] == contract.XL_ROOT + "model.safetensors.index.json":
                    item.update(size=len(raw), sha256=sha(raw))
            with self.subTest(shard=name), self.assertRaises(contract.ACEContractError):
                contract.verify_manifest_files(self.manifest, self.model)
        index.write_bytes(original)

    def test_float_input_rejects_clipping_and_nonfinite(self):
        ref = self.source(frames=1)
        for sample in (1.25, float("nan"), float("inf")):
            raw = (b"RIFF" + struct.pack("<I", 36 + 8) + b"WAVEfmt "
                   + struct.pack("<IHHIIHH", 16, 3, 2, 48000, 384000, 8, 32)
                   + b"data" + struct.pack("<Iff", 8, sample, -1.0))
            (self.run / "source.wav").write_bytes(raw)
            ref["sha256"] = sha(raw)
            with self.subTest(sample=sample), self.assertRaises(contract.ACEContractError):
                contract.verify_wav(ref)
        raw = (b"RIFF" + struct.pack("<I", 36 + 8) + b"WAVEfmt "
               + struct.pack("<IHHIIHH", 16, 3, 2, 48000, 384000, 8, 32)
               + b"data" + struct.pack("<Iff", 8, 1.0, -1.0))
        (self.run / "source.wav").write_bytes(raw)
        ref["sha256"] = sha(raw)
        contract.verify_wav(ref)

    def test_checkpoint_environment_override_is_rejected(self):
        class Writer:
            def __init__(self): self.events = []
            def progress(self, *args): pass
            def emit(self, value, **kwargs): self.events.append(value)
        writer = Writer()
        with mock.patch.dict(os.environ, {"ACESTEP_CHECKPOINTS_DIR": str(self.root)}):
            code = backend.run_provider(self.request_path, self.job, self.model,
                                        self.manifest_path, self.vendor, writer,
                                        lambda: False, lambda *args: None)
        self.assertEqual(code, 2)
        self.assertEqual(writer.events[-1]["kind"], "configuration")

    def test_view_never_copies_downloaded_model_python(self):
        downloaded = self.add_file(self.model, "files", "checkpoints/acestep-v15-xl-sft/model.py",
                                   b"raise RuntimeError('untrusted')", "xl")
        original = downloaded.read_bytes()
        view = runtime.prepare_runtime_view(self.run, self.model, self.vendor, self.manifest)
        self.assertFalse((view / "checkpoints/acestep-v15-xl-sft/model.py").exists())
        self.assertEqual((view / "checkpoints/acestep-v15-xl-sft/modeling_acestep_v15_xl_base.py").read_bytes(),
                         (self.vendor / "acestep/models/xl_sft/modeling_acestep_v15_xl_base.py").read_bytes())
        self.assertEqual(downloaded.read_bytes(), original)

    def test_edit_duration_uses_exact_source_frames(self):
        ref = self.source()
        self.request.update(operation="variation", durationSeconds=480001 / 48000,
                            source=ref)
        self.request["parameters"]["ace"]["editOptions"] = {
            "kind": "cover", "audioCoverStrength": .4, "noiseStrength": .2}
        contract.validate_request(self.request)
        self.request["operation"] = "inpaint"
        self.request["editRegion"] = {"startFrame": 480000, "endFrame": 480001}
        self.request["parameters"]["ace"]["editOptions"] = {"kind": "repaint", "strength": .8}
        contract.validate_request(self.request)
        self.request["editRegion"]["endFrame"] += 1
        with self.assertRaises(contract.ACEContractError): contract.validate_request(self.request)

    def test_duration_and_number_types(self):
        for value in (float("nan"), float("inf"), 0.099, 1.00001,
                      2**63 / 48000, True):
            self.request["durationSeconds"] = value
            with self.subTest(value=value), self.assertRaises(contract.ACEContractError):
                contract.validate_request(self.request)
        self.request["durationSeconds"] = 1.0
        self.request["parameters"]["ace"]["steps"] = True
        with self.assertRaises(contract.ACEContractError): contract.validate_request(self.request)

    def test_exact_cover_repaint_reference_and_no_lm_kwargs(self):
        ref = self.source()
        self.request.update(operation="variation", source=ref, durationSeconds=480001 / 48000)
        ace = self.request["parameters"]["ace"]
        ace["referenceAudio"] = ref
        ace["editOptions"] = {"kind": "cover", "audioCoverStrength": .3, "noiseStrength": .7}
        handler = types.SimpleNamespace(generate_instruction=lambda task: "instruction:" + task)
        kwargs, lyrics = backend.build_generate_kwargs(self.request, handler)
        self.assertEqual((kwargs["task_type"], kwargs["src_audio"], kwargs["reference_audio"]),
                         ("cover", str(contract.reference_path(ref)), str(contract.reference_path(ref))))
        self.assertEqual((kwargs["audio_cover_strength"], kwargs["cover_noise_strength"]), (.3, .7))
        self.assertEqual(lyrics, "[Instrumental]")
        self.assertFalse(any("lm" in key.lower() for key in kwargs))
        self.request["operation"] = "inpaint"
        self.request["editRegion"] = {"startFrame": 1, "endFrame": 480001}
        ace["editOptions"] = {"kind": "repaint", "strength": .6}
        kwargs, _ = backend.build_generate_kwargs(self.request, handler)
        self.assertEqual((kwargs["repainting_start"], kwargs["repainting_end"],
                          kwargs["repaint_strength"]), (1 / 48000, 480001 / 48000, .6))
        ace["unsupported"] = 1
        with self.assertRaises(contract.ACEContractError): contract.validate_request(self.request)

    def test_full_lyrics_and_instrumental_are_distinct(self):
        handler = types.SimpleNamespace(generate_instruction=lambda task: "instruction:" + task)
        kwargs, effective = backend.build_generate_kwargs(self.request, handler)
        self.assertEqual((kwargs["lyrics"], effective), ("[Instrumental]", "[Instrumental]"))
        full = "first line\n" + "la" * 1024 + "\nlast line"
        self.request["parameters"]["ace"]["vocal"] = {
            "kind": "lyrics", "text": full, "language": "zh"}
        contract.validate_request(self.request)
        kwargs, effective = backend.build_generate_kwargs(self.request, handler)
        self.assertEqual((kwargs["lyrics"], effective, kwargs["vocal_language"]),
                         (full, full, "zh"))

    def test_full_template_token_budgets_without_truncation(self):
        calls = []
        class Tokenizer:
            def __call__(self, text, **kwargs):
                calls.append((text, kwargs))
                return {"input_ids": [1] * (257 if "long caption" in text else 4)}
        handler = types.SimpleNamespace(
            extract_caption_from_sft_format=lambda text: text,
            _build_metadata_dict=lambda *args: {"bpm": 120},
            _dict_to_meta_string=lambda meta: "meta",
            _format_instruction=lambda text: text,
            _format_lyrics=lambda text, language: f"{language}:{text}",
            text_tokenizer=Tokenizer())
        kwargs = {"captions": "long caption", "bpm": None, "key_scale": "",
                  "time_signature": "", "audio_duration": 1, "instruction": "generate",
                  "lyrics": "all lyrics", "vocal_language": "en"}
        with (mock.patch.dict(sys.modules, {"acestep": types.ModuleType("acestep"),
                                            "acestep.constants": types.SimpleNamespace(SFT_GEN_PROMPT="{} {} {}")}),
              self.assertRaises(contract.ACEContractError)):
            backend.precheck_tokens(handler, kwargs)
        self.assertEqual(calls[0][1]["truncation"], False)
        self.assertIn("meta", calls[0][0])
        self.assertIn("long caption", calls[0][0])
        calls.clear()
        kwargs["captions"] = "short caption"
        class LyricTokenizer:
            def __call__(self, text, **options):
                calls.append((text, options))
                return {"input_ids": [1] * (2049 if "all lyrics" in text else 4)}
        handler.text_tokenizer = LyricTokenizer()
        with (mock.patch.dict(sys.modules, {"acestep": types.ModuleType("acestep"),
                                            "acestep.constants": types.SimpleNamespace(SFT_GEN_PROMPT="{} {} {}")}),
              self.assertRaises(contract.ACEContractError)):
            backend.precheck_tokens(handler, kwargs)
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[1][1]["truncation"], False)
        self.assertIn("all lyrics", calls[1][0])

    def test_cancel_and_failure_do_not_call_handler(self):
        class Writer:
            def __init__(self): self.events = []
            def progress(self, *args): pass
            def emit(self, value, **kwargs): self.events.append(value)
        for cancelled, expected in ((lambda: True, 130), (lambda: False, 2)):
            writer = Writer()
            def failed(*args):
                raise contract.ACEContractError("fake child startup failed", "engine")
            code = backend.run_provider(self.request_path, self.job, self.model,
                                        self.manifest_path, self.vendor, writer,
                                        cancelled, failed)
            self.assertEqual(code, expected)
            self.assertEqual(writer.events[-1]["type"], "error")
            self.assertFalse((self.job / "output.wav").exists())

    def test_initialization_cancellation_swallowed_by_official_wrapper_is_still_cancelled(self):
        cancelled = [False]
        class Writer:
            def __init__(self): self.events = []
            def progress(self, *args): pass
            def emit(self, value, **kwargs): self.events.append(value)
        class Handler:
            def initialize_service(self, **kwargs):
                cancelled[0] = True
                return "official wrapper caught InterruptedError", False
        writer = Writer()
        code = backend.run_provider(self.request_path, self.job, self.model,
            self.manifest_path, self.vendor, writer, lambda: cancelled[0], lambda *args: Handler())
        self.assertEqual(code, 130)
        self.assertEqual(writer.events[-1]["kind"], "cancelled")
        self.assertFalse((self.job / "output.wav").exists())

    def test_input_mutation_after_fake_handler_failure_wins(self):
        ref = self.source(frames=4800)
        self.request.update(operation="variation", durationSeconds=.1, source=ref)
        self.request["parameters"]["ace"]["editOptions"] = {
            "kind": "cover", "audioCoverStrength": .5, "noiseStrength": .5}
        self.save_request()
        class Writer:
            def __init__(self): self.events = []
            def progress(self, *args): pass
            def emit(self, value, **kwargs): self.events.append(value)
        class Handler:
            def initialize_service(self, **kwargs):
                path = contract.reference_path(ref)
                with path.open("r+b") as stream:
                    stream.seek(-1, os.SEEK_END)
                    stream.write(b"\1")
                return "forced failure", False
        writer = Writer()
        code = backend.run_provider(self.request_path, self.job, self.model,
                                    self.manifest_path, self.vendor, writer,
                                    lambda: False, lambda *args: Handler())
        self.assertEqual(code, 2)
        self.assertEqual(writer.events[-1]["kind"], "inputMutation")
        self.assertFalse((self.job / "output.wav").exists())

    def test_real_fake_child_failure_drains_both_pipes(self):
        script = self.root / "fake-child.py"
        script.write_text("""
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import d_audio_ace_backend as b
class Handler:
    def initialize_service(self, **kwargs):
        sys.stderr.write('E' * 131072)
        sys.stderr.flush()
        return 'forced failure', False
code=b.run_provider(*(Path(p) for p in sys.argv[2:7]), b.EventWriter(),
                    lambda: False, lambda *args: Handler())
sys.exit(code)
""")
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", TMPDIR=str(self.root))
        result = subprocess.run(
            [sys.executable, "-B", str(script), str(Path(backend.__file__).parent),
             str(self.request_path), str(self.job), str(self.model),
             str(self.manifest_path), str(self.vendor)],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(len(result.stderr), 131072)
        lines = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(lines[-1]["type"], "error")
        self.assertEqual(lines[-1]["kind"], "configuration")

    def test_production_has_no_global_pretrained_loader_patch(self):
        import inspect
        self.assertNotIn("unittest.mock", inspect.getsource(runtime))
        self.assertNotIn("local_only_loading", inspect.getsource(backend))

    def test_weight_hashes_once_before_and_once_after_fake_handler(self):
        counts = {}
        original = Path.open
        def measured(path, *args, **kwargs):
            if path.suffix == ".safetensors" and self.model in path.parents:
                counts[path] = counts.get(path, 0) + 1
            return original(path, *args, **kwargs)
        class Writer:
            def __init__(self): self.events = []
            def progress(self, *args): pass
            def emit(self, value, **kwargs): self.events.append(value)
        class Handler:
            dtype = "torch.float32"
            def initialize_service(self, **kwargs): return "ready", True
            def generate_instruction(self, task): return task
            def generate_music(self, **kwargs): return {"fake": True}
        writer = Writer()
        with (mock.patch.object(Path, "open", measured),
              mock.patch.object(backend, "forbid_torch_fallback"),
              mock.patch.object(backend, "precheck_tokens", return_value={"caption": 2, "lyrics": 2}),
              mock.patch.object(backend, "float32_samples", return_value=([0.0, 0.0] * 48000, 48000))):
            code = backend.run_provider(self.request_path, self.job, self.model,
                                        self.manifest_path, self.vendor, writer,
                                        lambda: False, lambda *args: Handler())
        self.assertEqual(code, 0)
        self.assertEqual(writer.events[-1]["type"], "result")
        expected = {self.model / item["path"] for item in self.manifest["files"]
                    if item["path"].endswith(".safetensors")}
        self.assertEqual(set(counts), expected)
        self.assertEqual(set(counts.values()), {2})

    def admitted_record(self):
        record = contract.capture_verified_record(self.manifest, self.manifest_path,
                                                  self.model, self.vendor)
        contract.verify_manifest_files(self.manifest, self.model)
        contract.verify_source_files(self.manifest, self.vendor)
        record.check(self.manifest, manifest_path=self.manifest_path,
                     model=self.model, vendor=self.vendor)
        return record

    def test_same_size_change_after_full_hash_is_rejected_before_handler(self):
        weight = self.model / contract.XL_ROOT / "model-00001-of-00004.safetensors"
        original_verify = backend.verify_source_files
        reached = []
        def mutate_after_complete_hash(manifest, vendor):
            original_verify(manifest, vendor)
            raw = weight.read_bytes()
            weight.write_bytes(b"X" + raw[1:])
        class Writer:
            def __init__(self): self.events = []
            def progress(self, *args): pass
            def emit(self, value, **kwargs): self.events.append(value)
        writer = Writer()
        with mock.patch.object(backend, "verify_source_files", side_effect=mutate_after_complete_hash):
            code = backend.run_provider(self.request_path, self.job, self.model,
                                        self.manifest_path, self.vendor, writer,
                                        lambda: False, lambda *args: reached.append("handler"))
        self.assertEqual(code, 2)
        self.assertEqual(writer.events[-1]["kind"], "inputMutation")
        self.assertIn(str(weight), writer.events[-1]["message"])
        self.assertEqual(reached, [])

    def test_record_rejects_new_location_and_manifest_value(self):
        record = self.admitted_record()
        view = runtime.prepare_runtime_view(self.run, self.model, self.vendor, self.manifest, record)
        record = record.with_view(view)
        record.check(self.manifest, manifest_path=self.manifest_path,
                     model=self.model, vendor=self.vendor, view=view)
        with self.assertRaises(contract.ACEContractError):
            record.check(self.manifest, model=self.root / "other-model")
        with self.assertRaises(contract.ACEContractError):
            record.check(self.manifest, view=self.root / "other-view")
        changed = dict(self.manifest, sourceRevision="other")
        with self.assertRaises(contract.ACEContractError): record.check(changed)

    def test_record_rejects_same_size_file_change(self):
        record = self.admitted_record()
        weight = self.model / contract.XL_ROOT / "model-00001-of-00004.safetensors"
        raw = weight.read_bytes()
        weight.write_bytes(b"X" + raw[1:])
        with self.assertRaisesRegex(contract.ACEContractError, str(weight)):
            record.check(self.manifest)

    def test_record_rejects_inode_replacement(self):
        record = self.admitted_record()
        weight = self.model / contract.XL_ROOT / "model-00001-of-00004.safetensors"
        replacement = weight.with_suffix(".replacement")
        replacement.write_bytes(weight.read_bytes())
        replacement.replace(weight)
        with self.assertRaisesRegex(contract.ACEContractError, str(weight)):
            record.check(self.manifest)

    def test_record_allows_unrelated_siblings(self):
        record = self.admitted_record()
        (self.root / "unrelated-output").write_bytes(b"result")
        (self.model / "unrelated-model").write_bytes(b"another model")
        record.check(self.manifest)

    def test_record_rejects_parent_identity_replacement(self):
        record = self.admitted_record()
        source_parent = self.vendor / "acestep/models/xl_sft"
        source_parent.rename(source_parent.with_name("xl_old"))
        source_parent.mkdir()
        with self.assertRaisesRegex(contract.ACEContractError, str(source_parent)):
            record.check(self.manifest)

    def test_record_rejects_parent_symlink(self):
        record = self.admitted_record()
        source_parent = self.vendor / "acestep/models/xl_sft"
        moved = source_parent.with_name("xl_old")
        source_parent.rename(moved)
        source_parent.symlink_to(moved, target_is_directory=True)
        with self.assertRaises(contract.ACEContractError):
            record.check(self.manifest)

    def test_record_rejects_unlisted_source_file(self):
        record = self.admitted_record()
        (self.vendor / "acestep/unlisted.py").write_bytes(b"pass\n")
        with self.assertRaisesRegex(contract.ACEContractError, "source tree differs"):
            record.check(self.manifest)

    def test_cancelled_job_still_reports_input_mutation(self):
        ref = self.source(frames=4800)
        self.request.update(operation="variation", durationSeconds=.1, source=ref)
        self.request["parameters"]["ace"]["editOptions"] = {
            "kind": "cover", "audioCoverStrength": .5, "noiseStrength": .5}
        self.save_request()
        state = {"cancelled": False}
        class Writer:
            def __init__(self): self.events = []
            def progress(self, *args): pass
            def emit(self, value, **kwargs): self.events.append(value)
        class Handler:
            def initialize_service(self, **kwargs):
                path = contract.reference_path(ref)
                raw = path.read_bytes()
                path.write_bytes(raw[:-1] + bytes([raw[-1] ^ 1]))
                state["cancelled"] = True
                return "cancelled", False
        writer = Writer()
        code = backend.run_provider(self.request_path, self.job, self.model,
                                    self.manifest_path, self.vendor, writer,
                                    lambda: state["cancelled"], lambda *args: Handler())
        self.assertEqual(code, 2)
        self.assertEqual(writer.events[-1]["kind"], "inputMutation")

    def test_view_copy_mutation_rejected(self):
        initial = self.admitted_record()
        view = runtime.prepare_runtime_view(self.run, self.model, self.vendor, self.manifest, initial)
        record = initial.with_view(view)
        config = view / "checkpoints/vae/config.json"
        raw = config.read_bytes()
        config.write_bytes(b"X" + raw[1:])
        with self.assertRaisesRegex(contract.ACEContractError, str(config)):
            runtime.verify_runtime_view(view, self.model, self.vendor, self.manifest, record)

    def test_view_rejects_unlisted_file(self):
        initial = self.admitted_record()
        view = runtime.prepare_runtime_view(self.run, self.model, self.vendor, self.manifest, initial)
        record = initial.with_view(view)
        (view / "unlisted").write_bytes(b"extra")
        with self.assertRaises(contract.ACEContractError):
            runtime.verify_runtime_view(view, self.model, self.vendor, self.manifest, record)

    def test_manifest_file_mutation_rejected(self):
        record = self.admitted_record()
        manifest_raw = self.manifest_path.read_bytes()
        self.manifest_path.write_bytes(b" " + manifest_raw[1:])
        with self.assertRaisesRegex(contract.ACEContractError, str(self.manifest_path)):
            record.check(self.manifest)

    def test_decoder_release_requires_materialized_f32_and_keeps_conditions(self):
        mlx = types.ModuleType("mlx")
        mlx.__path__ = []
        core = types.ModuleType("mlx.core")
        utils = types.ModuleType("mlx.utils")
        utils.tree_flatten = lambda parameters: [("p", parameters["p"])]
        class DType:
            def __init__(self, name): self.name = name
            def __str__(self): return "mlx.core." + self.name
            def __eq__(self, other): return isinstance(other, DType) and self.name == other.name
        core.float32 = DType("float32")
        core.float16 = DType("float16")
        array = types.SimpleNamespace(dtype=core.float32)
        decoder = types.SimpleNamespace(parameters=lambda: {"p": array})
        torch_decoder = object()
        tokenizer = object()
        detokenizer = object()
        condition = object()
        model = types.SimpleNamespace(decoder=torch_decoder, tokenizer=tokenizer,
                                      detokenizer=detokenizer, null_condition=condition)
        handler = types.SimpleNamespace(model=model, mlx_decoder=decoder, use_mlx_dit=True)
        core.eval = lambda *args: (_ for _ in ()).throw(RuntimeError("eval failed"))
        with mock.patch.dict(sys.modules, {"mlx": mlx, "mlx.core": core, "mlx.utils": utils}):
            with self.assertRaises(RuntimeError): runtime.release_torch_decoder(handler)
            self.assertIs(model.decoder, torch_decoder)
            core.eval = lambda *args: None
            array.dtype = core.float16
            with self.assertRaises(contract.ACEContractError): runtime.release_torch_decoder(handler)
            self.assertIs(model.decoder, torch_decoder)
            array.dtype = core.float32
            runtime.release_torch_decoder(handler)
        self.assertIsNone(model.decoder)
        self.assertIs(model.tokenizer, tokenizer)
        self.assertIs(model.detokenizer, detokenizer)
        self.assertIs(model.null_condition, condition)


if __name__ == "__main__":
    unittest.main()
