#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,re,subprocess
native=Path(__file__).resolve().parent
sources=[s for s in re.findall(r'"\$native_dir/([^"\n]+\.swift)"',(native/'reports-test.sh').read_text()) if not s.endswith('Tests.swift')]
sources+=['NativeReportMailBody.swift','NativeReportMailBodyTests.swift','NativeReportQueueTests.swift']
before={s:hashlib.sha256((native/s).read_bytes()).hexdigest() for s in sources}
binary=native/'build/NativeReportQueueTests'
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-lsqlite3',*[str(native/s) for s in sources],'-o',str(binary)],check=True)
result=subprocess.run([str(binary),str(native)],capture_output=True,text=True)
print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
assert before=={s:hashlib.sha256((native/s).read_bytes()).hexdigest() for s in sources}
(native/'build/report-queue-verification.json').write_text(json.dumps({'sources':before,'stdout':result.stdout,'exit':result.returncode},ensure_ascii=False,indent=2))
