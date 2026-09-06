#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPMENT_ROOT="${D_DEVELOPMENT_ROOT:-$(dirname "$PROJECT_ROOT")/D-Development}"
MLX_BUILD_ROOT="${D_MLX_BUILD_ROOT:-$(dirname "$PROJECT_ROOT")/BuildCaches/D-MLX}"
mkdir -p "$DEVELOPMENT_ROOT/Logs"
cd "$PROJECT_ROOT/Backends/MLX"
# Xcode compiles the MLX Metal library and bundles it beside the executable.
xcodebuild -scheme d-infer -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$MLX_BUILD_ROOT" \
  -clonedSourcePackagesDirPath "$DEVELOPMENT_ROOT/SourcePackages" \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build \
  > "$DEVELOPMENT_ROOT/Logs/build-mlx.log" 2>&1 || {
    awk '/error:|BUILD FAILED|The following build commands failed/ {print NR ":" $0}' "$DEVELOPMENT_ROOT/Logs/build-mlx.log" >&2
    printf 'Full build log: %s\n' "$DEVELOPMENT_ROOT/Logs/build-mlx.log" >&2
    exit 1
  }
printf '%s\n' "$MLX_BUILD_ROOT/Build/Products/Debug/d-infer"
