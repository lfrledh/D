#!/usr/bin/env python3
"""Package an already built, fixed CPython WASI runtime; never download or install globally."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def package(source: Path, capi: Path, destination: Path, identity: str) -> None:
    if not re.fullmatch(r"[0-9a-fA-F]{40}", identity):
        raise ValueError("Use the existing development signing identity SHA; no new identity is created.")
    if not destination.is_absolute() or os.path.lexists(destination):
        raise ValueError("Destination must be a new absolute path; existing resources are never replaced.")
    source = source.resolve(strict=True)
    capi = capi.resolve(strict=True)
    if '"3.14.8"' not in (source / "Include/patchlevel.h").read_text():
        raise ValueError("Expected CPython 3.14.8 source and build.")
    if '#define WASMTIME_VERSION "49.0.2"' not in (capi / "include/wasmtime.h").read_text():
        raise ValueError("Expected matching Wasmtime 49.0.2 full C API package.")
    build = source / "cross-build/wasm32-wasip1"
    module = build / "python.wasm"
    if module.is_symlink() or not module.is_file() or module.stat().st_size > 64 * 1024 * 1024:
        raise ValueError("Build the fixed WASI module first.")
    spec = importlib.util.spec_from_file_location("d_resource_core", ROOT / "scripts/prepare-development-resources.py")
    core = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(core)
    parent = destination.parent.resolve(strict=True)
    stage = Path(tempfile.mkdtemp(prefix=".chat-python-", dir=parent))
    try:
        runtime = stage / "runtime"
        library = runtime / "lib/python3.14"
        shutil.copytree(source / "Lib", library, symlinks=True,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "test", "idlelib", "tkinter", "ensurepip"))
        shutil.copy2(module, runtime / "python.wasm")
        metadata = list(build.glob("build/lib.wasi-wasm32-3.14/_sysconfigdata*.py"))
        if len(metadata) != 1:
            raise ValueError("Generate pybuilddir.txt with the official cross-build Makefile first.")
        shutil.copy2(metadata[0], library / metadata[0].name)
        shutil.copy2(ROOT / "tools/chat-python/d_result.py", library / "d_result.py")
        shutil.copy2(capi / "lib/libwasmtime.dylib", stage / "libwasmtime.dylib")
        shutil.copy2(source / "LICENSE", stage / "LICENSE-CPython.txt")
        shutil.copy2(capi / "LICENSE", stage / "LICENSE-Wasmtime.txt")
        subprocess.run(["/usr/bin/clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-I", str(capi / "include"), str(ROOT / "tools/chat-python/runner.c"),
                        "-L", str(capi / "lib"), "-lwasmtime", "-Wl,-rpath,@loader_path",
                        "-o", str(stage / "runner")], check=True, timeout=120)
        entitlements = stage / "runner.entitlements"
        entitlements.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True,
                                                 "com.apple.security.inherit": True}))
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, "--timestamp=none",
                        str(stage / "libwasmtime.dylib")], check=True, timeout=60)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, "--timestamp=none",
                        "--entitlements", str(entitlements), str(stage / "runner")], check=True, timeout=60)
        entitlements.unlink()  # Own build-only file, never a guest resource.
        for name in ("runner", "libwasmtime.dylib"):
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(stage / name)],
                           check=True, timeout=30)
        provenance = {
            "python": {"version": "3.14.8", "source": "https://www.python.org/ftp/python/3.14.8/Python-3.14.8.tar.xz",
                       "archiveSHA256": "c2215904f02b175596dc49351585104f4bc20341e1c47378b26a2c274360ce73",
                       "moduleSHA256": digest(module), "license": "LICENSE-CPython.txt"},
            "wasmtime": {"version": "49.0.2", "source": "https://github.com/bytecodealliance/wasmtime/releases/tag/v49.0.2",
                         "archiveSHA256": "f7000ab1661495d09b9dc87a11b356941b4e6097f295434bcb30a8cf1393b0d5",
                         "license": "LICENSE-Wasmtime.txt"},
            "wasiSDK": "24.0-arm64-macos", "engine": "pulley64", "networkGranted": False,
            "runnerSourceSHA256": digest(ROOT / "tools/chat-python/runner.c"),
            "inputResponsibility": "Version headers checked here. Verify official archive hashes before extracting/building.",
        }
        (stage / "PROVENANCE.json").write_text(json.dumps(provenance, indent=2) + "\n")
        inventory = core._walk_engine(stage)
        if inventory["symlinks"]:
            raise ValueError("Chat Python resources must not contain symlinks.")
        manifest = {"schemaVersion": 1, "kind": "d-chat-python-wasi", "pythonVersion": "3.14.8",
                    "wasmtimeVersion": "49.0.2", "engine": "pulley64", "files": inventory["files"]}
        (stage / "engine.json").write_text(json.dumps(manifest, indent=2) + "\n")
        core.inspect_engine(stage, "ChatPython.dengine")
        core._publish_exclusive(stage, destination)
    finally:
        if stage.exists():
            shutil.rmtree(stage)  # Only the private staging directory created by this invocation.


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cpython-source", type=Path, required=True)
    parser.add_argument("--wasmtime-c-api", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--identity", required=True)
    args = parser.parse_args()
    package(args.cpython_source, args.wasmtime_c_api, args.destination, args.identity)
