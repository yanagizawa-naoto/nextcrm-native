#!/usr/bin/env python3
"""Compare a preserved native MIME source with current code, without downloads."""
import argparse
import hashlib
import json
import pathlib
from native_mail_build import html_inputs, html_object
import statistics
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--baseline', type=pathlib.Path, required=True)
args = parser.parse_args()
(ROOT / 'build').mkdir(exist_ok=True)
BUILD = pathlib.Path(tempfile.mkdtemp(prefix='native-mail-buffers-',dir=ROOT/'build'))
ARTIFACT = ROOT.parent / 'artifacts' / 'native-mail-buffers-memory.json'
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
tracked = [ROOT/name for name in ['NativeMailTransport.c','NativeMailTransport.h','NativeMailTemporaryFiles.swift','NativeMail.swift','NativeMailMIME.swift','NativeMailIMAP.swift', 'NativeMailMIMESpool.swift', 'NativeMailTextHTML.swift', 'NativeMailIMAPFile.swift','NativeMailSpool.swift','NativeMailClient.swift','NativeMailBufferBenchmark.swift','native-mail-buffers-benchmark.py']] + html_inputs(ROOT) + [args.baseline.resolve()]
before = {str(p):digest(p) for p in tracked}
subprocess.run(['clang','-std=c11','-O2','-c',str(ROOT/'NativeMailTransport.c'),'-o',str(BUILD/'NativeMailTransport.o')],check=True)
html = html_object(ROOT,BUILD/'CampaignHTML.o')
executables = {}
for name, source in [('before', args.baseline.resolve()), ('after', ROOT / 'NativeMailMIME.swift')]:
    executable = BUILD / ('NativeMailBufferBenchmark-' + name)
    command = ['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-lcurl', '-lsqlite3', '-lxml2', '-import-objc-header', str(ROOT / 'NativeMailParsing.h'), str(BUILD / 'NativeMailTransport.o'), str(html), str(ROOT / 'NativeMailHTMLText.swift'), str(ROOT / 'NativeMailTemporaryFiles.swift'), str(ROOT / 'NativeMail.swift'), str(source), str(ROOT / 'NativeMailIMAP.swift'), str(ROOT / 'NativeMailMIMESpool.swift'), str(ROOT / 'NativeMailTextHTML.swift'), str(ROOT / 'NativeMailIMAPFile.swift'), str(ROOT / 'NativeMailSpool.swift'), str(ROOT / 'NativeMailClient.swift'), str(ROOT / 'NativeMailBufferBenchmark.swift'), '-o', str(executable)]
    subprocess.run(command, check=True)
    executables[name] = {'path': str(executable), 'sha256': digest(executable), 'mimeSourceSHA256': digest(source)}
samples = []
for scenario in ['ascii', 'japanese', 'newlines']:
    for run in range(3):
        # Alternate order to reduce systematic warm-cache/order effects.
        for version in (['before', 'after'] if run % 2 == 0 else ['after', 'before']):
            result = subprocess.run([executables[version]['path'], scenario], capture_output=True, text=True, check=True, timeout=60)
            sample = json.loads(result.stdout)
            sample.update(version=version, run=run + 1)
            samples.append(sample)
summary = []
for scenario in ['ascii', 'japanese', 'newlines']:
    group = [sample for sample in samples if sample['scenario'] == scenario]
    assert len({sample['mimeSHA256'] for sample in group}) == 1, 'MIME bytes changed: ' + scenario
    medians = {version: statistics.median(sample['peakRSSBytes'] for sample in group if sample['version'] == version) for version in ['before', 'after']}
    summary.append({'scenario': scenario, 'bodyBytes': group[0]['bodyBytes'], 'mimeBytes': group[0]['mimeBytes'], 'identicalMIME': True, 'medianPeakRSSMiB': {k: round(v / 2**20, 3) for k, v in medians.items()}, 'peakRSSReductionPercent': round((1-medians['after']/medians['before'])*100, 1)})
report = {'metric': 'Darwin getrusage(RUSAGE_SELF).ru_maxrss in bytes; whole isolated benchmark process peak RSS', 'network': 'none', 'samples': samples, 'summary': summary, 'executables': executables, 'harnessSHA256': digest(ROOT / 'NativeMailBufferBenchmark.swift'), 'limitations': ['Synthetic MIME creation only, three process pairs per scenario; not whole CRM, physical footprint, long-run, receive-side MIME, or completed-app measurement.', 'Both versions retain the original input String and final MIME Data. The new implementation bounds temporary normalization/Base64 batches; existing8MiB normalized text cap remains.']}
assert all(digest(pathlib.Path(p))==h for p,h in before.items()), 'Benchmark inputs changed'
report['inputsSHA256']=before;report['inputsUnchanged']=True
ARTIFACT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'artifact': str(ARTIFACT), 'summary': summary}, ensure_ascii=False))
