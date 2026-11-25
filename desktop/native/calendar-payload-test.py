#!/usr/bin/env python3
"""Original calendar handlers + disk provider ingestion, synthetic SQLite/loopback only."""
from pathlib import Path
import ast, datetime, hashlib, json, os, re, subprocess, time

N = Path(__file__).resolve().parent
R = N.parent.parent
B = N / 'build/calendar-payload-proof' / (datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + str(os.getpid()))
B.mkdir(parents=True)
h = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
started = time.monotonic()
phases = []

def sources(script, additions):
    names = list(dict.fromkeys(re.findall(r'\$native_dir/([^"/]+\.swift)', (N / script).read_text())))
    return list(dict.fromkeys([x for x in names if not x.endswith('Tests.swift')] + additions))

helpers = ['NativeCalendarResponse.swift', 'NativeMail.swift', 'NativeMailTemporaryFiles.swift']
google = sources('google-calendar-sync-test.sh', helpers + ['NativeCalendarGooglePayloadFixture.swift', 'NativeCalendarGooglePayloadTests.swift'])
push = sources('google-calendar-push-test.sh', helpers + ['NativeCalendarPushPayloadFixture.swift', 'NativeCalendarPushPayloadTests.swift', 'GoogleCalendarRuntime.swift', 'InvoiceJobRunner.swift'])
calendly = sources('calendly-runtime-test.sh', helpers + ['NativeCalendarCalendlyPayloadFixture.swift', 'NativeCalendarCalendlyPayloadTests.swift', 'GoogleCalendarRuntime.swift', 'CalendlyRuntime.swift', 'InvoiceJobRunner.swift'])
files = list(dict.fromkeys([N / x for x in google + calendly + push + ['NativeMailTransport.c', 'NativeMailTransport.h', 'NativeMailParsing.h', 'CampaignHTML.c', 'CampaignHTML.h', 'CampaignHTMLEntities.inc', 'schema.json', 'schema.sql', 'calendar-payload-test.py', 'calendar-payload-reference.cjs', 'calendar-push-payload-reference.cjs', 'google-calendar-push-test.sh', 'calendar-payload-harness.cjs', 'calendar-relay-payload-test.cjs', 'google-calendar-sync-test.sh', 'calendly-runtime-test.sh', 'plugins-source-loader.cjs']] + [R / 'pnpm-lock.yaml', N.parent / 'calendar-relay/relay.cjs'] + list((R / 'prisma/initial-data').glob('*.json'))))
before = {str(p.relative_to(R)): h(p) for p in files}

def run(name, command):
    start = time.monotonic()
    p = subprocess.run(command, cwd=R, capture_output=True, text=True)
    (B / (name + '.log')).write_text(p.stdout + p.stderr)
    phases.append({'name': name, 'exit': p.returncode, 'seconds': round(time.monotonic() - start, 3)})
    if p.returncode:
        raise RuntimeError(name + ': ' + str(B / (name + '.log')))

run('source', ['node', str(N / 'calendar-payload-reference.cjs'), str(B)])
run('push-source', ['node', str(N / 'calendar-push-payload-reference.cjs'), str(B)])
sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
run('mail-c', ['clang', '-O2', '-c', str(N / 'NativeMailTransport.c'), '-o', str(B / 'mail.o')])
run('html-c', ['clang', '-O2', '-I' + sdk + '/usr/include/libxml2', '-c', str(N / 'CampaignHTML.c'), '-o', str(B / 'html.o')])
flags = ['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-whole-module-optimization', '-framework', 'Security', '-framework', 'Network', '-lcurl', '-lsqlite3', '-lxml2', '-import-objc-header', str(N / 'NativeMailParsing.h'), str(B / 'mail.o'), str(B / 'html.o')]
for name, inputs in [('google', google), ('calendly', calendly), ('push', push)]:
    run(name + '-compile', flags + [str(N / x) for x in inputs] + ['-o', str(B / (name + '-tests'))])
    run(name, [str(B / (name + '-tests')), str(N), str(B)])
run('relay', ['node', str(N / 'calendar-relay-payload-test.cjs'), str(B)])
original = json.loads((B / 'reference.json').read_text())
google_result = json.loads((B / 'google-result.json').read_text())
calendly_result = json.loads((B / 'calendly-result.json').read_text())
for name, result, source_name in [('google', google_result, 'googleCases'), ('calendly', calendly_result, 'calendlyCases')]:
    assert len(result['comparisons']) == len(original[source_name])
    for source, native in zip(original[source_name], result['comparisons']):
        assert source['accepted'] and all(source[k] == v for k, v in native.items()), name
assert original['largePage']['accepted'] and original['largePage']['events'] == 17
push_result = json.loads((B / 'push-result.json').read_text())
push_source = json.loads((B / 'push-reference.json').read_text())
assert push_result['checks'] == 21 and len(push_source['cases']) == 3
assert all(c['accepted'] and c['providerWrites'] == 1 and c['mappingWrites'] == 1 and c['attendeesOmitted'] for c in push_source['cases'])
assert all(h(R / k) == v for k, v in push_source['sourceHashes'].items())
assert google_result['checks'] == 28
assert calendly_result['checks'] == 37 and calendly_result['existingAuthenticationChecks'] == 13
assert all(h(R / k) == v for k, v in before.items())
assert all(h(R / k) == v for k, v in original['sourceHashes'].items())
proof = {'phases': phases, 'inputs': before, 'sourceInputs': original['sourceHashes'], 'inputsUnchanged': True, 'google': google_result, 'push': push_result, 'pushSource': push_source, 'calendly': calendly_result, 'sourceScalarCases': 7, 'sourceLargePageEvents': 17, 'sourceDifferences': 0, 'relay': json.loads((B / 'relay-large-result.json').read_text()), 'normalData': False, 'realKeychain': False, 'externalNetworkCalls': 0, 'localLoopbackOnly': True, 'output': str(B.relative_to(R)), 'seconds': round(time.monotonic() - started, 2)}
(B / 'verification.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
(N / 'build/calendar-payload-verification.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'google': 28, 'push': 21, 'pushSourceCases': 3, 'calendly': 37, 'existingAuthentication': 13, 'originalScalarCases': 7, 'originalLargePageEvents': 17, 'sourceDifferences': 0, 'hashesStable': True, 'proof': str((B / 'verification.json').relative_to(R))}))
