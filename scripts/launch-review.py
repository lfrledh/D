#!/usr/bin/env python3
"""Verify and launch only a signed, persistent review-only artifact. Never bind a GUI tool."""
import argparse
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time


def pid_path(pid):
    buffer = ctypes.create_string_buffer(4096)
    library = ctypes.CDLL('/usr/lib/libproc.dylib')
    size = library.proc_pidpath(int(pid), buffer, len(buffer))
    return buffer.value.decode() if size > 0 else None


def launch_exit_code(returncode, ready):
    if returncode != 0:
        return returncode if returncode > 0 else 128 - returncode
    return 0 if ready else 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt', required=True, type=Path)
    parser.add_argument('--fixture-server', required=True, type=Path)
    parser.add_argument('--launch', action='store_true', help='Without this flag, verify only.')
    args = parser.parse_args()
    receipt = json.loads(args.receipt.read_text())
    app, root, worktree = (Path(receipt[key]) for key in ('app', 'root', 'worktree'))
    executable = app / 'Contents/MacOS/D'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info.get('DReviewLaunchMode') == 'isolated-download-v1', 'Persistent review marker missing'
    assert info.get('CFBundleIdentifier') == 'first-test.D.review.D', 'Not the dedicated review bundle'
    assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=worktree, text=True).strip() == receipt['source_sha']
    subprocess.run(['git', 'diff', '--exit-code', receipt['source_sha'], '--', 'D', 'Packages', 'D.xcodeproj', 'D.xcworkspace'], cwd=worktree, check=True)
    for relative, digest in receipt['code_files'].items():
        assert hashlib.sha256((app / relative).read_bytes()).hexdigest() == digest, 'Code changed: ' + relative
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    signature = subprocess.run(['codesign', '-dvv', str(app)], capture_output=True, text=True, check=True).stderr
    assert 'Authority=Apple Development:' in signature and 'TeamIdentifier=' + receipt['team'] in signature
    assert root.is_absolute() and root.resolve() == root and str(root).startswith('/Volumes/')
    fixture = json.loads((root / 'download-review-fixture.json').read_text())
    assert fixture['session'] == root.name == receipt['session']
    assert fixture['task'] == 'D-DOWNLOAD-MANAGEMENT-01'
    assert hashlib.sha256(args.fixture_server.read_bytes()).hexdigest() == receipt['fixture_server_sha256']
    print('Verified dedicated review artifact:', receipt['source_sha'], flush=True)
    if not args.launch:
        return
    # Lifetime flock also covers direct invocations of this launcher; no stale-lock deletion.
    with (root / '.d-review-launcher.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        runtime = root / 'review-runtime.json'
        if runtime.exists():
            previous = json.loads(runtime.read_text())
            assert pid_path(previous['pid']) != previous['executable'], 'Verified review process already running; attach to it, do not launch another'
        port_file = root / 'http-port'
        port_file.unlink(missing_ok=True)
        with (root / 'http.log').open('a') as http_log, (root / 'app.log').open('a') as app_log:
            server = subprocess.Popen([sys.executable, str(args.fixture_server), str(root)], stdout=http_log, stderr=subprocess.STDOUT)
            try:
                for _ in range(100):
                    if port_file.exists():
                        break
                    assert server.poll() is None, 'Fixture server stopped'
                    time.sleep(.05)
                port = int(port_file.read_text())
                assert 1 <= port <= 65535
                env = {key: value for key, value in os.environ.items() if not key.startswith(('D_UI_', 'D_DOWNLOAD_REVIEW_', 'D_AUDIO_PROBE_', 'D_AUDIO_DEPLOYMENT_'))}
                source = 'http://127.0.0.1:' + str(port)
                env.update(D_UI_TEST_SESSION=receipt['session'], D_DOWNLOAD_REVIEW_ROOT=str(root), D_DOWNLOAD_REVIEW_SOURCE=source)
                process = subprocess.Popen([str(executable)], env=env, stdout=app_log, stderr=subprocess.STDOUT)
                print('Launched owned PID', process.pid, '; authorize only the displayed exact review folder.', flush=True)
                # No automatic timeout-kill: an authorization panel may be waiting for the user.
                # Never call a desktop getApp API here; it may create another instance.
                announced = False
                while process.poll() is None:
                    if not announced and runtime.exists():
                        actual = json.loads(runtime.read_text())
                        if actual['pid'] == process.pid:
                            expected = {'session': receipt['session'], 'root': str(root), 'executable': str(executable),
                                        'bundle': str(app), 'bundleID': info['CFBundleIdentifier'], 'source': source,
                                        'modelIndex': str(root / 'ModelLibrary/index.json'), 'quick': str(root / 'Quick Creations.dproject')}
                            assert all(actual.get(key) == value for key, value in expected.items()), 'Runtime receipt conflicts'
                            assert pid_path(process.pid) == str(executable), 'Executable identity changed'
                            assert actual['phase'] == 'ready', 'Review services degraded; preserve session and stop acceptance'
                            print('READY verified PID', process.pid, json.dumps(expected), flush=True)
                            print('Attach only to this existing PID. If the tool cannot attach, stop and use user-visible actions; do not auto-launch.', flush=True)
                            announced = True
                    time.sleep(.5)
                print('Owned review process exited:', process.returncode, 'ready:', announced, flush=True)
                return launch_exit_code(process.returncode, announced)
            finally:
                server.terminate()
                server.wait(timeout=10)


if __name__ == '__main__':
    sys.exit(main())
