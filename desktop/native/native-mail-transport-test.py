#!/usr/bin/env python3
"""Exercise the real system libcurl adapter against disposable local mail servers.
The loopback override exists only in this separately compiled test library.
"""
import base64
import ctypes as C
import datetime
import email
import email.policy
import hashlib
import json
import os
from pathlib import Path
from native_mail_build import html_inputs, html_object
import socket
import ssl
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / 'build'
BUILD.mkdir(exist_ok=True)

class Request(C.Structure):
    _fields_ = [('url', C.c_char_p), ('username', C.c_char_p), ('password', C.c_char_p),
                ('command', C.c_char_p), ('sender', C.c_char_p), ('recipients', C.c_char_p),
                ('upload', C.c_void_p), ('upload_length', C.c_size_t), ('maximum_response', C.c_size_t),
                ('tls_mode', C.c_int), ('allow_self_signed', C.c_int), ('cancelled', C.c_void_p), ('context', C.c_void_p),
                ('stream_to_fd', C.c_int), ('output_fd', C.c_int), ('smtp_verify_only', C.c_int)]

class Result(C.Structure):
    _fields_ = [('code', C.c_int), ('server_code', C.c_long), ('body', C.c_void_p), ('body_length', C.c_size_t),
                ('headers', C.c_void_p), ('headers_length', C.c_size_t), ('uploaded_bytes', C.c_size_t), ('response_bytes', C.c_size_t)]

