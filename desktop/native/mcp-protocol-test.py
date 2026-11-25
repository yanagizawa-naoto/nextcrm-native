#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, subprocess
n = Path(__file__).resolve().parent
sources = [n/'NativeMCPProtocol.swift', n/'NativeMCPProtocolTests.swift']
watched = sources + [n/'mcp-protocol-reference.cjs', Path(__file__).resolve()]
before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
subprocess.run(['node', str(n/'mcp-protocol-reference.cjs'), str(n/'build/mcp-protocol-reference.json')], check=True)
binary = n/'build/NativeMCPProtocolTests'
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O',*map(str,sources),'-o',str(binary)],check=True)
result = subprocess.run([str(binary),str(n/'build/mcp-protocol-reference.json')],capture_output=True,text=True)
print(result.stdout,end=''); print(result.stderr,end=''); result.check_returncode()
assert before == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
(n/'build/mcp-protocol-verification.json').write_text(json.dumps({'sources':before,'stdout':result.stdout,'exit':result.returncode,
    'scope':'Protocol envelope against18 SDK cases; fixture tool callback only. Full schema validator, authenticated dispatch, listener and original123 handlers pending.',
    'binaryBytes':binary.stat().st_size},ensure_ascii=False,indent=2)+'\n')
