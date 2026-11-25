from pathlib import Path
import subprocess,json,os,time,hashlib,struct,sys
n=Path(__file__).resolve().parent;r=n/'build/avatar-worker'
header=lambda kind,length,magic=b'AVH1':magic+bytes([kind,0,0,0])+struct.pack('<I',length)
def alive(pid):
 try:os.kill(pid,0);return True
 except ProcessLookupError:return False
if '--parent' in sys.argv:
 hold='--hold' in sys.argv
 worker=subprocess.Popen([str(r/'NextCRMAvatarDecoder'),'--parent',str(os.getpid())],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
 b=(n/'build/avatar-streaming/webp-16mp.webp').read_bytes();worker.stdin.write(header(1,len(b))+b);worker.stdin.flush()
 h=worker.stdout.read(12);assert h[:5]==b'AVH1\x10';p=worker.stdout.read(struct.unpack('<I',h[8:12])[0]);assert len(p)==12
 keeper=subprocess.Popen(['/bin/sleep','1'],stdin=worker.stdin,stdout=worker.stdout,stderr=subprocess.DEVNULL)if hold else None
 rec={'parentPID':os.getpid(),'helperPID':worker.pid,'keeperPID':keeper.pid if keeper else None,'heldPipes':hold}
 (r/('parent-held.json'if hold else'parent-plain.json')).write_text(json.dumps(rec))
 worker.stdin.write(header(2,0));worker.stdin.flush();os._exit(0)
raw=[]
for name,packet,truncate in [('magic',header(1,1,b'AVH2'),False),('input-length',header(1,4194305),False),('uint-length',header(1,0xffffffff),False),('unknown',header(99,0),False),('next-payload',header(2,1),False),('truncated-body',header(1,16)+b'abc',True)]:
 w=subprocess.Popen([str(r/'NextCRMAvatarDecoder'),'--parent',str(os.getpid())],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
 try:
  w.stdin.write(packet);w.stdin.flush()
  if truncate:w.stdin.close()
  status=w.wait(timeout=2);out=w.stdout.read(100);assert not out and(status==0 if truncate else status!=0)
  raw.append({'name':name,'exit':status,'responseBytes':len(out)})
 finally:
  if w.poll()is None:w.kill();w.wait()
  if not w.stdin.closed:w.stdin.close()
  w.stdout.close()
records=[]
for hold in [False,True]:
 subprocess.run([sys.executable,str(Path(__file__).resolve()),'--parent']+(['--hold']if hold else[]),check=True,timeout=10)
 rec=json.loads((r/('parent-held.json'if hold else'parent-plain.json')).read_text());start=time.monotonic()
 while alive(rec['helperPID'])and time.monotonic()-start<2:time.sleep(.005)
 rec['helperGone']=not alive(rec['helperPID']);rec['keeperStillAlive']=bool(rec['keeperPID']and alive(rec['keeperPID']));rec['observedSeconds']=time.monotonic()-start
 assert rec['helperGone']and(not hold or rec['keeperStillAlive'])
 start=time.monotonic()
 while rec['keeperPID']and alive(rec['keeperPID'])and time.monotonic()-start<2:time.sleep(.01)
 assert rec['keeperPID']is None or not alive(rec['keeperPID']);records.append(rec)
files=[n/'NativeUserAvatarWorkerProtocol.swift',n/'NativeUserAvatarWorkerMain.swift',r/'NextCRMAvatarDecoder',Path(__file__).resolve()]
proof={'checks':11,'rawPackets':raw,'parentExit':records,'sourceSHA256':{str(p.relative_to(n)):hashlib.sha256(p.read_bytes()).hexdigest()for p in files}}
(r/'protocol-verification.json').write_text(json.dumps(proof,indent=2)+'\n');print(json.dumps({'checks':11,'parentExit':records}))
