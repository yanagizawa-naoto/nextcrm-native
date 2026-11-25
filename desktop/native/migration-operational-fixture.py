#!/usr/bin/env python3
import ast,base64,json,pathlib,re,struct,uuid,hashlib,zlib,sys
NATIVE=pathlib.Path(__file__).resolve().parent;ROOT=NATIVE.parents[1];OUT=pathlib.Path(sys.argv[1]);OUT.mkdir(exist_ok=True)
SCHEMA=json.loads((NATIVE/'schema.json').read_text());MODELS={m['name']:m for m in SCHEMA['models']}
module=ast.parse((NATIVE/'migration-import-test.py').read_text());exec(compile(ast.Module(body=[x for x in module.body if isinstance(x,(ast.FunctionDef,ast.AsyncFunctionDef))],type_ignores=[]),'existing-fixture-functions','exec'))
data=rows();ID=lambda x:str(uuid.uuid5(uuid.NAMESPACE_URL,'operational-fixture/'+x))
for m in SCHEMA['models']:
 for f in m['fields']:
  if f['type'].startswith('Unsupported("tsvector'):data[m['name']][0][f['name']]="'keyword':1"
u=data['Users'][0];u.update(role='admin',userStatus='ACTIVE',banned=False,name='移行管理者',avatar='avatars/profile.png',image=None,password='SYNTHETIC-SECRET-NOT-EXPORTED')
account=data['crm_Accounts'][0];account.update(name='移行会社',annual_revenue='12345678901234.56')
doc=data['Documents'][0];doc.update(key='documents/current.txt',document_file_url='documents/current.txt',thumbnail_url=None,document_name='現行の文書',parent_document_id=None,version='3',content_text='旧サーバーの抽出本文',processing_status='COMPLETED',deletedAt=None)
# Enum comes from current source schema (READY if applicable).
doc['processing_status']='COMPLETED' if 'COMPLETED' in SCHEMA['enums']['DocumentProcessingStatus'] else SCHEMA['enums']['DocumentProcessingStatus'][-1]
for i in [1,2]:
 d=dict(doc);d.update(id=ID('doc'+str(i)),key='documents/version'+str(i)+'.txt',document_file_url='documents/version'+str(i)+'.txt',document_name='過去の文書'+str(i),version=str(i),parent_document_id=doc['id']);data['Documents'].append(d)
for label,role in [('reader','user'),('other','user'),('manager','manager'),('partner','partner')]:
 user=dict(u);user.update(id=ID(label),email=label+'@example.invalid',name=label,role=role,avatar=None,image=None,password=None,partnerAccountId=None);data['Users'].append(user)
data['Users'][1]['image']='avatars/profile.png'
child=data['Documents'][1];child.update(created_by_user=ID('reader'),createdBy=ID('reader'),assigned_user=ID('reader'),visibility='private')
grand=dict(child);grand.update(id=ID('grand'),parent_document_id=child['id'],key='documents/grand.txt',document_file_url='documents/grand.txt',document_name='入れ子の版',version='4');data['Documents'].append(grand)
account['partnerUserId']=ID('partner')
data['DocumentsToAccounts'].append({'document_id':grand['id'],'account_id':account['id']})
missing=dict(doc);missing.update(id=ID('missing'),key='documents/missing.bin',document_file_url='https://example.invalid/unfetched',document_name='未取得',parent_document_id=None);data['Documents'].append(missing)
doc['thumbnail_url']='avatars/profile.png'
inv=data['Invoices'][0];inv.update(pdfStorageKey='invoices/historical.pdf')
att=data['Invoice_Attachments'][0];att['storageKey']='invoices/attachment.pdf'
# Required auth columns are intentionally real source values but export holds them.
for model in ['Session','Account','Verification','systemServices']:
 for f in MODELS[model]['fields']:
  if f['name'] in ['token','accessToken','refreshToken','idToken','password','value','servicePassword']:data[model][0][f['name']]='SYNTHETIC-SECRET-NOT-EXPORTED-'+model
