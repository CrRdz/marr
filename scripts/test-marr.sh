#!/bin/bash
# The default run never opts into tests that show native windows.
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_derived="${MARR_DERIVED_DATA:-$task_root/build/quiet-tests}"
task_visible=0
if [[ "${1:-}" == "--ui" ]]; then
  task_visible=1
  shift
fi
if [[ "${1:-}" == "--help" ]]; then
  echo 'Usage: scripts/test-marr.sh [--ui] [xcodebuild test options]'
  echo 'Default: logic, protocol, persistence and offscreen rendering; visible tests are skipped.'
  echo '--ui: also run tests that activate native windows. Use only on an available desktop.'
  exit 0
fi

# A terminal may retain flags from an earlier visible run. The explicit --ui
# switch is the only opt-in; reset both direct and XCTest-forwarded variants.
export MARR_RUN_UI_TESTS="$task_visible"
export MARR_RENDER_HELPER_UI="$task_visible"
export TEST_RUNNER_MARR_RUN_UI_TESTS="$task_visible"
export TEST_RUNNER_MARR_RENDER_HELPER_UI="$task_visible"
export MARR_TEST_HOST=1
export TEST_RUNNER_MARR_TEST_HOST=1

xcodebuild build-for-testing -project "$task_root/Marr.xcodeproj" -scheme Marr \
  -destination 'platform=macOS' -derivedDataPath "$task_derived" \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=

# Keep the fixture isolated from real Codex accounts and model requests,
# bound to loopback on a random port.
task_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/marr-loopback.XXXXXX")"
task_server_pid=""
cleanup_fixture() {
  if [[ -n "$task_server_pid" ]]; then
    kill "$task_server_pid" 2>/dev/null || true
    wait "$task_server_pid" 2>/dev/null || true
  fi
  rm -rf "$task_fixture_dir"
}
trap cleanup_fixture EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
python3 "$task_root/scripts/marr-loopback-test-server.py" --ready-file "$task_fixture_dir/ready" \
  >"$task_fixture_dir/server.log" 2>&1 &
task_server_pid=$!
for task_attempt in {1..100}; do
  [[ -s "$task_fixture_dir/ready" ]] && break
  if ! kill -0 "$task_server_pid" 2>/dev/null; then
    cat "$task_fixture_dir/server.log" >&2
    echo 'The loopback test fixture did not start.' >&2
    exit 1
  fi
  sleep 0.05
done
if [[ ! -s "$task_fixture_dir/ready" ]]; then
  echo 'Timed out waiting for the loopback test fixture.' >&2
  exit 1
fi
task_fixture_url="$(cat "$task_fixture_dir/ready")"
export MARR_TEST_APP_SERVER_URL="$task_fixture_url"
export TEST_RUNNER_MARR_TEST_APP_SERVER_URL="$task_fixture_url"

# Keep the copy beside its source so __TESTROOT__ remains correct. Editing the
# test configuration passes flags to the test host reliably (including CI).
task_run="$(python3 - "$task_derived/Build/Products" "$task_visible" "$task_fixture_url" <<'PY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
sources = [p for p in root.glob('*.xctestrun') if not p.name.startswith('Marr-configured-')]
if not sources:
    raise SystemExit('No xctestrun file was produced by build-for-testing')
source = max(sources, key=lambda p: p.stat().st_mtime)
with source.open('rb') as f:
    config = plistlib.load(f)
targets = []
if 'TestConfigurations' in config:
    for entry in config['TestConfigurations']:
        targets.extend(entry.get('TestTargets', []))
else:
    targets = [v for k, v in config.items() if not k.startswith('__') and isinstance(v, dict)]
if not targets:
    raise SystemExit('No test targets were found in the xctestrun configuration')
for target in targets:
    env = target.setdefault('EnvironmentVariables', {})
    env['MARR_RUN_UI_TESTS'] = sys.argv[2]
    env['MARR_RENDER_HELPER_UI'] = sys.argv[2]
    env['MARR_TEST_HOST'] = '1'
    env['MARR_TEST_APP_SERVER_URL'] = sys.argv[3]
output = root / ('Marr-configured-visible.xctestrun' if sys.argv[2] == '1' else 'Marr-configured-quiet.xctestrun')
with output.open('wb') as f:
    plistlib.dump(config, f)
print(output)
PY
)"
xcodebuild test-without-building -xctestrun "$task_run" -destination 'platform=macOS' \
  -parallel-testing-enabled NO "$@"
