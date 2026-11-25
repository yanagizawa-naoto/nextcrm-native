#!/usr/bin/env python3
"""Real AppKit settings and bounded log UI with an isolated SQLite/plugin host."""
from pathlib import Path
import hashlib
import json
import subprocess

n = Path(__file__).resolve().parent
manifest = n / 'plugins-production-sources.json'
names = json.loads(manifest.read_text())
names += ['NativePluginsAdmin', 'NativePluginsSettingsWindow', 'NativePluginLogWindow', 'NativePluginsAdminTests']
names += ['NativePluginsCredentials', 'NativePluginsQAServices', 'NativePluginsMail', 'InvoiceMail', 'InvoiceMailCredentials']
names = list(dict.fromkeys(names + ['NativeMailPreparationFiles', 'NativeTerminalMailBodyRecovery']))
sources = [n / (name + '.swift') for name in names]
inputs = sources + [manifest, n / 'schema.json', n / 'schema.sql', Path(__file__).resolve()]
hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
binary = n / 'build/NativePluginsAdminTests'
compile_result = subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-whole-module-optimization', '-framework', 'AppKit', '-lsqlite3', *map(str, sources), '-o', str(binary)], capture_output=True, text=True)
(n / 'build/plugins-admin-build.log').write_text(compile_result.stdout + compile_result.stderr)
if compile_result.returncode:
    print(json.dumps({'compileExit': compile_result.returncode, 'diagnostics': compile_result.stderr[-7000:]}))
    raise SystemExit(compile_result.returncode)
result = subprocess.run([str(binary), str(n)], capture_output=True, text=True, timeout=90)
stable = hashes == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
proof = {'sourcesSHA256': hashes, 'inputsUnchanged': stable, 'exit': result.returncode, 'result': result.stdout, 'stderr': result.stderr[-4000:], 'binaryBytes': binary.stat().st_size, 'scope': 'Actual AppKit settings/log controls and isolated SQLite host: permission grant, validation, secrets, stale revision, draft preservation, lifecycle, export, pagination and role revocation. Fake secret store; no normal user data, external HTTP, production Keychain or packaged-app claim.'}
(n / 'build/plugins-admin-verification.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: v for k, v in proof.items() if k not in ['sourcesSHA256', 'scope']}))
assert stable and result.returncode == 0, 'Plugin admin UI verification failed'
