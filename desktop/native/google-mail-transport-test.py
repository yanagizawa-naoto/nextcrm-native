#!/usr/bin/env python3
"""Exercise production OAuth target validation before any DNS or socket call."""
import ctypes as C,hashlib,importlib.util,json,subprocess,os
from pathlib import Path
N=Path(__file__).resolve().parent;O=N/'build'/'google-mail-transport';O.mkdir(parents=True,exist_ok=True)
spec=importlib.util.spec_from_file_location('mail_transport_fixture',N/'native-mail-transport-test.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
subprocess.run(['xcrun','clang','-std=c11','-dynamiclib','-O2','-Wall','-Wextra','-Werror','-lcurl',str(N/'NativeMailTransport.c'),'-o',str(O/'transport.dylib')],check=True)
lib=C.CDLL(str(O/'transport.dylib'));lib.native_mail_perform.argtypes=[C.POINTER(m.Request)];lib.native_mail_perform.restype=m.Result;lib.native_mail_result_free.argtypes=[C.POINTER(m.Result)]
cb=C.CFUNCTYPE(C.c_int,C.c_void_p)(lambda _:1)
def invoke(url,mode=2,selfsigned=0,bearer=b'synthetic-only',password=b'',smtp=False,maximum=1024,fd=None):
 q=m.Request();q.url=url.encode();q.username=b'owner@example.test';q.password=password;q.oauth_bearer=bearer;q.maximum_response=maximum;q.stream_to_fd=int(fd is not None);q.output_fd=fd if fd is not None else -1;q.tls_mode=mode;q.allow_self_signed=selfsigned;q.cancelled=C.cast(cb,C.c_void_p);q.command=None if smtp else b'NOOP';q.smtp_verify_only=int(smtp)
 r=lib.native_mail_perform(C.byref(q));code=r.code;lib.native_mail_result_free(C.byref(r));return code
checks=[]
for url,mode,selfsigned,bearer,password,smtp,want in [
 ('imaps://imap.gmail.com:993/',2,0,b'x',b'',False,-5),('smtps://smtp.gmail.com:465/',2,0,b'x',b'',True,-5),
 ('imaps://evil.example.test:993/',2,0,b'x',b'',False,-1),('smtps://evil.example.test:465/',2,0,b'x',b'',True,-1),
 ('imap://imap.gmail.com:993/',0,0,b'x',b'',False,-1),('smtp://smtp.gmail.com:587/',1,0,b'x',b'',True,-1),
 ('imaps://imap.gmail.com:993/',2,1,b'x',b'',False,-1),('smtps://smtp.gmail.com:465/',2,1,b'x',b'',True,-1),
 ('imaps://imap.gmail.com:995/',2,0,b'x',b'',False,-1),('imaps://imap.gmail.com:993/',2,0,b'',b'',False,-1),
 ('imaps://imap.gmail.com:993/',2,0,b'x\r\ny',b'',False,-1),('imaps://imap.gmail.com:993/',2,0,b'x',b'fallback',False,-1),
 ('imaps://imap.example.test:993/',2,0,None,b'legacy-password',False,-5),
 ('imaps://imap.gmail.com:993/?token=synthetic',2,0,b'x',b'',False,-1),
]:
 actual=invoke(url,mode,selfsigned,bearer,password,smtp);assert actual==want,(url,actual,want);checks.append({'url':url,'expectedCode':want,'actualCode':actual})
path=O/'owned-stream-fixture';fd=os.open(path,os.O_RDWR|os.O_CREAT|os.O_EXCL,0o600)
try:
 for maximum,stream,want in [(2**32,True,-5),(2**63-1,True,-5),(2**63,True,-1),(2**64-1,True,-1),(2**63-1,False,-1),(33554433,False,-1)]:
  actual=invoke('imaps://imap.gmail.com:993/',maximum=maximum,fd=fd if stream else None);assert actual==want,(maximum,stream,actual);checks.append({'maximum':maximum,'stream':stream,'actualCode':actual})
finally:os.close(fd);path.unlink()
proof={'checks':len(checks),'cases':checks,'network':'none: valid requests cancelled before DNS; invalid rejected earlier','sourcesSHA256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [N/'NativeMailTransport.c',N/'NativeMailTransport.h',N/'native-mail-transport-test.py',Path(__file__)]}}
(O/'verification.json').write_text(json.dumps(proof,indent=2)+'\n');print(json.dumps({'checks':len(checks),'exit':0}))
