from pathlib import Path
import hashlib,json,subprocess
n=Path(__file__).resolve().parent;r=n/'build/avatar-orientation';r.mkdir(parents=True,exist_ok=True);sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
files=[n/(x+'.swift')for x in ['NativeUserAvatarAnimation','NativeUserAvatarWebPAnimation','NativeUserAvatarAPNGAnimation','NativeUserAvatarOrientationTests']]
watched=files+[n/'user-avatar-orientation-reference.cjs',n/'user-avatar-orientation-compare.py',Path(__file__).resolve()];before={p.name:sha(p)for p in watched}
p=subprocess.run(['node',str(n/'user-avatar-orientation-reference.cjs')],capture_output=True,text=True,timeout=100,cwd=n.parent.parent)
if p.returncode:raise RuntimeError(p.stdout+p.stderr)
with(r/'build.log').open('w')as log:subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','CoreGraphics','-framework','ImageIO',*map(str,files),'-o',str(r/'Tests')],check=True,stdout=log,stderr=log)
subprocess.run([str(r/'Tests'),str(r)],check=True,capture_output=True,timeout=20)
p=subprocess.run(['python3',str(n/'user-avatar-orientation-compare.py')],capture_output=True,text=True,timeout=20)
if p.returncode:raise RuntimeError(p.stdout+p.stderr)
proof=json.loads((r/'native-verification.json').read_text());proof['inputsSHA256']=before;proof['inputsUnchanged']=before=={p.name:sha(p)for p in watched};proof['artifacts']={'files':len([p for p in r.iterdir()if p.is_file()]),'bytes':sum(p.stat().st_size for p in r.iterdir()if p.is_file())}
(n/'build/user-avatar-orientation-verification.json').write_text(json.dumps(proof,indent=2)+'\n');assert proof['inputsUnchanged'];print(json.dumps({k:proof[k]for k in ['checks','cases','htmlFramePairsExact','inputsUnchanged','artifacts']}))
