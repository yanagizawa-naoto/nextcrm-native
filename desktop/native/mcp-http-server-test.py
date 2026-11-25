#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, subprocess
n = Path(__file__).resolve().parent
sources = [n / name for name in ['NativeMCPProtocol.swift', 'NativeMCPHTTPParser.swift', 'NativeMCPHTTPServer.swift', 'NativeMCPHTTPServerFixture.swift']]
watched = sources + [n / 'mcp-http-server-test.cjs', Path(__file__).resolve()]
before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
binary = n / 'build/NativeMCPHTTPServerFixture'
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', *map(str, sources), '-o', str(binary)], check=True)
result = subprocess.run(['node', str(n / 'mcp-http-server-test.cjs'), str(binary)], capture_output=True, text=True, timeout=110)
print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
assert before == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
(n / 'build/mcp-http-server-verification.json').write_text(json.dumps({
    'sources': before, 'stdout': result.stdout, 'exit': result.returncode,
    'scope': 'Native loopback listener, installed SDK interoperability, limits, backpressure, disconnect and shutdown/restart. Fixture handlers only; full app/auth/source123 handlers pending.',
    'binaryBytes': binary.stat().st_size,
}, ensure_ascii=False, indent=2) + '\n')
