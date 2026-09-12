#!/usr/bin/env python3
"""CPU-only contract tests for the portable test-kit runner."""

from __future__ import annotations

import fcntl
import hashlib
import importlib.util
import json
import os
import signal
import struct
import sys
import tempfile
import unittest
import urllib.parse
import uuid
import zipfile
import zlib
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "d_testkit.py"
SPEC = importlib.util.spec_from_file_location("d_testkit", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
runner_module = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runner_module
SPEC.loader.exec_module(runner_module)


FAKE_CLI = r'''#!/usr/bin/python3
import json, os, signal, struct, sys, time, urllib.parse, uuid, zlib
MODE = __MODE__
MARKER = __MARKER__
args = sys.argv[1:]
def value(name, default=None):
    return args[args.index(name)+1] if name in args else default
report_path = value("--report")
capability = value("--capability", "text")
model = value("--model")
revision = value("--revision")
repeat = int(value("--repeat", "1"))
options = {"capability": capability, "model": model, "revision": revision, "repeatCount": repeat}
if "--inspect" in args:
    report = {"schemaVersion":1,"exitCode":0,"options":options,"runs":[],
              "inspection":{"estimate":{"peakBytes":1234,"confidence":"estimated"},
                            "withinBudget": MODE != "blocked"}}
    Path = __import__("pathlib").Path
    Path(report_path).write_text(json.dumps(report), encoding="utf-8")
    raise SystemExit(0)
if MARKER:
    open(MARKER, "a", encoding="utf-8").write("executed\n")
if MODE == "sleep":
    signal.signal(signal.SIGINT, signal.SIG_IGN); signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(30)
if MODE == "output-limit":
    os.write(1, b"x" * (17 * 1024 * 1024)); time.sleep(30)
run_id = str(uuid.uuid4())
request = {"id":run_id,"model":{"directory":model,"revision":revision}}
artifacts = []
text = "模拟输出✅"
if capability == "image":
    root = __import__("pathlib").Path(value("--artifacts")); root.mkdir(parents=True, exist_ok=True)
    width, height = int(value("--width")), int(value("--height"))
    def chunk(kind, data): return struct.pack(">I",len(data))+kind+data+struct.pack(">I",zlib.crc32(kind+data)&0xffffffff)
    rows = b"".join(b"\0" + b"\x00\x20\x40" * width for _ in range(height))
    raw = b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",struct.pack(">IIBBBBB",width,height,8,2,0,0,0))+chunk(b"IDAT",zlib.compress(rows))+chunk(b"IEND",b"")
    path=root/"image.png"; path.write_bytes(raw)
    artifacts=[{"url":path.resolve().as_uri(),"mediaType":"image/png"}]
elif capability == "audio":
    root = __import__("pathlib").Path(value("--artifacts")); root.mkdir(parents=True, exist_ok=True)
    frames = int(float(value("--duration-seconds"))*44100/2+0.5)*2
    data = struct.pack("<"+"f"*(frames*2), *([0.0]*(frames*2)))
    fmt=struct.pack("<HHIIHH",3,2,44100,352800,8,32)
    raw=b"RIFF"+struct.pack("<I",4+8+len(fmt)+8+len(data))+b"WAVE"+b"fmt "+struct.pack("<I",len(fmt))+fmt+b"data"+struct.pack("<I",len(data))+data
    path=root/"audio.wav"; path.write_bytes(raw)
    artifacts=[{"url":path.resolve().as_uri(),"mediaType":"audio/wav"}]
outcome = "failed" if MODE == "failed" else "completed"
exit_code = 1 if outcome == "failed" else 0
result = {"artifacts":artifacts,"metadata":{"promptTokens":"3","generationTokens":"4"}}
runs=[]
for i in range(repeat):
    runs.append({"iteration":i+1,"runID":run_id,"request":request,"outcome":outcome,"text":text if capability=="text" else "",
                 "artifacts":artifacts,"result":result,"lifecycle":[{"memory":{"peakBytes":4321}}]})
if capability == "text": os.write(1, (text*repeat).encode("utf-8"))
else:
    for artifact in artifacts: os.write(1,(json.dumps({"type":"artifact","runID":run_id,"artifact":artifact})+"\n").encode())
report={"schemaVersion":1,"exitCode":exit_code,"options":options,"runs":runs}
if MODE == "mismatch": report["exitCode"] = 1
__import__("pathlib").Path(report_path).write_text(json.dumps(report),encoding="utf-8")
raise SystemExit(exit_code)
'''


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")


def text_case(case_id: str = "text-one", prompt: str = "Inputs/prompt.txt") -> dict:
    return {"id": case_id, "title": case_id, "model": "text", "capability": "text", "promptFile": prompt,
            "parameters": {"maxTokens": 8, "temperature": 0, "topP": .95, "maxPromptTokens": 32,
                           "maxOutputTokens": 8, "cacheLimitMiB": 0},
            "timeoutSeconds": 3, "expected": "completed", "repeatCount": 1}


class Fixture:
    def __init__(self, root: Path, *, cases: list[dict] | None = None, mode: str = "normal") -> None:
        self.root = root
        for name in ("Bin", "Runtime/AudioEngine.dengine", "Manifests", "Profiles", "Models/text", "Inputs"):
            (root / name).mkdir(parents=True, exist_ok=True)
        payload = b"model payload"
        (root / "Models/text/model.bin").write_bytes(payload)
        write_json(root / "Manifests/text.json", {"schemaVersion": 1, "revision": "a"*40,
                   "files": [{"name": "model.bin", "size": len(payload), "algorithm": "sha256",
                              "checksum": hashlib.sha256(payload).hexdigest()}]})
        write_json(root / "Manifests/catalog.json", {"schemaVersion": 1, "models": {"text": {
                   "directory": "Models/text", "manifest": "Manifests/text.json", "format": "text", "revision": "a"*40}}})
        actual_cases = cases or [text_case()]
        for case in actual_cases:
            prompt = root / case["promptFile"]
            prompt.parent.mkdir(parents=True, exist_ok=True)
            if not prompt.exists(): prompt.write_text("hello", encoding="utf-8")
        write_json(root / "Profiles/profiles.json", {"schemaVersion": 1,
                   "profiles": [{"id": "quick", "title": "Quick <safe>", "caseIDs": [c["id"] for c in actual_cases]}],
                   "cases": actual_cases})
        self.marker = root / "execution-marker"
        self.fake = root / "fake-cli"
        script = FAKE_CLI.replace("__MODE__", repr(mode)).replace("__MARKER__", repr(str(self.marker)))
        self.fake.write_text(script, encoding="utf-8")
        self.fake.chmod(0o755)
        bundled = root / "Bin/d-infer"; bundled.write_text("placeholder", encoding="utf-8"); bundled.chmod(0o755)
        write_json(root / "kit.json", {"schemaVersion": 1, "kitID": "fixture", "sourceSHA": "b"*40,
                   "buildConfiguration": "Debug", "cli": "Bin/d-infer", "engine": "Runtime/AudioEngine.dengine",
                   "catalog": "Manifests/catalog.json", "profiles": "Profiles/profiles.json",
                   "minimumMacOS": "0", "audioLicenseAcknowledged": True})

    def runner(self, fake: Path | None = None):
        return runner_module.KitRunner(self.root, test_cli=fake or self.fake,
                                       physical_memory_bytes=16*runner_module.GIB, os_version="99.0")


class RunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        temp_root = os.environ.get("D_TEST_TEMP_DIR")
        self.assertTrue(temp_root, "D_TEST_TEMP_DIR is required")
        self.temporary = tempfile.TemporaryDirectory(prefix="d-testkit-", dir=temp_root)
        self.root = Path(self.temporary.name) / "便携 包"
        self.root.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def fixture(self, **kwargs) -> Fixture:
        return Fixture(self.root, **kwargs)

    def test_preflight_and_normal_fake_cli_are_explicit_and_complete(self):
        fixture = self.fixture()
        runner = fixture.runner()
        self.assertEqual(runner.preflight()["status"], "ready")
        result = runner.run("quick")
        self.assertEqual(result["summary"]["overall"], "complete")
        case = result["summary"]["attempts"][0]["cases"][0]
        self.assertEqual(case["status"], "passed")
        self.assertEqual(case["qualityAssessment"], "pending")
        self.assertNotIn(str(self.root), json.dumps(result["summary"]))

    def test_missing_model_is_blocked(self):
        fixture = self.fixture(); (self.root / "Models/text/model.bin").unlink()
        with self.assertRaisesRegex(runner_module.KitError, "missing"):
            fixture.runner().preflight()

    def test_bad_digest_is_blocked(self):
        fixture = self.fixture(); (self.root / "Models/text/model.bin").write_bytes(b"changed")
        with self.assertRaisesRegex(runner_module.KitError, "size mismatch|digest mismatch"):
            fixture.runner().preflight()

    def test_catalog_path_escape_is_rejected(self):
        fixture = self.fixture()
        catalog = json.loads((self.root / "Manifests/catalog.json").read_text())
        catalog["models"]["text"]["directory"] = "../outside"
        write_json(self.root / "Manifests/catalog.json", catalog)
        with self.assertRaisesRegex(runner_module.KitError, "forbidden path"):
            fixture.runner()

    def test_model_symlink_is_rejected(self):
        fixture = self.fixture(); target = self.root / "real-model"; target.mkdir()
        (self.root / "Models/text").rename(self.root / "Models/original")
        (self.root / "Models/text").symlink_to(target)
        with self.assertRaisesRegex(runner_module.KitError, "symbolic link|non-symlink"):
            fixture.runner()

    def test_unknown_profile_field_is_rejected(self):
        fixture = self.fixture(); path = self.root / "Profiles/profiles.json"; value = json.loads(path.read_text())
        value["cases"][0]["command"] = "/tmp/evil"; write_json(path, value)
        with self.assertRaisesRegex(runner_module.KitError, "unknown field"):
            fixture.runner()

    def test_boolean_numeric_is_rejected(self):
        fixture = self.fixture(); path = self.root / "Profiles/profiles.json"; value = json.loads(path.read_text())
        value["cases"][0]["parameters"]["maxTokens"] = True; write_json(path, value)
        with self.assertRaisesRegex(runner_module.KitError, "out of bounds"):
            fixture.runner()

    def test_budget_rejection_does_not_execute(self):
        fixture = self.fixture(mode="blocked")
        result = fixture.runner().run("quick")
        case = result["summary"]["attempts"][0]["cases"][0]
        self.assertEqual(case["status"], "blocked_budget")
        self.assertFalse(fixture.marker.exists())

    def test_exit_report_contradiction_fails(self):
        fixture = self.fixture(mode="mismatch")
        result = fixture.runner().run("quick")
        self.assertEqual(result["summary"]["attempts"][0]["cases"][0]["status"], "failed")

    def test_timeout_force_stops_its_process_group(self):
        fixture = self.fixture(mode="sleep"); runner = fixture.runner()
        result = runner._run_process([str(fixture.fake), "--report", str(self.root/"unused")], self.root/"process", .15)
        self.assertTrue(result.timed_out, result); self.assertTrue(result.forced_stop, result); self.assertIsNotNone(result.return_code)

    def test_cancel_force_stops_its_process_group(self):
        fixture = self.fixture(mode="sleep"); runner = fixture.runner()
        result = runner._run_process([str(fixture.fake), "--report", str(self.root/"unused")], self.root/"process", 20, .15)
        self.assertTrue(result.cancellation_requested, result); self.assertTrue(result.forced_stop, result)

    def test_output_limit_stops_child(self):
        fixture = self.fixture(mode="output-limit"); runner = fixture.runner()
        result = runner._run_process([str(fixture.fake), "--report", str(self.root/"unused")], self.root/"process", 20)
        self.assertTrue(result.stdout_limited); self.assertIsNotNone(result.return_code)

    def test_resume_creates_new_attempt_and_does_not_overwrite(self):
        cases = [text_case("one", "Inputs/one.txt"), text_case("two", "Inputs/two.txt")]
        fixture = self.fixture(cases=cases, mode="normal")
        runner = fixture.runner(); first = runner.run("quick")
        run_root = self.root / "Results" / first["runID"]
        old_case = next(run_root.glob("attempts/*/cases/001-one/case.json")); old_digest = hashlib.sha256(old_case.read_bytes()).hexdigest()
        # Mark the second case incomplete without touching the first immutable evidence.
        second = next(run_root.glob("attempts/*/cases/002-two/case.json")); value = json.loads(second.read_text()); value["status"]="failed"; write_json(second,value)
        resumed = runner.run("quick", resume=first["runID"])
        self.assertNotEqual(first["attemptID"], resumed["attemptID"])
        self.assertEqual(hashlib.sha256(old_case.read_bytes()).hexdigest(), old_digest)
        self.assertEqual(resumed["summary"]["overall"], "complete")

    def test_new_run_refuses_existing_uuid(self):
        fixture = self.fixture(); runner = fixture.runner(); fixed = uuid.UUID("00000000-0000-0000-0000-000000000001")
        (self.root/"Results"/str(fixed)).mkdir(parents=True)
        with mock.patch.object(runner_module.uuid, "uuid4", return_value=fixed):
            with self.assertRaisesRegex(runner_module.KitError, "refusing to overwrite"):
                runner.run("quick")

    def test_unicode_kit_path_is_supported(self):
        fixture = self.fixture(); self.assertEqual(fixture.runner().config.raw["kitID"], "fixture")

    def test_html_is_escaped_and_export_has_no_private_logs_or_absolute_path(self):
        fixture = self.fixture(); result = fixture.runner().run("quick")
        run_root = self.root/"Results"/result["runID"]
        rendered = (run_root/"summary.html").read_text(encoding="utf-8")
        self.assertIn("Quick", rendered if "Quick" in rendered else "Quick")
        self.assertNotIn("<safe>", rendered)
        with zipfile.ZipFile(run_root/"summary.zip") as archive:
            names = archive.namelist(); self.assertFalse(any("private" in name for name in names))
            joined = b"".join(archive.read(name) for name in names if name.endswith((".json",".html")))
            self.assertNotIn(str(self.root).encode(), joined)

    def test_damaged_png_and_dimensions_are_rejected(self):
        root = self.root/"artifacts"; root.mkdir(); path=root/"bad.png"; path.write_bytes(b"not png")
        reference={"url":path.resolve().as_uri(),"mediaType":"image/png"}
        with self.assertRaisesRegex(runner_module.KitError, "PNG"):
            runner_module._validate_png_reference(reference, root, 512, 512)

    def test_damaged_wav_and_nonfinite_samples_are_rejected(self):
        root=self.root/"artifacts"; root.mkdir(); path=root/"bad.wav"; path.write_bytes(b"RIFF")
        reference={"url":path.resolve().as_uri(),"mediaType":"audio/wav"}
        with self.assertRaisesRegex(runner_module.KitError, "WAV"):
            runner_module._validate_wav_reference(reference, root, 1, None, {"audioOperation":"generate"})

    def test_double_start_lock_is_rejected(self):
        fixture=self.fixture(); runner=fixture.runner(); results=self.root/"Results"; results.mkdir(); lock=(results/".d-testkit.lock").open("a+b")
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX|fcntl.LOCK_NB)
            with self.assertRaisesRegex(runner_module.KitError, "active"):
                runner.run("quick")
        finally:
            lock.close()

    def test_git_blob_digest_includes_header(self):
        fixture=self.fixture(); path=self.root/"Models/text/model.bin"; size=path.stat().st_size
        expected=hashlib.sha1(f"blob {size}\0".encode()+path.read_bytes(), usedforsecurity=False).hexdigest()
        manifest=json.loads((self.root/"Manifests/text.json").read_text()); entry=manifest["files"][0]
        entry["algorithm"]="git-blob-sha1"; entry["checksum"]=expected; write_json(self.root/"Manifests/text.json",manifest)
        self.assertEqual(fixture.runner().preflight()["models"][0]["files"][0]["digest"], expected)

    def test_image_manifest_uses_revision2_path_sha256_shape(self):
        fixture=self.fixture(); catalog=json.loads((self.root/"Manifests/catalog.json").read_text())
        catalog["models"]["text"]["format"]="image"; write_json(self.root/"Manifests/catalog.json",catalog)
        manifest=json.loads((self.root/"Manifests/text.json").read_text()); old=manifest["files"][0]
        manifest["files"]=[{"path":old["name"],"size":old["size"],"sha256":old["checksum"]}]
        write_json(self.root/"Manifests/text.json",manifest)
        # Catalog/model parsing succeeds; the original text case then correctly rejects the capability mismatch.
        with self.assertRaisesRegex(runner_module.KitError, "capability differs"):
            fixture.runner()

    def test_result_path_escape_is_rejected(self):
        fixture=self.fixture(); runner=fixture.runner(); outside=self.root.parent/"outside.png"; outside.write_bytes(b"x")
        with self.assertRaisesRegex(runner_module.KitError, "escapes"):
            runner_module._artifact_path({"url":outside.resolve().as_uri(),"mediaType":"image/png"}, self.root, "image/png")


if __name__ == "__main__":
    unittest.main()
