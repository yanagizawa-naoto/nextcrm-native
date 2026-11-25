#!/usr/bin/env python3
from pathlib import Path
import re, subprocess, json, hashlib
native = Path(__file__).resolve().parent
sources = re.findall(r'"\$native_dir/([^"\n]+\.swift)"', (native / 'campaigns-test.sh').read_text())
sources.remove('CampaignWorkflowTests.swift')
sources += ['NativeEmbeddingVector.swift', 'NativeEmbeddingClient.swift', 'NativeAICredentials.swift', 'NativeUserCredentialCleanup.swift', 'NativeAIQAServices.swift', 'CampaignAI.swift', 'CRMCampaignDraft.swift', 'CampaignAITests.swift']
subprocess.run(['node', str(native / 'campaign-ai-reference.cjs')], check=True)
before = {p: hashlib.sha256((native / p).read_bytes()).hexdigest() for p in sources}
output = native / 'build/CampaignAITests'
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-framework', 'Security', '-framework', 'LocalAuthentication', '-lsqlite3', *[str(native / p) for p in sources], '-o', str(output)], check=True)
result = subprocess.run([str(output), str(native)], capture_output=True, text=True)
print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
assert before == {p: hashlib.sha256((native / p).read_bytes()).hexdigest() for p in sources}
(native / 'build/campaign-ai-test-verification.json').write_text(json.dumps({'sources': before, 'stdout': result.stdout, 'exit': result.returncode}, ensure_ascii=False, indent=2))
