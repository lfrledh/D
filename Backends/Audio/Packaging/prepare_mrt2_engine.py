#!/usr/bin/env python3
"""Package the fixed MRT2 export runtime; does not install, sign, or run models."""
from __future__ import annotations

import argparse
from email.parser import Parser
import json
from pathlib import Path
import shutil
import sys
import tempfile

import prepare_engine as common

# Only the export/text-encoding entry points are shipped, never training SDKs.
DISTRIBUTIONS = {
    "mlx": "0.31.1", "mlx_metal": "0.31.1", "numpy": "2.3.5",
    "sentencepiece": "0.2.2", "ai_edge_litert": "2.2.0",
}
PACKAGES = ("mlx", "numpy", "sentencepiece", "ai_edge_litert")
PROVIDERS = ("d_audio_mrt2_backend.py", "d_audio_mrt2_contract.py", "d_mrt2_export.py", "d_audio_access.py", "d_audio_contract.py")


def copy_runtime(python_root: Path, site: Path, target: Path) -> None:
    """Copy approved installed components to a new task-owned directory."""
    interpreter = python_root / "bin/python3.12"
    stdlib = python_root / "lib/python3.12"
    common._reject_symlink_ancestors(interpreter.parent, "interpreter")
    common._reject_symlink_ancestors(stdlib, "stdlib")
    if interpreter.is_symlink() or not interpreter.is_file():
        raise common.PackagingError("regular bin/python3.12 is required")
    if not (stdlib / "LICENSE.txt").is_file() or not (stdlib / "encodings/__init__.py").is_file():
        raise common.PackagingError("Python standard library or license missing")
    common._validate_tree(stdlib, "stdlib", skip=True)
    selected = []
    for name in PACKAGES:
        path = site / name
        if not path.is_dir() or path.is_symlink():
            raise common.PackagingError(f"required export package missing or unsafe: {name}")
        selected.append(path)
    for name, version in DISTRIBUTIONS.items():
        path = site / f"{name}-{version}.dist-info"
        if not path.is_dir() or path.is_symlink():
            raise common.PackagingError(f"fixed distribution missing: {name} {version}")
        common._validate_tree(path, name)
        metadata = path / "METADATA"
        if not metadata.is_file():
            raise common.PackagingError(f"missing distribution metadata: {name}")
        info = Parser().parsestr(metadata.read_text(encoding="utf-8"))
        if info.get("Name", "").replace("-", "_").lower() != name or info.get("Version") != version:
            raise common.PackagingError(f"distribution identity mismatch: {name}")
        selected.append(path)
    # Optional wheel-native directories, only for the fixed distribution names.
    for name in (*PACKAGES, "mlx_metal"):
        for suffix in (".libs",) if name != "mlx_metal" else ("",):
            path = site / (name + suffix)
            if common._lexists(path):
                if not path.is_dir() or path.is_symlink():
                    raise common.PackagingError(f"unsafe native component: {path.name}")
                selected.append(path)
    for path in selected:
        common._validate_tree(path, path.name)
    (target / "bin").mkdir(parents=True, exist_ok=False)
    shutil.copy2(interpreter, target / "bin/python3")
    common._copy_tree(stdlib, target / "lib/python3.12", exclude_site_packages=True)
    destination = target / "lib/python3.12/site-packages"
    for path in selected:
        common._copy_tree(path, destination / path.name)
        if path.name.endswith(".dist-info"):
            # These installation records disclose machine paths and are not runtime inputs.
            for name in ("direct_url.json", "RECORD", "INSTALLER", "REQUESTED"):
                record = destination / path.name / name
                if record.is_file():
                    record.unlink()  # Only files copied into our new unpublished staging tree.


def prepare(args: argparse.Namespace) -> None:
    roots = [common._absolute_directory(getattr(args, key), key) for key in
             ("python_root", "site_packages", "provider_directory", "vendor_directory", "model_manifests")]
    python_root, site, provider, vendor, models = roots
    output = common._absolute_output(args.output)
    common._reject_overlap(output, roots)
    for root in (provider, vendor, models):
        common._validate_tree(root, root.name)
    for name in PROVIDERS:
        if not (provider / name).is_file():
            raise common.PackagingError(f"missing required provider file: {name}")
    model_manifest = models / "mrt2-small.json"
    if not model_manifest.is_file():
        raise common.PackagingError("mrt2-small.json model manifest missing")
    staging = Path(tempfile.mkdtemp(prefix=".d-mrt2-engine-", dir=output.parent))
    try:
        copy_runtime(python_root, site, staging / "python")
        (staging / "provider").mkdir()
        for name in PROVIDERS:
            shutil.copy2(provider / name, staging / "provider" / name)
        common._copy_tree(vendor, staging / "vendor")
        (staging / "model-manifests").mkdir()
        shutil.copy2(model_manifest, staging / "model-manifests/mrt2-small.json")
        manifest = common._manifest(staging)
        common._verify_manifest(staging, manifest)
        manifest.update(kind="d-mrt2-music-engine", providerScript="provider/d_audio_mrt2_backend.py")
        (staging / "engine.json").write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        common._publish_exclusive(staging, output)
    finally:
        if staging.exists():
            shutil.rmtree(staging)  # Never removes existing/published output or input trees.


def main(argv: list[str] | None = None) -> int:
    try:
        prepare(common.parse_arguments(sys.argv[1:] if argv is None else argv))
    except (common.PackagingError, OSError, shutil.Error, UnicodeError) as error:
        common._safe_message(sys.stderr, f"prepare_mrt2_engine: {error}")
        return 2
    return 0 if common._safe_message(sys.stdout, "Prepared MRT2 candidate; runtime/import/signature verification: unverified.") else 2


if __name__ == "__main__":
    raise SystemExit(main())
