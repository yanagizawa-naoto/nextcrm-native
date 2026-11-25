from pathlib import Path
import re,subprocess,hashlib,json,os
n=Path(__file__).resolve().parent;c=n/'build/invoice-pdf-transaction-test';c.mkdir(exist_ok=True)
regression=(n/'InvoicePDFTests.swift').read_text();assert regression.count('@main enum InvoicePDFTests')==1
(c/'InvoicePDFRegression.actual.swift').write_text(regression.replace('@main enum InvoicePDFTests','enum InvoicePDFTests',1))
sources=[n/x for x in re.findall(r'\$native_dir/([^" ]+\.swift)',(n/'invoice-pdf-test.sh').read_text()) if x!='InvoicePDFTests.swift']+[n/'InvoicePDFTransactionTests.swift',c/'InvoicePDFRegression.actual.swift']
inputs=sources+[n/'schema.json',n/'schema.sql',n/'InvoicePDFTests.swift',n/'invoice-pdf-test.sh',Path(__file__)]
h=lambda:{os.path.relpath(x,n):hashlib.sha256(x.read_bytes()).hexdigest() for x in inputs}
before=h();compile=subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-whole-module-optimization','-O','-framework','CoreText','-framework','CoreGraphics','-framework','PDFKit','-lsqlite3',*map(str,sources),'-o',str(c/'Tests')],capture_output=True,text=True);(c/'compile.log').write_text(compile.stdout+compile.stderr)
if compile.returncode:print(compile.stderr[-2500:]);compile.check_returncode()
r=subprocess.run([str(c/'Tests'),str(n),str(c/'regression.pdf')],capture_output=True,text=True);(c/'verification.json').write_text(json.dumps({'exit':r.returncode,'compileExit':compile.returncode,'sourceHashes':before,'stable':before==h(),'stdout':r.stdout,'stderr':r.stderr,'binarySHA256':hashlib.sha256((c/'Tests').read_bytes()).hexdigest()},indent=2)+'\n');print(r.stdout+r.stderr);r.check_returncode();assert before==h()
