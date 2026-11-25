#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, subprocess
n = Path(__file__).resolve().parent
sources = [n / name for name in ['NativeMCPProtocol.swift', 'NativeMCPInputCatalog.swift', 'NativeMCPInputCatalogTests.swift']]
wire_sources = [n / name for name in ['NativeMCPProtocol.swift', 'NativeMCPHTTPParser.swift', 'NativeMCPHTTPServer.swift', 'NativeMCPInputCatalog.swift', 'NativeMCPInputServerFixture.swift']]
watched = list(dict.fromkeys(sources + wire_sources + [n / 'mcp-tools-reference.cjs', n / 'mcp-input-reference.cjs', n / 'mcp-input-wire-test.cjs', Path(__file__).resolve()]))
before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
subprocess.run(['node', str(n / 'mcp-tools-reference.cjs'), str(n / 'build/mcp-tools-reference.json')], check=True)
subprocess.run(['node', str(n / 'mcp-input-reference.cjs'), str(n / 'MCPToolCatalog.json'), str(n / 'build/mcp-input-reference.json')], check=True)
catalog_hash = hashlib.sha256((n / 'MCPToolCatalog.json').read_bytes()).hexdigest()
binary = n / 'build/NativeMCPInputCatalogTests'
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', *map(str, sources), '-o', str(binary)], check=True)
result = subprocess.run([str(binary), str(n / 'MCPToolCatalog.json'), str(n / 'build/mcp-input-reference.json')], capture_output=True, text=True, timeout=120)
print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
wire_binary = n / 'build/NativeMCPInputServerFixture'
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', *map(str, wire_sources), '-o', str(wire_binary)], check=True)
wire = subprocess.run(['node', str(n / 'mcp-input-wire-test.cjs'), str(wire_binary), str(n / 'MCPToolCatalog.json'), str(n / 'build/mcp-input-reference.json'), str(n / 'build/mcp-tools-reference.json')], capture_output=True, text=True, timeout=80)
print(wire.stdout, end=''); print(wire.stderr, end=''); wire.check_returncode()
assert before == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
assert catalog_hash == hashlib.sha256((n / 'MCPToolCatalog.json').read_bytes()).hexdigest()
catalog = json.loads((n / 'MCPToolCatalog.json').read_text())
for name, digest in {**catalog['sourceSHA256'], **catalog['runtimeSHA256']}.items():
    assert hashlib.sha256((n.parent.parent / name).read_bytes()).hexdigest() == digest
(n / 'build/mcp-input-verification.json').write_text(json.dumps({
    'sources': before, 'catalogSHA256': catalog_hash, 'stdout': result.stdout, 'exit': result.returncode, 'wireStdout': wire.stdout, 'wireExit': wire.returncode,
    'scope': 'All123 source tool input definitions, expanded Zod fixtures, normalized dispatch and protocol error envelope with fixture-only effects. Actual authenticated123 handlers/app integration still pending.',
    'binaryBytes': binary.stat().st_size,
    'wireBinaryBytes': wire_binary.stat().st_size,
    'catalogBytes': (n / 'MCPToolCatalog.json').stat().st_size,
    'referenceBytes': (n / 'build/mcp-input-reference.json').stat().st_size,
}, ensure_ascii=False, indent=2) + '\n')
