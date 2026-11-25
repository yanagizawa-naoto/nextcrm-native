#!/usr/bin/env python3
"""Compile the actual app's sources with an offscreen integration-test entry."""
from pathlib import Path
import re
import subprocess
import hashlib
import json
import sys

native = Path(__file__).resolve().parent
from native_build_inputs import app_sources, restore_host_bridge_inputs
sources = app_sources(native)
assert sources.count('CRMApp.swift') == 1
sources = sources + ['GoogleCalendarSettingsUITests.swift']
sources.append('GoogleCalendarRuntimeUITests.swift')
sources.append('GoogleCalendarPushUITests.swift')
debug = '--debug' in sys.argv
output = native / 'build' / ('GoogleCalendarSettingsUITests-debug' if debug else 'GoogleCalendarSettingsUITests')
output.parent.mkdir(exist_ok=True)
subprocess.run(['zsh', str(native / 'build-campaign-html.sh')], check=True)
subprocess.run(['zsh', str(native / 'build-native-mail.sh')], check=True)
inputs = sources + ['CampaignHTML.c', 'CampaignHTML.h', 'CampaignHTMLEntities.inc', 'build-campaign-html.sh', 'build/CampaignHTML.o', 'NativeBridges.h', 'NativeMailTransport.h', 'NativeMailTransport.c', 'build-native-mail.sh', 'build/NativeMailTransport.o']
subprocess.run(['zsh', str(native / 'build-plugins-http.sh')], check=True)
inputs += ['native_build_inputs.py', 'build.sh', 'NativePluginsHTTP.c', 'NativePluginsHTTP.h', 'build-plugins-http.sh', 'build/NativePluginsHTTP.o']
inputs += restore_host_bridge_inputs(native)
before = {x: hashlib.sha256((native / x).read_bytes()).hexdigest() for x in inputs}
subprocess.run(['swiftc', '-D', 'RESTORE_APP_HOST', '-swift-version', '5', '-parse-as-library', '-whole-module-optimization', '-Onone' if debug else '-O', '-target', 'arm64-apple-macos13.0',
                '-framework', 'Security', '-framework', 'AppKit', '-framework', 'CoreText', '-lsqlite3', '-lxml2', '-lcurl', '-framework', 'LocalAuthentication',
                '-import-objc-header', str(native / 'NativeBridges.h'), str(native / 'build/CampaignHTML.o'), str(native / 'build/NativeMailTransport.o'), str(native / 'build/NativePluginsHTTP.o'), str(native / 'build/NativeRestoreHostBridge.o'),
                *[str(native / x) for x in sources], '-o', str(output)], check=True)
result = subprocess.run([str(output), str(native)], text=True, capture_output=True)
print(result.stdout, end='')
if result.stderr:
    print(result.stderr, end='')
result.check_returncode()
assert before == {x: hashlib.sha256((native / x).read_bytes()).hexdigest() for x in inputs}, 'Sources or C bridge changed during test'
(native / 'build' / ('google-calendar-settings-ui-verification-debug.json' if debug else 'google-calendar-settings-ui-verification.json')).write_text(json.dumps({
    'kind': 'offscreen AppKit control and fake runtime integration', 'network': 'none; injected authorization and fake secret store',
    'optimization': '-Onone' if debug else '-O',
    'sourcesSHA256': before, 'executableSHA256': hashlib.sha256(output.read_bytes()).hexdigest(),
    'stdout': result.stdout, 'exit': result.returncode,
}, ensure_ascii=False, indent=2)+'\n')
