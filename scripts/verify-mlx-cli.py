#!/usr/bin/env python3
"""Run sequential, real-model CLI acceptance checks without downloading or building."""

import argparse
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]
LONG_PROMPT = (
    "Count from 1 to 1000, writing every integer on its own line. "
    "Do not abbreviate, explain, or stop early. Start with 1 now."
)


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def run_process(command, destination, name, timeout, trigger=None):
    """Only signal the Popen child, drain both pipes, and always reap it."""
    started = time.monotonic()
    result = {"command": command, "trigger": trigger, "triggered": False}
    process = None
    selector = selectors.DefaultSelector()
    output = {"stdout": bytearray(), "stderr": bytearray()}
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=ROOT)
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        deadline = started + timeout
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"Process exceeded {timeout:g} seconds")
            for key, _ in selector.select(min(0.2, remaining)):
                channel = key.data
                first_byte_trigger = channel == "stdout" and trigger and not result["triggered"]
                chunk = os.read(key.fileobj.fileno(), 1 if first_byte_trigger else 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                output[channel].extend(chunk)
                if first_byte_trigger:
                    result["firstStdoutSeconds"] = time.monotonic() - started
                    if trigger == "broken-pipe":
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
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
            # A killed process must be reaped even after a timeout or a pipe/signal error.
            result["returnCode"] = process.wait(timeout=10)
            for pipe in (process.stdout, process.stderr):
                if pipe is not None and not pipe.closed:
                    pipe.close()
        selector.close()
        result["elapsedSeconds"] = time.monotonic() - started
        for channel, content in output.items():
            (destination / f"{name}.{channel}.log").write_bytes(content)
        write_json(destination / f"{name}.process.json", result)
    return result, output["stdout"].decode("utf-8", errors="replace"), output["stderr"].decode("utf-8", errors="replace")


def released_memory(run):
    events = run.get("lifecycle", [])
    phases = [event["phase"] for event in events]
    require(phases == ["loading", "loaded", "generating", "drained", "released"],
            f"Unexpected lifecycle: {phases}")
    require(all(event["runID"] == run["runID"] for event in events), "Lifecycle run IDs differ")
    require(all(a["uptimeSeconds"] <= b["uptimeSeconds"] for a, b in zip(events, events[1:])),
            "Lifecycle timestamps moved backwards")
    memory = events[-1]["memory"]
    require(memory["cacheBytes"] == 0, f"Released MLX cache is {memory['cacheBytes']} bytes")
    require(memory["activeBytes"] >= 0 and memory["peakBytes"] >= memory["activeBytes"],
            f"Invalid released memory snapshot: {memory}")
    return memory


def validate_case(name, process, stdout, stderr, report, revision):
    require("processError" not in process, process.get("processError", "Process error"))
    if name == "help":
        require(process["returnCode"] == 0, "Help did not exit 0")
        require("Usage: d-infer" in stdout, "Help text missing")
        require("Run " not in stderr and "loading" not in stderr, "Help initialized a run")
        require(report is None, "Help unexpectedly wrote an execution report")
        return {"backendDiagnosticsAbsent": True}

    require(isinstance(report, dict), "Execution report is missing or invalid")
    require(report.get("schemaVersion") == 1 and report.get("tool") == "d-infer", "Unknown report schema")
    require(report.get("exitCode") == process["returnCode"], "Report and process exit codes differ")
    require(report.get("system", {}).get("physicalMemoryBytes", 0) > 0, "System memory missing")
    runs = report.get("runs", [])

    if name == "invalid-arguments":
        require(process["returnCode"] == 2, "Invalid arguments must exit 2")
        require(not runs and bool(report.get("failure")), "Argument failure must precede any run")
        return {}

    require(report.get("options", {}).get("revision") == revision, "Fixture revision was not preserved")
    if name in ("missing-model", "memory-rejection"):
        require(process["returnCode"] == 1, "Rejected request must exit 1")
        require(len(runs) == 1 and runs[0]["outcome"] == "failed", "Expected one failed run")
        require(not runs[0].get("lifecycle"), "Rejected request started model loading")
        if name == "memory-rejection":
            require("memoryBudgetExceeded" in runs[0].get("failure", {}), "Wrong budget failure")
        return {"failure": runs[0].get("failure"), "lifecycleCount": 0}

    expected_runs = 5 if name == "repeat-five" else 1
    require(len(runs) == expected_runs, f"Expected {expected_runs} runs, got {len(runs)}")
    require(len({run["runID"] for run in runs}) == len(runs), "Repeated run ID")
    memories = [released_memory(run) for run in runs]
    measurements = {
        "releasedActiveBytes": [memory["activeBytes"] for memory in memories],
        "releasedCacheBytes": [memory["cacheBytes"] for memory in memories],
        "peakBytes": [memory["peakBytes"] for memory in memories],
        "firstChunkSeconds": [run.get("firstChunkSeconds") for run in runs],
        "cancellationLatencySeconds": [run.get("cancellationLatencySeconds") for run in runs],
    }

    if name in ("max-tokens-one", "repeat-five"):
        require(process["returnCode"] == 0, "Successful inference must exit 0")
        require(all(run["outcome"] == "completed" and run["text"] for run in runs),
                "Successful inference did not produce text")
        require(all(run["result"]["metadata"].get("modelRevision") == revision for run in runs),
                "Backend result revision differs from fixture")
        if name == "max-tokens-one":
            require(int(runs[0]["result"]["metadata"]["generationTokens"]) == 1,
                    "--max-tokens 1 did not generate exactly one token")
            require(report["options"]["maxTokens"] == 1, "Requested token limit missing")
        else:
            baseline = memories[0]["activeBytes"]
            growth = max(memory["activeBytes"] for memory in memories) - baseline
            measurements["maximumReleasedGrowthBytes"] = growth
            # Detect the original 2720-byte/load regression while allowing small bookkeeping noise.
            measurements["allowedGrowthBytes"] = 1024
            require(growth <= 1024,
                    f"Released allocation grew by {growth} bytes over the first run")
        return measurements

    run = runs[0]
    require(run["chunkCount"] >= 1, "Cancellation was not exercised after text output")
    if name == "broken-pipe":
        require(process["triggered"], "No stdout byte arrived before pipe close")
        require(process["returnCode"] != 0 and bool(run.get("outputError")),
                "Broken pipe did not preserve a nonzero result and outputError")
        measurements["outputError"] = run["outputError"]
        return measurements

    require(process["returnCode"] == 130 and run["outcome"] == "cancelled", "Expected drained cancellation")
    require(run.get("cancellationLatencySeconds", -1) >= 0, "Cancellation latency missing")
    if name in ("sigint", "sigterm"):
        expected_signal = int(signal.SIGINT if name == "sigint" else signal.SIGTERM)
        require(process["triggered"], "No stdout byte arrived before signal")
        require(report.get("terminationSignal") == expected_signal, "Wrong termination signal in report")
        require(report["options"]["repeatCount"] == 3, "Repeat-stop signal case was not configured")
    return measurements


def main():
    fixture = json.loads((ROOT / "fixtures/text-model.json").read_text(encoding="utf-8"))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path,
                        default=ROOT.parent / "BuildCaches/D-MLX/Build/Products/Debug/d-infer")
    parser.add_argument("--model", type=Path,
                        default=ROOT.parent / "D-Development/Models" / fixture["directoryName"])
    parser.add_argument("--reports", type=Path,
                        default=ROOT.parent / "D-Development/Logs/cli-acceptance")
    parser.add_argument("--timeout", type=float, default=90, help="Per-process timeout in seconds (default: 90)")
    args = parser.parse_args()
    if not args.binary.is_file() or not os.access(args.binary, os.X_OK):
        parser.error(f"Executable not found: {args.binary}")
    if not args.model.is_dir():
        parser.error(f"Local fixture model not found: {args.model}")
    if not 0 < args.timeout < float("inf"):
        parser.error("--timeout must be a finite positive value")
    binary, model, destination = args.binary.resolve(), args.model.resolve(), args.reports.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    revision = fixture["revision"]
    base = ["--model", str(model), "--prompt", LONG_PROMPT, "--revision", revision]
    missing = destination / ("missing-model-" + uuid.uuid4().hex)
    cases = [
        ("help", ["--help"], None),
        ("invalid-arguments", base + ["--max-tokens", "0"], None),
        ("missing-model", ["--model", str(missing), "--prompt", "Hello", "--revision", revision], None),
        ("memory-rejection", base + ["--memory-budget-mib", "1"], None),
        ("max-tokens-one", base + ["--max-tokens", "1"], None),
        ("repeat-five", base + ["--max-tokens", "32", "--repeat", "5"], None),
        ("cancel-after-chunk", base + ["--max-tokens", "512", "--cancel-after-chunks", "1"], None),
        ("sigint", base + ["--max-tokens", "512", "--repeat", "3"], "SIGINT"),
        ("sigterm", base + ["--max-tokens", "512", "--repeat", "3"], "SIGTERM"),
        ("broken-pipe", base + ["--max-tokens", "512"], "broken-pipe"),
    ]
    summary = {"schemaVersion": 1, "binary": str(binary), "model": str(model),
               "modelRepository": fixture["repository"], "modelRevision": revision,
               "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               "expectedCaseCount": len(cases), "complete": False, "passed": False, "cases": []}
    started = time.monotonic()
    write_json(destination / "summary.json", summary)
    verification_command = [sys.executable, str(ROOT / "scripts/download-test-model.py"),
                            "--destination", str(model), "--verify-only"]
    verification, _, _ = run_process(verification_command, destination, "fixture-verification", args.timeout)
    summary["fixtureVerification"] = {
        "passed": verification.get("returnCode") == 0 and "processError" not in verification,
        "returnCode": verification.get("returnCode"),
        "elapsedSeconds": verification["elapsedSeconds"],
        "processLog": str(destination / "fixture-verification.process.json"),
    }
    if not summary["fixtureVerification"]["passed"]:
        summary["failure"] = verification.get("processError", "Pinned fixture verification failed; no CLI cases were started.")
        summary["elapsedSeconds"] = time.monotonic() - started
        write_json(destination / "summary.json", summary)
        print(f"FAIL fixture-verification: {summary['failure']}", flush=True)
        print(f"Details: {destination / 'fixture-verification.stderr.log'}", flush=True)
        return 1
    print("PASS fixture-verification: pinned files, directory entries and provenance verified", flush=True)
    for name, arguments, trigger in cases:
        report_path = destination / f"{name}.json"
        # Never allow a previous invocation's report to satisfy a failed current invocation.
        report_path.unlink(missing_ok=True)
        command = [str(binary)] + arguments + ["--report", str(report_path)]
        process, stdout, stderr = run_process(command, destination, name, args.timeout, trigger)
        case = {"name": name, "returnCode": process.get("returnCode"),
                "elapsedSeconds": process["elapsedSeconds"], "report": str(report_path)}
        try:
            report = json.loads(report_path.read_text(encoding="utf-8")) if report_path.exists() else None
            if isinstance(report, dict):
                # Retain observed memory even when a later semantic assertion fails.
                case["observedReleasedMemory"] = [event["memory"] for run in report.get("runs", [])
                    for event in run.get("lifecycle", []) if event.get("phase") == "released"]
            case["measurements"] = validate_case(name, process, stdout, stderr, report, revision)
            case["passed"] = True
        except Exception as error:
            case["passed"] = False
            case["failure"] = f"{type(error).__name__}: {error}"
        summary["cases"].append(case)
        summary["complete"] = len(summary["cases"]) == len(cases)
        summary["passed"] = summary["complete"] and all(item["passed"] for item in summary["cases"])
        summary["elapsedSeconds"] = time.monotonic() - started
        write_json(destination / "summary.json", summary)
        print(f"{'PASS' if case['passed'] else 'FAIL'} {name}: exit={case['returnCode']} "
              f"{case['elapsedSeconds']:.3f}s" + (f" — {case['failure']}" if not case["passed"] else ""), flush=True)
    print(f"Summary: {destination / 'summary.json'}", flush=True)
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
