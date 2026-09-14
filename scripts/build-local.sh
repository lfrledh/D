#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPMENT_ROOT="${D_DEVELOPMENT_ROOT:-$(dirname "$PROJECT_ROOT")/D-Development}"
DERIVED_DATA_PATH="$DEVELOPMENT_ROOT/DerivedData"
SOURCE_PACKAGES_PATH="$DEVELOPMENT_ROOT/SourcePackages-App"
LOG_PATH="$DEVELOPMENT_ROOT/Logs/build-local.log"
PACKAGE_RESOLUTION_ARGS=(-onlyUsePackageVersionsFromResolvedFile)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --derived-data-path|--source-packages-path|--log-path)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "缺少 $1 的路径参数" >&2
        exit 2
      fi
      case "$1" in
        --derived-data-path) DERIVED_DATA_PATH="$2" ;;
        --source-packages-path) SOURCE_PACKAGES_PATH="$2" ;;
        --log-path) LOG_PATH="$2" ;;
      esac
      shift 2
      ;;
    --offline)
      PACKAGE_RESOLUTION_ARGS=(
        -disableAutomaticPackageResolution
        -skipPackageUpdates
        -onlyUsePackageVersionsFromResolvedFile
      )
      shift
      ;;
    *)
      echo "未知参数：$1" >&2
      exit 2
      ;;
  esac
done
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
mkdir -p "$(dirname "$LOG_PATH")"
xcodebuild -workspace "$PROJECT_ROOT/D.xcworkspace" -scheme D \
  "${BUILD_CONFIG_ARGS[@]}" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_PATH" \
  "${PACKAGE_RESOLUTION_ARGS[@]}" build \
  2>&1 | tee "$LOG_PATH"
