#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, subprocess
n = Path(__file__).resolve().parent
sources = [n / name for name in ['NativeMCPProtocol.swift', 'NativeMCPHTTPParser.swift', 'NativeMCPHTTPParserTests.swift']]
watched = sources + [n / 'mcp-protocol-reference.cjs', Path(__file__).resolve()]
before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
subprocess.run(['node', str(n / 'mcp-protocol-reference.cjs'), str(n / 'build/mcp-protocol-reference.json')], check=True)
binary = n / 'build/NativeMCPHTTPParserTests'
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', *map(str, sources), '-o', str(binary)], check=True)
result = subprocess.run([str(binary), str(n / 'build/mcp-protocol-reference.json')], capture_output=True, text=True)
print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
assert before == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
(n / 'build/mcp-http-parser-verification.json').write_text(json.dumps({
    'sources': before, 'stdout': result.stdout, 'exit': result.returncode,
    'scope': 'Incremental HTTP/1.1 framing, bounded buffers, Host/Origin validation and all18 installed SDK fixture requests. No live socket/listener, token dispatcher or original123 handlers yet.',
    'binaryBytes': binary.stat().st_size,
}, ensure_ascii=False, indent=2) + '\n')
