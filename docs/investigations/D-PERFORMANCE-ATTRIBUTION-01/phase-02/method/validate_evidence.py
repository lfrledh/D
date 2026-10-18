#!/usr/bin/env python3
"""Read-only checks for normalized diagnostic evidence, not a trace parser.

This tool does not open applications, send input, inspect a Mac, calculate FPS,
validate xctrace schemas, or decide causality. Exit 0 only means that the supplied
manifest passes these structural/accounting checks. Templates are not evidence.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path
from typing import Any

SHA = re.compile(r"^[0-9a-f]{40}$")
INTERACTIONS = {"NODE", "PAN", "ZOOM", "IDLE"}
VALIDITIES = {"VALID", "QUALIFIED", "INVALID", "BLOCKED"}
COVERAGE_STATUSES = {
    "OBSERVED", "CAUSAL_SUPPORT", "COUNTEREVIDENCE", "MIXED",
    "INCONCLUSIVE", "BLOCKED", "NOT_MEASURED", "SOURCE_ONLY",
}


def number(value: Any) -> bool:
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(float(value)))


def nonempty(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def validate_capture(data: Any) -> list[str]:
    errors: list[str] = []
    if not isinstance(data, dict):
        return ["capture must be a JSON object"]
    if data.get("template_only", True):
        errors.append("template_only must be false for submitted evidence")
    if not nonempty(data.get("capture_id")):
        errors.append("capture_id is required")
    if not isinstance(data.get("interaction"), str) or data["interaction"] not in INTERACTIONS:
        errors.append("interaction must be NODE, PAN, ZOOM or IDLE")
    validity = data.get("validity")
    if not isinstance(validity, str):
        validity = "INVALID_TYPE"
    if validity not in VALIDITIES:
        errors.append("validity must explicitly classify the capture")
    if validity != "VALID" and not nonempty(data.get("reason")):
        errors.append("qualified, invalid or blocked captures require a reason")

    def obj(name: str) -> dict[str, Any]:
        value = data.get(name)
        if not isinstance(value, dict):
            errors.append(f"{name} must be an object")
            return {}
        return value

    baseline = obj("baseline")
    timing = obj("timing")
    sched = obj("scheduler")
    samples = obj("samples")
    pres = obj("presentation")
    inputs = obj("inputs")
    tools = obj("tools")
    if validity in {"VALID", "QUALIFIED"}:
        if not isinstance(baseline.get("source_sha"), str) or not SHA.fullmatch(baseline["source_sha"]):
            errors.append("usable captures require the full 40-character source SHA")
        for field in ("build_configuration", "binary_uuid"):
            if not nonempty(baseline.get(field)):
                errors.append(f"baseline.{field} is required")
        for field in ("process_identity_verified", "isolation_verified"):
            if baseline.get(field) is not True:
                errors.append(f"baseline.{field} must be verified for a usable capture")
        if not data.get("sources"):
            errors.append("usable captures need trace/derived evidence references")
        if not nonempty(data.get("scene_fingerprint")):
            errors.append("usable captures need a scene fingerprint or explicit legacy-unknown reference")
    if validity == "VALID" and data.get("interaction") != "IDLE":
        if inputs.get("route_verified") is not True:
            errors.append("VALID interaction capture requires verified input route")
        if not nonempty(timing.get("actual_input_basis")):
            errors.append("VALID interaction capture requires actual input basis, not only cue times")
        if not isinstance(data.get("automation_level"), str) or data["automation_level"] not in {
            "A_NATIVE_TARGETED", "B_IN_PROCESS", "C_COMPONENT_OFFSCREEN", "MANUAL_SINGLE_SESSION"
        }:
            errors.append("VALID interaction capture must declare automation/evidence level")

    start, end = timing.get("active_start_s"), timing.get("active_end_s")
    duration = None
    if start is not None or end is not None:
        if not (number(start) and number(end) and 0 <= start < end):
            errors.append("active window must be finite, nonnegative and ordered")
        else:
            duration = end - start
    if validity in {"VALID", "QUALIFIED"} and duration is None:
        errors.append("usable capture requires a valid analysis window")

    window = sched.get("window_s")
    if window is not None:
        tolerance = sched.get("tolerance_s", 1e-6)
        if not number(tolerance) or tolerance < 0:
            errors.append("scheduler.tolerance_s must be finite and nonnegative")
            tolerance = 1e-6
        if not number(window) or window <= 0:
            errors.append("scheduler.window_s must be positive")
        else:
            if duration is not None and abs(window - duration) > tolerance:
                errors.append("scheduler window differs from selected analysis window")
            names = ["running_s", "runnable_s", "blocked_s", "other_states_s", "unobserved_s", "overlap_s"]
            values = [sched.get(n) for n in names]
            if any(not number(x) or x < 0 for x in values):
                errors.append("all scheduler state/unknown/overcount fields must be explicit nonnegative seconds")
            else:
                # overlap_s is documented duplicate-count excess, not the union of overlaps.
                accounted = sum(values[:5]) - values[5]
                if abs(accounted - window) > tolerance:
                    errors.append(f"scheduler has unexplained accounting residual: {window-accounted:.9f} s")
            if not nonempty(sched.get("source")):
                errors.append("scheduler needs source/schema/accounting reference")

    for field in ("running_weight_ms", "self_total_ms", "unclassified_weight_ms", "unsymbolicated_weight_ms"):
        val = samples.get(field)
        if val is not None and (not number(val) or val < 0):
            errors.append(f"samples.{field} must be null or finite nonnegative ms")
    weight, self_total = samples.get("running_weight_ms"), samples.get("self_total_ms")
    if number(weight) and number(self_total) and not math.isclose(weight, self_total, rel_tol=1e-6, abs_tol=1e-6):
        errors.append("self_total_ms (including unknown leaf weight) must reconcile to running sample weight")
    if samples.get("inclusive_overlap_declared") is not True:
        errors.append("inclusive overlap must be explicitly declared")

    metric_fields = ("unique_presentations", "p50_ms", "p95_ms", "fps", "input_to_display_p95_ms")
    metric_present = any(pres.get(k) is not None for k in metric_fields)
    for field in metric_fields:
        val = pres.get(field)
        if val is not None and (not number(val) or val < 0):
            errors.append(f"presentation.{field} must be null or finite nonnegative")
    if metric_present:
        if pres.get("status") != "ASSOCIATED":
            errors.append("display metrics require ASSOCIATED status")
        if not nonempty(pres.get("mapping_evidence")):
            errors.append("display metrics require actual target/window/surface mapping evidence")
        count = pres.get("unique_presentations")
        if not isinstance(count, int) or isinstance(count, bool) or count <= 0:
            errors.append("display metrics require a positive unique presentation count")
        if data.get("automation_level") == "C_COMPONENT_OFFSCREEN":
            errors.append("offscreen component captures cannot claim displayed frame metrics")
        if pres.get("input_to_display_p95_ms") is not None and not nonempty(timing.get("clock_alignment_evidence")):
            errors.append("input-to-display latency requires clock alignment and event-to-content mapping reference")
    if validity == "VALID" and (tools.get("wrapper_exit_code") not in (0, None) or tools.get("child_exit_code") not in (0, None)):
        errors.append("nonzero exits require QUALIFIED/INVALID classification and explicit reasoning")
    return errors


def validate_coverage(data: Any) -> list[str]:
    if not isinstance(data, dict):
        return ["coverage must be an object"]
    errors: list[str] = []
    if data.get("template_only", True):
        errors.append("coverage template_only must be false")
    cells = data.get("cells")
    if not isinstance(cells, list):
        return errors + ["coverage.cells must be a list"]
    expected = {(f"H{i:02}", action) for i in range(1, 11) for action in ("NODE", "PAN", "ZOOM")}
    seen: set[tuple[str, str]] = set()
    for cell in cells:
        if not isinstance(cell, dict):
            errors.append("each coverage cell must be an object")
            continue
        pair = (cell.get("hypothesis_id"), cell.get("interaction"))
        if not all(isinstance(x, str) for x in pair):
            errors.append("coverage IDs must be strings")
            continue
        if pair not in expected:
            errors.append(f"unexpected coverage pair {pair}")
        if pair in seen:
            errors.append(f"duplicate coverage pair {pair}")
        seen.add(pair)
        status = cell.get("status")
        if not isinstance(status, str):
            status = "INVALID_TYPE"
        if status not in COVERAGE_STATUSES:
            errors.append(f"{pair}: unexamined/invalid final status")
        if status in {"BLOCKED", "NOT_MEASURED", "INCONCLUSIVE"} and not nonempty(cell.get("reason")):
            errors.append(f"{pair}: unresolved status needs a concrete reason")
        if status in {"OBSERVED", "CAUSAL_SUPPORT", "COUNTEREVIDENCE", "MIXED", "SOURCE_ONLY"} and not cell.get("evidence"):
            errors.append(f"{pair}: evidence/source reference required")
        for key in ("evidence", "counterevidence", "limitations"):
            if not isinstance(cell.get(key), list):
                errors.append(f"{pair}: {key} must be a list")
        if status == "CAUSAL_SUPPORT" and not cell.get("limitations"):
            errors.append(f"{pair}: causal support needs explicit scope/limitations, not a universal claim")
    missing = sorted(expected - seen)
    if missing:
        errors.append(f"missing coverage pairs: {missing}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", action="append", type=Path, default=[], help="normalized capture JSON, repeatable")
    parser.add_argument("--coverage", type=Path, help="completed coverage JSON")
    args = parser.parse_args()
    if not args.capture and not args.coverage:
        parser.error("supply --capture and/or --coverage")
    errors: list[str] = []
    for path, validator in ([(p, validate_capture) for p in args.capture] + ([(args.coverage, validate_coverage)] if args.coverage else [])):
        try:
            content = json.loads(path.read_text(encoding="utf-8"))
            errors += [f"{path.name}: {e}" for e in validator(content)]
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            errors.append(f"{path.name}: cannot read JSON: {exc}")
    print(json.dumps({
        "status": "INVALID_MANIFEST" if errors else "MANIFEST_CHECKS_PASSED",
        "boundary": "Not a trace authenticity, causality, native smoothness or product acceptance verdict.",
        "errors": errors,
    }, ensure_ascii=False, indent=2))
    return 2 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
