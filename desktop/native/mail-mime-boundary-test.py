#!/usr/bin/env python3
"""Compare production MIME header decoding with installed mailparser/libmime.

Uses existing project-locked packages; no install/download or socket operations.
All C objects and executables are private to build/mail-mime-boundary. The Swift
compiler reads current production files directly, with input hashes checked
again after execution. --boundary-only avoids repeating NativeMailTests when
the parent suite already runs that existing regression.
"""
from pathlib import Path
from native_mail_build import html_inputs, html_object
import argparse
import hashlib
import json
import re
import subprocess
import time

NATIVE = Path(__file__).resolve().parent
ROOT = NATIVE.parent.parent
BUILD = NATIVE / 'build/mail-mime-boundary'
BUILD.mkdir(exist_ok=True)
parser = argparse.ArgumentParser()
parser.add_argument('--boundary-only', action='store_true')
args = parser.parse_args()
proof_path = NATIVE / ('build/mail-mime-boundary-only-verification.json' if args.boundary_only else 'build/mail-mime-boundary-verification.json')
hash_file = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
names = ['NativeMailHTMLText.swift', 'NativeMailTemporaryFiles.swift', 'NativeMail.swift', 'NativeMailMIME.swift', 'NativeMailIMAP.swift', 'NativeMailMIMESpool.swift', 'NativeMailTextHTML.swift', 'NativeMailIMAPFile.swift',
         'NativeMailSpool.swift', 'NativeMailClient.swift']
watched = [NATIVE / name for name in names + ['NativeMailTransport.c', 'NativeMailTransport.h',
    'NativeMailMIMEBoundaryTests.swift', 'mail-mime-boundary-reference.cjs', 'mail-mime-boundary-test.py']]
if not args.boundary_only:
    watched += [NATIVE / name for name in ['NativeMailTests.swift',
        'build/native-mail-transport-verification.json', 'build/native-mail-address-reference.json']]
watched += html_inputs(NATIVE)
inputs = {str(path.relative_to(NATIVE)): hash_file(path) for path in watched}
proof = {'scope': 'Current production MIME/IMAP code with installed upstream parser; no mail server calls.',
         'productionSourcesDirect': True, 'inputsSHA256': inputs, 'phases': [],
         'complete': False, 'boundaryOnly': args.boundary_only, 'networkRequests': 0,
         'downloads': False, 'normalDataAndKeychain': False,
         'limitations': [
             '53 cases cover adjacent independently valid B/Q transfer tokens and charset/encoding boundaries; not all malformed MIME recovery semantics.',
             'Existing 167-check NativeMailTests uses already recorded synthetic protocol/address fixtures; no new transport network suite is claimed.',
             'Header memory remains bounded by the existing 256KiB input cap. No whole-app memory or provider-fidelity claim.',
             'Compiler/link objects are local to this runner; shared production C objects and test.sh are unchanged.'
         ]}
start = time.monotonic()

def run(name, command):
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    (BUILD / (name + '.log')).write_text(result.stdout + result.stderr)
    proof['phases'].append({'name': name, 'exit': result.returncode})
    if result.returncode != 0:
        raise RuntimeError(name + ' failed; see ' + str(BUILD / (name + '.log')))
    return result

def compile_swift(name, source):
    command = ['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-whole-module-optimization',
               '-lcurl', '-lsqlite3', '-lxml2', '-import-objc-header', str(NATIVE / 'NativeMailParsing.h'),
               str(BUILD / 'NativeMailTransport.o'), str(BUILD / 'CampaignHTML.o')]
    command += [str(NATIVE / item) for item in names]
    command += [str(NATIVE / source), '-o', str(BUILD / name)]
    run(name + '-compile', command)

try:
    oracle_path = BUILD / 'source-reference.json'
    run('oracle', ['node', str(NATIVE / 'mail-mime-boundary-reference.cjs'), str(oracle_path)])
    oracle = json.loads(oracle_path.read_text())
    proof['oracle'] = {'cases': len(oracle['cases']), 'sha256': hash_file(oracle_path),
                       'sourceSHA256': oracle['sourceHashes'],
                       'path': str(oracle_path.relative_to(NATIVE)),
                       'authority': 'inngest/lib/imap-utils.ts uses mailparser.simpleParser; libmime.decodeWords joins compatible encoded words before charset conversion.'}
    run('c-object', ['clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-c',
        str(NATIVE / 'NativeMailTransport.c'), '-o', str(BUILD / 'NativeMailTransport.o')])
    html_object(NATIVE, BUILD / 'CampaignHTML.o', run)
    compile_swift('NativeMailMIMEBoundaryTests', 'NativeMailMIMEBoundaryTests.swift')
    result = run('boundary', [str(BUILD / 'NativeMailMIMEBoundaryTests'), str(oracle_path)])
    proof['boundary'] = json.loads(result.stdout)
    assert proof['boundary']['differenceCount'] == 0
    proof['checks'] = proof['boundary']['checks']
    if not args.boundary_only:
        compile_swift('NativeMailTests', 'NativeMailTests.swift')
        result = run('regression', [str(BUILD / 'NativeMailTests'), str(NATIVE)])
        match = re.search(r'NativeMailTests: (\d+) checks passed', result.stdout)
        assert match, 'Missing regression count'
        proof['regression'] = {'checks': int(match.group(1)), 'stdout': result.stdout.strip()}
        proof['checks'] += proof['regression']['checks']
    proof['binarySHA256'] = {f.name: hash_file(f) for f in [BUILD / 'NativeMailMIMEBoundaryTests'] +
        ([] if args.boundary_only else [BUILD / 'NativeMailTests'])}
    proof['inputsUnchanged'] = all(hash_file(NATIVE / key) == value for key, value in inputs.items())
    proof['oracleSourcesUnchanged'] = all(hash_file(Path(key)) == value for key, value in oracle['sourceHashes'].items())
    assert proof['inputsUnchanged'] and proof['oracleSourcesUnchanged'], 'Input changed during verification'
    proof['complete'] = True
finally:
    proof['elapsedSeconds'] = round(time.monotonic() - start, 2)
    proof['ownedArtifactBytes'] = sum(f.stat().st_size for f in BUILD.rglob('*') if f.is_file())
    proof_path.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'complete': proof['complete'], 'checks': proof['checks'],
    'cases': proof['oracle']['cases'], 'inputsUnchanged': proof['inputsUnchanged'],
    'proof': str(proof_path.relative_to(NATIVE)), 'ownedArtifactBytes': proof['ownedArtifactBytes']}))
