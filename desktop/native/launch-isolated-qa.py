#!/usr/bin/env python3
"""Keep this command running while using CUA; select the app only after ready.

Usage: python3 launch-isolated-qa.py /path/to/Prepared-QA.app /path/to/qa-data
The prepared bundle must have a distinct *-qa identifier and no URL handlers.
Do not call cua.getApp after this command exits: that can relaunch without env.
"""
from pathlib import Path
import json
import os
import plistlib
import signal
import subprocess
import sys
import time

app, data = (Path(x).resolve() for x in sys.argv[1:])
normal = (Path.home() / 'Library/Application Support/NextCRMNative').resolve()
assert data != normal and normal not in data.parents, 'Use a separate QA data directory'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'].endswith('-qa'), 'Use a distinct QA bundle identifier'
assert not info.get('CFBundleURLTypes'), 'Remove URL handlers from QA bundle'
data.mkdir(parents=True, exist_ok=True)
marker = data / '.native-mail-test'
if marker.exists():
    assert marker.read_text() == 'NextCRM isolated mail QA\n'
else:
    marker.write_text('NextCRM isolated mail QA\n')
executable = str(app / 'Contents/MacOS' / info['CFBundleExecutable'])
def application_pids():
    listing = subprocess.run(['ps', '-axo', 'pid=,comm='], capture_output=True, text=True, check=True)
    return [int(parts[0]) for line in listing.stdout.splitlines()
            if len(parts := line.strip().split(maxsplit=1)) == 2 and parts[1] == executable]

assert not application_pids(), 'This QA application is already running'
overrides = {k: v for k, v in os.environ.items() if k.startswith('NEXTCRM_NATIVE_')}
overrides.update(NEXTCRM_NATIVE_DATA_DIR=str(data), NEXTCRM_NATIVE_MAIL_TEST_MODE='success')
command = ['/usr/bin/open', '-n', '-W', '--stdout', str(data / 'qa-application.log'),
           '--stderr', str(data / 'qa-application.log')]
for key, value in overrides.items():
    command += ['--env', key + '=' + value]
command.append(str(app))
# LaunchServices supplies the normal Mac application launch context. Direct
# executable launches showed disabled standard Save panels during report QA.
pid = None
with (data / 'qa-process.log').open('a') as log:
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 10
        verified = False
        while process.poll() is None and time.monotonic() < deadline:
            matches = application_pids()
            assert len(matches) <= 1, 'Multiple instances of the QA application appeared'
            if not matches:
                time.sleep(0.1)
                continue
            pid = matches[0]
            opened = subprocess.run(['lsof', '-Fn', '-p', str(pid)], capture_output=True, text=True)
            paths = opened.stdout.splitlines()
            assert 'n'+str(normal / 'crm.sqlite') not in paths, 'QA opened normal database'
            if 'n'+str(data / 'crm.sqlite') in paths:
                verified = True
                break
            time.sleep(0.1)
        assert verified, 'QA failed to open its isolated database'
        state = {'pid': pid, 'launcherPID': process.pid, 'launchMethod': 'LaunchServices', 'bundle': info['CFBundleIdentifier'], 'database': str(data / 'crm.sqlite'), 'ready': True}
        (data / 'qa-process.json').write_text(json.dumps(state, indent=2)+'\n')
        print(json.dumps(state), flush=True)
        code = process.wait()
        assert pid not in application_pids(), 'Launcher exited while the QA app is still running'
        print(json.dumps({'pid': pid, 'launcherExit': code, 'applicationTerminated': True}), flush=True)
        sys.exit(code)
    finally:
        if process.poll() is None:
            # Only terminate the exact owned QA process, never the normal app.
            for owned in application_pids():
                os.kill(owned, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=10)
            if application_pids():
                print(json.dumps({'qaStillRunning': application_pids()}), flush=True)
