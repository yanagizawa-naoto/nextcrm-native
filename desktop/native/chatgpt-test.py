#!/usr/bin/env python3
"""Focused native SIWC protocol/session tests, using only fake credentials and loopback."""
from pathlib import Path
import hashlib,json,os,subprocess,sys,time

ROOT=Path(__file__).resolve().parent
FILES=["NativeChatGPTOAuth.swift","NativeChatGPTIdentity.swift","NativeChatGPTCredentials.swift","NativeChatGPTLoopback.swift","NativeChatGPTInference.swift","NativeChatGPTSession.swift","NativeChatGPTSettingsWindow.swift","NativeChatGPTTests.swift"]
OUT=ROOT/"build"/"chatgpt-tests"
OUT.mkdir(parents=True,exist_ok=True)
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
before={name:sha(ROOT/name) for name in FILES}
command=["xcrun","swiftc","-swift-version","5","-target","arm64-apple-macos13.0","-O","-whole-module-optimization",*[str(ROOT/name) for name in FILES],"-framework","AppKit","-framework","Network","-framework","Security","-o",str(OUT/"tests")]
start=time.monotonic()
with (OUT/"compile.log").open("w") as log:
    result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT)
if result.returncode:
    print((OUT/"compile.log").read_text()[-12000:]);sys.exit(result.returncode)
with (OUT/"run.log").open("w") as log:
    result=subprocess.run([str(OUT/"tests")],stdout=log,stderr=subprocess.STDOUT,timeout=120)
after={name:sha(ROOT/name) for name in FILES}
proof={"exit":result.returncode,"sourceSHA256":before,"sourceStable":before==after,"seconds":round(time.monotonic()-start,2),"binarySHA256":sha(OUT/"tests"),"binaryBytes":(OUT/"tests").stat().st_size,"scope":"Actual native ECDSA verification, loopback HTTP callback, fake Keychain/CAS and synthetic provider; no real account or external service."}
(OUT/"verification.json").write_text(json.dumps(proof,indent=2)+"\n")
print((OUT/"run.log").read_text()[-4000:]);print(json.dumps({k:v for k,v in proof.items() if k!="sourceSHA256"}))
sys.exit(result.returncode if before==after else 2)
