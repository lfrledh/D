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
LOG = __LOG__
args = sys.argv[1:]
def value(name, default=None):
    return args[args.index(name)+1] if name in args else default
report_path = value("--report")
capability = value("--capability", "text")
model = value("--model")
revision = value("--revision")
repeat = int(value("--repeat", "1"))
options = {"capability": capability, "model": model, "revision": revision, "repeatCount": repeat}
prompt_path=value("--prompt-file")
options["prompt"] = __import__("pathlib").Path(prompt_path).read_text(encoding="utf-8") if prompt_path else ""
options["memoryBudgetMiB"] = int(value("--memory-budget-mib", "1"))
mapping = {"--max-tokens":("maxTokens",int),"--temperature":("temperature",float),"--top-p":("topP",float),
 "--max-prompt-tokens":("maxPromptTokens",int),"--max-output-tokens":("maxOutputTokens",int),
 "--cache-limit-mib":("cacheLimitMiB",int),"--width":("width",int),"--height":("height",int),
 "--steps":("steps",int),"--guidance":("guidance",float),"--seed":("seed",int),
 "--image-profile":("imageProfile",str),"--image-memory-limit-mib":("imageMemoryLimitMiB",int),
 "--audio-operation":("audioOperation",str),"--duration-seconds":("durationSeconds",float),
 "--audio-strength":("audioStrength",float),"--audio-edit-start-frame":("audioEditStartFrame",int),
 "--audio-edit-end-frame":("audioEditEndFrame",int),"--audio-profile":("audioProfile",str),
 "--timeout-seconds":("timeoutSeconds",float),"--audio-source":("audioSource",str),
 "--audio-source-sha256":("audioSourceSHA256",str),"--audio-source-frames":("audioSourceFrames",int)}
for flag,(name,convert) in mapping.items(): options[name]=convert(value(flag)) if flag in args else None
if MODE == "wrong-parameter" and options.get("maxTokens") is not None: options["maxTokens"] += 1
backend={"id":"fake."+capability,"version":"1","capabilities":[]}
if "--inspect" in args:
    if LOG: open(LOG,"a",encoding="utf-8").write("inspect "+" ".join(args)+"\n")
    peak = options["memoryBudgetMiB"]*1024*1024+1 if MODE == "blocked" else 1234
    report = {"schemaVersion":True if MODE=="bool-inspect" else 1,"tool":"d-infer","exitCode":False if MODE=="bool-inspect" else 0,"options":options,"backend":backend,"runs":[],
              "inspection":{"estimate":{"peakBytes":peak,"confidence":"estimated"},
                            "withinBudget": MODE not in ("blocked","dishonest-inspect")}}
    Path = __import__("pathlib").Path
    Path(report_path).write_text(json.dumps(report), encoding="utf-8")
    raise SystemExit(0)
if MODE == "sleep":
    signal.signal(signal.SIGINT, signal.SIG_IGN); signal.signal(signal.SIGTERM, signal.SIG_IGN)
if MARKER:
    open(MARKER, "a", encoding="utf-8").write("executed\n")
if MODE == "sleep":
    time.sleep(30)
if MODE == "output-limit":
    os.write(1, b"x" * (17 * 1024 * 1024)); time.sleep(30)
run_id = str(uuid.uuid4())
p=options
if capability=="text": input_value={"prompt":p["prompt"],"maxTokens":p["maxTokens"],"temperature":p["temperature"],"topP":p["topP"]}
elif capability=="image": input_value={"prompt":p["prompt"],"width":p["width"],"height":p["height"],"steps":p["steps"],"guidanceScale":p["guidance"],"seed":p["seed"]}
else:
    source=None
    if "--audio-source" in args: source={"url":__import__("pathlib").Path(value("--audio-source")).resolve().as_uri(),"sha256":value("--audio-source-sha256"),"frameCount":int(value("--audio-source-frames")),"sampleRate":44100,"channels":2}
    input_value={"prompt":p["prompt"],"durationSeconds":p["durationSeconds"],"steps":p["steps"],"guidanceScale":p["guidance"],"seed":p["seed"],"strength":p["audioStrength"],"operation":p["audioOperation"],"source":source}
