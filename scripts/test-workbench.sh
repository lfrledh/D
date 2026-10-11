#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPMENT_ROOT="${D_DEVELOPMENT_ROOT:-$(dirname "$PROJECT_ROOT")/D-Development}"
WORKBENCH_CACHE="${D_WORKBENCH_CACHE:-$(dirname "$PROJECT_ROOT")/BuildCaches/D-Workbench}"
export D_TEST_TEMP_DIR="$DEVELOPMENT_ROOT/Tests/Workbench"
mkdir -p "$D_TEST_TEMP_DIR" "$DEVELOPMENT_ROOT/Logs"
# Installer and backend must accept the same exact pinned model files. Keep the
# resource in both standalone packages, and reject drift at the integration gate.
if ! cmp -s "$PROJECT_ROOT/Packages/UI/Sources/DWorkbench/Models/Resources/flux2-klein-model.json" \
  "$PROJECT_ROOT/Backends/MLX/Sources/DMLXBackend/Resources/flux2-klein-model.json"; then
  echo "Model catalog differs from the backend's fixed manifest." >&2
  exit 1
fi
# CPU fixtures do not run models. The integration test target still compiles MLX.
# Keep dependency selection locked; caller may pass filter/cache/job options.
swift test --package-path "$PROJECT_ROOT/Packages/UI" --scratch-path "$WORKBENCH_CACHE" \
  --force-resolved-versions --skip-update "$@" \
  2>&1 | tee "$DEVELOPMENT_ROOT/Logs/workbench-package-tests.log"
