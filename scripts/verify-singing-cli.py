#!/usr/bin/env python3
"""Offline process verifier for frozen singing CLI parsing and inspection."""
import argparse, json, math, subprocess
from pathlib import Path

def absolute(value):
    p = Path(value)
    if not p.is_absolute(): raise argparse.ArgumentTypeError("must be absolute")
    return p

def inside(child, root):
    try: child.resolve().relative_to(root.resolve()); return True
    except ValueError: return False

def run(command, timeout):
    try:
        p = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=timeout, start_new_session=True, check=False)
        return {"exit": p.returncode, "stdout": p.stdout.decode("utf-8", "replace"), "stderr": p.stderr.decode("utf-8", "replace")}
    except subprocess.TimeoutExpired as e:
        return {"timeout": timeout, "stdout": (e.stdout or b"").decode("utf-8", "replace"), "stderr": (e.stderr or b"").decode("utf-8", "replace")}

def main():
    parser = argparse.ArgumentParser()
    for name in ("cli", "request", "model", "python", "script", "vendor", "profile", "vocoder", "output"):
        parser.add_argument("--" + name, required=True, type=absolute)
    parser.add_argument("--revision", required=True); parser.add_argument("--timeout", type=float, default=30)
    a = parser.parse_args()
    if not math.isfinite(a.timeout) or a.timeout <= 0: parser.error("--timeout must be finite and positive")
    roots = [a.cli, a.request, a.model, a.python, a.script.parent, a.vendor, a.profile, a.vocoder]
    if a.output.exists() or any(inside(a.output, x) or inside(x, a.output) for x in roots): parser.error("--output must be fresh and disjoint")
    if not a.cli.is_file() or not a.request.is_file(): parser.error("--cli and --request must be regular files")
    original = a.request.read_bytes(); a.output.mkdir(mode=0o700)
    request = a.output / "request.json"; request.write_bytes(original)
    artifacts = a.output / "artifacts"; artifacts.mkdir(mode=0o700)
    base = [str(a.cli), "--capability", "singing", "--model", str(a.model), "--revision", a.revision, "--singing-request", str(request), "--singing-python", str(a.python), "--singing-script", str(a.script), "--singing-vendor", str(a.vendor), "--singing-profile", str(a.profile), "--singing-vocoder", str(a.vocoder), "--artifacts", str(artifacts), "--memory-budget-mib", "8192"]
    results = []
    def check(name, extra, expected, inspect=False, protected=()):
        report = a.output / (name + ".json"); before = {p: p.read_bytes() for p in protected if p.exists()}
        command = base + extra + ["--report", str(report)]; actual = run(command, a.timeout); valid = False
        if inspect and actual.get("exit") == 0 and report.is_file():
            try:
                d = json.loads(report.read_text("utf-8")); valid = d.get("schemaVersion") == 1 and d.get("options", {}).get("capability") == "singing" and "inspection" in d and not d.get("runs")
            except (OSError, ValueError): pass
        results.append({"name": name, "command": command, "actual": actual, "expectedExit": expected, "inspectionValid": valid, "protectedUnchanged": all(p.read_bytes() == v for p, v in before.items()), "artifactChildren": [p.name for p in artifacts.iterdir()]})
    check("valid-inspect", ["--inspect"], 0, True)
    for name, extra in [("empty-prompt", ["--inspect", "--prompt", ""]), ("repeat", ["--inspect", "--repeat", "2"]), ("timeout-nan", ["--inspect", "--timeout-seconds", "nan"]), ("wrong-mode", ["--inspect", "--seed", "1"]), ("duplicate", ["--inspect", "--singing-profile", str(a.profile)]), ("unknown", ["--inspect", "--unknown-option", "x"])]: check(name, extra, 2)
    bad = a.output / "float.json"; bad.write_text('{"schemaVersion":1.0}', encoding="utf-8"); check("float-schema", ["--inspect", "--singing-request", str(bad)], 2)
    fixture = a.output / "provider"; fixture.mkdir(); sentinel = fixture / "keep.py"; sentinel.write_text("sentinel")
    check("protected-report", ["--inspect", "--singing-script", str(sentinel), "--report", str(fixture / "x")], 2, protected=(sentinel,))
    passed = all(x["actual"].get("exit") == x["expectedExit"] and x["protectedUnchanged"] and not x["artifactChildren"] and (x["name"] != "valid-inspect" or x["inspectionValid"]) for x in results)
    (a.output / "results.json").write_text(json.dumps(results, indent=2, sort_keys=True), encoding="utf-8")
    return 0 if passed and a.request.read_bytes() == original and request.read_bytes() == original else 1
if __name__ == "__main__": raise SystemExit(main())