request = {"id":run_id,"model":{"directory":__import__("pathlib").Path(model).resolve().as_uri(),"revision":revision},"input":{capability:{"_0":input_value}}}
if MODE in ("graceful-cancel", "audio-cancel", "audio-cancel-unknown-error"):
    def stop(sig, frame):
        run={"iteration":1,"runID":run_id,"startedAt":"2026-01-01T00:00:00Z","request":request,"outcome":"cancelled",
             "text":"","artifacts":[],"elapsedSeconds":.2,"progress":[],"lifecycle":[
             {"runID":run_id,"phase":"drained","uptimeSeconds":1,"memory":{"activeBytes":1,"cacheBytes":0,"peakBytes":10}},
             {"runID":run_id,"phase":"released","uptimeSeconds":2,"memory":{"activeBytes":0,"cacheBytes":0,"peakBytes":10}}]}
        if capability == "audio":
            run.update(lifecycle=[], cancellationRequestedSeconds=.1, cancellationLatencySeconds=.1,
                       streamError="The operation couldn’t be completed. (Swift.CancellationError error 1.)"
                       if MODE == "audio-cancel" else "Unexpected provider failure")
        __import__("pathlib").Path(report_path).write_text(json.dumps({"schemaVersion":1,"tool":"d-infer","backend":backend,
          "exitCode":130,"terminationSignal":2,"options":options,"runs":[run],"elapsedSeconds":.2}),encoding="utf-8")
        if capability == "text": os.write(1, b"\n")
        raise SystemExit(130)
    signal.signal(signal.SIGINT, stop)
    if MARKER: open(MARKER,"a",encoding="utf-8").write("ready\n")
    while True: time.sleep(.1)
artifacts = []
text = "模拟输出✅"
if MODE == "text-trailing-newline": text += "\n"
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
    data = b"\0" * (frames * 8)
    fmt=struct.pack("<HHIIHH",3,2,44100,352800,8,32)
    raw=b"RIFF"+struct.pack("<I",4+8+len(fmt)+8+len(data))+b"WAVE"+b"fmt "+struct.pack("<I",len(fmt))+fmt+b"data"+struct.pack("<I",len(data))+data
    path=root/"audio.wav"; path.write_bytes(raw)
    artifacts=[{"url":path.resolve().as_uri(),"mediaType":"audio/wav"}]
if MODE == "missing-artifact": artifacts=[]
outcome = "failed" if MODE == "failed" or (MODE == "fail-edit" and options.get("audioOperation") in ("variation","inpaint")) else "completed"
exit_code = 1 if outcome == "failed" else 0
result = {"artifacts":artifacts,"metadata":{"promptTokens":"3","generationTokens":"4","promptSeconds":"0.01",
          "generationSeconds":"0.02","randomSeed":"42","modelRevision":revision}}
if capability=="audio" and outcome=="completed" and artifacts:
    provider_path=root/"result.json"
    provider={"schemaVersion":1,"type":"result","runID":run_id.lower(),"artifact":{"path":str(path.resolve()),
      "sha256":__import__("hashlib").sha256(raw).hexdigest(),"byteCount":len(raw),"frameCount":frames,
      "sampleRate":44100,"channels":2,"encoding":"float32"},"metadata":{"request":{"schemaVersion":1,
      "runID":run_id.lower(),"prompt":p["prompt"],"durationSeconds":p["durationSeconds"],"guidanceScale":p["guidance"],
      "operation":p["audioOperation"],"seed":p["seed"],"steps":p["steps"],"strength":p["audioStrength"],
      **({"source":{"sha256":source["sha256"],"frameCount":source["frameCount"],"sampleRate":44100,"channels":2}} if source else {})},
      "profile":p["audioProfile"],"modelRevision":revision,"vendorRevision":"c"*40,
      "precision":{"dit":"float16","text":"float16","encoder":"float32","decoder":"float32","master":"float32"},
      "timingsSeconds":{"encodingText":.1,"denoising":.2,"decoding":.1,"publishing":.01},
      "mlxAllocations":{"measurementKind":"mlx-allocator","measurementPhase":"afterDecodeBeforeFinalCleanup",
       "activeBytes":12,"cacheBytes":3,"peakBytes":99,"observedActiveLowerBoundBytes":12,"cleanupStatus":"completed",
       "postCleanup":{"measurementKind":"mlx-allocator","measurementPhase":"afterFinalCleanup","activeBytes":1,
       "cacheBytes":0,"peakBytes":99,"observedActiveLowerBoundBytes":1}}}}
    provider_path.write_text(json.dumps(provider),encoding="utf-8")
    result={"artifacts":artifacts,"metadata":{"modelRevision":revision,"profile":p["audioProfile"],
      "precision":"dit=float16,text=float16,encoder=float32,decoder=float32,master=float32","recordPath":str(provider_path.resolve())}}
