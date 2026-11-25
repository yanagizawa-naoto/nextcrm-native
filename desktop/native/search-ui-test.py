#!/usr/bin/env python3
"""Exercise production global search controls and document navigation with isolated fakes."""
from pathlib import Path
import hashlib
import json
import re
import subprocess

native = Path(__file__).resolve().parent
from native_build_inputs import app_sources, restore_host_bridge_inputs
sources = app_sources(native)
assert sources.count('CRMApp.swift') == 1
sources = sources + ['NativeSearchUITests.swift']
for script in ['build-campaign-html.sh', 'build-native-mail.sh']:
    subprocess.run(['zsh', str(native / script)], check=True)
inputs = sources + ['NativeBridges.h', 'build/CampaignHTML.o', 'build/NativeMailTransport.o', 'schema.json', 'schema.sql']
subprocess.run(['zsh', str(native / 'build-plugins-http.sh')], check=True)
inputs += ['native_build_inputs.py', 'build.sh', 'NativePluginsHTTP.c', 'NativePluginsHTTP.h', 'build-plugins-http.sh', 'build/NativePluginsHTTP.o']
inputs += restore_host_bridge_inputs(native)
before = {x: hashlib.sha256((native / x).read_bytes()).hexdigest() for x in inputs}
output = native / 'build/NativeSearchUITests'
subprocess.run(['swiftc', '-D', 'RESTORE_APP_HOST', '-swift-version', '5', '-parse-as-library', '-whole-module-optimization', '-O', '-target', 'arm64-apple-macos13.0', '-framework', 'Security', '-framework', 'LocalAuthentication', '-framework', 'AppKit', '-framework', 'CoreText', '-lsqlite3', '-lxml2', '-lcurl', '-import-objc-header', str(native / 'NativeBridges.h'), str(native / 'build/CampaignHTML.o'), str(native / 'build/NativeMailTransport.o'), str(native / 'build/NativePluginsHTTP.o'), str(native / 'build/NativeRestoreHostBridge.o'), *[str(native / x) for x in sources], '-o', str(output)], check=True)
result = subprocess.run([str(output), str(native)], text=True, capture_output=True, timeout=90)
print(result.stdout, end='')
print(result.stderr, end='')
result.check_returncode()
assert before == {x: hashlib.sha256((native / x).read_bytes()).hexdigest() for x in inputs}, 'Sources changed during tests'
(native / 'build/native-search-ui-verification.json').write_text(json.dumps({'kind':'offscreen production AppKit global search and document navigation','network':'none; in-memory secrets, fake embeddings, no real provider','sourcesSHA256':before,'executableSHA256':hashlib.sha256(output.read_bytes()).hexdigest(),'stdout':result.stdout,'exit':result.returncode}, ensure_ascii=False, indent=2)+'\n')
