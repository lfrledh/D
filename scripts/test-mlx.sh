#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPMENT_ROOT="${D_DEVELOPMENT_ROOT:-$(dirname "$PROJECT_ROOT")/D-Development}"
MLX_BUILD_ROOT="${D_MLX_BUILD_ROOT:-$(dirname "$PROJECT_ROOT")/BuildCaches/D-MLX}"
MODEL_DIR="${1:-$DEVELOPMENT_ROOT/Models/Qwen2.5-0.5B-Instruct-4bit}"
IMAGE_MODEL_DIR="${2:-$DEVELOPMENT_ROOT/Models/FLUX.2-klein-4B-q8}"
FLUX_FIXTURE="$PROJECT_ROOT/Vendor/flux2-swift/fixtures/flux2_tiny_klein_pipeline"
python3 "$PROJECT_ROOT/scripts/verify-mlx-vendor.py"
python3 "$PROJECT_ROOT/scripts/verify-flux2-vendor.py"
mkdir -p "$DEVELOPMENT_ROOT/Logs" "$DEVELOPMENT_ROOT/TestTemporary"
# A missing or damaged fixture is a failed acceptance run, never a silently skipped suite.
python3 "$PROJECT_ROOT/scripts/download-test-model.py" --destination "$MODEL_DIR" --verify-only >/dev/null
python3 "$PROJECT_ROOT/Experiments/Flux2Probe/download_model.py" \
  --manifest "$PROJECT_ROOT/Experiments/Flux2Probe/model-manifest.json" \
  --destination "$IMAGE_MODEL_DIR" --verify-only >/dev/null
if [[ ! -f "$FLUX_FIXTURE/klein_inputs.safetensors" || ! -f "$FLUX_FIXTURE/klein_expected.safetensors" ]]; then
  printf 'Pinned Flux2 numerical fixture is missing: %s\n' "$FLUX_FIXTURE" >&2
  exit 1
fi
cd "$PROJECT_ROOT/Backends/MLX"
xcodebuild -workspace "$PROJECT_ROOT/D.xcworkspace" -scheme DMLXTests -configuration Debug \
  -enableCodeCoverage NO \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$MLX_BUILD_ROOT" \
  -clonedSourcePackagesDirPath "$DEVELOPMENT_ROOT/SourcePackages-MLX" \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build-for-testing \
  > "$DEVELOPMENT_ROOT/Logs/build-mlx-tests.log" 2>&1 || {
    awk '/error:|BUILD FAILED|TEST BUILD FAILED/ {print NR ":" $0}' "$DEVELOPMENT_ROOT/Logs/build-mlx-tests.log" >&2
    exit 1
  }
TEST_RUN=$(python3 - "$MLX_BUILD_ROOT/Build/Products" "$MODEL_DIR" "$DEVELOPMENT_ROOT/TestTemporary" "$IMAGE_MODEL_DIR" "$FLUX_FIXTURE" <<'PY'
import pathlib, plistlib, sys
products = pathlib.Path(sys.argv[1])
candidates = list(products.glob('DMLXTests_*.xctestrun'))
if not candidates:
    raise SystemExit('Xcode did not produce an xctestrun file.')
source = max(candidates, key=lambda p: p.stat().st_mtime)
with source.open('rb') as f:
    data = plistlib.load(f)
count = 0
def configure(node):
    global count
    if isinstance(node, dict):
        if 'TestBundlePath' in node and node.get('BlueprintName') == 'DMLXBackendTests':
            node.setdefault('EnvironmentVariables', {}).update({
                'D_TEST_MODEL_DIR': str(pathlib.Path(sys.argv[2]).resolve()),
                'D_TEST_TEMP_DIR': sys.argv[3],
                'D_TEST_IMAGE_MODEL_DIR': str(pathlib.Path(sys.argv[4]).resolve()),
                'D_TEST_FLUX_FIXTURE': str(pathlib.Path(sys.argv[5]).resolve()),
            })
            count += 1
        for value in node.values():
            configure(value)
    elif isinstance(node, list):
        for value in node:
            configure(value)
configure(data)
if count != 1:
    raise SystemExit(f'Expected one DMLXBackendTests target, found {count}; refusing an unconfigured test run.')
destination = products / ('D-configured-' + source.name)
with destination.open('wb') as f:
    plistlib.dump(data, f)
print(destination)
PY
)
RESULT_BUNDLE="$DEVELOPMENT_ROOT/Logs/MLXTests-$(date +%Y%m%dT%H%M%S)-$$.xcresult"
xcodebuild test-without-building -xctestrun "$TEST_RUN" \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 300 \
  -maximum-test-execution-time-allowance 300 -resultBundlePath "$RESULT_BUNDLE" \
  > "$DEVELOPMENT_ROOT/Logs/mlx-tests.log" 2>&1 || {
    tail -60 "$DEVELOPMENT_ROOT/Logs/mlx-tests.log" >&2
    if /usr/bin/grep -q 'timed out while preparing to run tests' "$DEVELOPMENT_ROOT/Logs/mlx-tests.log"; then
      printf '\nIf macOS is requesting removable-volume access for Xcode/xctest, allow that system prompt before rerunning. No model test is considered passed by a startup timeout.\n' >&2
    fi
    exit 1
  }
# The result bundle distinguishes executed tests from build-only success or a skipped suite.
RESULT_SUMMARY="${RESULT_BUNDLE%.xcresult}.summary.json"
xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" > "$RESULT_SUMMARY"
python3 - "$DEVELOPMENT_ROOT/Logs/mlx-tests.log" "$RESULT_SUMMARY" <<'PY'
import json, pathlib, sys
log = pathlib.Path(sys.argv[1]).read_text()
if 'D_MLX_RELEASE cycle=5' not in log or 'D_MLX_CANCELLATION seconds=' not in log:
    raise SystemExit('Real-model execution evidence missing from the test log.')
image_markers = [
    'MLX image lifecycle normal-round-3:',
    'MLX image lifecycle cancel-drained:',
    'MLX image lifecycle mixed-queue:',
    'MLX image lifecycle damaged-vae-copy:',
    'MLX image lifecycle artifact-root-moved:',
    'MLX image lifecycle consumer-recovery-artifact:',
    'Flux2 tiny cache breakdown:',
]
missing = [marker for marker in image_markers if marker not in log]
if missing:
    raise SystemExit('Image/fixture execution evidence missing: ' + ', '.join(missing))
summary = json.loads(pathlib.Path(sys.argv[2]).read_text())
if (summary.get('result') != 'Passed' or summary.get('totalTestCount', 0) <= 0
        or summary.get('passedTests', 0) <= 0 or summary.get('failedTests') != 0
        or summary.get('skippedTests') != 0 or summary.get('expectedFailures') != 0):
    raise SystemExit('MLX acceptance requires executed tests with zero failures, skips, or expected failures.')
configurations = summary.get('devicesAndConfigurations', [])
if not configurations or any(c.get('passedTests', 0) <= 0 or c.get('failedTests') != 0
                             or c.get('skippedTests') != 0 or c.get('expectedFailures') != 0
                             for c in configurations):
    raise SystemExit('A device/configuration did not execute the complete test suite successfully.')
PY
printf 'MLX tests passed. Result bundle: %s\n' "$RESULT_BUNDLE"
