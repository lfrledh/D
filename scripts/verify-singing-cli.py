#!/usr/bin/env python3
"""Offline developer verifier for the frozen singing CLI contract.

It never builds, downloads, or invokes a model.  The supplied binary is executed
directly against copied request files and existing fixed deployment material.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


def absolute(value: str) -> Path:
    path = Path(value)
    if not path.is_absolute():
        raise argparse.ArgumentTypeError("must be an absolute path")
    return path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True, type=absolute)
    parser.add_argument("--request", required=True, type=absolute)
    parser.add_argument("--model", required=True, type=absolute)
    parser.add_argument("--python", required=True, type=absolute)
    parser.add_argument("--script", required=True, type=absolute)
    parser.add_argument("--vendor", required=True, type=absolute)
    parser.add_argument("--profile", required=True, type=absolute)
    parser.add_argument("--vocoder", required=True, type=absolute)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--output", required=True, type=absolute)
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()
    if not args.timeout > 0 or not args.timeout < float("inf"):
        parser.error("--timeout must be finite and positive")
    if args.output.exists():
        parser.error("--output must not already exist")
    if not args.cli.is_file() or not args.request.is_file():
        parser.error("--cli and --request must be existing regular files")

    args.output.mkdir(mode=0o700)
    copied = args.output / "request.json"
    before = args.request.read_bytes()
    shutil.copyfile(args.request, copied)
    artifacts = args.output / "artifacts"
    artifacts.mkdir(mode=0o700)
    report = args.output / "inspect-report.json"
    command = [str(args.cli), "--capability", "singing", "--singing-request", str(copied),
               "--singing-python", str(args.python), "--singing-script", str(args.script),
               "--singing-vendor", str(args.vendor), "--singing-profile", str(args.profile),
               "--singing-vocoder", str(args.vocoder), "--model", str(args.model),
               "--revision", args.revision, "--artifacts", str(artifacts),
               "--memory-budget-mib", "8192", "--inspect", "--report", str(report)]
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=args.timeout,
                                   check=False)
        result = {"command": command, "exit": completed.returncode,
                  "stdout": completed.stdout, "stderr": completed.stderr,
                  "requestUnchanged": args.request.read_bytes() == before,
                  "copiedRequestUnchanged": copied.read_bytes() == before,
                  "artifactContents": sorted(item.name for item in artifacts.iterdir()),
                  "reportExists": report.exists()}
    except subprocess.TimeoutExpired as error:
        result = {"command": command, "timeout": args.timeout,
                  "stdout": error.stdout, "stderr": error.stderr,
                  "requestUnchanged": args.request.read_bytes() == before}
    (args.output / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True), encoding="utf-8")
    return 0 if result.get("exit") == 0 and not result["artifactContents"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
