#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,subprocess
n=Path(__file__).resolve().parent
base=[n/'NativeMCPProtocol.swift',n/'NativeMCPHTTPParser.swift']
unit=base+[n/'NativeMCPHTTPBodyTests.swift']
network=base+[n/'NativeMCPHTTPServer.swift',n/'NativeMCPHTTPBodyServerFixture.swift']
watched=list(dict.fromkeys(unit+network+[n/'mcp-http-body-test.cjs',Path(__file__).resolve()]))
before={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
outputs=[];sizes={}
for names,binaryName,run in [(unit,'NativeMCPHTTPBodyTests',[]),(network,'NativeMCPHTTPBodyServerFixture',['node',str(n/'mcp-http-body-test.cjs')])]:
 binary=n/'build'/binaryName
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O',*map(str,names),'-o',str(binary)],check=True)
 result=subprocess.run(run+[str(binary)],capture_output=True,text=True,timeout=90)
 print(result.stdout,end='',flush=True);print(result.stderr,end='',flush=True);result.check_returncode();outputs.append(result.stdout);sizes[binaryName]=binary.stat().st_size
assert before=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
(n/'build/mcp-http-body-verification.json').write_text(json.dumps({'sources':before,'stdout':outputs,'exit':0,'binaries':sizes,'scope':'Streamed HTTP request bodies and raw responses: unit framing/cleanup plus actual native TCP content, length, authorization, backpressure and cancellation. Real storage/SDK/app integration separate.'},ensure_ascii=False,indent=2)+'\n')
