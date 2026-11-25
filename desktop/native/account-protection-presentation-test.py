#!/usr/bin/env python3
from pathlib import Path
import json,hashlib,subprocess
n=Path(__file__).resolve().parent
manifest=n/'plugins-production-sources.json'
names=json.loads(manifest.read_text())+['NativePluginPresentation','NativeAccountProtectionPresentation','NativeAccountProtectionPresentationTests']
sources=[n/(name+'.swift') for name in names]
original=[n.parent.parent/'plugins/account-protection/ui'/name for name in ['common.ts','ProtectionTab.tsx','ProtectionPanel.tsx','ExpiringPage.tsx','ConflictsSection.tsx']]
watched=sources+[manifest,n/'schema.json',n/'schema.sql',Path(__file__).resolve()]
hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
binary=n/'build/NativeAccountProtectionPresentationTests'
compile=subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-whole-module-optimization','-framework','Security','-lsqlite3',*map(str,sources),'-o',str(binary)],capture_output=True,text=True)
if compile.returncode:print(json.dumps({'compile':compile.returncode,'error':compile.stderr[-10000:]}));raise SystemExit(compile.returncode)
result=subprocess.run([str(binary),str(n)],capture_output=True,text=True,timeout=120)
proof={'exit':result.returncode,'result':result.stdout,'stderr':result.stderr[-1000:],'hashes':hashes,'sourceHashes':{str(p.relative_to(n.parent.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in original},'unchanged':hashes=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in watched},'binaryBytes':binary.stat().st_size,'scope':'Read-only Japanese account protection DTO over real isolated SQLite. Current role/slot/primary/related access checks, no Keychain/provider/worker calls. Source UI reviewed; backend source-oracle suite unchanged.'}
(n/'build/account-protection-presentation-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');print(json.dumps({k:v for k,v in proof.items() if k not in ['hashes','sourceHashes']},ensure_ascii=False));raise SystemExit(result.returncode or (0 if proof['unchanged'] else 1))