runs=[]
for i in range(repeat):
    runs.append({"iteration":i+1,"runID":run_id,"startedAt":"2026-01-01T00:00:00Z","request":request,
                 "outcome":outcome,"text":text if capability=="text" else "","artifacts":artifacts,"result":result,
                 "elapsedSeconds":.1,"firstChunkSeconds":.01 if capability=="text" else None,
                 "firstProgressSeconds":.02 if capability!="text" else None,"firstArtifactSeconds":.08 if artifacts else None,
                 "progress":[],"lifecycle":[] if capability=="audio" else [{"runID":run_id,"phase":"drained","uptimeSeconds":1,"memory":{"activeBytes":1,"cacheBytes":0,"peakBytes":4321}},
                                            {"runID":run_id,"phase":"released","uptimeSeconds":2,"memory":{"activeBytes":0,"cacheBytes":0,"peakBytes":4321}}]})
if capability == "text":
    framed = (text+"\n")*repeat
    if MODE == "missing-frame": framed = framed[:-1]
    if MODE == "extra-frame": framed += "\n"
    os.write(1, framed.encode("utf-8"))
else:
    for artifact in artifacts: os.write(1,(json.dumps({"type":"wrong" if MODE=="invalid-artifact-line" else "artifact","runID":run_id,"artifact":artifact})+"\n").encode())
