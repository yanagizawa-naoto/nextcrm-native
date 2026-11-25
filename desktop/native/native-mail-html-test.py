#!/usr/bin/env python3
"""Actual system WebKit; only locally authored loopback content, no downloads."""
from pathlib import Path
import base64, hashlib, http.server, json, struct, subprocess, threading, zlib

native = Path(__file__).resolve().parent
def chunk(kind, body):
    return struct.pack('!I', len(body)) + kind + body + struct.pack('!I', zlib.crc32(kind + body) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', 8, 8, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress((b'\0' + bytes([30, 110, 180]) * 8) * 8)) + chunk(b'IEND', b'')
events = []
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path == '/events': data, kind = json.dumps(events).encode(), 'application/json'
        else:
            events.append(self.path)
            data, kind = (png, 'image/png') if self.path == '/image.png' else (b'#external{color:rgb(0,85,0)}', 'text/css') if self.path == '/style.css' else (b'unexpected', 'text/plain')
        self.send_response(200); self.send_header('Content-Type', kind); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)

files = ['NativeMailHTML.swift', 'NativeMailHTMLRenderer.swift', 'NativeMailHTMLTests.swift']
hashes = {x:hashlib.sha256((native / x).read_bytes()).hexdigest() for x in files}
output = native / 'build/NativeMailHTMLTests'
output.parent.mkdir(exist_ok=True)
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-target','arm64-apple-macos13.0','-framework','AppKit','-framework','WebKit',*[str(native / x) for x in files],'-o',str(output)],check=True)
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    result = subprocess.run([str(output), f'http://127.0.0.1:{server.server_port}', base64.b64encode(png).decode()],capture_output=True,text=True,timeout=90)
finally: server.shutdown(); server.server_close()
print(result.stdout, end='')
if result.stderr: print(result.stderr[-3000:],end='')
assert hashes == {x:hashlib.sha256((native / x).read_bytes()).hexdigest() for x in files}, 'Sources changed during tests'
(native / 'build/native-mail-html-tests.json').write_text(json.dumps({'exit':result.returncode,'sourcesSHA256':hashes,'stdout':result.stdout,'requests':events,'network':'loopback only; authored PNG/CSS'},ensure_ascii=False,indent=2)+'\n')
result.check_returncode()
