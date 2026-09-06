#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPMENT_ROOT="${D_DEVELOPMENT_ROOT:-$(dirname "$PROJECT_ROOT")/D-Development}"
# Avoid a Swift debug-path mapping collision between repository D and sibling D-Development.
FOUNDATION_BUILD_ROOT="${D_FOUNDATION_BUILD_ROOT:-$(dirname "$PROJECT_ROOT")/BuildCaches/D-Foundation}"
mkdir -p "$DEVELOPMENT_ROOT/Logs"
swift test --package-path "$PROJECT_ROOT" \
  --scratch-path "$FOUNDATION_BUILD_ROOT" \
  2>&1 | tee "$DEVELOPMENT_ROOT/Logs/foundation-tests.log"
