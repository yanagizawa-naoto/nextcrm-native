#!/usr/bin/env python3
"""Production incoming IDN/CRM checks with an actual original TS oracle.

All native production files are compiled directly. A generated copy of the
existing CRMEmailTests adds only two new test calls (and an explicit IDN-only
option) before its unchanged assertions. All objects/binaries are private to
this runner. No shared build object, Keychain, provider or regular data is used.
"""
from pathlib import Path
from native_mail_build import html_inputs, html_object
import argparse
import hashlib
import json
import re
import subprocess
import time

N = Path(__file__).resolve().parent
ROOT = N.parent.parent
B = N / 'build/mail-idn'
B.mkdir(exist_ok=True)
parser = argparse.ArgumentParser()
parser.add_argument('--idn-only', action='store_true', help='Skip regressions already run by the parent suite.')
args = parser.parse_args()
proof_path = N / ('build/mail-idn-only-verification.json' if args.idn_only else 'build/mail-idn-verification.json')
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
source_main = (N / 'CRMEmailTests.swift').read_text()
old = 'try run(); let resources = URL(fileURLWithPath:CommandLine.arguments[1])'
new = '''let resources = URL(fileURLWithPath:CommandLine.arguments[1])
            let reference = URL(fileURLWithPath:CommandLine.arguments[2])
            try NativeMailIDNParseTests.run(reference:reference)
            try NativeMailIDNCRMTests.run(resources:resources,reference:reference)
            if CommandLine.arguments.contains("--idn-only") { return }
            try run()'''
assert source_main.count(old) == 1, 'Existing test entry changed; review injection before use'
generated = B / 'CRMEmailTests.swift'
generated.write_text(source_main.replace(old, new))
names = re.findall(r'\$native_dir/([^"\s]+\.swift)', (N / 'crm-email-test.sh').read_text())
assert names and len(names) == len(set(names))
sources = [generated if name == 'CRMEmailTests.swift' else N / name for name in names]
watch = list(dict.fromkeys(sources + [N / name for name in [
    'CRMEmailTests.swift', 'crm-email-test.sh', 'NativeMailIDNTests.swift', 'mail-idn-reference.cjs',
    'mail-idn-test.py', 'NativeMailTransport.c', 'NativeMailTransport.h', 'schema.json', 'schema.sql']] +
    ([] if args.idn_only else [N / name for name in ['NativeMailTests.swift',
        'build/native-mail-transport-verification.json', 'build/native-mail-address-reference.json']])))
watch += html_inputs(N)
hashes = {str(p.relative_to(N)): sha(p) for p in watch}
proof = {'productionSourcesDirect': True, 'idnOnly': args.idn_only, 'inputsSHA256': hashes,
         'testEntryInjection': {'source': 'CRMEmailTests.swift', 'originalSHA256': sha(N / 'CRMEmailTests.swift'),
             'generatedSHA256': sha(generated), 'replacementCount': 1,
             'originalAssertionsUnchanged': True, 'oldText': old, 'newText': new},
         'phases': [], 'complete': False, 'externalRequests': 0, 'normalDataKeychain': False,
         'limitations': [
             'Only tested valid IDNA A-labels; not all malformed Punycode/IDNA equivalence with upstream.',
             'Already persisted native A-label emails are not rewritten or backfilled by the incoming-parser change.',
             'Original TS matching uses an explicit exact-string Prisma adapter, not PostgreSQL. Native existing scoped/case-insensitive policy is retained.',
             'Hidden-record and BCC assertions supplement the native fixture; no source authorization parity claim.',
             'Existing MIME regression reads recorded synthetic wire/address fixtures; no fresh transport or live provider run.',
             'No full-app UI or long-run/peak memory claim; large recipient metadata remains outside this slice.'
         ]}
start = time.monotonic()

def run(name, command):
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    (B / (name + '.log')).write_text(result.stdout + result.stderr)
    proof['phases'].append({'name': name, 'exit': result.returncode})
    if result.returncode != 0:
        raise RuntimeError(name + ' failed; see ' + str(B / (name + '.log')))
    return result

