#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,re,subprocess
native=Path(__file__).resolve().parent
sources=[]
for script in ['reports-test.sh','invoice-mail-test.sh']:
    for source in re.findall(r'"\$native_dir/([^"\n]+\.swift)"',(native/script).read_text()):
        if not source.endswith('Tests.swift') and source not in sources:sources.append(source)
sources+=['NativeReportPresentation.swift','NativeReportExport.swift','NativeReportMailBody.swift','NativeReportMail.swift','NativeReportMailTests.swift']
sources=list(dict.fromkeys(sources+['NativeMailPreparationFiles.swift','NativeTerminalMailBodyRecovery.swift']))
before={s:hashlib.sha256((native/s).read_bytes()).hexdigest() for s in sources}
binary=native/'build/NativeReportMailTests'
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-framework','Security','-framework','CoreText','-framework','CoreGraphics','-framework','PDFKit','-lsqlite3',*[str(native/s) for s in sources],'-o',str(binary)],check=True)
result=subprocess.run([str(binary),str(native)],capture_output=True,text=True)
print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
assert before=={s:hashlib.sha256((native/s).read_bytes()).hexdigest() for s in sources}
(native/'build/report-mail-verification.json').write_text(json.dumps({'sources':before,'stdout':result.stdout,'exit':result.returncode},ensure_ascii=False,indent=2))
