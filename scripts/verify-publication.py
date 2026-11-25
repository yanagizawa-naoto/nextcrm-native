#!/usr/bin/env python3
"""Offline checks for the native source snapshot and public documentation."""
from pathlib import Path
import hashlib
import json
import math
from datetime import datetime
from statistics import median
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / 'desktop/native'
sources = json.loads((NATIVE / 'ApplicationSources.json').read_text())
assert len(sources) == 453 and len(sources) == len(set(sources))
build = (NATIVE / 'build.sh').read_text()
main = build.split('swiftc -D PERSONAL_APP_HOST ', 1)[1].split('-o "$app/Contents/MacOS/NextCRMNative"', 1)[0]
compiled_sources = re.findall(r'\$native_dir/([A-Za-z0-9_]+\.swift)', main)
assert len(compiled_sources) == len(sources) and set(compiled_sources) == set(sources)
snapshot = json.loads((ROOT / 'docs/verification/source-manifest.json').read_text())
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
assert snapshot['sourceCount'] == len(sources)
for name in sources:
    assert sha(NATIVE / name) == snapshot['runtimeSHA256'][name], name
required = ['LICENSE', 'THIRD_PARTY_NOTICES.md', 'licenses/Inter-OFL.txt',
            'licenses/Python-LICENSE.txt', 'public/fonts/OFL-NotoSansJP.txt',
            'prisma/schema.prisma', 'lib/enrichment/services/openai.ts',
            'lib/enrichment/e2b/agent-script.ts', 'lib/enrichment/presets/target-fields.ts',
            'desktop/macos/AppIcon.icns', 'desktop/native/使い方.txt',
            'desktop/campaign-relay/test.sh', 'desktop/calendar-relay/test.sh']
assert all((ROOT / p).is_file() for p in required)
assert 'Copyright (c) 2023 Pavel Dovhomilja' in (ROOT / 'LICENSE').read_text()
memory = json.loads((ROOT / 'docs/verification/memory.json').read_text())
for row in memory['measurements']:
    assert row['MB'] == round(row['bytes'] / 1_000_000, 2)
    assert row['MiB'] == round(row['bytes'] / 1_048_576, 2)
# Public comparison evidence is independently recomputed from all 60 samples.
comparison = json.loads((ROOT / 'docs/verification/memory-comparison-20261126.json').read_text())
assert comparison['schemaVersion'] == 1
assert comparison['units'] == {'MB': 1_000_000, 'MiB': 1_048_576}
assert comparison['dataset']['targetCount'] == 10_000
assert comparison['dataset']['postMeasurementHashesMatch'] is True
assert comparison['conditions']['samplesPerLaunch'] == 5
assert comparison['conditions']['launchesPerVariantPerMode'] == 3
readme = (ROOT / 'README.md').read_text()
memory_doc = (ROOT / 'docs/MEMORY.md').read_text()
assert {e['mode'] for e in comparison['experiments']} == {'background', 'foreground'}
assert len(comparison['experiments']) == 2
accepted_samples = 0
for experiment in comparison['experiments']:
    trials = experiment['trials']
    assert len(trials) == 6 and len({t['id'] for t in trials}) == 6
    assert experiment['acceptedRunOrder'] == [t['variant'] for t in trials]
    assert {t['variant'] for t in trials} == {'native', 'web'}
    for trial in trials:
        samples = trial['samples']
        assert [s['index'] for s in samples] == [1, 2, 3, 4, 5]
        assert trial['medianBytes'] == median(s['bytes'] for s in samples)
        ready = datetime.fromisoformat(trial['uiReadyUTC'])
        previous = ready
        for sample in samples:
            assert type(sample['bytes']) is int and sample['bytes'] > 0
            assert sample['processCount'] == {'native': 3, 'web': 15}[trial['variant']]
            assert sample['durationSeconds'] > 0
            assert re.fullmatch(r'[a-f0-9]{64}', sample['rawSHA256'])
            start = datetime.fromisoformat(sample['startUTC'])
            assert (start - ready).total_seconds() >= 30
            assert start > previous
            previous = start
            accepted_samples += 1
    for variant in ('native', 'web'):
        runs = [t for t in trials if t['variant'] == variant]
        assert len(runs) == 3
        values = [s['bytes'] for t in runs for s in t['samples']]
        run_medians = [t['medianBytes'] / 1_000_000 for t in runs]
        expected = median(t['medianBytes'] for t in runs)
        summary = experiment['summary'][variant]
        assert summary['bytes'] == expected
        assert summary['MB'] == expected / 1_000_000
        assert summary['MiB'] == expected / 1_048_576
        assert summary['trialMediansMB'] == run_medians
        assert summary['trialMedianRangeMB'] == [min(run_medians), max(run_medians)]
        assert summary['allSampleRangeMB'] == [min(values) / 1_000_000, max(values) / 1_000_000]
        assert summary['samples'] == len(values) == 15
        assert f"{summary['MB']:.1f} MB" in readme
        assert f"{expected:,} | {summary['MB']:.2f} | {summary['MiB']:.2f}" in memory_doc
    summary = experiment['summary']
    reduction = (1 - summary['native']['bytes'] / summary['web']['bytes']) * 100
    assert math.isclose(summary['reductionPercent'], reduction, abs_tol=1e-12)
    assert f"{reduction:.1f}%" in readme and f"{reduction:.1f}%" in memory_doc
