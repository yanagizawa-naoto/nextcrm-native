#!/usr/bin/env python3
"""Synthetic SQLite/FS and real child-process crash recovery; never normal roots."""
import pathlib,json,hashlib,subprocess,tempfile,time,re
ROOT=pathlib.Path(__file__).resolve().parents[2];NATIVE=ROOT/'desktop/native';BUILD=NATIVE/'build';BUILD.mkdir(exist_ok=True)
extra=['NativeDataMaintenanceRecoveryTypes','NativeDataMaintenanceRecoveryFiles','NativeDataMaintenanceRecovery','NativeDataMaintenanceRecoveryTests']
names=list(dict.fromkeys(json.loads((NATIVE/'NativeDataMaintenanceSources.json').read_text())+extra))
sources=[NATIVE/(name+'.swift') for name in names]
tracked=sources+[pathlib.Path(__file__),NATIVE/'NativeDataMaintenanceSources.json',NATIVE/'NativeDataMaintenanceRecoveryFormat.md',NATIVE/'schema.json',NATIVE/'schema.sql']
hash_=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();hashes={str(p.relative_to(ROOT)):hash_(p) for p in tracked}
binary=BUILD/'NativeDataMaintenanceRecoveryTests';log=BUILD/'native-data-maintenance-recovery-test.log';start=time.time()
with log.open('w') as out:subprocess.run(['swiftc','-swift-version','5','-target','arm64-apple-macosx13.0','-O','-whole-module-optimization',*[str(p) for p in sources],'-framework','AppKit','-lsqlite3','-o',str(binary)],check=True,stdout=out,stderr=subprocess.STDOUT)
with tempfile.TemporaryDirectory(prefix='NextCRMRecoveryFixtures-') as path:
 root=pathlib.Path(path).resolve()
 with log.open('a') as out:subprocess.run(['/usr/bin/time','-l',str(binary),'test',str(NATIVE),str(root)],check=True,stdout=out,stderr=subprocess.STDOUT)
 result=json.loads((root/'result.json').read_text());fixture_bytes=sum(p.stat().st_size for p in root.rglob('*') if p.is_file() and not p.is_symlink())
 stable=all(hash_(ROOT/p)==h for p,h in hashes.items());assert stable
 rss=re.search(r'(\d+)\s+maximum resident set size',log.read_text())
 result.update(sourceHashes=hashes,sourceHashesStable=stable,maximumResidentBytes=int(rss[1]) if rss else None,binaryBytes=binary.stat().st_size,temporaryFixtureBytes=fixture_bytes,seconds=round(time.time()-start,2),limitations=['Controller registration and background recovery API are integrated and tested; root App startup invocation remains a separate integration step.','Creation before an ownership marker is durable is retained as pending; never inferred from a folder name.','Published artifacts, activation state and activation-verification staging are outside deletion scope.','Process SIGKILL and interrupted journal appends are tested; actual power-loss/filesystem fault hardware is not simulated.'])
 (BUILD/'native-data-maintenance-recovery-verification.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');print(json.dumps({k:v for k,v in result.items() if k not in ['sourceHashes','limitations']}))
