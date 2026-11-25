#!/usr/bin/env python3
"""CRM automation production regressions; private SQLite and fake transport only."""
from pathlib import Path
import argparse, hashlib, json, re, subprocess, sys, time

HERE = Path(__file__).resolve().parent
N = next((p for p in [HERE, *HERE.parents]
          if (p / 'schema.json').is_file() and (p / 'CRMService.swift').is_file()), None)
if N is None:
    raise SystemExit('Native production source directory not found')
R = N.parent.parent
manifest = HERE / 'crm-automation-sources.json'
groups = json.loads(manifest.read_text())['groups']
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--suite', choices=['all', *groups], default='all')
args = parser.parse_args()
selected = list(groups) if args.suite == 'all' else [args.suite]
production = list(dict.fromkeys(name for group in selected for name in groups[group]['production']))
for name in production:
    if Path(name).name != name or not name.endswith('.swift'):
        raise SystemExit('Only directly named production Swift files are allowed: ' + name)
missing = [name for name in production if not (N / name).is_file()]
if missing:
    raise SystemExit('Production promotion required; no candidate fallback: ' + ', '.join(missing))
O = N / 'build/crm-automation-test'
O.mkdir(parents=True, exist_ok=True)
started = time.monotonic()
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
watched = [N / name for name in production]
watched += [HERE / name for name in dict.fromkeys(name for group in selected for name in groups[group]['tests'])]
watched += [manifest, Path(__file__).resolve(), N / 'schema.json', N / 'schema.sql',
            HERE / 'crm-renewals-reference.cjs', HERE / 'crm-renewals-localize.py', HERE / 'crm-stage-reference.cjs']
before = {str(path.relative_to(R)): sha(path) for path in watched}
proof = {'productionOnly': True, 'candidateFallback': False, 'suites': {},
         'normalData': False, 'network': False, 'realProviderCalls': 0,
         'keychainAccess': False, 'originalSourceSHA256': {}}
source_hashes = proof['originalSourceSHA256']

def command(label, argv, timeout=300):
    log = O / (label + '.log')
    with log.open('w') as stream:
        result = subprocess.run(argv, cwd=R, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{label} exit {result.returncode}; see {log.relative_to(R)}')
    return log

try:
    references = {}
    for oracle in dict.fromkeys(groups[group].get('oracle') for group in selected):
        if oracle is None:
            continue
        folder = O / oracle
        folder.mkdir(exist_ok=True)
        if oracle == 'renewal':
            raw = folder / 'original-reference.json'
            command('renewal-oracle', ['node', str(HERE / 'crm-renewals-reference.cjs'), str(raw), str(N)])
            command('renewal-localization', [sys.executable, str(HERE / 'crm-renewals-localize.py'), str(raw), str(folder / 'reference.json')])
        else:
            raw = folder / 'reference.json'
            command('stage-oracle', ['node', str(HERE / 'crm-stage-reference.cjs'), str(raw), str(N)])
        reference = json.loads(raw.read_text())
        source_hashes.update(reference['sourceSHA256'])
        references[oracle] = folder
        proof[oracle + 'Reference'] = {
            'sourceCases': len(reference['cases']), 'pureCases': len(reference.get('pure', [])),
            'rawSHA256': sha(raw), 'nativeReferenceSHA256': sha(folder / 'reference.json')}
    for name in selected:
        group = groups[name]
        binary = O / ('CRM' + name.title() + 'Tests')
        files = [N / file for file in group['production']] + [HERE / file for file in group['tests']]
        flags = ['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-whole-module-optimization',
                 '-target', 'arm64-apple-macos13.0', '-lsqlite3']
        for framework in group['frameworks']:
            flags += ['-framework', framework]
        for define in group.get('defines', []):
            flags += ['-D', define]
        command(name + '-compile', flags + list(map(str, files)) + ['-o', str(binary)], timeout=600)
        argv = [str(binary), str(N)]
        if group.get('oracle'):
            argv.append(str(references[group['oracle']]))
        log = command(name + '-native', argv, timeout=180)
        output = log.read_text()
        count = re.search(r': (\d+) checks passed', output)
        if count is None or int(count.group(1)) != group['expectedChecks']:
            raise RuntimeError(f'{name}: unexpected check count; see {log.relative_to(R)}')
        proof['suites'][name] = {'exit': 0, 'checks': int(count.group(1)), 'stdout': output.strip(),
                                'productionFiles': group['production']}
    proof['exit'] = 0
except Exception as error:
    proof['exit'] = 1
    proof['error'] = str(error)
finally:
    proof['inputsSHA256'] = before
    proof['inputsUnchanged'] = all((R / path).is_file() and sha(R / path) == digest for path, digest in before.items())
    proof['originalSourceUnchanged'] = all((R / path).is_file() and sha(R / path) == digest for path, digest in source_hashes.items())
    proof['seconds'] = round(time.monotonic() - started, 1)
    if not proof['inputsUnchanged'] or not proof['originalSourceUnchanged']:
        proof['exit'] = 1
    destination = O / ('verification.json' if args.suite == 'all' else args.suite + '-verification.json')
    destination.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: v for k, v in proof.items() if k not in ['inputsSHA256', 'originalSourceSHA256', 'suites']}, ensure_ascii=False))
    for name, result in proof['suites'].items():
        print(f'{name}: {result["checks"]} checks passed')
raise SystemExit(proof['exit'])
