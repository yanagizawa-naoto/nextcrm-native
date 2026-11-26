#!/usr/bin/env python3
"""Google mail: isolated SQLite and fake HTTP/secret store; never a real login."""
from pathlib import Path
import hashlib,json,re,subprocess,sys,time
from native_mail_build import html_object
N=Path(__file__).resolve().parent
O=N/'build'/'google-mail-test';O.mkdir(parents=True,exist_ok=True)
sources=[]
for script in ['crm-email-test.sh','google-calendar-auth-test.sh']:
 for name in re.findall(r'\$native_dir/([^"/\s]+\.swift)',(N/script).read_text()):
  if name.endswith('Tests.swift'):continue
  if name not in sources:sources.append(name)
sources += ['NativeDistributionConfiguration.swift','GoogleMailOAuth.swift','GoogleMailAccounts.swift','NativeMailSyncTests.swift','NativeMailContentTests.swift','NativeMailSendTests.swift','NativeMailRuntimeTests.swift','GoogleMailTests.swift']
(O/'MailFixture.swift').write_text((N/'CRMEmailTests.swift').read_text().split('@main enum CRMEmailTests {',1)[0])
inputs=sources+['CRMEmailTests.swift']+['NativeMailTransport.c','NativeMailTransport.h','CampaignHTML.c','CampaignHTML.h','CampaignHTMLEntities.inc','NativeMailParsing.h','google-mail-test.py']
hashes={name:hashlib.sha256((N/name).read_bytes()).hexdigest() for name in inputs}
subprocess.run(['xcrun','clang','-std=c11','-O2','-Wall','-Wextra','-Werror','-c',str(N/'NativeMailTransport.c'),'-o',str(O/'mail.o')],check=True)
html_object(N,O/'html.o')
cmd=['swiftc','-swift-version','5','-parse-as-library','-whole-module-optimization','-Onone','-framework','Security','-framework','LocalAuthentication','-framework','Network','-lsqlite3','-lcurl','-lxml2','-import-objc-header',str(N/'NativeMailParsing.h'),str(O/'mail.o'),str(O/'html.o'),*[str(N/x) for x in sources],str(O/'MailFixture.swift'),'-o',str(O/'Tests')]
start=time.time();compile=subprocess.run(cmd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);(O/'compile.log').write_text(compile.stdout)
if compile.returncode:print(compile.stdout[-12000:]);sys.exit(compile.returncode)
run=subprocess.run([str(O/'Tests'),str(N)],capture_output=True,text=True,timeout=120)
(O/'test.log').write_text(run.stdout+run.stderr)
proof={'inputsSHA256':hashes,'unchanged':all(hashlib.sha256((N/x).read_bytes()).hexdigest()==h for x,h in hashes.items()),'compileExit':compile.returncode,'exit':run.returncode,'seconds':time.time()-start,'output':run.stdout+run.stderr,'network':'fake closures only; no real Google/Keychain','sources':sources}
(O/'verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');print(run.stdout+run.stderr);assert proof['unchanged'];sys.exit(run.returncode)