class Server:
    def __init__(self, smtp=False, mode='plain', context=None, failure=None, payload=None, utf8=False):
        self.smtp, self.mode, self.context, self.failure = smtp, mode, context, failure
        self.payload = payload
        self.utf8, self.tls_active, self.envelope = utf8, mode == 'tls', []
        self.commands, self.messages, self.errors = [], [], []
        self.listener = socket.socket(); self.listener.bind(('127.0.0.1', 0)); self.listener.listen(1)
        self.listener.settimeout(8); self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self.run, daemon=True); self.thread.start()

    def run(self):
        connection = None
        try:
            connection, _ = self.listener.accept(); connection.settimeout(8)
            if self.mode == 'tls': connection = self.context.wrap_socket(connection, server_side=True)
            reader = connection.makefile('rb')
            def send(text): connection.sendall(text.encode() if isinstance(text, str) else text)
            def read(): return reader.readline(4 * 1024 * 1024)
            send('220 fixture.test ESMTP\r\n' if self.smtp else '* OK fixture IMAP4rev1\r\n')
            while True:
                line = read()
                if not line: break
                text = line.decode(errors='replace').rstrip('\r\n')
                if self.smtp:
                    command = text.split(' ', 1)[0].upper(); self.commands.append(command)
                    if command in ('EHLO', 'HELO'):
                        utf8 = self.utf8 is True or self.utf8 == ('after-tls' if self.tls_active else 'before-tls')
                        send('250-fixture.test\r\n'+('' if self.failure=='no-starttls' else '250-STARTTLS\r\n')+('250-SMTPUTF8\r\n250-8BITMIME\r\n' if utf8 else '')+'250 AUTH PLAIN\r\n')
                    elif command == 'STARTTLS':
                        if self.failure == 'starttls-rejected': send('454 TLS temporarily unavailable\r\n'); continue
                        send('220 ready\r\n'); reader.close(); connection = self.context.wrap_socket(connection, server_side=True); reader = connection.makefile('rb'); self.tls_active = True
                    elif command == 'AUTH':
                        parts = text.split(' ')
                        if len(parts) < 3: send('334 \r\n'); token = read().strip()
                        else: token = parts[2].encode()
                        assert base64.b64decode(token).endswith(b'\0fixture@example.test\0synthetic-only')
                        send('535 authentication failed\r\n' if self.failure == 'auth' else '235 authenticated\r\n')
                    elif command == 'MAIL': self.envelope.append(text); send('250 sender\r\n')
                    elif command == 'RCPT': self.envelope.append(text); send('550 rejected\r\n' if self.failure == 'recipient' else '250 recipient\r\n')
                    elif command == 'DATA':
                        send('354 continue\r\n'); message = bytearray()
                        while True:
                            item = read()
                            if item == b'.\r\n': break
                            if not item: raise AssertionError('incomplete DATA')
                            message.extend(item[1:] if item.startswith(b'..') else item)
                        self.messages.append(bytes(message))
                        if self.failure == 'lost-result': break
                        send('250 accepted fixture-id\r\n')
                    elif command == 'QUIT': send('221 bye\r\n'); break
                    else: raise AssertionError('unexpected SMTP command: ' + command)
                else:
                    tag, command = text.split(' ', 1); verb = command.split(' ', 1)[0].upper(); self.commands.append(command if verb != 'AUTHENTICATE' else verb)
                    if verb == 'CAPABILITY': send('* CAPABILITY IMAP4rev1 STARTTLS AUTH=PLAIN\r\n' + tag + ' OK capability\r\n')
                    elif verb == 'STARTTLS':
                        send(tag + ' OK begin TLS\r\n'); reader.close(); connection = self.context.wrap_socket(connection, server_side=True); reader = connection.makefile('rb')
                    elif verb == 'AUTHENTICATE':
                        send('+ \r\n'); token = read().strip()
                        assert base64.b64decode(token).endswith(b'\0fixture@example.test\0synthetic-only')
                        send(tag + ' OK authenticated\r\n')
                    elif verb in ('SELECT', 'EXAMINE'):
                        send('* 2 EXISTS\r\n* OK [UIDVALIDITY 77] valid\r\n' + tag + ' OK selected\r\n')
                    elif verb == 'STATUS': send('* STATUS "INBOX" (UIDVALIDITY 77 UIDNEXT 3)\r\n' + tag + ' OK status\r\n')
                    elif verb == 'LIST': send('* LIST (\\HasNoChildren) "/" "INBOX"\r\n* LIST () "/" "&kAFP4W4IMH8-"\r\n' + tag + ' OK listed\r\n')
                    elif command.startswith('UID SEARCH'):
                        if self.payload is not None: send(self.payload + tag.encode() + b' OK searched\r\n')
                        else: send('* SEARCH 1 2\r\n' + tag + ' OK searched\r\n')
                    elif command.startswith('UID FETCH'):
                        body = b'Message-ID: <fixture-1@test>\r\nSubject: =?UTF-8?B?5pel5pys6Kqe?=\r\nFrom: Fixture <sender@example.test>\r\n\r\n'
                        if self.payload is not None: body = self.payload
                        if self.failure == 'literal-too-large': send(b'* 1 FETCH (UID 1 BODY[] {33554433}\r\n'); break
                        if self.failure == 'bad-literal': send(b'* 1 FETCH (UID 1 BODY[] {oops}\r\n'); break
                        section = b'BODY[HEADER]' if 'HEADER' in command else b'BODY[]'
                        response = b'* 1 FETCH (UID 1 FLAGS (\\Seen) '+section+b' {' + str(len(body)).encode() + b'}\r\n' + body + b')\r\n' + tag.encode() + b' OK fetched\r\n'
                        if self.failure == 'truncated': send(response[:response.index(body)+max(0,len(body)-3)]); break
                        if self.failure == 'unsolicited': response = b'* 2 FETCH (UID 2 FLAGS ())\r\n' + response
                        if self.failure == 'two-literals':
                            response = b'* 1 FETCH (UID 1 BODY[HEADER] {0}\r\n BODY[TEXT] {'+str(len(body)).encode()+b'+}\r\n'+body+b')\r\n'+tag.encode()+b' OK fetched\r\n'
                        if self.failure == 'fragmented':
                            for index in range(0,len(response),7): send(response[index:index+7])
                        else: send(response)
                    elif verb == 'NOOP':
                        if self.failure == 'slow': time.sleep(2)
                        send('* OK ' + ('x' * 4096) + '\r\n' + tag + ' OK noop\r\n')
                    elif verb == 'LOGOUT': send('* BYE closing\r\n' + tag + ' OK logout\r\n'); break
                    else: raise AssertionError('unexpected IMAP command: ' + command)
        except (ssl.SSLError, ConnectionResetError, BrokenPipeError):
            pass  # Expected during rejected certificate, bounded response, and cancellation checks.
        except Exception as error:
            self.errors.append(str(error))
        finally:
            if connection: connection.close()
            self.listener.close()

    def finish(self):
        self.thread.join(10)
        assert not self.thread.is_alive(), 'fixture did not terminate'
        assert not self.errors, self.errors

