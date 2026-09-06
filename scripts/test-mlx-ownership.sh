#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPMENT_ROOT="${D_DEVELOPMENT_ROOT:-$(dirname "$PROJECT_ROOT")/D-Development}"
MLX_BUILD_ROOT="${D_MLX_BUILD_ROOT:-$(dirname "$PROJECT_ROOT")/BuildCaches/D-MLX}"
# Rebuild Cmlx and all callers together before testing its inline ownership operations.
"$PROJECT_ROOT/scripts/build-mlx.sh" >/dev/null
TEST_BINARY="$MLX_BUILD_ROOT/Build/Products/Debug/d-mlx-ownership-tests"
xcrun --sdk macosx clang++ -std=c++17 -arch arm64 -mmacosx-version-min=14.0 \
  -I "$PROJECT_ROOT/Vendor/mlx-swift/Source/Cmlx/mlx" \
  "$PROJECT_ROOT/Tests/MLXOwnershipRegression/ownership.cpp" \
  "$MLX_BUILD_ROOT/Build/Products/Debug/Cmlx.o" \
  -framework Foundation -framework Metal -framework Accelerate -o "$TEST_BINARY"
"$TEST_BINARY" 2>&1 | tee "$DEVELOPMENT_ROOT/Logs/mlx-ownership-tests.log"
