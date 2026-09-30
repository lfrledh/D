"""Read-only admission of the code-owned, pinned H3 FL2VA BF16 pack.

This verifies resource identity and floating tensor headers, not inference or
hardware readiness. The model directory supplies no trusted manifest.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import stat

from h3_plan import PROFILE
from resource_inventory import ResourceError, verify_inventory


REPOSITORY = "MiniMaxAI/MiniMax-H3"
REVISION = "42ed227ee7df40d41602854ae760620d6eb651fe"
_EXTRA = frozenset({".download.lock", ".provenance.json"})


def _inventory():
    # Tests may explicitly replace this code-owned source with tiny fixtures.
    return json.loads((Path(__file__).parent / "Resources/h3-fl2va-bf16.json").read_bytes())


def _closed_tree(root: Path, names: set[str], cancelled):
    """Reject all unlisted leaves and symlinks, including nested directories."""
    directories = {""}
    for name in names:
        parts = name.split("/")
        directories.update("/".join(parts[:index]) for index in range(1, len(parts)))
    expected_files = names | _EXTRA

    def visit(path: Path, relative: str):
        if cancelled():
            raise InterruptedError("Cancelled during H3 pack traversal")
        with os.scandir(path) as entries:
            for entry in entries:
                if cancelled():
                    raise InterruptedError("Cancelled during H3 pack traversal")
                name = f"{relative}/{entry.name}" if relative else entry.name
                mode = entry.stat(follow_symlinks=False).st_mode
                if stat.S_ISDIR(mode) and name in directories:
                    visit(Path(entry.path), name)
                elif stat.S_ISREG(mode) and name in expected_files:
                    continue
                else:
                    raise ResourceError("Unexpected H3 resource or symlink: " + name)

    visit(root, "")


def admit_h3_fl2va(model, *, cancelled=lambda: False):
    root = Path(model)
    if (not root.is_absolute() or ".." in root.parts or
            any(stat.S_ISLNK(part.lstat().st_mode) for part in (root, *root.parents)) or
            not stat.S_ISDIR(root.lstat().st_mode)):
        raise ResourceError("H3 pack must be an explicit physical directory")
    inventory = _inventory()
    if (inventory.get("profile") != PROFILE or
            inventory.get("repository") != REPOSITORY or
            inventory.get("revision") != REVISION):
        raise ResourceError("H3 code-owned inventory identity differs from pinned FL2VA")
    entries = inventory.get("files")
    if not isinstance(entries, list) or any(
        not isinstance(row, dict) or row.get("tensor_policy") == "quantized_explicit"
        for row in entries
    ):
        raise ResourceError("H3 inventory must list only full-precision resources")
    names = {row.get("name") for row in entries}
    if len(names) != len(entries) or any(type(name) is not str for name in names):
        raise ResourceError("Invalid or duplicate H3 inventory paths")
    _closed_tree(root, names, cancelled)
    verified = verify_inventory(root, inventory, cancelled=cancelled)
    # A model installer must not add discovery-altering files while hashing.
    _closed_tree(root, names, cancelled)
    return {
        "profile": PROFILE,
        "repository": REPOSITORY,
        "revision": REVISION,
        "component_precision": "pinned original BF16 tensors with F32 components",
        "layers": 50,
        "verification": verified,
        "inference_verified": False,
        "streaming_scope": "DiT weight prefetch only; text and VAE stages are separate",
    }
