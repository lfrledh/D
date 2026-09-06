#!/usr/bin/env python3
"""Run an isolated probe with a time limit and sampled process RSS evidence.

The RSS threshold is a watchdog, not a hard allocation limit. MLX reports its
own GPU allocations separately; sampled RSS is not a replacement for those.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--log-prefix", required=True, type=Path)
parser.add_argument("--timeout-seconds", type=int, default=900)
parser.add_argument("--rss-limit-gib", type=float, default=13.0)
parser.add_argument("command", nargs=argparse.REMAINDER)
args = parser.parse_args()
command = args.command[1:] if args.command[:1] == ["--"] else args.command
if not command or args.timeout_seconds <= 0 or args.rss_limit_gib <= 0:
    parser.error("supply a command and positive watchdog limits")
args.log_prefix.parent.mkdir(parents=True, exist_ok=True)
started = time.monotonic()
samples = []
reason = None


def interrupted(signum, frame):
    raise KeyboardInterrupt(f"Monitor received signal {signum}")


signal.signal(signal.SIGTERM, interrupted)


def terminate_group(process):
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=10)


with args.log_prefix.with_suffix(".stdout.log").open("wb") as stdout, args.log_prefix.with_suffix(".stderr.log").open("wb") as stderr:
    process = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
    try:
        while process.poll() is None:
            elapsed = time.monotonic() - started
            result = subprocess.run(["ps", "-o", "rss=", "-p", str(process.pid)], capture_output=True, text=True, timeout=3)
            rss = int(result.stdout.strip() or "0") * 1024
            samples.append({"elapsedSeconds": round(elapsed, 3), "rssBytes": rss})
            if elapsed > args.timeout_seconds:
                reason = "timeout"
            elif rss > args.rss_limit_gib * 1024**3:
                reason = "sampled_rss_threshold"
            if reason:
                terminate_group(process)
                break
            time.sleep(1)
    except BaseException:
        reason = "monitor_interrupted"
        terminate_group(process)
        raise
    finally:
        code = process.wait(timeout=10)
        report = {
            "command": command,
            "exitCode": code,
            "watchdogReason": reason,
            "elapsedSeconds": time.monotonic() - started,
            "sampledPeakRSSBytes": max((x["rssBytes"] for x in samples), default=0),
            "rssSamplingIntervalSeconds": 1,
            "timeoutSeconds": args.timeout_seconds,
            "rssLimitBytes": int(args.rss_limit_gib * 1024**3),
            "samples": samples,
        }
        args.log_prefix.with_suffix(".process.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({key: value for key, value in report.items() if key != "samples"}))
raise SystemExit(code if 0 <= code <= 255 else 1)
