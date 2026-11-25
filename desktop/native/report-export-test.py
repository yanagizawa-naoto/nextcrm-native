#!/usr/bin/env python3
from pathlib import Path
import csv, hashlib, json, re, subprocess
native=Path(__file__).resolve().parent
subprocess.run(['node',str(native/'report-export-reference.cjs')],check=True)
sources=re.findall(r'"\$native_dir/([^"\n]+\.swift)"',(native/'reports-test.sh').read_text())
sources=[s for s in sources if s not in ['NativeReportsTests.swift','NativeReportConfigurationTests.swift']]
sources+=['NativeReportPresentation.swift','NativeReportExport.swift','NativeReportExportTests.swift']
before={s:hashlib.sha256((native/s).read_bytes()).hexdigest() for s in sources}
executable=native/'build/NativeReportExportTests'
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-framework','CoreText','-framework','CoreGraphics','-framework','PDFKit','-lsqlite3',*[str(native/s) for s in sources],'-o',str(executable)],check=True)
result=subprocess.run([str(executable),str(native)],capture_output=True,text=True)
print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
reference=json.loads((native/'build/report-export-reference.json').read_text())
with (native/'../artifacts/native-reports-export/代表レポート.csv').open(encoding='utf-8-sig',newline='') as stream:
    rows=list(csv.reader(stream))
assert rows[0]==reference['headers']
assert rows[1:]==[[r['name'],str(r['Number'])] for r in reference['rows']]
assert before=={s:hashlib.sha256((native/s).read_bytes()).hexdigest() for s in sources}
(native/'build/report-export-verification.json').write_text(json.dumps({'sources':before,'originalSources':reference['hashes'],'CSVRows':len(rows)-1,'stdout':result.stdout,'exit':result.returncode},ensure_ascii=False,indent=2))
