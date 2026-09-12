#!/usr/bin/env python3
"""CPU-only contract checks for the portable-kit d-infer CLI.

Every binary invocation uses --inspect or fails during argument parsing. The checks
therefore exercise no model generation and never launch the audio provider.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any


MIB = 1024 * 1024
AUDIO_REVISION = "da6edc54ddba10bfd79a077102ded687f80e882b"


class VerificationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def write_text_model(root: Path) -> Path:
    model = root / "text-model"
    model.mkdir()
    config = {
        "model_type": "qwen2",
        "hidden_size": 128,
        "num_hidden_layers": 2,
        "num_attention_heads": 4,
        "num_key_value_heads": 2,
        "max_position_embeddings": 65536,
        "vocab_size": 1024,
        "intermediate_size": 256,
    }
    (model / "config.json").write_text(json.dumps(config), encoding="utf-8")
    (model / "tokenizer.json").write_text("{}", encoding="utf-8")
    (model / "tokenizer_config.json").write_text("{}", encoding="utf-8")
    (model / "model.safetensors").write_bytes(b"fixture00")
    return model


def write_audio_fixture(root: Path) -> dict[str, Path]:
    model = root / "audio-model"
    vendor = root / "audio-vendor"
    artifacts = root / "audio-artifacts"
    model.mkdir()
    vendor.mkdir()
    artifacts.mkdir()
    paths = [
        "MLX/dit_sm-music_f16.npz",
        "MLX/t5gemma_f16.npz",
        "MLX/same_s_encoder_f32.npz",
        "MLX/same_s_decoder_f32.npz",
    ]
    files = []
    for relative in paths:
        destination = model / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(b"x")
        files.append({"path": relative, "size": 1, "sha256": "0" * 64})
    manifest = root / "audio-manifest.json"
    manifest.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "repository": "stabilityai/stable-audio-3-optimized",
                "revision": AUDIO_REVISION,
                "files": files,
            }
        ),
        encoding="utf-8",
    )
    sentinel = root / "provider-was-executed"
    provider = root / "provider.py"
    provider.write_text(
        "from pathlib import Path\nPath(" + repr(str(sentinel)) + ").write_text('bad')\n",
        encoding="utf-8",
    )
    return {
        "model": model,
        "vendor": vendor,
        "artifacts": artifacts,
        "manifest": manifest,
        "provider": provider,
        "sentinel": sentinel,
    }


def invoke(binary: Path, reports: Path, name: str, arguments: list[str]) -> tuple[subprocess.CompletedProcess[str], dict[str, Any]]:
    report_path = reports / f"{name}.json"
    command = [str(binary), *arguments, "--report", str(report_path)]
    environment = os.environ.copy()
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    process = subprocess.run(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="strict",
        timeout=30,
        check=False,
        env=environment,
    )
    require(report_path.is_file(), f"{name}: CLI did not write its JSON report")
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"{name}: invalid JSON report: {error}") from error
    require(report.get("schemaVersion") == 1, f"{name}: schemaVersion changed")
    require(report.get("tool") == "d-infer", f"{name}: wrong report tool")
    require(report.get("exitCode") == process.returncode, f"{name}: report/process exit mismatch")
    return process, report


def inspect_success(binary: Path, reports: Path, name: str, arguments: list[str], within_budget: bool) -> dict[str, Any]:
    process, report = invoke(binary, reports, name, [*arguments, "--inspect"])
    require(process.returncode == 0, f"{name}: inspect exited {process.returncode}: {process.stderr}")
    require(process.stdout == "", f"{name}: inspect emitted generation stdout")
    require(report.get("runs") == [], f"{name}: inspect report contains runs")
    inspection = report.get("inspection")
    require(isinstance(inspection, dict), f"{name}: inspection object missing")
    estimate = inspection.get("estimate")
    require(isinstance(estimate, dict), f"{name}: estimate missing")
    require(isinstance(estimate.get("peakBytes"), int) and estimate["peakBytes"] > 0,
            f"{name}: invalid peakBytes")
    require(estimate.get("confidence") in {"estimated", "measured"}, f"{name}: invalid confidence")
    require(inspection.get("withinBudget") is within_budget, f"{name}: wrong budget decision")
    require(isinstance(report.get("backend"), dict), f"{name}: backend descriptor missing")
    return report


def invalid_arguments(binary: Path, reports: Path, name: str, arguments: list[str]) -> None:
    process, report = invoke(binary, reports, name, arguments)
    require(process.returncode == 2, f"{name}: expected argument exit 2, got {process.returncode}")
    require(report.get("runs") == [], f"{name}: invalid arguments created a run")
    require("inspection" not in report, f"{name}: invalid arguments produced an inspection")


def inspect_failure(binary: Path, reports: Path, name: str, arguments: list[str]) -> dict[str, Any]:
    process, report = invoke(binary, reports, name, [*arguments, "--inspect"])
    require(process.returncode == 1, f"{name}: expected inspection exit 1, got {process.returncode}")
    require(process.stdout == "", f"{name}: failed inspect emitted generation stdout")
    require(report.get("runs") == [], f"{name}: failed inspect created a run")
    require("inspection" not in report, f"{name}: failed inspect reported a successful estimate")
    return report


def verify(binary: Path, root: Path) -> int:
    reports = root / "reports"
    reports.mkdir()
    model = write_text_model(root)
    base = ["--model", str(model), "--prompt", "直接提示🙂"]
    passed = 0

    default_report = inspect_success(binary, reports, "defaults", base, True)
    options = default_report["options"]
    require(options["maxTokens"] == 64, "defaults: maxTokens changed")
    require(options["maxPromptTokens"] == 2048, "defaults: maxPromptTokens missing")
    require(options["maxOutputTokens"] == 1024, "defaults: maxOutputTokens missing")
    require(options["cacheLimitMiB"] == 64, "defaults: cacheLimitMiB missing")
    passed += 1

    inspect_success(binary, reports, "over-budget", [*base, "--memory-budget-mib", "1"], False)
    passed += 1

    prompt = root / "提示🙂.txt"
    prompt.write_text("中文🙂\n", encoding="utf-8")
    file_report = inspect_success(
        binary, reports, "prompt-file-unicode",
        ["--model", str(model), "--prompt-file", str(prompt)], True,
    )
    require(file_report["options"]["prompt"] == "中文🙂\n", "prompt file contents were not frozen")
    require(file_report["options"]["promptFile"] == str(prompt), "prompt file path missing from report")
    passed += 1

    empty = root / "empty.txt"
    empty.write_bytes(b"")
    inspect_success(binary, reports, "prompt-file-empty", ["--model", str(model), "--prompt-file", str(empty)], True)
    passed += 1

    exact = root / "exact-limit.txt"
    exact.write_bytes(b"a" * MIB)
    inspect_success(binary, reports, "prompt-file-exact-limit",
                    ["--model", str(model), "--prompt-file", str(exact)], True)
    passed += 1

    non_utf8 = root / "non-utf8.txt"
    non_utf8.write_bytes(b"\xff")
    oversized = root / "oversized.txt"
    oversized.write_bytes(b"a" * (MIB + 1))
    symlink = root / "prompt-link.txt"
    symlink.symlink_to(prompt)
    prompt_directory = root / "prompt-directory"
    prompt_directory.mkdir()
    invalid_prompt_cases = {
        "prompt-both": [*base, "--prompt-file", str(prompt)],
        "prompt-missing": ["--model", str(model), "--inspect"],
        "prompt-relative": ["--model", str(model), "--prompt-file", "relative.txt", "--inspect"],
        "prompt-non-utf8": ["--model", str(model), "--prompt-file", str(non_utf8), "--inspect"],
        "prompt-oversized": ["--model", str(model), "--prompt-file", str(oversized), "--inspect"],
        "prompt-symlink": ["--model", str(model), "--prompt-file", str(symlink), "--inspect"],
        "prompt-directory": ["--model", str(model), "--prompt-file", str(prompt_directory), "--inspect"],
    }
    for name, arguments in invalid_prompt_cases.items():
        invalid_arguments(binary, reports, name, arguments)
        passed += 1

    lower = inspect_success(
        binary, reports, "text-lower-bounds",
        [*base, "--max-tokens", "1", "--max-prompt-tokens", "1",
         "--max-output-tokens", "1", "--cache-limit-mib", "0"], True,
    )
    require(lower["options"]["cacheLimitMiB"] == 0, "lower bounds were not preserved")
    passed += 1
    upper = inspect_success(
        binary, reports, "text-upper-bounds",
        [*base, "--max-tokens", "8192", "--max-prompt-tokens", "32768",
         "--max-output-tokens", "8192", "--cache-limit-mib", "1024",
         "--memory-budget-mib", "4096"], True,
    )
    require(upper["options"]["maxOutputTokens"] == 8192, "upper bounds were not preserved")
    passed += 1

    invalid_numeric_cases = {
        "max-prompt-zero": [*base, "--max-prompt-tokens", "0", "--inspect"],
        "max-prompt-high": [*base, "--max-prompt-tokens", "32769", "--inspect"],
        "max-output-zero": [*base, "--max-output-tokens", "0", "--inspect"],
        "max-output-high": [*base, "--max-output-tokens", "8193", "--inspect"],
        "cache-negative": [*base, "--cache-limit-mib", "-1", "--inspect"],
        "cache-high": [*base, "--cache-limit-mib", "1025", "--inspect"],
        "max-token-config": [*base, "--max-tokens", "2", "--max-output-tokens", "1", "--inspect"],
        "inspect-value": [*base, "--inspect=true"],
        "inspect-repeated": [*base, "--inspect", "--inspect"],
    }
    for name, arguments in invalid_numeric_cases.items():
        invalid_arguments(binary, reports, name, arguments)
        passed += 1

    missing = root / "missing-model"
    inspect_failure(binary, reports, "missing-model", ["--model", str(missing), "--prompt", "x"])
    passed += 1

    image_artifacts = root / "image-artifacts"
    image_arguments = [
        "--model", str(missing), "--prompt", "x", "--capability", "image",
        "--artifacts", str(image_artifacts), "--memory-budget-mib", "4",
    ]
    image_report = inspect_failure(
        binary, reports, "image-memory-accepted",
        [*image_arguments, "--image-memory-limit-mib", "4"],
    )
    require(image_report["options"]["imageMemoryLimitMiB"] == 4,
            "accepted image memory limit missing from report")
    passed += 1
    invalid_arguments(binary, reports, "image-memory-zero",
                      [*image_arguments, "--image-memory-limit-mib", "0", "--inspect"])
    passed += 1
    invalid_arguments(binary, reports, "image-memory-over-budget",
                      [*image_arguments, "--image-memory-limit-mib", "5", "--inspect"])
    passed += 1
    invalid_arguments(binary, reports, "image-option-on-text",
                      [*base, "--image-memory-limit-mib", "1", "--inspect"])
    passed += 1
    invalid_arguments(
        binary, reports, "text-option-on-image",
        [*image_arguments, "--max-prompt-tokens", "1", "--inspect"],
    )
    passed += 1

    audio = write_audio_fixture(root)
    audio_arguments = [
        "--model", str(audio["model"]), "--prompt", "audio inspect",
        "--capability", "audio", "--artifacts", str(audio["artifacts"]),
        "--steps", "8", "--guidance", "1", "--audio-profile", "sm-music",
        "--audio-python", "/usr/bin/true", "--audio-script", str(audio["provider"]),
        "--audio-vendor", str(audio["vendor"]), "--audio-manifest", str(audio["manifest"]),
        "--audio-license-acknowledged", "true", "--revision", AUDIO_REVISION,
    ]
    inspect_success(binary, reports, "audio-provider-not-executed", audio_arguments, True)
    require(not audio["sentinel"].exists(), "audio provider executed during inspection")
    require(not any(audio["artifacts"].iterdir()), "audio inspection generated an artifact")
    passed += 1

    return passed


def main() -> int:
    binary_raw = os.environ.get("D_TESTKIT_CLI")
    temp_raw = os.environ.get("D_TEST_TEMP_DIR")
    require(bool(binary_raw), "D_TESTKIT_CLI must name the Lead-built d-infer binary")
    require(bool(temp_raw), "D_TEST_TEMP_DIR must name the authorized temporary root")
    binary = Path(binary_raw).resolve(strict=True)
    temp_root = Path(temp_raw).resolve(strict=True)
    require(binary.is_file(), "D_TESTKIT_CLI is not a regular file")
    require(os.access(binary, os.X_OK), "D_TESTKIT_CLI is not executable")
    require(temp_root.is_dir(), "D_TEST_TEMP_DIR is not a directory")

    with tempfile.TemporaryDirectory(prefix="verify-testkit-cli-", dir=temp_root) as temporary:
        count = verify(binary, Path(temporary))
    print(f"PASS verify-testkit-cli: {count} CPU-only inspect/argument cases")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.SubprocessError, VerificationError) as error:
        print(f"FAIL verify-testkit-cli: {error}", file=sys.stderr)
        raise SystemExit(1)