assert accepted_samples == 60
assert 'Inngest' in readme and '認証エラー' in readme
assert '本体だけ' in readme and '参考値' in readme

# Check only versioned files when this directory is its own checkout. Builds,
# dependency links, and temporary test fixtures never become publication input.
git_root = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', '--show-toplevel'],
                          capture_output=True, text=True)
if git_root.returncode == 0 and Path(git_root.stdout.strip()).resolve() == ROOT:
    tracked = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '-z'], text=True)
    files = [ROOT / p for p in tracked.split('\0') if p]
else:
    excluded_parts = {'node_modules', '.git', '__pycache__', 'build', 'artifacts'}
    files = [p for p in ROOT.rglob('*') if p.is_file()
             and not set(p.relative_to(ROOT).parts).intersection(excluded_parts)]
violations = []
for p in files:
    rel = p.relative_to(ROOT).as_posix()
    if p.is_symlink() or any(part in {'node_modules', '.git', '__pycache__', 'build', 'artifacts'}
                             for part in p.relative_to(ROOT).parts):
        violations.append((rel, 'generated-or-symlink'))
    if (p.name.startswith('.env') and p.name not in {'.env.example', '.env.local.example'}) or p.suffix in {'.pem', '.key', '.p12', '.sqlite', '.db', '.log'}:
        violations.append((rel, 'local-data'))
    try:
        text = p.read_text()
    except UnicodeError:
        continue
    # Matches private macOS account paths, but permits synthetic /Users/Shared.
    if re.search('/' + 'Users/' + r'(?!Shared(?:/|\b))[^/\s"\']+', text):
        violations.append((rel, 'private-home-path'))
    if re.search(r'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----', text):
        violations.append((rel, 'private-key'))
    if re.search(r'(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,}|AKIA[0-9A-Z]{16})', text):
        violations.append((rel, 'credential-shaped-value'))
assert not violations, json.dumps(violations)
for p in [ROOT / 'README.md', *sorted((ROOT / 'docs').glob('*.md'))]:
    if p.name == 'UPSTREAM-README.md':
        continue
    for target in re.findall(r'\]\(([^)]+)\)', p.read_text()):
        if '://' in target or target.startswith('#'):
            continue
        target = target.split('#', 1)[0]
        assert (p.parent / target).exists(), (str(p.relative_to(ROOT)), target)
print(json.dumps({'publicationChecks': 'passed', 'runtimeSources': len(sources),
                  'checkedFiles': len(files), 'comparisonSamples': accepted_samples, 'memoryUnits': 'decimal MB and binary MiB'}))
