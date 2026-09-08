#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPMENT_ROOT="${D_DEVELOPMENT_ROOT:-$(dirname "$PROJECT_ROOT")/D-Development}"
# Optional machine-local identity and Team; never store a private key here.
SIGNING_CONFIG="${D_SIGNING_CONFIG:-$DEVELOPMENT_ROOT/Configuration/DevelopmentSigning.xcconfig}"
BUILD_CONFIG_ARGS=(-configuration Debug)
if [[ -f "$SIGNING_CONFIG" ]]; then
  BUILD_CONFIG_ARGS+=(-xcconfig "$SIGNING_CONFIG")
elif [[ -n "${D_SIGNING_CONFIG:-}" ]]; then
  echo "指定的签名配置不存在：$SIGNING_CONFIG" >&2
  exit 2
fi
python3 "$PROJECT_ROOT/scripts/verify-mlx-vendor.py"
mkdir -p "$DEVELOPMENT_ROOT/Logs"
xcodebuild -workspace "$PROJECT_ROOT/D.xcworkspace" -scheme D \
  "${BUILD_CONFIG_ARGS[@]}" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DEVELOPMENT_ROOT/DerivedData" \
  -clonedSourcePackagesDirPath "$DEVELOPMENT_ROOT/SourcePackages-App" \
  -onlyUsePackageVersionsFromResolvedFile build \
  2>&1 | tee "$DEVELOPMENT_ROOT/Logs/build-local.log"