# Registered built-in plugin business settings are preserved separately from secrets.
data['InstalledPlugin'][0].update(id='account-protection',settings={'json':'{"protectionDays":30}'},secrets=base64.b64encode(bytes(32)).decode())
for label,settings in [('odoo-connector',{'url':'https://odoo.example.invalid','database':'fixture'}),('oxo-erp-connector',{'url':'https://oxo.example.invalid'}),('registry-ares',{})]:
 plugin=dict(data['InstalledPlugin'][0]);plugin.update(id=label,settings={'json':json.dumps(settings)},secrets=None);data['InstalledPlugin'].append(plugin)
data['systemServices'][0].update(name='resend_smtp',serviceKey='SYNTHETIC-SECRET-NOT-EXPORTED-resend')
for name in ['calendly_api_token','calendly_signing_key']:
 setting=dict(data['crm_SystemSettings'][0]);setting.update(key=name,value='SYNTHETIC-SECRET-NOT-EXPORTED-'+name);data['crm_SystemSettings'].append(setting)
session=dict(data['Session'][0]);session.update(id=ID('session2'),token='SYNTHETIC-SECRET-NOT-EXPORTED-session2');data['Session'].append(session)
for row in data['PluginData']:row['pluginId']='account-protection'
for row in data['PluginLog']:row['pluginId']='account-protection'
(OUT/'rows.json').write_text(json.dumps(data,ensure_ascii=False))
(OUT/'fixture-ids.json').write_text(json.dumps({'user':u['id'],'account':account['id'],'document':doc['id'],'versions':[ID('doc1'),ID('doc2')],'invoice':inv['id'],'attachment':att['id'],'missing':ID('missing'),'grand':ID('grand'),'reader':ID('reader'),'other':ID('other'),'manager':ID('manager'),'partner':ID('partner')}))
objects=OUT/'objects';objects.mkdir(exist_ok=True)
def chunk(k,v):return struct.pack('>I',len(v))+k+v+struct.pack('>I',zlib.crc32(k+v)&0xffffffff)
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',2,2,8,6,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+b'\xff\0\0\xff'*2)*2))+chunk(b'IEND',b'')
def pdf():
 objects=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>']
 stream=b'BT /F1 12 Tf 10 50 Td (Historical invoice) Tj ET';objects += [b'<< /Length '+str(len(stream)).encode()+b' >>\nstream\n'+stream+b'\nendstream',b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
 out=bytearray(b'%PDF-1.4\n');offsets=[0]
 for i,body in enumerate(objects,1):offsets.append(len(out));out.extend(str(i).encode()+b' 0 obj\n'+body+b'\nendobj\n')
 xref=len(out);out.extend(b'xref\n0 6\n0000000000 65535 f \n')
 for offset in offsets[1:]:out.extend(f'{offset:010d} 00000 n \n'.encode())
 out.extend(b'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n'+str(xref).encode()+b'\n%%EOF\n');return bytes(out)
items={'avatars/profile.png':png,'documents/current.txt':'現行'.encode(),'documents/grand.txt':'入れ子の版'.encode(),'documents/version1.txt':'第一版'.encode(),'documents/version2.txt':'第二版'.encode(),'invoices/historical.pdf':pdf(),'invoices/attachment.pdf':b'%PDF-1.4\n%attachment exact bytes\n%%EOF\n','unknown/orphan.bin':b'unknown-owned-object'}
with (OUT/'objects.ndjson').open('w') as out:
 for key,blob in items.items():
  p=objects/key;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(blob);out.write(json.dumps({'storageKey':key,'path':key,'bytes':len(blob),'sha256':hashlib.sha256(blob).hexdigest()})+'\n')
print(json.dumps({'models':len(data),'rows':sum(map(len,data.values())),'objects':len(items)}))
