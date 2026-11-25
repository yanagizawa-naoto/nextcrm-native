#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess
import hashlib
import json

native = Path(__file__).resolve().parent
sources = re.findall(r'"\$native_dir/([^"\n]+\.swift)"', (native / 'templates-test.sh').read_text())
assert sources.count('CampaignTemplatesTests.swift') == 1
sources = ['CampaignTemplatesUITests.swift' if x == 'CampaignTemplatesTests.swift' else x for x in sources]
sources += ['CampaignRichText.swift', 'CampaignTemplateEditor.swift', 'CRMTemplatesWindow.swift', 'LightweightTable.swift', 'MemoryBudget.swift']
sources += ['NativeEmbeddingVector.swift', 'NativeEmbeddingClient.swift', 'NativeAICredentials.swift', 'NativeUserCredentialCleanup.swift', 'CampaignAI.swift', 'CRMCampaignDraft.swift', 'CampaignWorkflow.swift', 'CRMCampaigns.swift']
sources += ['NativeMailHTML.swift', 'CampaignTemplatePreview.swift', 'CampaignHTML.swift']
output = native / 'build' / 'CampaignTemplatesUITests'
output.parent.mkdir(exist_ok=True)
subprocess.run(['zsh', str(native/'build-campaign-html.sh')], check=True)
inputs = sources + ['CampaignHTML.c', 'CampaignHTML.h', 'CampaignHTMLEntities.inc', 'build-campaign-html.sh', 'build/CampaignHTML.o']
before = {x: hashlib.sha256((native / x).read_bytes()).hexdigest() for x in inputs}
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-target', 'arm64-apple-macos13.0',
                '-framework', 'Security', '-framework', 'AppKit', '-framework', 'CoreText', '-framework', 'LocalAuthentication', '-lsqlite3', '-lxml2', '-import-objc-header', str(native/'CampaignHTML.h'), str(native/'build/CampaignHTML.o'),
                *[str(native / x) for x in sources], '-o', str(output)], check=True)
result = subprocess.run([str(output), str(native)], text=True, capture_output=True)
print(result.stdout, end='')
if result.stderr:
    print(result.stderr, end='')
result.check_returncode()
assert before == {x: hashlib.sha256((native / x).read_bytes()).hexdigest() for x in inputs}, 'Sources changed during test'
(native / 'build' / 'templates-ui-verification.json').write_text(json.dumps({
    'kind': 'offscreen Japanese template rich/HTML editing, persistence, conflicts and list controls', 'network': False,
    'sourcesSHA256': before, 'executableSHA256': hashlib.sha256(output.read_bytes()).hexdigest(),
    'stdout': result.stdout, 'exit': result.returncode,
}, ensure_ascii=False, indent=2)+'\n')
