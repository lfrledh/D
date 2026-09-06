#!/usr/bin/env python3
"""Reproduce the bounded B1 image probe; all GPU runs are sequential."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import signal
import struct
import subprocess
import sys

probe = Path(__file__).resolve().parent
project = probe.parent.parent
development = project.parent / "D-Development"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", type=Path, default=project.parent / "BuildCaches/D-Flux2Probe/Build/Products/Debug/d-flux2-probe")
parser.add_argument("--model", type=Path, default=development / "Models/FLUX.2-klein-4B-q8")
parser.add_argument("--fixture", type=Path, default=development / "SourcePackages-Flux2Probe/checkouts/flux2.swift/fixtures/flux2_tiny_klein_pipeline")
parser.add_argument("--reports", type=Path, default=development / "Logs" / ("flux2-probe-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")))
args = parser.parse_args()
destination = args.reports.expanduser().resolve()
destination.mkdir(parents=True, exist_ok=False)
summary = {"schemaVersion": 1, "scope": "B1 isolated 512px image hardware probe", "complete": False, "passed": False}


def read(name):
    return json.loads((destination / name).read_text())


def run(name, options, expected_exit=0):
    command = [sys.executable, str(probe / "run_monitored.py"), "--log-prefix", str(destination / name), "--",
               str(args.binary.resolve())] + options
    runner = subprocess.Popen(command)
    try:
        code = runner.wait(timeout=940)
    except BaseException:
        # Killing the monitor directly would strand its separately grouped child.
        # Let its interrupt handler stop and reap that child before unwinding.
        if runner.poll() is None:
            runner.send_signal(signal.SIGINT)
            runner.wait(timeout=30)
        raise
    evidence = read(name + ".process.json")
    if code != expected_exit or evidence["exitCode"] != expected_exit or evidence["watchdogReason"] is not None:
        raise RuntimeError(f"{name} process failed or was stopped by its watchdog: {evidence}")


def final_stage(report):
    if not report["stages"] or report["stages"][-1]["name"] != "all_local_scopes_released":
        raise RuntimeError("Missing terminal release evidence")
    return report["stages"][-1]


try:
    summary["binarySHA256"] = hashlib.sha256(args.binary.resolve().read_bytes()).hexdigest()
    with (destination / "model-verification.log").open("w") as log:
        subprocess.run([sys.executable, str(probe / "download_model.py"), "--manifest", str(probe / "model-manifest.json"),
                        "--destination", str(args.model.resolve()), "--verify-only"], stdout=log, stderr=log, check=True, timeout=300)
    run("tiny", ["--fixture-only", str(args.fixture.resolve()), "--report", str(destination / "tiny.json")])
    tiny = read("tiny.json")
    if tiny["status"] != "passed" or len(tiny["checks"]) != 5 or not all(x["passed"] for x in tiny["checks"]):
        raise RuntimeError("Tiny reference comparison did not pass all five checks")
    common = ["--model", str(args.model.resolve()), "--seed", "42", "--repeat", "3"]
    run("normal", common + ["--output", str(destination / "normal.png"), "--report", str(destination / "normal.json")])
    normal = [read("normal" + ("" if index == 1 else f"-{index}") + ".json") for index in range(1, 4)]
    expected_fields = {
        "width": 512, "height": 512, "textMaxLength": 512, "inferenceSteps": 4,
        "guidanceScale": 1.0, "modelTimestepScale": 0.001,
        "modelRepositoryExpected": "mzbac/FLUX.2-klein-4B-q8",
        "modelRevisionExpected": "ef52ee019fd1d0e75ae4deb40476ba65989716d7",
        "flux2SourceRevision": "959a4af7c0721c800851c84431ffd3fa1f353f1f",
        "modelSnapshot": str(args.model.resolve()),
    }
    for index, report in enumerate(normal, 1):
        artifact = report.get("artifact", {})
        if (report["status"] != "completed" or report["runIndex"] != index or report["runCount"] != 3
            or report["seed"] != 42 or not artifact.get("decodedPixelsFinite")
            or not artifact.get("pngDecodedAndValidated") or artifact.get("decodedShape") != [1, 3, 512, 512]):
            raise RuntimeError(f"Normal run {index} lacks valid completion/artifact evidence")
        if any(report.get(key) != value for key, value in expected_fields.items()):
            raise RuntimeError(f"Normal run {index} does not use the fixed B1 configuration")
        image_path = destination / ("normal" + ("" if index == 1 else f"-{index}") + ".png")
        if artifact.get("path") != str(image_path) or report.get("outputRequested") != str(image_path):
            raise RuntimeError("Artifact path does not match this run's output")
        png = image_path.read_bytes()
        if (len(png) < 33 or png[:8] != b"\x89PNG\r\n\x1a\n" or png[12:16] != b"IHDR"
            or struct.unpack(">II", png[16:24]) != (512, 512) or artifact.get("bytes") != len(png)):
            raise RuntimeError("Independent PNG header, dimensions or length check failed")
        if [x["name"] for x in report["stages"] if x["name"].startswith("denoise_step_") and x["name"].endswith("_evaluated")] != [f"denoise_step_{step}_evaluated" for step in range(1, 5)]:
            raise RuntimeError("The run did not evaluate all four ordered denoising steps")
    released = [final_stage(report) for report in normal]
    hashes = [hashlib.sha256(Path(report["artifact"]["path"]).read_bytes()).hexdigest() for report in normal]
    summary["normal"] = {
        "runs": len(normal), "sameProcess": True, "pngSHA256": hashes,
        "sameSeedPNGIdentical": len(set(hashes)) == 1,
        "releasedActiveBytes": [x["activeBytes"] for x in released],
        "releasedCacheBytes": [x["cacheBytes"] for x in released],
        "mlxPeakBytes": [x["largestObservedPeakBytes"] for x in released],
        "processMaximumResidentBytes": [x.get("processMaximumResidentBytes") for x in released],
        "elapsedSeconds": [report["elapsedSeconds"] for report in normal],
    }
    if len(set(hashes)) != 1 or len({x["activeBytes"] for x in released}) != 1 or any(x["cacheBytes"] for x in released):
        raise RuntimeError("Repeated output or released-memory values changed; inspect the recorded trend")
    run("stopped", common + ["--stop-after-step", "1", "--output", str(destination / "stopped.png"),
                             "--report", str(destination / "stopped.json")], expected_exit=130)
    stopped = read("stopped.json")
    end = final_stage(stopped)
    stages = {x["name"] for x in stopped["stages"]}
    if (stopped["status"] != "stopped" or stopped.get("artifact") is not None
        or "denoise_step_1_evaluated" not in stages or "denoise_step_2_started" in stages
        or "decode_vae_load_started" in stages or end["cacheBytes"] != 0
        or end["activeBytes"] != released[-1]["activeBytes"]
        or any(stopped.get(key) != value for key, value in expected_fields.items())
        or any((destination / name).exists() for name in ["stopped.png", "stopped-2.png", "stopped-2.json"])):
        raise RuntimeError("Intentional step-stop did not release before subsequent work/output")
    summary["stopped"] = {"exitCode": 130, "releasedActiveBytes": end["activeBytes"], "releasedCacheBytes": end["cacheBytes"]}
    summary["tinyComparisonsPassed"] = len(tiny["checks"])
    summary["complete"] = True
    summary["passed"] = True
except Exception as error:
    summary["error"] = f"{type(error).__name__}: {error}"
finally:
    (destination / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(destination / "summary.json")
raise SystemExit(0 if summary["passed"] else 1)
