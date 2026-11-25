from pathlib import Path
import subprocess,struct,zlib,json,os,hashlib
n=Path(__file__).resolve().parent;r=n/'build/avatar-worker'
header=lambda k,size:b'AVH1'+bytes([k,0,0,0])+struct.pack('<I',size)
chunk=lambda tag,b:struct.pack('>I',len(b))+tag+b+struct.pack('>I',zlib.crc32(tag+b))
def apng(w,h):
 c=zlib.compressobj();raw=bytearray();row=b'\0'+bytes([255,0,0,255])*w
 for _ in range(h):raw.extend(c.compress(row))
 raw.extend(c.flush())
 return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0))+chunk(b'acTL',struct.pack('>II',1,1))+chunk(b'fcTL',struct.pack('>IIIIIHHBB',0,w,h,0,0,1,10,0,0))+chunk(b'IDAT',raw)+chunk(b'IEND',b'')
def read(w,cap):
 h=w.stdout.read(12);assert len(h)==12 and h[:4]==b'AVH1' and h[5:8]==bytes(3);size=struct.unpack('<I',h[8:])[0];assert size<=cap;p=w.stdout.read(size);assert len(p)==size;return h[4],p
checks=0;cases=[]
for name,w,h in [('maximum-side',16384,1024),('over-1024',1025,1),('over-side',16385,1),('over-pixels',4096,4097),('exact-input',0,0)]:
 if name=='exact-input':b=(n/'build/avatar-streaming/gif-16mp.gif').read_bytes();b+=bytes(4194304-len(b))
 else:b=apng(w,h)
 p=subprocess.Popen([str(r/'NextCRMAvatarDecoder'),'--parent',str(os.getpid())],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
 try:
  p.stdin.write(header(1,len(b))+b);p.stdin.flush();kind,payload=read(p,12)
  if name.startswith('over-')and name!='over-1024':assert kind==0x7f and struct.unpack('<I',payload)[0]==3;checks+=1
  else:
   assert kind==0x10;checks+=1;p.stdin.write(header(2,0));p.stdin.flush();kind,frame=read(p,262176);assert kind==0x11;checks+=1
   width,height=struct.unpack('<HH',frame[4:8]);assert 0<width<=256 and 0<height<=256 and len(frame)==32+width*height*4;checks+=1
  cases.append({'name':name,'inputBytes':len(b),'width':w,'height':h,'responseKind':kind})
 finally:
  p.stdin.close()
  try:p.wait(timeout=2)
  except subprocess.TimeoutExpired:p.kill();p.wait();raise
  p.stdout.close()
  checks+=1
files=[n/'NativeUserAvatarWorkerProtocol.swift',n/'NativeUserAvatarWorkerMain.swift',r/'NextCRMAvatarDecoder',n/'NativeUserAvatarAnimation.swift',n/'NativeUserAvatarWebPAnimation.swift',n/'NativeUserAvatarAPNGAnimation.swift',Path(__file__).resolve()]
proof={'checks':checks,'cases':cases,'temporaryFiles':0,'sourceSHA256':{str(p.relative_to(n)):hashlib.sha256(p.read_bytes()).hexdigest()for p in files}}
(r/'bounds-verification.json').write_text(json.dumps(proof,indent=2)+'\n');print(json.dumps({'checks':checks,'cases':len(cases),'temporaryFiles':0}))
