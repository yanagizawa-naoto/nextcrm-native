from pathlib import Path
import csv,hashlib,json,re,subprocess,os,time
n=Path(__file__).resolve().parent;c=n/'build/report-category-scale';c.mkdir(parents=True,exist_ok=True)
names=[x for x in re.findall(r'"\$native_dir/([^"\n]+\.swift)"',(n/'reports-test.sh').read_text()) if not x.endswith('Tests.swift')]
names+=['NativeReportPresentation.swift','NativeReportExport.swift']
sources=[n/x for x in names]+[n/'NativeReportCategoryScaleTests.swift']
inputs=sources+[n/'schema.json',n/'schema.sql',n/'reports-test.sh',Path(__file__)]
h=lambda:{os.path.relpath(p,n):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
before=h();start=time.time()
p=subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-whole-module-optimization','-O','-framework','CoreText','-framework','CoreGraphics','-framework','PDFKit','-lsqlite3',*map(str,sources),'-o',str(c/'Tests')],text=True,capture_output=True);(c/'compile.log').write_text(p.stdout+p.stderr)
if p.returncode:print(p.stderr[-5000:]);p.check_returncode()
output=c/'artifacts';r=subprocess.run([str(c/'Tests'),str(n),str(output)],env={**os.environ,'TZ':'UTC'},text=True,capture_output=True);(c/'test.log').write_text(r.stdout+r.stderr)
proof={'compileExit':p.returncode,'exit':r.returncode,'seconds':round(time.time()-start,2),'sourcesSHA256':before,'sourceStable':before==h(),'stdout':r.stdout,'stderr':r.stderr,'sourceCount':len(sources),'binarySHA256':hashlib.sha256((c/'Tests').read_bytes()).hexdigest()}
if r.returncode==0:
 data=json.loads((output/'result.json').read_text());csvChecks=0
 for e in data['exports']:
  with (output/e['csv']).open(encoding='utf-8-sig',newline='') as actual,(output/e['expected']).open(encoding='utf-8') as expected:
   reader=csv.reader(actual);assert next(reader)==e['headers'];csvChecks+=1
   count=0
   for line in expected:
    assert next(reader)==json.loads(line),(e['section'],count);count+=1;csvChecks+=1
   assert next(reader,None) is None and count==e['rows'];csvChecks+=1
 proof['nativeChecks']=data['checks'];proof['streamingCSVChecks']=csvChecks
(c/'verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');print(json.dumps({k:v for k,v in proof.items() if k not in ['sourcesSHA256','stderr']},ensure_ascii=False));print(r.stderr[-3500:] if r.returncode else '');r.check_returncode();assert proof['sourceStable']
