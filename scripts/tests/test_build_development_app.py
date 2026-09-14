#!/usr/bin/env python3
"""Synthetic CPU-only tests for build-development-app orchestration."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from unittest import mock


REPOSITORY = Path(__file__).resolve().parents[2]
TARGET = REPOSITORY / "scripts/build-development-app.py"
BUILD_LOCAL = REPOSITORY / "scripts/build-local.sh"
INTERPRETER = Path(os.environ.get("D_MB_TEST_PYTHON", os.sys.executable))
SOURCE_HEAD = "a" * 40
PIN_REVISION = "b" * 40
IDENTITY = "c" * 40
TOKENIZER_CONTENTS = {
    "special_tokens_map.json": b"synthetic-special-tokens\n",
    "spiece.model": b"synthetic-spiece\n",
    "tokenizer.json": b"synthetic-tokenizer\n",
    "tokenizer_config.json": b"synthetic-tokenizer-config\n",
}
TOKENIZER_DIGESTS = {name: hashlib.sha256(value).hexdigest() for name, value in TOKENIZER_CONTENTS.items()}


FAKE_BUILD_LOCAL = r'''#!/bin/bash
set -euo pipefail
printf 'build-local\n' >> "$FAKE_TRACE"
derived=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --derived-data-path) derived="$2"; shift 2 ;;
    --source-packages-path|--log-path) shift 2 ;;
    --offline) shift ;;
    *) exit 90 ;;
  esac
done
if [[ "${FAKE_STAGE:-}" == "build-fail" ]]; then exit 11; fi
if [[ "${FAKE_STAGE:-}" == "timeout" || "${FAKE_STAGE:-}" == "cancel" || "${FAKE_STAGE:-}" == "repeat-cancel" ]]; then
  "$FAKE_NATIVE_PYTHON" -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)' &
  child=$!
  printf '%s\n' "$child" > "$FAKE_CHILD_PID"
  wait "$child"
fi
if [[ "${FAKE_STAGE:-}" == "leader-first" || "${FAKE_STAGE:-}" == "held-pipes" ]]; then
  "$FAKE_NATIVE_PYTHON" -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)' &
  child=$!
  printf '%s\n' "$child" > "$FAKE_CHILD_PID"
  exit 0
fi
if [[ "${FAKE_STAGE:-}" != "missing-build-output" ]]; then
  mkdir -p "$derived/Build/Products/Debug/D.app/Contents/Resources"
fi
'''


FAKE_PACKAGER = """#!/usr/bin/env python3
TOKENIZER_DIGESTS = %r
REQUIRED_DISTRIBUTIONS = {"mlx": "0.31.1", "mlx-metal": "0.31.1", "numpy": "2.4.3", "tokenizers": "0.22.2", "ftfy": "6.3.1", "wcwidth": "0.8.3"}
REQUIRED_PACKAGES = ("mlx", "numpy", "tokenizers", "ftfy", "wcwidth")
VIDEO_SCRIPTS = ("d_video_run.py", "d_video_model.py", "d_video_prepare.py")
MODEL_DECLARATION = "wan21.json"
TOKENIZERS_LICENSE_SHA256 = %r
""" % (TOKENIZER_DIGESTS, hashlib.sha256(b"synthetic-tokenizers-license\n").hexdigest()) + r'''
import argparse
import json
import os
from pathlib import Path
import shutil
import sys

name = Path(__file__).name
trace = Path(os.environ["FAKE_TRACE"])

def manifest(kind):
    return {"schemaVersion": 1, "kind": kind, "files": []}

def write_manifest(root, engine, kind):
    target = root / "Contents/Resources" / engine
    target.mkdir(parents=True, exist_ok=True)
    (target / "engine.json").write_text(json.dumps(manifest(kind)) + "\n", encoding="utf-8")

if name == "package_audio_app.py":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--python-root", required=True)
    parser.add_argument("--sa3-site-packages", required=True)
    parser.add_argument("--mrt2-site-packages", required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    with trace.open("a", encoding="utf-8") as handle: handle.write("package-audio-app\n")
    if os.environ.get("FAKE_STAGE") == "audio-fail": sys.exit(12)
    if os.environ.get("USE_SHARED_HELPER") == "1":
        sys.path.insert(0, os.environ["REAL_AUDIO_PACKAGING"])
        import package_audio_app as shared
        shared._run_command([os.environ["FAKE_NATIVE_COMMAND"]], timeout=1)
    output = Path(args.output)
    output.mkdir()
    write_manifest(output, "AudioEngine.dengine", "d-audio-engine")
    write_manifest(output, "MRT2MusicEngine.dengine", "d-mrt2-engine")
    print(json.dumps({"status": "packaged", "output": str(output), "engines": ["AudioEngine.dengine", "MRT2MusicEngine.dengine"], "runtimeVerification": "not-run"}))
elif name == "prepare_video_engine.py":
    parser = argparse.ArgumentParser()
    for option in ("python-root", "site-packages", "video-root", "audio-provider-directory", "tokenizer", "output"):
        parser.add_argument("--" + option, required=True)
    args = parser.parse_args()
    with trace.open("a", encoding="utf-8") as handle: handle.write("prepare-video-engine\n")
    if os.environ.get("FAKE_STAGE") == "video-prepare-fail": sys.exit(13)
    output = Path(args.output)
    output.mkdir()
    (output / "engine.json").write_text(json.dumps(manifest("d-video-engine")) + "\n", encoding="utf-8")
else:
    parser = argparse.ArgumentParser()
    for option in ("app", "engine", "identity", "output", "report"):
        parser.add_argument("--" + option, required=True)
    args = parser.parse_args()
    with trace.open("a", encoding="utf-8") as handle: handle.write("package-video-app\n")
    if os.environ.get("FAKE_STAGE") == "video-package-fail": sys.exit(14)
    output = Path(args.output)
    output.mkdir()
    for engine, kind in (("AudioEngine.dengine", "d-audio-engine"), ("MRT2MusicEngine.dengine", "d-mrt2-engine"), ("VideoEngine.dengine", "d-video-engine")):
        write_manifest(output, engine, kind)
    report = {"status": "packaged", "output": str(output), "engine": "VideoEngine.dengine", "runtimeVerification": "not-run"}
    Path(args.report).write_text(json.dumps(report) + "\n", encoding="utf-8")
    mutation = os.environ.get("MUTATE_SOURCE_PATH")
    if mutation:
        Path(mutation).write_text("changed during packaging\n", encoding="utf-8")
    if os.environ.get("MAKE_REPORT_DIRECTORY_READ_ONLY") == "1":
        Path(args.report).parent.chmod(0o500)
    if os.environ.get("COLLIDE_WRAPPER_REPORT") == "1":
        (output.parents[1] / "evidence/build-development-report.json").mkdir()
    print(json.dumps(report))
'''


FAKE_GIT = f'''#!/bin/bash
case "$*" in
  *"checkouts/dependency rev-parse --git-dir"*) printf '%s\\n' "${{FAKE_GIT_DIR:-.git}}" ;;
  *"checkouts/dependency rev-parse --git-common-dir"*) printf '%s\\n' "${{FAKE_COMMON_DIR:-.git}}" ;;
  *"checkouts/dependency status --porcelain=v1 -z --untracked-files=all"*)
    if [[ -n "${{FAKE_CHECKOUT_DIRTY:-}}" ]]; then printf ' M dirty\\0'; fi ;;
  *"checkouts/dependency rev-parse HEAD"*) printf '{PIN_REVISION}\\n' ;;
  *"rev-parse HEAD"*) printf '{SOURCE_HEAD}\\n' ;;
  *"status --porcelain=v1 -z --untracked-files=all"*)
    if [[ -n "${{FAKE_TRACKED:-}}" ]]; then printf ' M %s\\0' "$FAKE_TRACKED"; fi
    if [[ -n "${{FAKE_UNTRACKED:-}}" ]]; then printf '?? %s\\0' "$FAKE_UNTRACKED"; fi ;;
  *"ls-files -s -z"*)
    if [[ -n "${{FAKE_TRACKED:-}}" ]]; then printf '100644 {PIN_REVISION} 0\\t%s\\0' "$FAKE_TRACKED"; fi ;;
  *"diff --name-only -z --no-ext-diff"*)
    if [[ -n "${{FAKE_TRACKED:-}}" ]]; then printf '%s\\0' "$FAKE_TRACKED"; fi ;;
  *"ls-files --others --exclude-standard -z"*)
    if [[ -n "${{FAKE_UNTRACKED:-}}" ]]; then printf '%s\\0' "$FAKE_UNTRACKED"; fi ;;
  *"--version"*) printf 'git version synthetic\\n' ;;
  *) printf 'unexpected fake git arguments: %s\\n' "$*" >&2; exit 81 ;;
esac
'''


FAKE_XCODEBUILD = '''#!/bin/bash
if [[ "$*" == "-version" ]]; then
  printf 'Xcode synthetic\nBuild version synthetic\n'
else
  exit 82
fi
'''

FAKE_PREPARE_ENGINE = '''#!/usr/bin/env python3
REQUIRED_PACKAGES = ("mlx", "numpy", "sentencepiece")
REQUIRED_DISTRIBUTIONS = ("mlx", "mlx_metal", "numpy", "sentencepiece")
'''

FAKE_PREPARE_MRT2 = '''#!/usr/bin/env python3
DISTRIBUTIONS = {"mlx": "0.31.1", "mlx_metal": "0.31.1", "numpy": "2.3.5", "sentencepiece": "0.2.2", "ai_edge_litert": "2.2.0"}
PACKAGES = ("mlx", "numpy", "sentencepiece", "ai_edge_litert")
PROVIDERS = ("d_audio_mrt2_backend.py", "d_audio_mrt2_contract.py", "d_mrt2_export.py", "d_audio_access.py", "d_audio_contract.py")
'''


def _write_executable(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def _digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _tree_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        if path.is_file() and not path.is_symlink():
            digest.update(path.read_bytes())
    return digest.hexdigest()


def _load_coordinator(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load coordinator test target: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _actual_git(arguments: list[str], *, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment.update({
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0",
    })
    return subprocess.run(
        ["/Applications/Xcode.app/Contents/Developer/usr/bin/git", *arguments],
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
        timeout=10,
        env=environment,
    )


class _FailingReportFile:
    def __init__(self, wrapped, phase: str) -> None:
        self.wrapped = wrapped
        self.phase = phase

    def __enter__(self):
        return self

    def __exit__(self, exception_type, exception, traceback) -> bool:
        return self.wrapped.__exit__(exception_type, exception, traceback)

    def write(self, payload):
        if self.phase == "write":
            raise OSError("synthetic report write failure")
        return self.wrapped.write(payload)

    def flush(self) -> None:
        if self.phase == "flush":
            raise OSError("synthetic report flush failure")
        self.wrapped.flush()

    def fileno(self) -> int:
        return self.wrapped.fileno()


def _known_pid_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def _assert_known_pid_gone(test: unittest.TestCase, pid_path: Path) -> None:
    pid = int(pid_path.read_text().strip())
    deadline = time.monotonic() + 2
    while _known_pid_is_alive(pid) and time.monotonic() < deadline:
        time.sleep(0.02)
    try:
        test.assertFalse(_known_pid_is_alive(pid), f"owned fixture child {pid} is still alive")
    finally:
        if _known_pid_is_alive(pid):
            os.kill(pid, signal.SIGKILL)


def _make_stdout_read_only() -> None:
    descriptor = os.open(os.devnull, os.O_RDONLY)
    try:
        os.dup2(descriptor, 1)
    finally:
        os.close(descriptor)


def _make_stdout_read_only_and_close_stderr() -> None:
    _make_stdout_read_only()
    os.close(2)


class Fixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.source = root / "源 source"
        self.run = root / "运行 output"
        self.trace = root / "trace.txt"
        self.child_pid = root / "child.pid"
        scripts = self.source / "scripts"
        scripts.mkdir(parents=True)
        shutil.copy2(TARGET, scripts / TARGET.name)
        _write_executable(scripts / "build-local.sh", FAKE_BUILD_LOCAL)
        (self.source / "Backends/Audio/Python").mkdir(parents=True)
        audio_packaging = self.source / "Backends/Audio/Packaging"
        video_packaging = self.source / "Backends/Video/Packaging"
        video_packaging.mkdir(parents=True)
        audio_packaging.mkdir(parents=True)
        _write_executable(audio_packaging / "package_audio_app.py", FAKE_PACKAGER)
        _write_executable(audio_packaging / "prepare_engine.py", FAKE_PREPARE_ENGINE)
        _write_executable(audio_packaging / "prepare_mrt2_engine.py", FAKE_PREPARE_MRT2)
        _write_executable(video_packaging / "prepare_video_engine.py", FAKE_PACKAGER)
        _write_executable(video_packaging / "package_video_app.py", FAKE_PACKAGER)
        license_path = video_packaging / "Licenses/tokenizers-0.22.2-LICENSE.txt"
        license_path.parent.mkdir()
        license_path.write_bytes(b"synthetic-tokenizers-license\n")

        lock = self.source / "D.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        lock.parent.mkdir(parents=True)
        lock.write_text(json.dumps({
            "version": 3,
            "pins": [{
                "identity": "dependency",
                "kind": "remoteSourceControl",
                "location": "https://invalid.example/dependency",
                "state": {"revision": PIN_REVISION, "version": "1.0.0"},
            }],
        }), encoding="utf-8")

        self.developer = root / "Fake Xcode.app/Contents/Developer"
        _write_executable(self.developer / "usr/bin/git", FAKE_GIT)
        _write_executable(self.developer / "usr/bin/xcodebuild", FAKE_XCODEBUILD)
        self.template = root / "locked packages"
        (self.template / "checkouts/dependency/.git").mkdir(parents=True)

        python_root = root / "python"
        _write_executable(python_root / "bin/python3.12", "#!/bin/bash\nexit 0\n")
        (python_root / "lib/python3.12/encodings").mkdir(parents=True)
        (python_root / "lib/python3.12/LICENSE.txt").write_text("synthetic Python license\n", encoding="utf-8")
        (python_root / "lib/python3.12/encodings/__init__.py").write_text("# synthetic\n", encoding="utf-8")
        (python_root / "protected.txt").write_text("python", encoding="utf-8")

        sa3 = root / "sa3"
        for name in ("mlx", "numpy", "sentencepiece"):
            (sa3 / name).mkdir(parents=True)
        for name in ("mlx", "mlx_metal", "numpy", "sentencepiece"):
            (sa3 / f"{name}-1.0.dist-info").mkdir()

        mrt2 = root / "mrt2"
        mrt_versions = {"mlx": "0.31.1", "mlx_metal": "0.31.1", "numpy": "2.3.5", "sentencepiece": "0.2.2", "ai_edge_litert": "2.2.0"}
        for name in ("mlx", "numpy", "sentencepiece", "ai_edge_litert"):
            (mrt2 / name).mkdir(parents=True)
        for name, version in mrt_versions.items():
            distribution = mrt2 / f"{name}-{version}.dist-info"
            distribution.mkdir()
            distribution_name = name.replace("_", "-")
            (distribution / "METADATA").write_text(
                f"Name: {distribution_name}\nVersion: {version}\n", encoding="utf-8"
            )
        (mrt2 / "protected.txt").write_text("mrt2", encoding="utf-8")

        video = root / "video"
        video_versions = {"mlx": "0.31.1", "mlx-metal": "0.31.1", "numpy": "2.4.3", "tokenizers": "0.22.2", "ftfy": "6.3.1", "wcwidth": "0.8.3"}
        for name in ("mlx", "numpy", "tokenizers", "ftfy", "wcwidth"):
            (video / name).mkdir(parents=True)
        for name, version in video_versions.items():
            stem = name.replace("-", "_")
            distribution = video / f"{stem}-{version}.dist-info"
            distribution.mkdir()
            (distribution / "METADATA").write_text(f"Name: {name}\nVersion: {version}\n", encoding="utf-8")
            (distribution / "LICENSE.txt").write_text("synthetic license\n", encoding="utf-8")
        (video / "protected.txt").write_text("video", encoding="utf-8")

        tokenizer = root / "tokenizer"
        tokenizer.mkdir()
        for name, content in TOKENIZER_CONTENTS.items():
            (tokenizer / name).write_bytes(content)
        (tokenizer / "protected.txt").write_text("tokenizer", encoding="utf-8")

        providers = self.source / "Backends/Audio/Python"
        for name in (
            "d_audio_backend.py", "d_audio_contract.py", "d_audio_sa3.py",
            "d_audio_mrt2_backend.py", "d_audio_mrt2_contract.py", "d_mrt2_export.py", "d_audio_access.py",
        ):
            (providers / name).write_text("# synthetic provider\n", encoding="utf-8")
        (self.source / "Vendor/stable-audio3-mlx").mkdir(parents=True)
        (self.source / "Backends/Audio/MRT2Vendor").mkdir(parents=True)
        audio_models = self.source / "Backends/Audio/Models"
        audio_models.mkdir(parents=True)
        (audio_models / "mrt2-small.json").write_text("{}\n", encoding="utf-8")
        video_python = self.source / "Backends/Video/Python"
        video_python.mkdir()
        for name in ("d_video_run.py", "d_video_model.py", "d_video_prepare.py"):
            (video_python / name).write_text("# synthetic provider\n", encoding="utf-8")
        (self.source / "Backends/Video/Vendor/wan21").mkdir(parents=True)
        video_models = self.source / "Backends/Video/Models"
        video_models.mkdir()
        (video_models / "wan21.json").write_text(json.dumps({
            "schemaVersion": 1,
            "repository": "Wan-AI/Wan2.1-T2V-1.3B",
            "revision": "37ec512624d61f7aa208f7ea8140a131f93afc9a",
            "profile": "wan21-t2v-1.3b-bf16-v1",
            "precision": {
                "text": "BF16",
                "diffusion": "BF16 with original FP32 time/head/modulation/norm tensors",
                "vae": "F32",
            },
        }) + "\n", encoding="utf-8")
        self.signing = root / "existing signing.xcconfig"
        self.signing.write_text("DEVELOPMENT_TEAM = SYNTHETIC\n", encoding="utf-8")
        self.config = root / "本机 config.json"
        self.config_value = {
            "schemaVersion": 1,
            "developerDirectory": str(self.developer),
            "signingConfig": str(self.signing),
            "signingIdentity": IDENTITY,
            "pythonRoot": str(root / "python"),
            "sa3SitePackages": str(root / "sa3"),
            "mrt2SitePackages": str(root / "mrt2"),
            "videoSitePackages": str(root / "video"),
            "tokenizerDirectory": str(root / "tokenizer"),
            "sourcePackagesTemplate": str(self.template),
        }
        self.write_config()

    def write_config(self) -> None:
        self.config.write_text(json.dumps(self.config_value, ensure_ascii=False), encoding="utf-8")

    def environment(self, **values: str) -> dict[str, str]:
        environment = os.environ.copy()
        environment.update({
            "PYTHONDONTWRITEBYTECODE": "1",
            "D_MB_TEST_PYTHON": str(INTERPRETER),
            "FAKE_TRACE": str(self.trace),
            "FAKE_CHILD_PID": str(self.child_pid),
            "FAKE_NATIVE_PYTHON": str(INTERPRETER),
            "REAL_AUDIO_PACKAGING": str(REPOSITORY / "Backends/Audio/Packaging"),
        })
        environment.update(values)
        return environment

    def command(self, *, timeout: float = 5.0) -> list[str]:
        return [
            str(INTERPRETER), "-B", str(self.source / "scripts/build-development-app.py"),
            "--config", str(self.config), "--run-root", str(self.run),
            "--timeout-per-stage", str(timeout),
        ]

    def run_command(self, *, timeout: float = 5.0, **environment: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            self.command(timeout=timeout),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            timeout=15,
            env=self.environment(**environment),
        )


class BuildDevelopmentAppTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        value = os.environ.get("D_MB_TEST_TMP_ROOT")
        if not value:
            raise RuntimeError("D_MB_TEST_TMP_ROOT is required")
        cls.output_root = Path(value)
        if not cls.output_root.is_absolute() or not cls.output_root.is_dir():
            raise RuntimeError("D_MB_TEST_TMP_ROOT must be an existing absolute directory")

    def setUp(self) -> None:
        self.case = Path(tempfile.mkdtemp(prefix="d-mb-build1-", dir=self.output_root))

    def tearDown(self) -> None:
        shutil.rmtree(self.case)

    def fixture(self, name: str = "中文 and spaces") -> Fixture:
        root = self.case / name
        root.mkdir()
        return Fixture(root)

    def test_success_runs_four_stages_and_reports_three_manifests(self) -> None:
        fixture = self.fixture()
        protected = {
            path: _digest(path)
            for path in (
                fixture.config,
                fixture.signing,
                fixture.root / "python/protected.txt",
                fixture.root / "video/mlx-0.31.1.dist-info/METADATA",
            )
        }
        result = fixture.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = json.loads(result.stdout)
        self.assertEqual(summary["status"], "packaged")
        self.assertEqual(summary["runtimeVerification"], "not-run")
        self.assertEqual(fixture.trace.read_text().splitlines(), [
            "build-local", "package-audio-app", "prepare-video-engine", "package-video-app",
        ])
        report = json.loads((fixture.run / "evidence/build-development-report.json").read_text())
        self.assertEqual(report["status"], "packaged")
        self.assertEqual(set(report["engineManifests"]), {
            "AudioEngine.dengine", "MRT2MusicEngine.dengine", "VideoEngine.dengine",
        })
        self.assertEqual(report["source"]["head"], SOURCE_HEAD)
        self.assertTrue(report["protectedInputsUnchanged"])
        self.assertTrue((fixture.run / "output/D Development.app").is_dir())
        self.assertEqual(protected, {path: _digest(path) for path in protected})

    def test_config_schema_types_missing_and_unknown_are_rejected(self) -> None:
        mutations = (
            lambda value: value.update(schemaVersion="1"),
            lambda value: value.pop("pythonRoot"),
            lambda value: value.update(unexpected="value"),
            lambda value: value.update(videoSitePackages=7),
        )
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                fixture = self.fixture(f"config-{index}")
                mutate(fixture.config_value)
                fixture.write_config()
                result = fixture.run_command()
                self.assertEqual(result.returncode, 2)
                self.assertIn('"status": "failed"', result.stderr)
                self.assertFalse(fixture.trace.exists())

    def test_missing_tool_and_missing_checkpoint_stop_before_later_stages(self) -> None:
        missing = self.fixture("missing-tool")
        (missing.developer / "usr/bin/xcodebuild").unlink()
        result = missing.run_command()
        self.assertEqual(result.returncode, 2)
        self.assertIn("xcodebuild is missing", result.stderr)
        self.assertFalse(missing.trace.exists())

        checkpoint = self.fixture("missing-checkpoint")
        result = checkpoint.run_command(FAKE_STAGE="missing-build-output")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(checkpoint.trace.read_text().splitlines(), ["build-local"])

    def test_existing_overlap_and_symlink_run_roots_are_rejected(self) -> None:
        existing = self.fixture("existing")
        existing.run.mkdir()
        self.assertEqual(existing.run_command().returncode, 2)

        overlap = self.fixture("overlap")
        overlap.run = overlap.root / "python/new-run"
        self.assertEqual(overlap.run_command().returncode, 2)

        linked = self.fixture("linked")
        target = linked.root / "link-target"
        target.mkdir()
        linked.run.symlink_to(target, target_is_directory=True)
        self.assertEqual(linked.run_command().returncode, 2)
        self.assertFalse(existing.trace.exists())
        self.assertFalse(overlap.trace.exists())
        self.assertFalse(linked.trace.exists())

    def test_each_stage_failure_prevents_following_stages(self) -> None:
        expectations = {
            "build-fail": ["build-local"],
            "audio-fail": ["build-local", "package-audio-app"],
            "video-prepare-fail": ["build-local", "package-audio-app", "prepare-video-engine"],
            "video-package-fail": ["build-local", "package-audio-app", "prepare-video-engine", "package-video-app"],
        }
        for stage, trace in expectations.items():
            with self.subTest(stage=stage):
                fixture = self.fixture(stage)
                result = fixture.run_command(FAKE_STAGE=stage)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(fixture.trace.read_text().splitlines(), trace)
                report = json.loads((fixture.run / "evidence/build-development-report.json").read_text())
                self.assertEqual(report["status"], "failed")
                self.assertEqual(report["stages"][-1]["status"], "failed")

    def test_timeout_and_cancel_reap_owned_process_group(self) -> None:
        timeout_fixture = self.fixture("timeout")
        result = timeout_fixture.run_command(timeout=0.2, FAKE_STAGE="timeout")
        self.assertEqual(result.returncode, 2)
        report = json.loads((timeout_fixture.run / "evidence/build-development-report.json").read_text())
        self.assertEqual(report["stages"][0]["status"], "timed-out")
        self.assertFalse(report["stages"][0]["cleanupIncomplete"])
        _assert_known_pid_gone(self, timeout_fixture.child_pid)

        cancel_fixture = self.fixture("cancel")
        process = subprocess.Popen(
            cancel_fixture.command(timeout=10),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=cancel_fixture.environment(FAKE_STAGE="cancel"),
        )
        deadline = time.monotonic() + 5
        while not cancel_fixture.child_pid.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(cancel_fixture.child_pid.exists())
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 130, (stdout, stderr))
        report = json.loads((cancel_fixture.run / "evidence/build-development-report.json").read_text())
        self.assertEqual(report["status"], "cancelled")
        self.assertEqual(report["stages"][0]["status"], "cancelled")
        self.assertFalse(report["stages"][0]["cleanupIncomplete"])
        _assert_known_pid_gone(self, cancel_fixture.child_pid)

    def test_leader_first_and_held_output_children_are_drained_before_next_stage(self) -> None:
        for stage in ("leader-first", "held-pipes"):
            with self.subTest(stage=stage):
                fixture = self.fixture(stage)
                result = fixture.run_command(FAKE_STAGE=stage)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(fixture.trace.read_text().splitlines(), ["build-local"])
                report = json.loads((fixture.run / "evidence/build-development-report.json").read_text())
                self.assertEqual(report["stages"][0]["status"], "abnormal-leftover")
                self.assertTrue(report["stages"][0]["leftoverDetected"])
                self.assertFalse(report["stages"][0]["cleanupIncomplete"])
                _assert_known_pid_gone(self, fixture.child_pid)

    def test_repeated_cancellation_is_bounded_and_drains_known_child(self) -> None:
        fixture = self.fixture("repeat-cancel")
        process = subprocess.Popen(
            fixture.command(timeout=10),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=fixture.environment(FAKE_STAGE="repeat-cancel"),
        )
        deadline = time.monotonic() + 5
        while not fixture.child_pid.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(fixture.child_pid.exists())
        process.send_signal(signal.SIGTERM)
        time.sleep(0.05)
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 130, (stdout, stderr))
        _assert_known_pid_gone(self, fixture.child_pid)

    def test_shared_audio_helper_supervised_and_standalone_drain_fake_native_child(self) -> None:
        fixture = self.fixture("shared-helper-supervised")
        native = fixture.root / "fake-native"
        _write_executable(native, '''#!/bin/bash
"$FAKE_NATIVE_PYTHON" -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)' &
printf '%s\n' "$!" > "$FAKE_CHILD_PID"
exit 0
''')
        result = fixture.run_command(
            USE_SHARED_HELPER="1",
            FAKE_NATIVE_COMMAND=str(native),
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(fixture.trace.read_text().splitlines(), ["build-local", "package-audio-app"])
        report = json.loads((fixture.run / "evidence/build-development-report.json").read_text())
        self.assertEqual(report["stages"][1]["status"], "abnormal-leftover")
        _assert_known_pid_gone(self, fixture.child_pid)

        standalone = self.fixture("shared-helper-standalone")
        native = standalone.root / "fake-native"
        _write_executable(native, '''#!/bin/bash
"$FAKE_NATIVE_PYTHON" -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)' &
printf '%s\n' "$!" > "$FAKE_CHILD_PID"
exit 0
''')
        harness = standalone.root / "helper-harness.py"
        harness.write_text('''import os, sys
sys.path.insert(0, os.environ["REAL_AUDIO_PACKAGING"])
import package_audio_app
try:
    package_audio_app._run_command([os.environ["FAKE_NATIVE_COMMAND"]], timeout=1)
except package_audio_app.PackagingError as error:
    print(error, file=sys.stderr)
    raise SystemExit(2)
raise SystemExit(0)
''', encoding="utf-8")
        result = subprocess.run(
            [str(INTERPRETER), "-B", str(harness)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            timeout=10,
            env=standalone.environment(FAKE_NATIVE_COMMAND=str(native)),
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("left processes", result.stderr)
        _assert_known_pid_gone(self, standalone.child_pid)

    def test_shared_audio_helper_cancellation_restores_handler_and_drains_in_both_modes(self) -> None:
        native_text = '''#!/bin/bash
printf '%s\n' "$$" > "$FAKE_CHILD_PID"
exec "$FAKE_NATIVE_PYTHON" -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)'
'''
        supervised = self.fixture("shared-helper-supervised-cancel")
        native = supervised.root / "fake-native-hang"
        _write_executable(native, native_text)
        process = subprocess.Popen(
            supervised.command(timeout=10),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=supervised.environment(USE_SHARED_HELPER="1", FAKE_NATIVE_COMMAND=str(native)),
        )
        deadline = time.monotonic() + 5
        while not supervised.child_pid.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(supervised.child_pid.exists())
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 130, (stdout, stderr))
        _assert_known_pid_gone(self, supervised.child_pid)

        standalone = self.fixture("shared-helper-standalone-cancel")
        native = standalone.root / "fake-native-hang"
        _write_executable(native, native_text)
        receipt = standalone.root / "handler-restored.txt"
        harness = standalone.root / "helper-cancel-harness.py"
        harness.write_text('''import os, signal, sys
sys.path.insert(0, os.environ["REAL_AUDIO_PACKAGING"])
import package_audio_app
before = signal.getsignal(signal.SIGTERM)
try:
    package_audio_app._run_command([os.environ["FAKE_NATIVE_COMMAND"]], timeout=10)
except KeyboardInterrupt:
    restored = signal.getsignal(signal.SIGTERM) == before
    open(os.environ["HANDLER_RECEIPT"], "w", encoding="utf-8").write(str(restored))
    raise SystemExit(130)
raise SystemExit(1)
''', encoding="utf-8")
        process = subprocess.Popen(
            [str(INTERPRETER), "-B", str(harness)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=standalone.environment(FAKE_NATIVE_COMMAND=str(native), HANDLER_RECEIPT=str(receipt)),
        )
        deadline = time.monotonic() + 5
        while not standalone.child_pid.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(standalone.child_pid.exists())
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 130, (stdout, stderr))
        self.assertEqual(receipt.read_text(), "True")
        _assert_known_pid_gone(self, standalone.child_pid)

    def test_report_failure_after_publication_retains_app_and_is_clear(self) -> None:
        fixture = self.fixture()
        result = fixture.run_command(COLLIDE_WRAPPER_REPORT="1")
        self.assertEqual(result.returncode, 2)
        self.assertIn("report failure", result.stderr)
        self.assertIn("packaged App retained", result.stderr)
        self.assertTrue((fixture.run / "output/D Development.app").is_dir())

    def test_locked_checkout_mismatch_fails_before_run_creation(self) -> None:
        fixture = self.fixture()
        lock = fixture.source / "D.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        value = json.loads(lock.read_text())
        value["pins"][0]["state"]["revision"] = "d" * 40
        lock.write_text(json.dumps(value), encoding="utf-8")
        result = fixture.run_command()
        self.assertEqual(result.returncode, 2)
        self.assertIn("expected", result.stderr)
        self.assertFalse(fixture.run.exists())

    def test_swiftpm_links_git_storage_and_checkout_cleanliness_are_protected(self) -> None:
        cases = []
        escaping = self.fixture("escaping-link")
        (escaping.root / "outside").mkdir()
        (escaping.template / "repositories").symlink_to("../outside", target_is_directory=True)
        cases.append((escaping, {}, "escapes its root"))

        internal_absolute = self.fixture("internal-absolute-link")
        (internal_absolute.template / "repositories").symlink_to(
            internal_absolute.template / "checkouts", target_is_directory=True
        )
        cases.append((internal_absolute, {}, "absolute symbolic link"))

        broken = self.fixture("broken-link")
        (broken.template / "repositories").symlink_to("missing", target_is_directory=True)
        cases.append((broken, {}, "broken symbolic link"))

        git_redirect = self.fixture("git-redirect")
        shutil.rmtree(git_redirect.template / "checkouts/dependency/.git")
        (git_redirect.template / "checkouts/dependency/.git").write_text("gitdir: /outside\n", encoding="utf-8")
        cases.append((git_redirect, {}, ".git must be"))

        common_redirect = self.fixture("common-redirect")
        (common_redirect.root / "outside-git").mkdir()
        cases.append((common_redirect, {"FAKE_COMMON_DIR": str(common_redirect.root / "outside-git")}, "escapes its private"))

        dirty = self.fixture("dirty-checkout")
        cases.append((dirty, {"FAKE_CHECKOUT_DIRTY": "1"}, "is not clean"))

        for fixture, environment, expected in cases:
            with self.subTest(case=fixture.root.name):
                result = fixture.run_command(**environment)
                self.assertEqual(result.returncode, 2)
                self.assertIn(expected, result.stderr)
                self.assertFalse(fixture.run.exists())
                self.assertFalse(fixture.trace.exists())

        internal = self.fixture("internal-relative-link")
        (internal.template / "repositories").symlink_to("checkouts", target_is_directory=True)
        result = internal.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        copied = internal.run / "cache/SourcePackages-App/repositories"
        self.assertTrue(copied.is_symlink())
        self.assertTrue(copied.resolve().is_relative_to(internal.run / "cache/SourcePackages-App"))

    def test_actual_git_alternates_are_resolved_from_objects_directory(self) -> None:
        module = _load_coordinator(TARGET, "build_development_app_alternates_test")
        git = Path("/Applications/Xcode.app/Contents/Developer/usr/bin/git")
        environment = os.environ.copy()
        environment.update(module.NETWORK_RESTRICTING_ENVIRONMENT)

        internal_root = self.case / "actual-git-internal"
        cache = internal_root / "cache"
        checkout = cache / "checkouts/dep"
        pool = cache / "pool"
        checkout.parent.mkdir(parents=True)
        self.assertEqual(_actual_git(["init", str(checkout)]).returncode, 0)
        self.assertEqual(_actual_git(["init", "--bare", str(pool)]).returncode, 0)
        alternates = checkout / ".git/objects/info/alternates"
        alternates.parent.mkdir(parents=True, exist_ok=True)
        alternates.write_text("../../../../pool/objects\n", encoding="utf-8")
        count = _actual_git(["count-objects", "-v"], cwd=checkout)
        self.assertEqual(count.returncode, 0, count.stderr)
        self.assertIn(str(pool / "objects"), count.stdout)
        module._validate_git_storage(checkout, cache, git, environment, "internal alternate")

        external_root = self.case / "actual-git-external"
        cache = external_root / "cache"
        checkout = cache / "checkouts/dep"
        outside = external_root / "outside"
        misleading = cache / "outside/objects"
        checkout.parent.mkdir(parents=True)
        misleading.mkdir(parents=True)
        self.assertEqual(_actual_git(["init", str(checkout)]).returncode, 0)
        self.assertEqual(_actual_git(["init", "--bare", str(outside)]).returncode, 0)
        alternates = checkout / ".git/objects/info/alternates"
        alternates.parent.mkdir(parents=True, exist_ok=True)
        alternates.write_text("../../../../../outside/objects\n", encoding="utf-8")
        count = _actual_git(["count-objects", "-v"], cwd=checkout)
        self.assertEqual(count.returncode, 0, count.stderr)
        self.assertIn(str(outside / "objects"), count.stdout)
        self.assertNotIn(str(misleading), count.stdout)
        with self.assertRaisesRegex(module.BuildError, "escapes SourcePackages"):
            module._validate_git_storage(checkout, cache, git, environment, "external alternate")

    def test_required_runtime_metadata_and_tokenizer_files_fail_before_build(self) -> None:
        removals = (
            ("python", lambda fixture: fixture.root / "python/bin/python3.12"),
            ("sa3", lambda fixture: fixture.root / "sa3/mlx"),
            ("mrt2", lambda fixture: fixture.root / "mrt2/numpy-2.3.5.dist-info/METADATA"),
            ("video", lambda fixture: fixture.root / "video/ftfy-6.3.1.dist-info/METADATA"),
            ("tokenizer", lambda fixture: fixture.root / "tokenizer/tokenizer.json"),
        )
        for name, locate in removals:
            with self.subTest(name=name):
                fixture = self.fixture(f"missing-runtime-{name}")
                path = locate(fixture)
                if path.is_dir():
                    shutil.rmtree(path)
                else:
                    path.unlink()
                result = fixture.run_command()
                self.assertEqual(result.returncode, 2)
                self.assertFalse(fixture.trace.exists())
                self.assertFalse(fixture.run.exists())

    def test_source_snapshot_accepts_unchanged_dirty_content_and_detects_same_path_mutation(self) -> None:
        unchanged = self.fixture("unchanged-dirty")
        dirty = unchanged.source / "tracked.txt"
        dirty.write_text("already dirty\n", encoding="utf-8")
        result = unchanged.run_command(FAKE_TRACKED="tracked.txt")
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads((unchanged.run / "evidence/build-development-report.json").read_text())
        self.assertEqual(report["source"]["snapshot"], report["source"]["finalSnapshot"])
        self.assertEqual(report["source"]["snapshot"]["workingTracked"]["fileCount"], 1)

        changed = self.fixture("changed-same-path")
        dirty = changed.source / "tracked.txt"
        dirty.write_text("already dirty\n", encoding="utf-8")
        result = changed.run_command(FAKE_TRACKED="tracked.txt", MUTATE_SOURCE_PATH=str(dirty))
        self.assertEqual(result.returncode, 2)
        self.assertIn("dirty content changed", result.stderr)
        self.assertTrue((changed.run / "output/D Development.app").is_dir())
        report = json.loads((changed.run / "evidence/build-development-report.json").read_text())
        self.assertNotEqual(report["source"]["snapshot"], report["source"]["finalSnapshot"])

    def test_read_only_stdout_is_exit_two_with_packaged_disk_report_buffered_and_unbuffered(self) -> None:
        for unbuffered in (False, True):
            with self.subTest(unbuffered=unbuffered):
                fixture = self.fixture(f"closed-stdout-{unbuffered}")
                command = fixture.command()
                if unbuffered:
                    command.insert(2, "-u")
                process = subprocess.run(
                    command,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    check=False,
                    timeout=15,
                    env=fixture.environment(),
                    preexec_fn=_make_stdout_read_only,
                )
                self.assertEqual(process.returncode, 2, process.stderr)
                self.assertIn("on-disk packaged report was written", process.stderr)
                report = json.loads((fixture.run / "evidence/build-development-report.json").read_text())
                self.assertEqual(report["status"], "packaged")

        unavailable = self.fixture("closed-output-and-error")
        process = subprocess.run(
            unavailable.command(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            timeout=15,
            env=unavailable.environment(),
            preexec_fn=_make_stdout_read_only_and_close_stderr,
        )
        self.assertEqual(process.returncode, 2)
        self.assertEqual(process.stderr, "")
        self.assertEqual(
            json.loads((unavailable.run / "evidence/build-development-report.json").read_text())["status"],
            "packaged",
        )

    def test_report_io_failure_after_publication_retains_app(self) -> None:
        fixture = self.fixture("readonly-report-directory")
        result = fixture.run_command(MAKE_REPORT_DIRECTORY_READ_ONLY="1")
        try:
            self.assertEqual(result.returncode, 2)
            self.assertIn("packaged App retained", result.stderr)
            self.assertTrue((fixture.run / "output/D Development.app").is_dir())
        finally:
            (fixture.run / "evidence").chmod(0o700)

    def test_direct_report_write_flush_and_fsync_failures_retain_published_app(self) -> None:
        for phase in ("write", "flush", "fsync"):
            with self.subTest(phase=phase):
                fixture = self.fixture(f"direct-report-{phase}")
                module = _load_coordinator(
                    fixture.source / "scripts/build-development-app.py",
                    f"build_development_app_report_{phase}",
                )
                config_path = module._absolute(str(fixture.config), "--config")
                run_root = module._absolute(str(fixture.run), "--run-root")
                with mock.patch.dict(os.environ, fixture.environment(), clear=True):
                    preflight = module._preflight(config_path, run_root)
                original_inputs = {
                    path: _digest(path)
                    for path in (
                        fixture.config,
                        fixture.signing,
                        fixture.root / "python/protected.txt",
                        fixture.root / "tokenizer/tokenizer.json",
                    )
                }
                final_app = fixture.run / "output/D Development.app"
                published_digest: list[str] = []

                if phase in {"write", "flush"}:
                    real_fdopen = module.os.fdopen
                    call_count = 0

                    def failing_fdopen(descriptor, *args, **kwargs):
                        nonlocal call_count
                        wrapped = real_fdopen(descriptor, *args, **kwargs)
                        call_count += 1
                        if call_count == 1:
                            published_digest.append(_tree_digest(final_app))
                            return _FailingReportFile(wrapped, phase)
                        return wrapped

                    patcher = mock.patch.object(module.os, "fdopen", side_effect=failing_fdopen)
                else:
                    real_fsync = module.os.fsync
                    call_count = 0

                    def failing_fsync(descriptor):
                        nonlocal call_count
                        call_count += 1
                        if call_count == 1:
                            published_digest.append(_tree_digest(final_app))
                            raise OSError("synthetic report fsync failure")
                        return real_fsync(descriptor)

                    patcher = mock.patch.object(module.os, "fsync", side_effect=failing_fsync)

                with mock.patch.dict(os.environ, fixture.environment(), clear=True), patcher:
                    with self.assertRaisesRegex(module.BuildError, "report write/flush/fsync failed"):
                        module._execute(preflight, config_path, run_root, 5)

                self.assertEqual(len(published_digest), 1)
                self.assertTrue(final_app.is_dir())
                self.assertEqual(_tree_digest(final_app), published_digest[0])
                failure_report = json.loads(
                    (fixture.run / "evidence/build-development-report.json").read_text()
                )
                self.assertEqual(failure_report["status"], "failed")
                self.assertEqual(failure_report["retainedPublishedApp"], str(final_app))
                self.assertIn(f"synthetic report {phase} failure", failure_report["error"])
                self.assertEqual(original_inputs, {path: _digest(path) for path in original_inputs})


class BuildLocalCompatibilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        value = os.environ.get("D_MB_TEST_TMP_ROOT")
        if not value:
            raise RuntimeError("D_MB_TEST_TMP_ROOT is required")
        cls.output_root = Path(value)

    def setUp(self) -> None:
        self.case = Path(tempfile.mkdtemp(prefix="d-mb-build-local-", dir=self.output_root))
        self.project = self.case / "project"
        (self.project / "scripts").mkdir(parents=True)
        shutil.copy2(BUILD_LOCAL, self.project / "scripts/build-local.sh")
        (self.project / "scripts/verify-mlx-vendor.py").write_text("synthetic fixture\n", encoding="utf-8")
        (self.project / "D.xcworkspace").mkdir()
        self.fake_bin = self.case / "bin"
        self.args_log = self.case / "xcode-args.txt"
        _write_executable(self.fake_bin / "python3", "#!/bin/bash\nexit 0\n")
        _write_executable(self.fake_bin / "xcodebuild", '#!/bin/bash\nprintf "%s\\n" "$@" > "$XCODE_ARGS_LOG"\nprintf "synthetic xcodebuild\\n"\n')

    def tearDown(self) -> None:
        shutil.rmtree(self.case)

    def invoke(self, arguments: list[str], development: Path) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update({
            "PATH": f"{self.fake_bin}:/usr/bin:/bin",
            "D_DEVELOPMENT_ROOT": str(development),
            "XCODE_ARGS_LOG": str(self.args_log),
        })
        environment.pop("D_SIGNING_CONFIG", None)
        return subprocess.run(
            ["/bin/bash", str(self.project / "scripts/build-local.sh"), *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            env=environment,
        )

    def test_no_arguments_preserve_defaults_and_explicit_offline_passthrough(self) -> None:
        default_root = self.case / "default development"
        result = self.invoke([], default_root)
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = self.args_log.read_text().splitlines()
        self.assertIn(str(default_root / "DerivedData"), arguments)
        self.assertIn(str(default_root / "SourcePackages-App"), arguments)
        self.assertIn("-onlyUsePackageVersionsFromResolvedFile", arguments)
        self.assertNotIn("-disableAutomaticPackageResolution", arguments)
        self.assertNotIn("-skipPackageUpdates", arguments)

        explicit = self.case / "explicit paths"
        derived = explicit / "Derived Data"
        packages = explicit / "Source Packages"
        log = explicit / "logs/xcode.log"
        result = self.invoke([
            "--derived-data-path", str(derived),
            "--source-packages-path", str(packages),
            "--log-path", str(log),
            "--offline",
        ], self.case / "unused development")
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = self.args_log.read_text().splitlines()
        for expected in (
            str(derived), str(packages), "-disableAutomaticPackageResolution",
            "-skipPackageUpdates", "-onlyUsePackageVersionsFromResolvedFile",
        ):
            self.assertIn(expected, arguments)
        self.assertTrue(log.is_file())


if __name__ == "__main__":
    unittest.main()
