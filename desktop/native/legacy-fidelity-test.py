#!/usr/bin/env python3
"""Actual source save/page -> generic import -> report/mail/CSV fidelity.

Compiles current production sources directly. Existing 2,140 report regression
checks run separately in test.sh; historical baseline failures remain candidate
proofs and are not replayed here. No C objects or shared runner outputs are used.
"""
import hashlib, json, os, pathlib, re, shutil, subprocess, tempfile, time
NATIVE=pathlib.Path(__file__).resolve().parent; ROOT=NATIVE.parents[1]
BUILD=NATIVE/'build/legacy-fidelity'; BUILD.mkdir(parents=True,exist_ok=True)
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def dump(path,value):path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
helpers=NATIVE/'migration-import-test.py'
# Reuse only the existing pure schema/fixture helpers, never its executable
# suite, which would write to other runners' output paths.
marker='cases=[];expected={};source_records={};checks=0'
assert helpers.read_text().count(marker)==1
prefix=helpers.read_text().split(marker,1)[0]
assert 'subprocess.run(' not in prefix
ns={'__file__':str(helpers)};exec(compile(prefix,str(helpers),'exec'),ns)
MODELS=ns['MODELS'];SCHEMA=ns['SCHEMA'];data=ns['data'];digest=ns['digest']
source_names=[name for name in re.findall(r'"\$native_dir/([^"\n]+\.swift)"',(NATIVE/'reports-test.sh').read_text()) if not name.endswith('Tests.swift')]
source_names += [x+'.swift' for x in ['NativeReportPresentation','NativeReportExport','NativeReportMailBody','NativeReportMail','InvoiceMailCredentials','InvoiceWorkflow','InvoiceDraftStore','CRMInvoices','CRMInvoiceSettings','InvoiceFXClient']]
source_names += [p.name for p in ns['SOURCES'] if p.name!='NativeMigrationImportTests.swift']
source_names += ['NativeLegacyFidelityTests.swift']
source_names=list(dict.fromkeys(source_names));sources=[NATIVE/name for name in source_names]
tracked=sources+[helpers,NATIVE/'reports-test.sh',NATIVE/'schema.json',NATIVE/'schema.sql',ROOT/'prisma/schema.prisma',NATIVE/'legacy-fidelity-reference.cjs',pathlib.Path(__file__).resolve()]
before={str(p.relative_to(ROOT)):sha(p) for p in tracked}
started=time.time();proof={'complete':False,'sourceHashes':before,'directProductionInputs':True,'schemaModels':len(MODELS),'schemaFields':sum(len(m['fields']) for m in MODELS.values()),'externalRequests':0,'realKeychain':False,'normalData':False,'existingReportsRegressionRepeated':False,'limits':['Actual source oracle uses synthetic Prisma and no display_currency cookie.','Invoice scalar/JSON fixture is synthetic; original issuance/PDF code is inspected, not fully executed.','Source schedule has no timezone field/history table; explicit native timezone confirmation remains.','Lowercase original currency acceptance differs from existing native uppercase validation.','No live PostgreSQL snapshot authenticity, credential migration or full app activation is claimed.']}
reference_path=BUILD/'reference.json'
oracle=subprocess.run(['node',str(NATIVE/'legacy-fidelity-reference.cjs'),str(reference_path)],capture_output=True,text=True)
(BUILD/'oracle.log').write_text(oracle.stdout+oracle.stderr);oracle.check_returncode()
reference=json.loads(reference_path.read_text());actor=reference['cases'][0]['saved']['createdBy']
proof.update(oracle=reference,oracleSummary=oracle.stdout.strip())
resources=BUILD/'resources';resources.mkdir(exist_ok=True)
for filename in ['schema.json','schema.sql']:shutil.copy2(NATIVE/filename,resources/filename)
def records_for(item):
 records=ns['rows']();old=records['Users'][0]['id']
 def replace(value):
  if isinstance(value,dict):return {k:replace(v) for k,v in value.items()}
  if isinstance(value,list):return [replace(v) for v in value]
  return actor if value==old else value
 records=replace(records)
 records['Users'][0].update(role='admin',userStatus='ACTIVE',banned=False)
 base=records['Currency'][0];base.update(code='JPY',name='JPY',symbol='JPY')
 records['Currency'] += [{**base,'code':code,'name':code,'symbol':code} for code in ['USD','CZK']]
 setting=records['crm_SystemSettings'][0]
 records['crm_SystemSettings']=[] if item['defaultCurrency'] is None else [{**setting,'key':'default_currency','value':item['defaultCurrency']}]
 config=records['crm_Report_Config'][0];config.update(item['saved']);config['filters']={'json':json.dumps(item['saved']['filters'],ensure_ascii=False,separators=(',',':'))}
 schedule=records['crm_Report_Schedule'][0]
 schedule.update(reportConfigId=config['id'],cronExpression='0 9 * * *',recipients={'json':'["recipient@example.test"]'},format='csv',isActive=True,lastSentAt='2024-02-20T09:00:00.123456Z')
 invoice=records['Invoices'][0];invoice.update(status='ISSUED',currency='USD',baseCurrency='CZK',fxRateToBase='22.12345678',subtotal='100.00',discountTotal='0.00',vatTotal='8.25',grandTotal='108.25',paidTotal='0.00',balanceDue='108.25',issueDate='2024-02-20T09:00:00.123456Z',number='INV-HISTORIC-42',billingSnapshot={'json':'{"name":"当時の名称","address":"東京","nested":{"preserve":[1,null,"古い"]}}'})
 line=records['Invoice_LineItems'][0];line.update(taxRateSnapshot='8.25',quantity='1.0000',unitPrice='100.0000',discountPercent='0.00',lineSubtotal='100.00',lineVat='8.25',lineTotal='108.25')
 records['Invoice_TaxRates'][0]['rate']='20.00'
 opportunity=records['crm_Opportunities'][0];opportunity.update(budget='10.00',currency='USD',status='CLOSED',created_on='2024-02-15T00:00:00Z',close_date='2024-02-20T00:00:00Z',deletedAt=None)
 rate=records['ExchangeRate'][0]
 records['ExchangeRate']=[{**rate,'id':ns['key']('rate-'+code),'fromCurrency':'USD','toCurrency':code,'rate':value,'source':'MANUAL'} for code,value in [('CZK','22.00000000'),('JPY','150.00000000')]]
 return records