def main():
    watched = [ROOT/name for name in ['NativeMailTransport.c','NativeMailTransport.h','NativeMailTemporaryFiles.swift','NativeMail.swift','NativeMailMIME.swift','NativeMailIMAP.swift', 'NativeMailMIMESpool.swift', 'NativeMailTextHTML.swift', 'NativeMailIMAPFile.swift','NativeMailSpool.swift','NativeMailClient.swift','NativeMailWireIntegrationTests.swift','native-mail-transport-test.py']] + html_inputs(ROOT)
    before = {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
    checks = []
    def check(value, name):
        assert value, name
        checks.append(name)
    with tempfile.TemporaryDirectory(prefix='native-mail-', dir=BUILD) as temporary:
        temp = Path(temporary); dylib = temp / 'transport.dylib'; production = temp / 'production.dylib'
        for path, flags in [(dylib, ['-DNATIVE_MAIL_TRANSPORT_TESTING']), (production, [])]:
            subprocess.run(['clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-dynamiclib', *flags, str(ROOT/'NativeMailTransport.c'), '-lcurl', '-o', str(path)], check=True)
        fixture_object = temp/'NativeMailQA.o'
        subprocess.run(['clang','-std=c11','-O2','-DNATIVE_MAIL_TRANSPORT_TESTING','-c',str(ROOT/'NativeMailTransport.c'),'-o',str(fixture_object)],check=True)
        html = html_object(ROOT,temp/'CampaignHTML.o')
        bridge = temp/'NativeMailWireIntegrationTests'
        subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-lcurl','-lsqlite3','-lxml2','-import-objc-header',str(ROOT/'NativeMailParsing.h'),str(fixture_object),str(html),*[str(ROOT/name) for name in ['NativeMailHTMLText.swift','NativeMailTemporaryFiles.swift','NativeMail.swift','NativeMailMIME.swift','NativeMailIMAP.swift', 'NativeMailMIMESpool.swift', 'NativeMailTextHTML.swift', 'NativeMailIMAPFile.swift','NativeMailSpool.swift','NativeMailClient.swift','NativeMailWireIntegrationTests.swift']],'-o',str(bridge)],check=True)
        library = C.CDLL(str(dylib)); prod = C.CDLL(str(production))
        for lib in (library, prod):
            lib.native_mail_perform.argtypes = [C.POINTER(Request)]; lib.native_mail_perform.restype = Result
            lib.native_mail_result_free.argtypes = [C.POINTER(Result)]
            lib.native_mail_address_is_public.argtypes = [C.c_char_p]
        def perform(server=None, command=b'LIST "" "*"', mailbox='', smtp=False, verify=False, cap=1_048_576, url=None, lib=library, cancel=False, output_fd=None, tls_override=None, smtp_verify_only=False):
            mode = server.mode if server else 'plain'
            address = url or ('smtp' if smtp else 'imap') + ('s' if mode == 'tls' else '') + f'://127.0.0.1:{server.port}/{mailbox}'
            body = b'From: fixture@example.test\r\nTo: receiver@example.test\r\nSubject: test\r\n\r\n..dot\r\nbody\r\n'
            upload = C.create_string_buffer(body)
            cancellation = C.CFUNCTYPE(C.c_int, C.c_void_p)(lambda _: int(cancel))
            q = Request(address.encode(), b'fixture@example.test', b'synthetic-only', None if smtp else command,
                        b'fixture@example.test' if smtp and not smtp_verify_only else None, b'receiver@example.test' if smtp and not smtp_verify_only else None,
                        C.cast(upload, C.c_void_p) if smtp and not smtp_verify_only else None, len(body) if smtp and not smtp_verify_only else 0, cap,
                        tls_override if tls_override is not None else {'plain': 0, 'starttls': 1, 'tls': 2}[mode], int(not verify), C.cast(cancellation, C.c_void_p), None,
                        int(output_fd is not None), output_fd if output_fd is not None else -1, int(smtp_verify_only))
            result = lib.native_mail_perform(C.byref(q))
            response = {'code': result.code, 'serverCode': result.server_code, 'uploaded': result.uploaded_bytes, 'responseBytes':result.response_bytes,
                        'body': C.string_at(result.body, result.body_length), 'headers': C.string_at(result.headers, result.headers_length)}
            lib.native_mail_result_free(C.byref(result))
            if server: server.finish()
            return response
        for address in ['127.0.0.1','10.0.0.1','169.254.169.254','172.16.0.1','192.168.1.1','100.64.0.1','192.0.2.1','198.18.0.1','198.51.100.1','203.0.113.1','224.0.0.1','::1','fc00::1','fe80::1','::ffff:127.0.0.1','2001:db8::1','2002:7f00:1::1']:
            check(not library.native_mail_address_is_public(address.encode()), 'blocked address '+address)
        for address in ['8.8.8.8','1.1.1.1','2606:4700:4700::1111']:
            check(library.native_mail_address_is_public(address.encode()), 'public address '+address)
        check(perform(url='imap://127.0.0.1:143/', lib=prod)['code'] == -2, 'production denies loopback')
        check(perform(url='imap://127.0.0.1:9999/', lib=prod)['code'] == -2, 'production public-host policy also covers custom mail ports')
        check(perform(url='imap://127.0.0.1:65536/', lib=prod)['code'] == -1, 'production rejects out-of-range mail port')
        check(perform(url='http://127.0.0.1:143/', lib=prod)['code'] == -1, 'reject wrong protocol')
        check(perform(url='imap://user@127.0.0.1:143/', lib=prod)['code'] == -1, 'reject URL credentials')
        check(perform(url='imap://127.0.0.1:143/', command=b'NOOP\r\nLOGOUT', lib=prod)['code'] == -1, 'reject command injection')
        for command in [b'STORE 1 +FLAGS (\\Seen)',b'UID FETCH 1 BODY[]',b'UID FETCH 1 (BODY.PEEK[] BODY[])',b'CLOSE']:
            check(perform(url='imap://127.0.0.1:143/', command=command, lib=prod)['code'] == -1, 'reject mutating command before network '+command.decode())
        check(perform(url='imap://127.0.0.1:143/', lib=prod, cancel=True)['code'] == -5, 'cancellation before DNS and authentication')
        check(perform(url='imap://8.8.8.8:1993/',lib=prod,cancel=True)['code']==-5, 'production accepts custom IMAP port then cancels before DNS/network')
        check(perform(url='smtp://8.8.8.8:2587/',smtp=True,lib=prod,cancel=True)['code']==-5, 'production accepts custom SMTP port then cancels before DNS/network')
        key, cert = temp/'key.pem', temp/'cert.pem'
        subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key), '-out', str(cert), '-days', '1', '-subj', '/CN=localhost'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert, key)
        samples = {}
        for mode in ['plain','starttls','tls']:
            server = Server(mode=mode,context=context); result = perform(server)
            check(result['code']==0 and b'INBOX' in result['body'], 'IMAP folder list '+mode)
            if mode=='starttls': check('STARTTLS' in server.commands, 'IMAP upgrades before auth')
            server = Server(smtp=True,mode=mode,context=context); result = perform(server,smtp=True)
            check(result['code']==0 and len(server.messages)==1 and b'..dot\r\n' in server.messages[0], 'SMTP delivery and dot-stuffing '+mode)
            if mode=='starttls': check(server.commands.index('STARTTLS') < server.commands.index('AUTH'), 'SMTP upgrades before auth')
        for mode, tls, failure in [('plain',0,None),('starttls',1,None),('tls',2,None),('starttls',3,None),('plain',3,'no-starttls')]:
            server=Server(smtp=True,mode=mode,context=context,failure=failure)
            result=perform(server,smtp=True,tls_override=tls,smtp_verify_only=True)
            check(result['code']==0 and 'AUTH' in server.commands and result['uploaded']==0, 'SMTP verification authenticates '+str(tls))
            check(not set(server.commands).intersection(['MAIL','RCPT','DATA']) and not server.messages, 'SMTP verification never sends '+str(tls))
            server=Server(smtp=True,mode=mode,context=context,failure=failure)
            result=subprocess.run([str(bridge),str(server.port),str(tls),'smtp-verify'],capture_output=True,text=True,timeout=15)
            server.finish()
            check(result.returncode==0 and 'AUTH' in server.commands and not set(server.commands).intersection(['MAIL','RCPT','DATA']), 'Swift SMTP verification '+str(tls))
        for mode, tls, failure, verify, code in [('plain',0,'auth',False,67),('plain',1,'no-starttls',False,64),('plain',3,'starttls-rejected',False,64),('tls',2,None,True,60)]:
            server=Server(smtp=True,mode=mode,context=context,failure=failure)
            result=perform(server,smtp=True,tls_override=tls,smtp_verify_only=True,verify=verify)
            check(result['code']==code and result['uploaded']==0 and not set(server.commands).intersection(['MAIL','RCPT','DATA']), 'SMTP verification failure '+str(failure or 'certificate'))
        for mode, tls, utf8 in [('plain',0,True),('tls',2,True),('starttls',1,'after-tls'),('starttls',3,'after-tls')]:
            server=Server(smtp=True,mode=mode,context=context,utf8=utf8)
            result=subprocess.run([str(bridge),str(server.port),str(tls),'smtp-utf8'],capture_output=True,text=True,timeout=15); server.finish()
            check(result.returncode==0 and len(server.messages)==1, 'actual Swift international mailbox delivery '+str(tls)+': '+result.stderr[-200:])
            check(any(line.startswith('MAIL FROM:') and ' SMTPUTF8' in line for line in server.envelope) and 'RCPT TO:<担当者@xn--r8jz45g.xn--zckzah>' in server.envelope, 'SMTPUTF8 negotiation and IDNA envelope '+str(tls))
        for mode,tls,utf8 in [('plain',0,False),('tls',2,False),('starttls',1,'before-tls'),('starttls',3,'before-tls')]:
            server=Server(smtp=True,mode=mode,context=context,utf8=utf8)
            result=subprocess.run([str(bridge),str(server.port),str(tls),'smtp-utf8-unsupported'],capture_output=True,text=True,timeout=15); server.finish()
            check(result.returncode==0 and not server.messages and not set(server.commands).intersection(['AUTH','MAIL','RCPT','DATA']), 'unsupported SMTPUTF8 rejected before auth/send including post-TLS change '+str(tls)+': '+result.stderr[-200:])
        server=Server(smtp=True)
        result=subprocess.run([str(bridge),str(server.port),'0','smtp-addresses'],capture_output=True,text=True,timeout=15); server.finish()
        check(result.returncode==0 and 'RCPT TO:<"a,@b"@example.test>' in server.envelope and len(server.messages)==1, 'quoted local-part survives real libcurl address parsing')
        server=Server(smtp=True)
        result=subprocess.run([str(bridge),str(server.port),'0','smtp-many'],capture_output=True,text=True,timeout=30); server.finish()
        check(result.returncode==0 and [line for line in server.envelope if line.startswith('RCPT TO:')] == [f'RCPT TO:<person{i}@example.test>' for i in range(3501)], 'all3501 recipients and envelope beyond64KiB survive real Swift/C/libcurl')
        check(len(server.messages)==1 and b'person3001@example.test' not in server.messages[0] and b'person3500@example.test' not in server.messages[0], 'large Bcc is envelope-only')
        server=Server(smtp=True)
        result=subprocess.run([str(bridge),str(server.port),'0','smtp-many-large'],capture_output=True,text=True,timeout=30); server.finish()
        check(result.returncode==0 and [line for line in server.envelope if line.startswith('RCPT TO:')] == [f'RCPT TO:<person{i}@example.test>' for i in range(19001)], '19001 recipients complete with bounded per-command protocol buffer')
        check(len(server.messages)==1 and b'person19000@example.test' not in server.messages[0], 'large reply volume cannot truncate recipients or expose Bcc')
        server=Server(smtp=True); result=perform(server,smtp=True,cap=16)
        check(result['code']==-4 and result['uploaded']==0 and not server.messages, 'individual SMTP reply byte cap remains enforced')
        check(perform(url='smtp://8.8.8.8:2587/',smtp=True,lib=prod,cancel=True,smtp_verify_only=True)['code']==-5, 'SMTP verification cancels before network')
        for smtp in [False,True]:
            server = Server(smtp=smtp,mode='tls',context=context); result=perform(server,smtp=smtp,verify=True)
            check(result['code']!=0 and not server.messages and 'AUTH' not in server.commands, 'untrusted TLS rejected '+str(smtp))
        server=Server(smtp=True,mode='starttls',context=context); result=perform(server,smtp=True,tls_override=3)
        check(result['code']==0 and server.commands.index('STARTTLS')<server.commands.index('AUTH'), 'automatic SMTP upgrades before authentication when advertised')
        server=Server(smtp=True,failure='no-starttls'); result=perform(server,smtp=True,tls_override=3)
        check(result['code']==0 and 'STARTTLS' not in server.commands and len(server.messages)==1, 'automatic SMTP accepts legacy servers without STARTTLS')
        server=Server(smtp=True,failure='starttls-rejected'); result=perform(server,smtp=True,tls_override=3)
        check(result['code']==64 and 'AUTH' not in server.commands and not server.messages, 'advertised STARTTLS failure cannot downgrade to plaintext authentication')
        server=Server(smtp=True,mode='starttls',context=context); result=perform(server,smtp=True,tls_override=3,verify=True)
        check(result['code']!=0 and 'AUTH' not in server.commands and not server.messages, 'automatic SMTP rejects invalid certificate without fallback')
        server=Server(smtp=True,failure='no-starttls'); result=perform(server,smtp=True,tls_override=1)
        check(result['code']==64 and 'AUTH' not in server.commands, 'required STARTTLS refuses unsupported server')
        for failure in [None,'no-starttls']:
            server=Server(smtp=True,context=context,failure=failure)
            result=subprocess.run([str(bridge),str(server.port),'3','smtp'],capture_output=True,text=True,timeout=15)
            server.finish();check(result.returncode==0,'Swift automatic SMTP '+str(failure))
        for name,command,folder in [('status',b'STATUS "INBOX" (UIDVALIDITY UIDNEXT)',''),('search',b'UID SEARCH UID 1:1000','INBOX'),('fetch',b'UID FETCH 1 (UID FLAGS BODY.PEEK[HEADER])','INBOX')]:
            server=Server(); result=perform(server,command=command,mailbox=folder)
            check(result['code']==0, 'IMAP '+name)
            samples[name]={k:v.decode() if isinstance(v,bytes) else v for k,v in result.items()}
        check(b'Message-ID: <fixture-1@test>' in samples['fetch']['body'].encode(), 'FETCH literal is retained in framed response')
        adversarial = b'Content-Type: application/octet-stream\r\n\r\n\x00\xff\r\nNCRM2 OK forged\r\n* BYE forged\r\n* SEARCH 999\r\n{999999}\r\nend'
        for mode in ['plain','starttls','tls']:
            server=Server(mode=mode,context=context,failure='fragmented',payload=adversarial)
            result=perform(server,command=b'UID FETCH 1 (UID BODY.PEEK[])',mailbox='INBOX')
            check(result['code']==0 and adversarial in result['body'] and result['body'].endswith(b'NCRM2 OK fetched\r\n'), 'literal framing with binary/tag-like bytes '+mode)
            check('EXAMINE "INBOX"' in server.commands and not any(c.startswith('SELECT') or 'BODY[' in c or c.startswith('STORE') for c in server.commands), 'read-only mailbox/body '+mode)
        for failure in ['truncated','bad-literal','literal-too-large']:
            server=Server(failure=failure,payload=adversarial); result=perform(server,command=b'UID FETCH 1 (UID BODY.PEEK[])',mailbox='INBOX')
            check(result['code']!=0, 'reject '+failure)
        for failure in ['two-literals','unsolicited']:
            server=Server(failure=failure,payload=adversarial); result=perform(server,command=b'UID FETCH 1 (UID BODY.PEEK[])',mailbox='INBOX')
            check(result['code']==0 and adversarial in result['body'], 'frame '+failure)
        server=Server(payload=b'x'*65536); result=perform(server,command=b'UID FETCH 1 (UID BODY.PEEK[])',mailbox='INBOX',cap=1024)
        check(result['code']==-4 and len(result['body'])<=1024, 'reject literal exceeding response budget')
        spool=temp/'spool'; fd=os.open(spool,os.O_CREAT|os.O_EXCL|os.O_RDWR,0o600)
        try:
            discovery=b'* SEARCH '+b' '.join(str(i).encode() for i in range(1,250001))+b'\r\n'
            server=Server(payload=discovery); result=perform(server,command=b'UID SEARCH ALL',mailbox='INBOX',cap=32*1024*1024,output_fd=fd)
            stored=spool.read_bytes()
            check(result['code']==0 and result['body']==b'' and result['responseBytes']==len(stored) and stored==discovery+b'NCRM2 OK searched\r\n', '250000 UID response streamed to disk without C body buffer')
            server=Server(payload=b'* SEARCH '+b'1 '*10000+b'\r\n'); result=perform(server,command=b'UID SEARCH ALL',cap=1024,output_fd=fd)
            check(result['code']==-4 and spool.stat().st_size<=1024, 'disk response cap and previous contents truncated')
            os.chmod(spool,0o644)
            check(perform(url='imap://127.0.0.1:143/',output_fd=fd)['code']==-1, 'reject shared-permission spool before network')
            os.chmod(spool,0o600); os.link(spool,temp/'linked')
            check(perform(url='imap://127.0.0.1:143/',output_fd=fd)['code']==-1, 'reject hardlinked spool before network')
        finally: os.close(fd)
        server=Server(); result=perform(server,command=b'NOOP',cap=128)
        check(result['code']==-4, 'bounded IMAP response')
        server=Server(smtp=True,failure='recipient'); result=perform(server,smtp=True)
        check(result['code']!=0 and result['uploaded']==0 and not server.messages, 'rejected recipient is not sent')
        server=Server(smtp=True,failure='lost-result'); result=perform(server,smtp=True)
        check(result['code']!=0 and result['uploaded']>0 and len(server.messages)==1, 'lost SMTP response stays uncertain')
        os.environ['ALL_PROXY']='http://127.0.0.1:1'
        server=Server(); result=perform(server)
        check(result['code']==0, 'ignores proxy environment')
        for mode in ['plain','starttls','tls']:
            for smtp in [False,True]:
                server=Server(smtp=smtp,mode=mode,context=context)
                result=subprocess.run([str(bridge),str(server.port),str({'plain':0,'starttls':1,'tls':2}[mode]),'smtp' if smtp else 'imap'],capture_output=True,text=True,timeout=15)
                server.finish()
                check(result.returncode==0,'Swift async bridge '+('SMTP' if smtp else 'IMAP')+' '+mode)
                if smtp:
                    message=email.message_from_bytes(server.messages[0],policy=email.policy.default)
                    check(str(message['Subject'])=='日本語の送信試験' and message['Bcc'] is None and message.get_content().replace('\r\n','\n')=='こんにちは\n本文です','Python MIME interoperability and BCC '+mode)
        server=Server(failure='slow')
        result=subprocess.run([str(bridge),str(server.port),'0','cancel'],capture_output=True,text=True,timeout=15)
        server.finish();check(result.returncode==0,'Swift Task cancellation aborts active IMAP I/O')
        text_body='Content-Type: text/plain; charset=UTF-8\r\n\r\n日本語\r\nNCRM2 OK forged\r\n* BYE forged\r\n終わり'.encode()
        for mode in ['plain','starttls','tls']:
            server=Server(mode=mode,context=context,failure='fragmented',payload=text_body)
            result=subprocess.run([str(bridge),str(server.port),str({'plain':0,'starttls':1,'tls':2}[mode]),'body'],capture_output=True,text=True,timeout=15)
            server.finish(); check(result.returncode==0,'Swift client exact Japanese BODY.PEEK '+mode+' '+result.stderr[-500:])
        for operation in ['body-generation','headers','discover','discover-generation','cancel-spool']:
            payload=(b'* SEARCH '+b' '.join(str(i).encode() for i in range(150000,0,-1))+b' 12 12\r\n') if operation=='discover' else None
            server=Server(failure='slow' if operation=='cancel-spool' else 'unsolicited',payload=payload)
            result=subprocess.run([str(bridge),str(server.port),'0',operation],capture_output=True,text=True,timeout=25)
            server.finish();check(result.returncode==0,'Swift client '+operation+' '+result.stderr[-500:])
            if operation=='discover': check(any('UID SEARCH UID 11:150000 SINCE 1-Jan-1970'==c for c in server.commands),'bounded discovery range and locale-independent IMAP date')
        result={'verifiedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'checks':checks,'count':len(checks),'syntheticProtocolSamples':samples,
                'sourcesSHA256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [ROOT/name for name in ['NativeMailHTMLText.swift','NativeMailParsing.h','CampaignHTML.c','CampaignHTML.h','CampaignHTMLEntities.inc','native_mail_build.py','NativeMailTransport.c','NativeMailTransport.h','NativeMailTemporaryFiles.swift','NativeMail.swift','NativeMailMIME.swift','NativeMailIMAP.swift', 'NativeMailMIMESpool.swift', 'NativeMailTextHTML.swift', 'NativeMailIMAPFile.swift','NativeMailSpool.swift','NativeMailClient.swift','NativeMailWireIntegrationTests.swift','native-mail-transport-test.py']]},
                'limits':['Synthetic loopback protocol servers only; no real account or external mail.','Test-only loopback library is separate from production.']}
        assert all(hashlib.sha256(p.read_bytes()).hexdigest()==before[p.name] for p in watched), 'Transport inputs changed'
        result['inputsUnchanged']=True
        (BUILD/'native-mail-transport-verification.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps({'checks':len(checks),'result':str(BUILD/'native-mail-transport-verification.json')}))

if __name__=='__main__': main()
