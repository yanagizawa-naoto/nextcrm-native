#!/usr/bin/env python3
"""Compile production AppKit sources and exercise both AI draft entry flows."""
from pathlib import Path
import re, subprocess, json, hashlib
native = Path(__file__).resolve().parent
(native / 'build').mkdir(exist_ok=True)
from native_build_inputs import app_sources, restore_host_bridge_inputs
sources = app_sources(native)
sources = sources + ['CampaignAIUITests.swift']
for name in ['CampaignTemplatesUITests', 'CampaignWorkflowUITests']:
    # Reuse the actual previous regression suites under one test entry point.
    (native / f'build/{name}-library.swift').write_text((native / f'{name}.swift').read_text().replace('@main enum', 'enum'))
    sources.append(f'build/{name}-library.swift')
for script in ['build-campaign-html.sh', 'build-native-mail.sh']:
    subprocess.run(['zsh', str(native / script)], check=True)
inputs = sources + ['build/CampaignHTML.o', 'build/NativeMailTransport.o', 'NativeBridges.h']
subprocess.run(['zsh', str(native / 'build-plugins-http.sh')], check=True)
inputs += ['native_build_inputs.py', 'build.sh', 'NativePluginsHTTP.c', 'NativePluginsHTTP.h', 'build-plugins-http.sh', 'build/NativePluginsHTTP.o']
inputs += restore_host_bridge_inputs(native)
before = {p: hashlib.sha256((native / p).read_bytes()).hexdigest() for p in inputs}
output = native / 'build/CampaignAIUITests'
subprocess.run(['swiftc', '-D', 'RESTORE_APP_HOST', '-swift-version', '5', '-parse-as-library', '-whole-module-optimization', '-O', '-target', 'arm64-apple-macos13.0',
    '-framework', 'Security', '-framework', 'AppKit', '-framework', 'CoreText', '-framework', 'LocalAuthentication', '-lsqlite3', '-lxml2', '-lcurl',
    '-import-objc-header', str(native / 'NativeBridges.h'), str(native / 'build/CampaignHTML.o'), str(native / 'build/NativeMailTransport.o'), str(native / 'build/NativePluginsHTTP.o'), str(native / 'build/NativeRestoreHostBridge.o'),
    *[str(native / p) for p in sources], '-o', str(output)], check=True)
result = subprocess.run([str(output), str(native)], capture_output=True, text=True)
print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
assert before == {p: hashlib.sha256((native / p).read_bytes()).hexdigest() for p in inputs}
(native / 'build/campaign-ai-ui-verification.json').write_text(json.dumps({'sources': before, 'stdout': result.stdout, 'exit': result.returncode}, ensure_ascii=False, indent=2))