def bundle(folder,records):
 folder.mkdir();(folder/'models').mkdir();(folder/'objects').mkdir()
 assets,secrets=ns['inventories'](records)
 def write(path,values):
  raw=b''.join(data(x) for x in values);(folder/path).write_bytes(raw);return {'path':path,'rows':len(values),'bytes':len(raw),'sha256':digest(raw)}
 manifest={'formatVersion':1,'schemaSHA256':SCHEMA['schemaSHA256'],'source':{'kind':'web-postgresql','snapshotID':'synthetic-legacy-source-actions','consistent':True,'completed':True},'models':[]}
 for model in MODELS:manifest['models'].append({'name':model,**write('models/'+model+'.ndjson',records[model])})
 for asset in assets:(folder/asset['path']).write_bytes(b'\x00\xffA')
 for kind,values in [('assets',assets),('secrets',secrets),('jobs',[])]:manifest[kind]=write(kind+'.ndjson',values)
 (folder/'manifest.json').write_bytes(data(manifest))
 return sha(folder/'manifest.json')
binary=BUILD/'NativeLegacyFidelityTests'
compile_command=['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-framework','Security','-framework','CoreText','-framework','CoreGraphics','-lsqlite3',*[str(p) for p in sources],'-o',str(binary)]
try:
 with (BUILD/'compile.log').open('w') as out:
  compiled=subprocess.run(compile_command,stdout=out,stderr=subprocess.STDOUT,timeout=600)
 proof['compileExit']=compiled.returncode;compiled.check_returncode()
 proof['binarySHA256']=sha(binary)
 with tempfile.TemporaryDirectory(prefix='NextCRM-LegacyFidelity-') as td:
  base=pathlib.Path(td).resolve();(base/'inputs').mkdir();(base/'outputs').mkdir();cases=[];manifests={}
  for item in reference['cases']:
   records=records_for(item);folder=base/'inputs'/item['name'];manifests[item['name']]=bundle(folder,records)
   cases.append({'name':item['name'],'bundle':str(folder),'destination':str(base/'outputs'/item['name']),'actor':actor,'invoiceID':records['Invoices'][0]['id'],'lineID':records['Invoice_LineItems'][0]['id'],'scheduleID':records['crm_Report_Schedule'][0]['id'],'expectedCurrency':item['expected']['currency'],'expectedRevenue':item['expected']['revenue'],'filtersJSON':records['crm_Report_Config'][0]['filters']['json'],'billingJSON':records['Invoices'][0]['billingSnapshot']['json']})
  cases_path=base/'cases.json';dump(cases_path,cases)
  output=BUILD/'outcomes.json'
  environment={**os.environ,'TZ':'UTC'};environment.pop('NEXTCRM_NATIVE_DATA_DIR',None)
  result=subprocess.run([str(binary),str(resources),str(cases_path),str(output)],capture_output=True,text=True,env=environment,umask=0o077,timeout=300)
  (BUILD/'run.log').write_text(result.stdout+result.stderr)
  proof.update(exit=result.returncode,stdout=result.stdout,stderr=result.stderr[-2000:],manifests=manifests,temporaryFixtureBytes=sum(p.stat().st_size for p in base.rglob('*') if p.is_file()))
  if output.exists():
   outcomes=json.loads(output.read_text());proof.update(outcomes=outcomes,cases=len(outcomes),checks=sum(x['checks'] for x in outcomes),mismatches=sum(len(x['mismatches']) for x in outcomes))
  result.check_returncode()
  assert proof['cases']==5 and proof['checks']==224 and proof['mismatches']==0
 proof['temporaryFixturesRemoved']=True
 proof['sourceHashesStable']=before=={str(p.relative_to(ROOT)):sha(p) for p in tracked}
 proof['sourceOracleHashesStable']=all(sha(ROOT/name)==value for name,value in reference['sourceHashes'].items())
 assert proof['sourceHashesStable'] and proof['sourceOracleHashesStable'],'source changed during verification'
 proof['complete']=True
finally:
 proof['elapsedSeconds']=round(time.time()-started,3)
 proof['artifactBytesBeforeProof']=sum(p.stat().st_size for p in BUILD.rglob('*') if p.is_file())
 dump(BUILD/'verification.json',proof)
print(json.dumps({k:proof[k] for k in ['complete','cases','checks','mismatches','sourceHashesStable','sourceOracleHashesStable','temporaryFixturesRemoved']},ensure_ascii=False))