report={"schemaVersion":1,"tool":"d-infer","backend":backend,"exitCode":exit_code,"options":options,"runs":runs,"elapsedSeconds":.2}
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
        self.log = root / "fake-cli.log"
        self.fake = root / "fake-cli"
        script = FAKE_CLI.replace("#!/usr/bin/python3", f"#!{sys.executable}", 1).replace("__MODE__", repr(mode)).replace("__MARKER__", repr(str(self.marker))).replace("__LOG__", repr(str(self.log)))
        self.fake.write_text(script, encoding="utf-8")
        self.fake.chmod(0o755)
        bundled = root / "Bin/d-infer"; bundled.write_text("placeholder", encoding="utf-8"); bundled.chmod(0o755)
        write_json(root / "kit.json", {"schemaVersion": 1, "kitID": "fixture", "sourceSHA": "b"*40,
                   "buildConfiguration": "Debug", "cli": "Bin/d-infer", "engine": "Runtime/AudioEngine.dengine",
                   "catalog": "Manifests/catalog.json", "profiles": "Profiles/profiles.json",
                   "minimumMacOS": "0", "audioLicenseAcknowledged": True})

    def configure_image(self) -> None:
        catalog=json.loads((self.root/"Manifests/catalog.json").read_text()); catalog["models"]["text"]["format"]="image"
        write_json(self.root/"Manifests/catalog.json",catalog)
        manifest=json.loads((self.root/"Manifests/text.json").read_text()); old=manifest["files"][0]
        manifest["files"]=[{"path":old["name"],"size":old["size"],"sha256":old["checksum"]}]; write_json(self.root/"Manifests/text.json",manifest)
        case={"id":"image","title":"image","model":"text","capability":"image","promptFile":"Inputs/prompt.txt",
              "parameters":{"width":256,"height":256,"steps":4,"guidance":1,"seed":"18446744073709551615","imageProfile":"scalableKlein4B"},
              "timeoutSeconds":5,"expected":"completed","repeatCount":1}
        write_json(self.root/"Profiles/profiles.json",{"schemaVersion":1,"profiles":[{"id":"quick","title":"image","caseIDs":["image"]}],"cases":[case]})

    def configure_audio(self, mode: str = "normal") -> None:
        catalog=json.loads((self.root/"Manifests/catalog.json").read_text()); item=catalog["models"]["text"]
        item["format"]="audio"; item["audioProfile"]="sm-music"; write_json(self.root/"Manifests/catalog.json",catalog)
        manifest=json.loads((self.root/"Manifests/text.json").read_text()); old=manifest["files"][0]
        manifest["files"]=[{"path":old["name"],"size":old["size"],"sha256":old["checksum"]}]; write_json(self.root/"Manifests/text.json",manifest)
        engine=self.root/"Runtime/AudioEngine.dengine"; files=[]
        for relative,data,executable in (("python/bin/python3",b"python",True),("provider/d_audio_backend.py",b"provider",False)):
            path=engine/relative; path.parent.mkdir(parents=True,exist_ok=True); path.write_bytes(data); path.chmod(0o755 if executable else 0o644)
            files.append({"path":relative,"sizeBytes":len(data),"sha256":hashlib.sha256(data).hexdigest(),"executable":executable})
        (engine/"vendor").mkdir(); (engine/"model-manifests").mkdir()
        write_json(engine/"engine.json",{"schemaVersion":1,"kind":"d-audio-engine","pythonABI":"3.12",
          "pythonExecutable":"python/bin/python3","providerScript":"provider/d_audio_backend.py","vendorDirectory":"vendor",
          "modelManifestsDirectory":"model-manifests","files":files})
        base={"durationSeconds":1,"steps":8,"guidance":1,"seed":"42","audioOperation":"generate","audioStrength":1}
        generate={"id":"source","title":"source","model":"text","capability":"audio","promptFile":"Inputs/prompt.txt",
          "parameters":base,"timeoutSeconds":6,"expected":"completed","repeatCount":1}
        edit={"id":"edit","title":"edit","model":"text","capability":"audio","promptFile":"Inputs/prompt.txt",
          "parameters":dict(base,audioOperation="variation",audioStrength=.5),"timeoutSeconds":6,"expected":"completed","repeatCount":1,"sourceCase":"source"}
        write_json(self.root/"Profiles/profiles.json",{"schemaVersion":1,"profiles":[{"id":"quick","title":"audio","caseIDs":["source","edit"]}],"cases":[generate,edit]})

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

    def audio_cancel_case(self, mode):
        fixture = self.fixture(mode=mode)
        fixture.configure_audio()
        path = self.root / "Profiles/profiles.json"
        profiles = json.loads(path.read_text())
        profiles["profiles"][0]["caseIDs"] = ["source"]
        profiles["cases"] = profiles["cases"][:1]
        profiles["cases"][0].update(expected="cancelled", cancelAfterSeconds=.3)
        write_json(path, profiles)
        return fixture.runner().run("quick")["summary"]["attempts"][0]["cases"][0]

    def test_audio_cancellation_stream_error_matches_formal_cli(self):
        case = self.audio_cancel_case("audio-cancel")
        self.assertEqual(case["status"], "passed", case.get("message"))
        self.assertIn("Swift.CancellationError", case["runs"][0]["streamError"])

    def test_audio_cancellation_does_not_hide_unrelated_stream_error(self):
        case = self.audio_cancel_case("audio-cancel-unknown-error")
        self.assertEqual(case["status"], "failed")

    def test_relocated_results_can_be_resummarized_without_old_absolute_paths(self):
        fixture = self.fixture()
        result = fixture.runner().run("quick")
        original = str(self.root)
        moved = self.root.with_name("另一台 Mac 的测试包")
        self.root.rename(moved)
        runner = runner_module.KitRunner(moved, test_cli=moved / "fake-cli",
                                         physical_memory_bytes=16*runner_module.GIB, os_version="99.0")
        summary = runner.summarize(result["runID"])
        self.assertNotIn(original, json.dumps(summary, ensure_ascii=False))
        self.assertEqual(summary["overall"], "complete")

    def test_formal_framing_preserves_generated_trailing_newline(self):
        fixture = self.fixture(mode="text-trailing-newline")
        result = fixture.runner().run("quick")
        attempt = result["summary"]["attempts"][0]
        self.assertEqual(result["summary"]["overall"], "complete")
        artifact = attempt["cases"][0]["artifacts"][0]
        text = (self.root / "Results" / result["runID"] / artifact["path"]).read_text()
        self.assertEqual(text, "模拟输出✅\n\n")
        checked = attempt["preflight"]["models"][0]["files"][0]
        self.assertEqual(checked["digest"], hashlib.sha256(b"model payload").hexdigest())

    def test_missing_cli_framing_is_not_silently_accepted(self):
        result = self.fixture(mode="missing-frame").runner().run("quick")
        self.assertEqual(result["summary"]["attempts"][0]["cases"][0]["status"], "failed")

    def test_extra_stdout_is_not_silently_stripped(self):
        result = self.fixture(mode="extra-frame").runner().run("quick")
        self.assertEqual(result["summary"]["attempts"][0]["cases"][0]["status"], "failed")

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

    def test_normal_image_simulation_is_structurally_valid(self):
        fixture=self.fixture(); fixture.configure_image(); result=fixture.runner().run("quick")
        artifact=result["summary"]["attempts"][0]["cases"][0]["artifacts"][0]
        self.assertEqual((artifact["width"],artifact["height"]),(256,256))

    def test_completed_image_requires_one_valid_artifact_line(self):
        fixture=self.fixture(mode="missing-artifact"); fixture.configure_image(); result=fixture.runner().run("quick")
        self.assertEqual(result["summary"]["attempts"][0]["cases"][0]["status"],"failed")
        self.temporary.cleanup(); self.temporary=tempfile.TemporaryDirectory(prefix="d-testkit-",dir=os.environ["D_TEST_TEMP_DIR"])
        self.root=Path(self.temporary.name)/"second"; self.root.mkdir(); fixture=Fixture(self.root,mode="invalid-artifact-line"); fixture.configure_image()
        result=fixture.runner().run("quick"); self.assertEqual(result["summary"]["attempts"][0]["cases"][0]["status"],"failed")

    def test_audio_edit_inspection_receives_same_attempt_source(self):
        fixture=self.fixture(); fixture.configure_audio(); result=fixture.runner().run("quick")
        self.assertEqual(result["summary"]["overall"],"complete")
        inspect_lines=[line for line in fixture.log.read_text().splitlines() if "--inspect" in line]
        self.assertEqual(len(inspect_lines),2); self.assertIn("--audio-source",inspect_lines[1])
        source_case=next((self.root/"Results"/result["runID"]).glob("attempts/*/cases/001-source/case.json"))
        raw=json.loads(source_case.read_text()); self.assertEqual(raw["runs"][0]["lifecycle"],[])
        self.assertEqual(raw["memoryMeasurement"]["source"],"provider")
        self.assertEqual(raw["audioProviderRecords"][0]["mlxAllocations"]["postCleanup"]["activeBytes"],1)
        self.assertFalse(Path(raw["sourceForDependents"]["path"]).is_absolute())

    def test_audio_resume_reruns_source_in_same_attempt(self):
        fixture=self.fixture(mode="fail-edit"); fixture.configure_audio(); runner=fixture.runner(); first=runner.run("quick")
        run_root=self.root/"Results"/first["runID"]; old_attempt=run_root/"attempts"/first["attemptID"]; old_hash=hashlib.sha256((old_attempt/"attempt.json").read_bytes()).hexdigest()
        normal=self.root/"normal-cli"; normal.write_text(FAKE_CLI.replace("#!/usr/bin/python3",f"#!{sys.executable}",1).replace("__MODE__",repr("normal")).replace("__MARKER__",repr(str(fixture.marker))).replace("__LOG__",repr(str(fixture.log))),encoding="utf-8"); normal.chmod(0o755)
        runner._test_cli=normal; resumed=runner.run("quick",resume=first["runID"])
        new_attempt=json.loads((run_root/"attempts"/resumed["attemptID"]/"attempt.json").read_text())
        self.assertEqual(new_attempt["selectedCaseIDs"],["source","edit"]); self.assertEqual(new_attempt["lineage"][0]["policy"],"same-attempt-rerun")
        self.assertEqual(hashlib.sha256((old_attempt/"attempt.json").read_bytes()).hexdigest(),old_hash)

    def test_graceful_expected_cancellation_passes_without_force(self):
        case=text_case(); case["expected"]="cancelled"; case["cancelAfterSeconds"]=2
        fixture=self.fixture(cases=[case],mode="graceful-cancel"); result=fixture.runner().run("quick")
        observed=result["summary"]["attempts"][0]["cases"][0]
        self.assertEqual(observed["status"],"passed"); self.assertFalse(observed["publicProcess"]["forcedStop"])

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

    def test_inspection_rejects_boolean_schema_and_dishonest_budget(self):
        fixture=self.fixture(mode="bool-inspect"); result=fixture.runner().run("quick")
        self.assertEqual(result["summary"]["attempts"][0]["cases"][0]["status"],"failed")
        self.temporary.cleanup(); self.temporary=tempfile.TemporaryDirectory(prefix="d-testkit-",dir=os.environ["D_TEST_TEMP_DIR"])
        self.root=Path(self.temporary.name)/"dishonest"; self.root.mkdir(); fixture=Fixture(self.root,mode="dishonest-inspect")
        result=fixture.runner().run("quick"); self.assertEqual(result["summary"]["attempts"][0]["cases"][0]["status"],"failed")

    def test_exit_report_contradiction_fails(self):
        fixture = self.fixture(mode="mismatch")
        result = fixture.runner().run("quick")
        self.assertEqual(result["summary"]["attempts"][0]["cases"][0]["status"], "failed")

    def test_wrong_actual_parameter_is_rejected(self):
        fixture = self.fixture(mode="wrong-parameter")
        result = fixture.runner().run("quick")
        self.assertEqual(result["summary"]["attempts"][0]["cases"][0]["status"], "failed")

    def test_timeout_force_stops_its_process_group(self):
        fixture = self.fixture(mode="sleep"); runner = fixture.runner()
        with mock.patch.object(runner_module, "INTERRUPT_GRACE_SECONDS", .1), mock.patch.object(runner_module, "TERM_GRACE_SECONDS", .1):
            result = runner._run_process([str(fixture.fake), "--report", str(self.root/"unused")], self.root/"process", .01,
                                         _test_ready=fixture.marker)
        self.assertTrue(result.timed_out, result); self.assertTrue(result.forced_stop, result); self.assertIsNotNone(result.return_code)

    def test_cancel_force_stops_its_process_group(self):
        fixture = self.fixture(mode="sleep"); runner = fixture.runner()
        with mock.patch.object(runner_module, "INTERRUPT_GRACE_SECONDS", .1), mock.patch.object(runner_module, "TERM_GRACE_SECONDS", .1):
            result = runner._run_process([str(fixture.fake), "--report", str(self.root/"unused")], self.root/"process", 20, .01,
                                         _test_ready=fixture.marker)
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
        self.assertIn("Quick &lt;safe&gt;", rendered)
        self.assertNotIn("<safe>", rendered)
        with zipfile.ZipFile(run_root/"summary.zip") as archive:
            names = archive.namelist(); self.assertFalse(any("private" in name for name in names))
            joined = b"".join(archive.read(name) for name in names if name.endswith((".json",".html")))
            self.assertNotIn(str(self.root).encode(), joined)

    def test_results_symlink_is_rejected_without_touching_sentinel(self):
        fixture = self.fixture(); outside = self.root.parent / "outside-results"; outside.mkdir()
        sentinel = outside / "sentinel"; sentinel.write_text("keep", encoding="utf-8")
        (self.root / "Results").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(runner_module.KitError, "symbolic link"):
            fixture.runner().run("quick")
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")

    def test_export_rejects_altered_public_artifact(self):
        fixture = self.fixture(); runner = fixture.runner(); result = runner.run("quick")
        run_root = self.root / "Results" / result["runID"]
        artifact = result["summary"]["attempts"][0]["cases"][0]["artifacts"][0]
        (run_root / artifact["path"]).write_bytes(b"altered")
        with self.assertRaisesRegex(runner_module.KitError, "changed"):
            runner.summarize(result["runID"])

    def test_summary_rejects_duplicate_attempt_and_missing_models_do_not_block_valid_summary(self):
        fixture = self.fixture(); runner = fixture.runner(); result = runner.run("quick")
        run_root = self.root / "Results" / result["runID"]
        (self.root / "Models/text/model.bin").unlink(); (self.root / "Models/text").rmdir()
        self.assertEqual(fixture.runner().summarize(result["runID"])["overall"], "complete")
        run_path = run_root / "run.json"; run = json.loads(run_path.read_text()); run["attempts"].append(dict(run["attempts"][0])); write_json(run_path, run)
        with self.assertRaisesRegex(runner_module.KitError, "duplicate attempt"):
            fixture.runner().summarize(result["runID"])
        run["attempts"].pop(); run["schemaVersion"]=True; write_json(run_path,run)
        with self.assertRaisesRegex(runner_module.KitError, "invalid run"):
            fixture.runner().summarize(result["runID"])

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
