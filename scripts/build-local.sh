#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPMENT_ROOT="${D_DEVELOPMENT_ROOT:-$(dirname "$PROJECT_ROOT")/D-Development}"
mkdir -p "$DEVELOPMENT_ROOT/Logs"
xcodebuild -project "$PROJECT_ROOT/D.xcodeproj" -scheme D \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DEVELOPMENT_ROOT/DerivedData" \
  -clonedSourcePackagesDirPath "$DEVELOPMENT_ROOT/SourcePackages" \
  -onlyUsePackageVersionsFromResolvedFile build \
  2>&1 | tee "$DEVELOPMENT_ROOT/Logs/build-local.log"
