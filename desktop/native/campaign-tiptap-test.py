#!/usr/bin/env python3
"""Verify production campaign HTML saves against installed upstream TipTap.

No installation, browser download, baseline candidate, or rich-regression rerun.
The latter belongs to template-rich-test.sh in the regular test suite.
"""
from pathlib import Path
import copy
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess

native = Path(__file__).resolve().parent
root = native.parent.parent
output = native / 'build/campaign-tiptap'
output.mkdir(parents=True, exist_ok=True)
proof_file = output / 'verification.json'
proof_file.unlink(missing_ok=True)


def relative(path):
    return str(Path(path).relative_to(root))


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(arguments):
    command = [relative(x) if isinstance(x, Path) else x for x in arguments]
    child = subprocess.Popen(command, cwd=root, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        stdout, stderr = child.communicate(timeout=600)
    except BaseException:
        # Only this runner's newly created child group; never unrelated processes.
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            child.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.communicate()
        raise
    if child.returncode:
        raise RuntimeError(stdout[-2500:] + stderr[-6500:])
    if stdout.strip():
        print(stdout.strip(), flush=True)
    return stdout


# Reuse the project's established explicit template-service dependency list.
service_names = re.findall(r'"\$native_dir/([^"\n]+\.swift)"',
                           (native / 'templates-test.sh').read_text())
assert service_names.count('CampaignTemplatesTests.swift') == 1
save_sources = [native / name for name in service_names if name != 'CampaignTemplatesTests.swift']
save_sources += [native / name for name in [
    'CampaignTemplateEditor.swift', 'MemoryBudget.swift', 'NativeEmbeddingVector.swift',
    'NativeEmbeddingClient.swift', 'NativeAICredentials.swift', 'NativeUserCredentialCleanup.swift', 'CampaignAI.swift',
    'CRMCampaignDraft.swift', 'CampaignWorkflow.swift', 'CRMCampaigns.swift',
    'CampaignRichText.swift', 'CampaignTipTapSaveTests.swift',
    'CampaignHTML.swift', 'NativeMailHTML.swift', 'CampaignTemplatePreview.swift',
]]
assert len(save_sources) == len(set(save_sources))
core_sources = [native / name for name in [
    'NativeDatabase.swift', 'CampaignMergeTags.swift', 'CampaignRichText.swift',
    'CampaignTipTapRoundtripTests.swift',
 'MailReview.swift']]
# Use the project's existing C bridge build, then retain this runner's own object.
run(['zsh', native / 'build-campaign-html.sh'])
save_c_object = output / 'CampaignHTML.o'
shutil.copyfile(native / 'build/CampaignHTML.o', save_c_object)
fixture_file = native / 'campaign-tiptap-fixtures.json'
inputs = set(core_sources + save_sources + [
    fixture_file, Path(__file__), native / 'campaign-tiptap-reference.cjs',
    native / 'campaign-tiptap-consumers.cjs', native / 'campaign-tiptap-validation.md',
    native / 'schema.json', native / 'schema.sql', native / 'templates-test.sh',
    native / 'CampaignHTML.c', native / 'CampaignHTML.h', native / 'CampaignHTMLEntities.inc',
    native / 'build-campaign-html.sh', native / 'generate-campaign-entities.py', save_c_object,
])
before = {relative(path): sha(path) for path in sorted(inputs)}
fixtures = json.loads(fixture_file.read_text())
assert len(fixtures) == 112 and len({x['id'] for x in fixtures}) == 112
shutil.copyfile(fixture_file, output / 'fixtures.json')
flags = ['swiftc', '-swift-version', '5', '-parse-as-library', '-O',
         '-target', 'arm64-apple-macos13.0', '-framework', 'AppKit',
         '-framework', 'WebKit', '-framework', 'Security',
         '-framework', 'LocalAuthentication', '-lsqlite3']

run(['node', native / 'campaign-tiptap-reference.cjs'])
probe = output / 'CampaignTipTapRoundtripTests'
run(flags + core_sources + ['-o', probe])
run([probe, output])
shutil.copyfile(output / 'results.json', output / 'schema-results.json')
initial = json.loads((output / 'schema-results.json').read_text())
checks = 0


def check(value, label):
    global checks
    if not value:
        raise AssertionError(label)
    checks += 1


def source_equal(fixture, row):
    expected = row['source']['json']
    if fixture.get('knownURLNormalization'):
        # Only the reviewed literal href conversion in two special fixtures.
        # No other content, mark, attribute, or URL is normalized for comparison.
        expected = copy.deepcopy(expected)
        matched = 0

        def visit(value):
            nonlocal matched
            if isinstance(value, dict):
                if value.get('href') == fixture['knownURLNormalization']['from']:
                    value['href'] = fixture['knownURLNormalization']['to']
                    matched += 1
                for child in value.values():
                    visit(child)
            elif isinstance(value, list):
                for child in value:
                    visit(child)
        visit(expected)
        assert matched == 1, ('unexpected known URL fixture', fixture['id'])
    return expected == row['nativeHTML']['json']


protected, known_urls = [], []
check(len(initial['fixtures']) == len(initial['oracle']['rows']) == 112, 'initial cardinality')
for expected, fixture, row in zip(fixtures, initial['fixtures'], initial['oracle']['rows']):
    label = fixture['id']
    check(expected['id'] == label == row['id'], ('fixture identity', label))
    check(row['initialUpdates'] == 0, ('metadata-only load does not update', label))
    check(row['source'] == row['sourceJSONRound'], ('upstream JSON roundtrip', label))
    check(row['source'] == row['sourceHTMLRound'], ('upstream HTML roundtrip', label))
    check(row['edited']['updates'] > 0, ('actual upstream edit', label))
    check(source_equal(fixture, row), ('HTML semantic loss', label))
    if fixture.get('expectEditable'):
        check(fixture['protectedBlocks'] == 0, ('ordinary rich body became protected', label))
    if fixture.get('knownURLNormalization'):
        check(row['urlSemantics']['equal'], ('actual browser URL destination differs', label))
        known_urls.append({'id': label, **fixture['knownURLNormalization'], **row['urlSemantics']})
    check(re.search(r'NextCRMPreserve[0-9A-F]{32}[ESP]',
                    fixture['nativeHTML'] + fixture['nativeJSON']) is None,
          ('sentinel persisted', label))
    check(row['nativeJSON']['valid'], ('invalid native schema', label))
    if not fixture['protectedBlocks']:
        check(row['nativeHTML']['json'] == row['nativeJSON']['json'], ('HTML/JSON disagree', label))
    else:
        check(fixture['nativeHTML'] == fixture['html'], ('protected HTML bytes changed', label))
        protected.append(label)
check(set(protected) == {'table', 'image', 'style', 'html', 'comment'},
      'only documented unsupported inputs use protected HTML')

save_binary = output / 'CampaignTipTapSaveTests'
run(flags + ['-lxml2', '-import-objc-header', native / 'CampaignHTML.h', save_c_object] + save_sources + ['-o', save_binary])
save_stdout = run([save_binary, native, output])
saved = json.loads((output / 'saved-results.json').read_text())
check(len(saved['fixtures']) == 114, '112 saves plus actual selection/save/re-edit records')
(output / 'saved-fixtures.json').write_text(json.dumps(saved['fixtures'], ensure_ascii=False) + '\n')
run([probe, output, 'saved-fixtures.json'])
shutil.copyfile(output / 'results.json', output / 'saved-schema-results.json')
saved_schema = json.loads((output / 'saved-schema-results.json').read_text())
check(len(saved_schema['oracle']['rows']) == 114, 'all persisted rows parsed upstream')
for fixture, row in zip(saved['fixtures'], saved_schema['oracle']['rows']):
    label = fixture['id']
    check(label == row['id'], ('saved identity', label))
    check(source_equal(fixture, row), ('saved actual rich HTML', label))
    check(row['nativeJSON']['valid'], ('saved actual JSON schema', label))
    if not fixture['protectedBlocks']:
        check(row['nativeJSON']['json'] == row['nativeHTML']['json'], ('saved JSON semantic', label))

run(['node', native / 'campaign-tiptap-consumers.cjs'])
consumer = json.loads((output / 'consumer-verification.json').read_text())
upstream = json.loads((output / 'source-inputs.json').read_text())
assert before == {relative(path): sha(path) for path in sorted(inputs)}, 'Inputs changed during verification'
assert all(sha(root / path) == digest for path, digest in upstream['sourceHashes'].items())
assert all(sha(root / path) == digest for path, digest in consumer['sourceSHA256'].items())
proof = {
    'status': 'production CampaignRichText.swift directly verified',
    'fixtures': len(fixtures), 'actualSavedSchemaFixtures': len(saved['fixtures']),
    'schemaChecks': checks, 'actualSQLiteAppKitChecks': saved['checks'],
    'consumerRenderChecks': consumer['checks'], 'nativeSourceSHA256': before,
    'executablesSHA256': {relative(path): sha(path) for path in [probe, save_binary]},
    'upstream': upstream, 'sourceDom': initial['oracle']['userAgent'],
    'protectedJSONNotPortable': protected, 'existingURLNormalizationBoundary': known_urls,
    'actualSave': save_stdout.strip(), 'consumers': consumer,
    'downloads': False, 'network': False, 'realKeychain': False, 'normalUserData': False,
    'notCovered': ['generic rich/visual HTML parity', 'JSON-only external renderers for protected HTML',
                   'live provider send', 'PostgreSQL/MCP transport/export execution'],
}
proof_file.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
print(f'Campaign TipTap production: {checks} schema + {saved["checks"]} AppKit/SQLite '
      f'+ {consumer["checks"]} upstream render checks; all input hashes stable', flush=True)
