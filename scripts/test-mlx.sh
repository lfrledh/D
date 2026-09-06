#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPMENT_ROOT="${D_DEVELOPMENT_ROOT:-$(dirname "$PROJECT_ROOT")/D-Development}"
MLX_BUILD_ROOT="${D_MLX_BUILD_ROOT:-$(dirname "$PROJECT_ROOT")/BuildCaches/D-MLX}"
MODEL_DIR="${1:-$DEVELOPMENT_ROOT/Models/Qwen2.5-0.5B-Instruct-4bit}"
mkdir -p "$DEVELOPMENT_ROOT/Logs" "$DEVELOPMENT_ROOT/TestTemporary"
# A missing or damaged fixture is a failed acceptance run, never a silently skipped suite.
python3 "$PROJECT_ROOT/scripts/download-test-model.py" --destination "$MODEL_DIR" --verify-only >/dev/null
cd "$PROJECT_ROOT/Backends/MLX"
xcodebuild -scheme DMLXIntegration-Package -configuration Debug \
  -enableCodeCoverage NO \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$MLX_BUILD_ROOT" \
  -clonedSourcePackagesDirPath "$DEVELOPMENT_ROOT/SourcePackages" \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build-for-testing \
  > "$DEVELOPMENT_ROOT/Logs/build-mlx-tests.log" 2>&1 || {
    awk '/error:|BUILD FAILED|TEST BUILD FAILED/ {print NR ":" $0}' "$DEVELOPMENT_ROOT/Logs/build-mlx-tests.log" >&2
    exit 1
  }
TEST_RUN=$(python3 - "$MLX_BUILD_ROOT/Build/Products" "$MODEL_DIR" "$DEVELOPMENT_ROOT/TestTemporary" <<'PY'
import pathlib, plistlib, sys
products = pathlib.Path(sys.argv[1])
candidates = [p for p in products.glob('*.xctestrun') if not p.name.startswith('D-configured-')]
if not candidates:
    raise SystemExit('Xcode did not produce an xctestrun file.')
source = max(candidates, key=lambda p: p.stat().st_mtime)
with source.open('rb') as f:
    data = plistlib.load(f)
count = 0
def configure(node):
    global count
    if isinstance(node, dict):
        if 'TestBundlePath' in node:
            node.setdefault('EnvironmentVariables', {}).update({
                'D_TEST_MODEL_DIR': str(pathlib.Path(sys.argv[2]).resolve()),
                'D_TEST_TEMP_DIR': sys.argv[3],
            })
            count += 1
        for value in node.values():
            configure(value)
    elif isinstance(node, list):
        for value in node:
            configure(value)
configure(data)
if count == 0:
    raise SystemExit('No test targets found; refusing an unconfigured test run.')
destination = products / ('D-configured-' + source.name)
with destination.open('wb') as f:
    plistlib.dump(data, f)
print(destination)
PY
)
RESULT_BUNDLE="$DEVELOPMENT_ROOT/Logs/MLXTests-$(date +%Y%m%dT%H%M%S)-$$.xcresult"
xcodebuild test-without-building -xctestrun "$TEST_RUN" \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  -maximum-test-execution-time-allowance 180 -resultBundlePath "$RESULT_BUNDLE" \
  > "$DEVELOPMENT_ROOT/Logs/mlx-tests.log" 2>&1 || {
    tail -60 "$DEVELOPMENT_ROOT/Logs/mlx-tests.log" >&2
    if /usr/bin/grep -q 'timed out while preparing to run tests' "$DEVELOPMENT_ROOT/Logs/mlx-tests.log"; then
      printf '\nIf macOS is requesting removable-volume access for Xcode/xctest, allow that system prompt before rerunning. No model test is considered passed by a startup timeout.\n' >&2
    fi
    exit 1
  }
# Swift Testing writes these descriptions to the runner log. Assert real tests were enabled.
python3 - "$DEVELOPMENT_ROOT/Logs/mlx-tests.log" <<'PY'
import pathlib, sys
log = pathlib.Path(sys.argv[1]).read_text()
if 'D_MLX_RELEASE cycle=5' not in log or 'D_MLX_CANCELLATION seconds=' not in log:
    raise SystemExit('Real-model execution evidence missing from the test log.')
PY
printf 'MLX tests passed. Result bundle: %s\n' "$RESULT_BUNDLE"
