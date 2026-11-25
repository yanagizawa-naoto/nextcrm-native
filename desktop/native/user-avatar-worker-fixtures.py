from pathlib import Path
import struct,zlib,json,hashlib
r=Path(__file__).resolve().parent/'build/avatar-worker';r.mkdir(parents=True,exist_ok=True)
chunk=lambda t,b:struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b))
def pixels(w,h,c):
 o=zlib.compressobj();result=bytearray();row=b'\0'+bytes(c)*w
 for _ in range(h):result.extend(o.compress(row))
 result.extend(o.flush());return bytes(result)
def make(name,w,h,colors,poster=None,loops=0):
 p=[b'\x89PNG\r\n\x1a\n',chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0)),chunk(b'acTL',struct.pack('>II',len(colors),loops))];seq=0
 if poster:p.append(chunk(b'IDAT',pixels(w,h,poster)))
 for index,c in enumerate(colors):
  p.append(chunk(b'fcTL',struct.pack('>IIIIIHHBB',seq,w,h,0,0,1,10,0,0)));seq+=1;raw=pixels(w,h,c)
  if index==0 and not poster:p.append(chunk(b'IDAT',raw))
  else:p.append(chunk(b'fdAT',struct.pack('>I',seq)+raw));seq+=1
 p.append(chunk(b'IEND',b''));(r/(name+'.png')).write_bytes(b''.join(p))
make('wide-infinite',1025,8,[(255,0,0,255),(0,255,0,255)])
make('wide-single-poster',1025,8,[(0,255,0,255)],(0,0,255,255),1)
make('wide-finite',1025,8,[(255,0,0,255),(0,255,0,255)],loops=1)
print(json.dumps({'fixtureBytes':sum(p.stat().st_size for p in r.glob('wide-*.png'))}))