try:
    oracle_path = B / 'source-reference.json'
    run('oracle', ['node', str(N / 'mail-idn-reference.cjs'), str(oracle_path)])
    oracle = json.loads(oracle_path.read_text())
    proof['oracle'] = {'cases': len(oracle['cases']), 'sourceSHA256': oracle['sourceHashes'],
        'sha256': sha(oracle_path), 'scope': oracle['scope'], 'path': str(oracle_path.relative_to(N))}
    obj = B / 'NativeMailTransport.o'
    run('c-object', ['clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-c',
        str(N / 'NativeMailTransport.c'), '-o', str(obj)])
    html = html_object(N, B / 'CampaignHTML.o', run)
    flags = ['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-whole-module-optimization',
        '-lsqlite3', '-lcurl', '-framework', 'Security', '-framework', 'LocalAuthentication',
        '-lxml2', '-import-objc-header', str(N / 'NativeMailParsing.h'), str(obj), str(html)]
    crm_binary = B / 'NativeMailIDNCRMTests'
    run('crm-compile', flags + [str(p) for p in sources] + [str(N / 'NativeMailIDNTests.swift'), '-o', str(crm_binary)])
    result = run('crm', [str(crm_binary), str(N), str(oracle_path)] + (['--idn-only'] if args.idn_only else []))
    rows = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
    assert len(rows) == 2 and all(row['differenceCount'] == 0 for row in rows)
    proof['parse'], proof['sqlite'] = rows
    proof['crmOutput'] = result.stdout.strip()
    proof['existingCRMChecks'] = sum(int(x) for x in re.findall(r': (\d+) checks passed', result.stdout))
    proof['checks'] = sum(row['checks'] for row in rows) + proof['existingCRMChecks']
    binaries = [crm_binary]
    if not args.idn_only:
        mime_names = ['NativeMailHTMLText.swift', 'NativeMailTemporaryFiles.swift', 'NativeMail.swift', 'NativeMailMIME.swift', 'NativeMailIMAP.swift', 'NativeMailMIMESpool.swift', 'NativeMailTextHTML.swift', 'NativeMailIMAPFile.swift',
                      'NativeMailSpool.swift', 'NativeMailClient.swift', 'NativeMailTests.swift']
        binary = B / 'NativeMailTests'
        run('mime-compile', flags + [str(N / name) for name in mime_names] + ['-o', str(binary)])
        result = run('mime', [str(binary), str(N)])
        match = re.search(r'NativeMailTests: (\d+) checks passed', result.stdout)
        assert match, 'Missing MIME regression count'
        proof['existingMIMEChecks'] = int(match.group(1))
        proof['checks'] += proof['existingMIMEChecks']
        proof['mimeOutput'] = result.stdout.strip()
        binaries.append(binary)
    proof['binarySHA256'] = {binary.name: sha(binary) for binary in binaries}
    proof['inputsUnchanged'] = all(sha(N / key) == value for key, value in hashes.items())
    proof['oracleSourcesUnchanged'] = all(sha(Path(key)) == value for key, value in oracle['sourceHashes'].items())
    assert proof['inputsUnchanged'] and proof['oracleSourcesUnchanged'], 'Input changed during verification'
    proof['complete'] = True
finally:
    proof['elapsedSeconds'] = round(time.monotonic() - start, 2)
    proof['ownedArtifactBytes'] = sum(f.stat().st_size for f in B.rglob('*') if f.is_file())
    proof_path.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'complete': proof['complete'], 'checks': proof['checks'],
    'sourceCases': proof['oracle']['cases'], 'parse': proof['parse']['checks'],
    'sqlite': proof['sqlite']['checks'], 'inputsUnchanged': proof['inputsUnchanged'],
    'proof': str(proof_path.relative_to(N)), 'ownedArtifactBytes': proof['ownedArtifactBytes']}))
