#!/usr/bin/env python3
"""Exercise the actual native report window with an isolated synthetic DB."""
from pathlib import Path
import hashlib, json, re, subprocess
native = Path(__file__).resolve().parent
sources = re.findall(r'"\$native_dir/([^"\n]+\.swift)"', (native / 'reports-test.sh').read_text())
sources = [s for s in sources if s != 'NativeReportsTests.swift']
sources += ['NativeReportPresentation.swift', 'NativeReportExport.swift', 'NativeReportExportDialog.swift', 'LightweightTable.swift', 'NativeReportConfigurationsWindow.swift', 'NativeReportSchedulesWindow.swift', 'MailReview.swift', 'InvoiceJobRunner.swift', 'NativeReportsWindow.swift', 'NativeReportsUITests.swift']
before = {s: hashlib.sha256((native / s).read_bytes()).hexdigest() for s in sources}
output = native / 'build/NativeReportsUITests'
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-framework', 'AppKit', '-framework', 'CoreText', '-framework', 'CoreGraphics', '-lsqlite3', *[str(native / s) for s in sources], '-o', str(output)], check=True)
result = subprocess.run([str(output), str(native)], capture_output=True, text=True)
print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
assert before == {s: hashlib.sha256((native / s).read_bytes()).hexdigest() for s in sources}
(native / 'build/reports-ui-verification.json').write_text(json.dumps({'sources':before, 'stdout':result.stdout, 'exit':result.returncode}, ensure_ascii=False, indent=2))
