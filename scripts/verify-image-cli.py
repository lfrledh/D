#!/usr/bin/env python3
"""Sequential B2 image CLI checks; --offline-only runs argument checks without MLX inference.

Does not build, download, or delete artifacts. Full verification checks the pinned
model before running bounded 512px jobs. Reports must use a new directory.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import selectors
import signal
import struct
import subprocess
import sys
import time
from urllib.parse import unquote, urlparse


ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "Experiments/Flux2Probe"
PROMPT = "A red fox sitting in a snowy forest, soft morning light, detailed photography."


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def run_process(command, directory, name, timeout, trigger=None):
    """Drain and reap only this Popen child, including on verifier interruption.

    Signals wait for completed step 1. Broken-pipe closes stdout at that same
    point, before the single artifact line is written, so it reliably exercises
    a failed write rather than racing a small completed pipe write.
    """
    started = time.monotonic()
    process = None
    selector = selectors.DefaultSelector()
    output = {"stdout": bytearray(), "stderr": bytearray()}
    result = {"command": command, "trigger": trigger, "triggered": False}
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, cwd=ROOT)
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        deadline = started + timeout
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"Child exceeded {timeout:g} seconds")
            for key, _ in selector.select(min(0.2, remaining)):
                content = os.read(key.fileobj.fileno(), 65536)
                if not content:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                output[key.data].extend(content)
                if (trigger and not result["triggered"] and key.data == "stderr"
                        and b"] progress 1/4\n" in output["stderr"]):
                    if trigger == "broken-pipe":
                        if not process.stdout.closed:
                            selector.unregister(process.stdout)
                            process.stdout.close()
                    else:
                        process.send_signal(signal.SIGINT if trigger == "SIGINT" else signal.SIGTERM)
                    result["triggered"] = True
                    result["triggerSeconds"] = time.monotonic() - started
        result["returnCode"] = process.wait(timeout=max(0.1, deadline - time.monotonic()))
    except Exception as error:
        result["processError"] = f"{type(error).__name__}: {error}"
    finally:
        if process is not None:
            if process.poll() is None:
                process.kill()
            result["returnCode"] = process.wait(timeout=10)
            for pipe in (process.stdout, process.stderr):
                if pipe is not None and not pipe.closed:
                    pipe.close()
        selector.close()
        result["elapsedSeconds"] = time.monotonic() - started
        for channel, content in output.items():
            (directory / f"{name}.{channel}.log").write_bytes(content)
        write_json(directory / f"{name}.process.json", result)
    return result, output["stdout"].decode("utf-8", errors="replace"), output["stderr"].decode("utf-8", errors="replace")


def check_png(reference, artifact_root, run_id):
    require(reference.get("mediaType") == "image/png", "Artifact media type is not PNG")
    url = urlparse(reference.get("url", ""))
    require(url.scheme == "file" and url.netloc in ("", "localhost"), "Artifact is not a local file URL")
    path = Path(unquote(url.path))
    require(path.is_absolute() and path.is_file() and not path.is_symlink(), "Published artifact is missing or a symlink")
    relative = path.resolve().relative_to(artifact_root.resolve())
    require(len(relative.parts) >= 2, "Artifact lacks a unique run subdirectory")
    require(run_id.lower() in relative.parts[0].lower(), "Artifact directory does not identify this run")
    png = path.read_bytes()
    require(len(png) >= 33 and png[:8] == b"\x89PNG\r\n\x1a\n" and png[12:16] == b"IHDR",
            "Published artifact has an invalid PNG header")
    require(struct.unpack(">II", png[16:24]) == (512, 512), "PNG dimensions differ from the request")
    return {"path": str(path), "bytes": len(png), "sha256": hashlib.sha256(png).hexdigest()}


def released_memory(run):
    events = run.get("lifecycle", [])
    phases = [event["phase"] for event in events]
    require(phases and phases[-1] == "released" and "drained" in phases, "Missing drain/release evidence")
    require(phases.index("drained") < len(phases) - 1, "Resources released before drain")
    require(all(event["runID"] == run["runID"] for event in events), "Lifecycle run ID mismatch")
    require(all(a["uptimeSeconds"] <= b["uptimeSeconds"] for a, b in zip(events, events[1:])),
            "Lifecycle timestamps moved backwards")
    memory = events[-1]["memory"]
    require(memory["cacheBytes"] == 0, f"Released cache is {memory['cacheBytes']} bytes")
    require(memory["activeBytes"] == 0, f"Released active allocation is {memory['activeBytes']} bytes")
    require(memory["activeBytes"] >= 0 and memory["peakBytes"] >= memory["activeBytes"], "Invalid memory snapshot")
    return memory


def validate_case(name, result, stdout, stderr, report, revision, artifact_root):
    require("processError" not in result, result.get("processError", "Process failed"))
    if name == "help":
        require(result["returnCode"] == 0 and "--capability text|image" in stdout, "Image help unavailable")
        require(report is None and "Run " not in stderr and "active=" not in stderr, "Help initialized backend work")
        return {}
    require(isinstance(report, dict) and report.get("schemaVersion") == 1, "Execution report missing or invalid")
    require(report["exitCode"] == result["returnCode"], "Report/process exit codes differ")
    require(not report.get("artifactCleanupError"), "Final host cleanup failed")
    runs = report.get("runs", [])
    require(not list(artifact_root.rglob("*.partial")), "Host cleanup left an unpublished temporary image")
    if name.startswith("invalid-"):
        require(result["returnCode"] == 2 and not runs and report.get("failure"), "Invalid arguments started work")
        require("active=" not in stderr, "Invalid arguments initialized MLX work")
        return {}
    require(report.get("backend", {}).get("id") == "mlx.image.flux2-klein", "Wrong backend")
    options = report.get("options", {})
    require(options.get("capability") == "image" and options.get("revision") == revision, "Image provenance/options missing")
    if name in ("missing-model", "memory-rejection"):
        require(result["returnCode"] == 1 and len(runs) == 1 and runs[0]["outcome"] == "failed", "Request was not rejected")
        require(not runs[0].get("lifecycle"), "Rejected request entered the loading lifecycle")
        if name == "memory-rejection":
            require("memoryBudgetExceeded" in runs[0].get("failure", {}), "Wrong admission failure")
        require(not list(artifact_root.rglob("*.png")), "Rejected request published an image")
        return {"failure": runs[0].get("failure")}
    require(len(runs) == (3 if name == "repeat-three" else 1), "Wrong number of runs; cancellation must stop repeat")
    require(len({run["runID"] for run in runs}) == len(runs), "Repeated run ID")
    memories = [released_memory(run) for run in runs]
    measurements = {
        "releasedActiveBytes": [memory["activeBytes"] for memory in memories],
        "releasedCacheBytes": [memory["cacheBytes"] for memory in memories],
        "peakBytes": [memory["peakBytes"] for memory in memories],
        "elapsedSeconds": [run["elapsedSeconds"] for run in runs],
        "cancellationLatencySeconds": [run.get("cancellationLatencySeconds") for run in runs],
    }
    for run in runs:
        require(not run.get("artifactCleanupError"), "Per-run host cleanup failed")
        request = run.get("request", {})
        require(request.get("id") == run["runID"] and request.get("model", {}).get("revision") == revision,
                "Per-run typed request/provenance missing")
    if name in ("cancel-after-step", "sigint", "sigterm"):
        run = runs[0]
        require(result["returnCode"] == 130 and run["outcome"] == "cancelled", "Expected drained cancellation")
        require(any(event["completed"] >= 1 for event in run.get("progress", [])), "Cancellation did not follow a completed step")
        require(run.get("cancellationLatencySeconds", -1) >= 0, "Missing cancellation latency")
        require(not run.get("artifacts") and not list(artifact_root.rglob("*.png")), "Cancelled denoise published an image")
        if name in ("sigint", "sigterm"):
            require(result["triggered"], "Signal was never sent")
            expected = int(signal.SIGINT if name == "sigint" else signal.SIGTERM)
            require(report.get("terminationSignal") == expected, "Signal missing from report")
        return measurements
    if name == "broken-pipe":
        require(result["triggered"] and result["returnCode"] != 0 and runs[0].get("outputError"),
                "Broken stdout did not preserve a failure report")
        # The image was already published before the failed host stdout write.
        require(len(runs[0].get("artifacts", [])) == 1, "Published image reference lost on stdout failure")
        measurements["artifacts"] = [check_png(runs[0]["artifacts"][0], artifact_root, runs[0]["runID"])]
        return measurements
    require(result["returnCode"] == 0, "Successful image runs must exit 0")
    lines = [json.loads(line) for line in stdout.splitlines()]
    require(len(lines) == len(runs), "Expected one artifact JSON line per run")
    images = []
    for run, line in zip(runs, lines):
        require(run["outcome"] == "completed" and not run.get("outputError"), "Image run failed")
        completed = [event["completed"] for event in run.get("progress", [])]
        require(completed in ([1, 2, 3, 4], [0, 1, 2, 3, 4]), "Four-step progress differs")
        require(all(event["total"] == 4 for event in run["progress"]), "Wrong progress total")
        require(len(run.get("artifacts", [])) == 1 and run["artifacts"] == run["result"]["artifacts"], "Final artifact references differ")
        require(line.get("type") == "artifact" and line.get("runID") == run["runID"]
                and line.get("artifact") == run["artifacts"][0], "Artifact JSON line differs from report")
        require(run["result"]["metadata"].get("modelRevision") == revision, "Backend model revision missing")
        images.append(check_png(run["artifacts"][0], artifact_root, run["runID"]))
    require(len({image["path"] for image in images}) == len(images), "Repeated runs reused output paths")
    require(len({image["sha256"] for image in images}) == 1, "Same-seed image changed within the process")
    growth = max(memory["activeBytes"] for memory in memories) - memories[0]["activeBytes"]
    require(growth == 0, f"Released active allocation grew {growth} bytes; inspect the actual trend")
    measurements.update(artifacts=images, maximumReleasedGrowthBytes=growth, allowedGrowthBytes=0)
    return measurements


def main():
    manifest = json.loads((PROBE / "model-manifest.json").read_text(encoding="utf-8"))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT.parent / "BuildCaches/D-MLX/Build/Products/Debug/d-infer")
    parser.add_argument("--model", type=Path, default=ROOT.parent / "D-Development/Models/FLUX.2-klein-4B-q8")
    parser.add_argument("--reports", type=Path, default=ROOT.parent / "D-Development/Logs" /
                        ("image-cli-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")))
    parser.add_argument("--timeout", type=float, default=300, help="Bounded timeout per child, seconds")
    parser.add_argument("--offline-only", action="store_true", help="Only help and invalid arguments; no model load or verification")
    args = parser.parse_args()
    if not args.binary.is_file() or not os.access(args.binary, os.X_OK):
        parser.error(f"Executable not found: {args.binary}")
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    binary, model, destination = args.binary.resolve(), args.model.resolve(), args.reports.resolve()
    if destination == model or model in destination.parents:
        parser.error("Reports must be outside the model directory")
    destination.mkdir(parents=True, exist_ok=False)
    revision = manifest["revision"]
    base = ["--capability", "image", "--model", str(model), "--prompt", PROMPT, "--revision", revision]
    cases = [
        ("help", ["--help"], None, False),
        ("invalid-capability", ["--model", str(model), "--prompt", PROMPT, "--capability", "video"], None, False),
        ("invalid-missing-artifacts", base, None, False),
        ("invalid-relative-artifacts", base + ["--artifacts", "relative"], None, False),
        ("invalid-model-artifacts", base + ["--artifacts", str(model / "must-not-be-created")], None, False),
        ("invalid-guidance", base + ["--guidance", "nan"], None, True),
        ("invalid-seed", base + ["--seed", "-1"], None, True),
        ("invalid-width", base + ["--width", "0"], None, True),
        ("invalid-mixed-flags", base + ["--max-tokens", "1"], None, True),
        ("invalid-image-flags-in-text", ["--model", str(model), "--prompt", PROMPT, "--width", "512"], None, False),
    ]
    if not args.offline_only:
        cases += [
            ("missing-model", ["--capability", "image", "--model", str(destination / "absent-model"),
                               "--prompt", PROMPT, "--revision", revision], None, True),
            ("memory-rejection", base + ["--memory-budget-mib", "1"], None, True),
            ("repeat-three", base + ["--repeat", "3"], None, True),
            ("cancel-after-step", base + ["--cancel-after-steps", "1", "--repeat", "3"], None, True),
            ("sigint", base + ["--repeat", "3"], "SIGINT", True),
            ("sigterm", base + ["--repeat", "3"], "SIGTERM", True),
            ("broken-pipe", base, "broken-pipe", True),
        ]
    summary = {"schemaVersion": 1, "scope": "B2 image CLI", "offlineOnly": args.offline_only,
               "binary": str(binary), "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
               "model": str(model), "modelRepository": manifest["repository"], "modelRevision": revision,
               "expectedCaseCount": len(cases), "cases": [], "complete": False, "passed": False}
    started = time.monotonic()
    write_json(destination / "summary.json", summary)
    try:
        if not args.offline_only:
            command = [sys.executable, str(PROBE / "download_model.py"), "--manifest", str(PROBE / "model-manifest.json"),
                       "--destination", str(model), "--verify-only"]
            result, _, _ = run_process(command, destination, "fixture-verification", args.timeout)
            summary["fixtureVerification"] = result
            require(result.get("returnCode") == 0 and "processError" not in result, "Pinned fixture verification failed")
        for name, options, trigger, add_artifacts in cases:
            report_path = destination / f"{name}.json"
            artifact_root = destination / f"{name}-artifacts"
            command = [str(binary)] + options + ["--report", str(report_path)]
            if add_artifacts:
                command += ["--artifacts", str(artifact_root)]
            result, stdout, stderr = run_process(command, destination, name, args.timeout, trigger)
            case = {"name": name, "passed": False, "returnCode": result.get("returnCode")}
            try:
                report = json.loads(report_path.read_text(encoding="utf-8")) if report_path.exists() else None
                case["measurements"] = validate_case(name, result, stdout, stderr, report, revision, artifact_root)
                case["passed"] = True
            except Exception as error:
                case["failure"] = f"{type(error).__name__}: {error}"
            summary["cases"].append(case)
            write_json(destination / "summary.json", summary)
            print(f"{'PASS' if case['passed'] else 'FAIL'} {name}: {case.get('failure', '')}", flush=True)
            # Stop on failure rather than launch more expensive inference after a regression.
            require(case["passed"], f"{name}: {case.get('failure')}")
        summary["complete"] = True
        summary["passed"] = True
    except Exception as error:
        summary["failure"] = f"{type(error).__name__}: {error}"
    finally:
        summary["elapsedSeconds"] = time.monotonic() - started
        write_json(destination / "summary.json", summary)
    print(destination / "summary.json", flush=True)
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
