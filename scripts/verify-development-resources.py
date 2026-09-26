#!/usr/bin/env python3
"""Read-only preflight for the native Xcode resource-copy phase; no downloads or signing."""
from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path
import sys

sys.dont_write_bytecode = True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepared", required=True)
    args = parser.parse_args()
    try:
        spec = importlib.util.spec_from_file_location(
            "d_resource_validation", Path(__file__).with_name("prepare-development-resources.py"))
        if spec is None or spec.loader is None:
            raise RuntimeError("resource validator is unavailable")
        core = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(core)
        prepared = core._absolute_directory(args.prepared, "prepared resource set")
        core.validate_prepared(prepared)
        if not core._safe_report(sys.stdout, {"status": "verified", "runtimeVerification": "not-run"}):
            return 2
        return 0
    except Exception as error:
        # Xcode treats this as a build failure before a development artifact is accepted.
        try:
            sys.stderr.write("error: D resources are not ready: " + str(error) +
                             ". Follow Development/README.md; no resources were changed.\n")
            sys.stderr.flush()
        except (OSError, ValueError):
            pass
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
