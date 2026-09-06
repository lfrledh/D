#!/bin/bash
set -euo pipefail
PROBE_ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$PROBE_ROOT/../.." && pwd)"
DEVELOPMENT_ROOT="${D_DEVELOPMENT_ROOT:-$(dirname "$PROJECT_ROOT")/D-Development}"
BUILD_ROOT="${D_FLUX2_BUILD_ROOT:-$(dirname "$PROJECT_ROOT")/BuildCaches/D-Flux2Probe}"
python3 "$PROJECT_ROOT/scripts/verify-mlx-vendor.py"
mkdir -p "$DEVELOPMENT_ROOT/Logs"
cd "$PROBE_ROOT"
xcodebuild -workspace "$PROBE_ROOT/Probe.xcworkspace" -scheme d-flux2-probe \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_ROOT" \
  -clonedSourcePackagesDirPath "$DEVELOPMENT_ROOT/SourcePackages-Flux2Probe" \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build \
  > "$DEVELOPMENT_ROOT/Logs/build-flux2-probe.log" 2>&1 || {
    awk '/error:|BUILD FAILED|The following build commands failed/ {print NR ":" $0}' "$DEVELOPMENT_ROOT/Logs/build-flux2-probe.log" >&2
    exit 1
  }
printf '%s\n' "$BUILD_ROOT/Build/Products/Debug/d-flux2-probe"
