#!/usr/bin/env python3
# Run the existing project suites, adding whole-module optimization only to
# avoid reparsing the same shared Swift sources for every primary file.
from pathlib import Path
import subprocess,json,hashlib,os,re,tempfile
from concurrent.futures import ThreadPoolExecutor
n=Path(__file__).resolve().parent
suites=['contact-enrichment','target-enrichment','contact-enrichment-ui','target-enrichment-ui','enrichment-provider','e2b']
watched=set()
for suite in suites:
 script=n/(suite+'-test.sh');watched.add(script)
 names=re.search(r'sources=\(([^)]+)\)',script.read_text())[1].split()
 watched.update(n/(name+'.swift') for name in names)
watched.update([n/'schema.json',n/'schema.sql',Path(__file__).resolve()])
before={str(p.relative_to(n)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(watched)}
compiler=subprocess.check_output(['xcrun','--find','swiftc'],text=True).strip()
sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
with tempfile.TemporaryDirectory(prefix='NextCRM-EnrichmentCompiler-') as temporary:
 wrapper=Path(temporary)/'swiftc'
 wrapper.write_text('#!/usr/bin/env python3\nimport os,sys\nos.execv('+repr(compiler)+',['+repr(compiler)+',*sys.argv[1:],"-whole-module-optimization","-sdk",'+repr(sdk)+'])\n')
 wrapper.chmod(0o700)
 environment=dict(os.environ,PATH=temporary+os.pathsep+os.environ['PATH'])
 def run(suite):
  result=subprocess.run(['zsh',str(n/(suite+'-test.sh'))],capture_output=True,text=True,env=environment,timeout=900)
  value={'suite':suite,'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr[:12000]}
  print(json.dumps(value,ensure_ascii=False),flush=True)
  return value
 with ThreadPoolExecutor(max_workers=2) as pool: results=list(pool.map(run,suites))
after={str(p.relative_to(n)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(watched)}
proof={'sources':before,'unchanged':before==after,'compiler':compiler,'additionalCompilerFlags':['-whole-module-optimization','-sdk',sdk],'results':results,'exit':0 if before==after and all(r['exit']==0 for r in results) else 1}
(n/'build/mcp-enrichment-regression-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
raise SystemExit(proof['exit'])
