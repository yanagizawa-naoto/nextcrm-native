#!/usr/bin/env python3
from pathlib import Path
import subprocess,json,hashlib,threading,time
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
n=Path(__file__).resolve().parent
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  try:
   if self.path=='/slow':time.sleep(2)
   if self.path=='/redirect':
    self.send_response(302);self.send_header('Location',f'http://different.invalid:{self.server.server_port}/auth');self.send_header('Content-Length','0');self.end_headers();return
   body=(self.headers.get('Host','') if self.path=='/host' else self.headers.get('Authorization','none') if self.path=='/auth' else 'x'*200000 if self.path=='/large' else '日本語 fixture').encode()
   self.send_response(200,'Fixture OK');self.send_header('Content-Length',str(len(body)));self.end_headers()
   for i in range(0,len(body),200):self.wfile.write(body[i:i+200]);self.wfile.flush()
  except (BrokenPipeError,ConnectionResetError):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
files=['NativePluginsHTTP.c','NativePluginsHTTP.h','NativeMailTransport.c','NativeMailTransport.h','NativePluginsTypes.swift','NativePluginsHTTP.swift','NativePluginsHTTPTransport.swift','NativePluginsHTTPTests.swift','plugins-http-reference.cjs','plugins-source-loader.cjs','plugins-http-test.py']
before={f:hashlib.sha256((n/f).read_bytes()).hexdigest() for f in files}
commands=[['node',str(n/'plugins-http-reference.cjs')],['clang','-Wall','-Wextra','-Werror','-c',str(n/'NativePluginsHTTP.c'),'-o',str(n/'build/NativePluginsHTTP.o')],['clang','-c',str(n/'NativeMailTransport.c'),'-o',str(n/'build/plugins-http-mail-guard.o')],['swiftc','-swift-version','5','-whole-module-optimization','-parse-as-library','-import-objc-header',str(n/'NativePluginsHTTP.h'),*[str(n/f) for f in ['NativePluginsTypes.swift','NativePluginsHTTP.swift','NativePluginsHTTPTransport.swift','NativePluginsHTTPTests.swift']],str(n/'build/NativePluginsHTTP.o'),str(n/'build/plugins-http-mail-guard.o'),'-lcurl','-o',str(n/'build/plugins-http-tests')], [str(n/'build/plugins-http-tests'),str(n/'build/plugins-http-reference.json'),str(server.server_port)]]
results=[]
try:
 for command in commands:
  r=subprocess.run(command,capture_output=True,text=True,timeout=180);results.append({'tool':Path(command[0]).name,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr[-9000:]})
  if r.returncode:break
finally:server.shutdown();server.server_close()
proof={'exit':results[-1]['exit'],'results':results,'sources':before,'unchanged':all(hashlib.sha256((n/f).read_bytes()).hexdigest()==h for f,h in before.items())}
if (n/'build/plugins-http-reference.json').exists():proof['sourceHashes']=json.loads((n/'build/plugins-http-reference.json').read_text())['sourceHashes']
(n/'build/plugins-http-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');print(json.dumps(proof,ensure_ascii=False));raise SystemExit(proof['exit'])
