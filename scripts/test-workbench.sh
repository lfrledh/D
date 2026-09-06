#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPMENT_ROOT="${D_DEVELOPMENT_ROOT:-$(dirname "$PROJECT_ROOT")/D-Development}"
WORKBENCH_CACHE="${D_WORKBENCH_CACHE:-$(dirname "$PROJECT_ROOT")/BuildCaches/D-Workbench}"
export D_TEST_TEMP_DIR="$DEVELOPMENT_ROOT/Tests/Workbench"
mkdir -p "$D_TEST_TEMP_DIR" "$DEVELOPMENT_ROOT/Logs"
# CPU fixtures exercise application ownership and persistence; no MLX or model download.
swift test --package-path "$PROJECT_ROOT/Packages/UI" --scratch-path "$WORKBENCH_CACHE" \
  2>&1 | tee "$DEVELOPMENT_ROOT/Logs/workbench-package-tests.log"
