#!/usr/bin/env python3
"""Exercise real AppKit terminateLater while a Swift shutdown task suspends."""
import hashlib, json, pathlib, subprocess
native=pathlib.Path(__file__).resolve().parent
build=native/'build';build.mkdir(exist_ok=True)
sources=[native/'NativeSheetTermination.swift',native/'NativeTerminationRunLoopTests.swift']
tracked=sources+[pathlib.Path(__file__)]
digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before={p.name:digest(p) for p in tracked}
binary=build/'NativeTerminationRunLoopTests'
with (build/'termination-runloop-test.log').open('w') as log:
    subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O',*map(str,sources),
                    '-framework','AppKit','-o',str(binary)],stdout=log,stderr=subprocess.STDOUT,check=True)
result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=10)
stable=all(digest(p)==before[p.name] for p in tracked)
proof=dict(inputsSHA256=before,inputsUnchanged=stable,exit=result.returncode,
           stdout=result.stdout,stderr=result.stderr,binaryBytes=binary.stat().st_size,
           scope='Actual NSApplication run loop, nested sheet close, terminateLater and asynchronously suspended MainActor termination reply; full CRM confirmation flow is checked separately.')
(build/'termination-runloop-verification.json').write_text(json.dumps(proof,indent=2)+'\n')
print(json.dumps({k:v for k,v in proof.items() if k!='inputsSHA256'}))
assert result.returncode==0 and stable and 'completed' in result.stdout
