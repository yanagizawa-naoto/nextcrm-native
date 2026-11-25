#!/usr/bin/env python3
"""Build the optimized candidate with stable input hashes; never install or run it."""
from pathlib import Path
import hashlib
import json
import re
import subprocess

native = Path(__file__).resolve().parent
repo = native.parent.parent
build = native / "build"
build.mkdir(exist_ok=True)
swift = re.findall(r'"\$native_dir/([^"\n]+\.swift)"', (native / "build.sh").read_text())
names = set(swift + [
    "build.sh", "mcp-leads-build.py", "Info.plist", "NativeMailHTML-Info.plist",
    "NativeMailHTMLApp.swift", "NativeMailHTMLRenderer.swift", "schema.json", "schema.sql", "MCPToolCatalog.json",
    "build-campaign-html.sh", "build-native-mail.sh", "build-native-mail-html.sh",
    "generate-catalog.py", "generate-campaign-entities.py", "generate-enrichment-prompts.cjs", "generate-target-enrichment-agent.cjs",
    "CampaignHTML.c", "CampaignHTML.h", "CampaignHTMLEntities.inc", "NativeBridges.h",
    "NativeMailTransport.c", "NativeMailTransport.h", "使い方.txt",
])
inputs = [native / name for name in sorted(names)] + sorted((repo / "prisma/initial-data").glob("*.json"))
inputs += [repo / "prisma/schema.prisma", repo / "LICENSE", native.parent / "macos/AppIcon.icns"]
def hashes():
    return {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
before = hashes()
result = subprocess.run(["zsh", str(native / "build.sh")], text=True, capture_output=True)
print(result.stdout, end="")
print(result.stderr, end="")
after = hashes()
bundle = build / "NextCRM Native.app"
binary = bundle / "Contents/MacOS/NextCRMNative"
record = {"kind": "optimized arm64 macOS candidate build and nested codesign verification", "optimization": "O",
          "installed": False, "externalMailSent": False, "exit": result.returncode, "sourcesSHA256": before,
          "inputsUnchanged": before == after, "stdout": result.stdout, "stderr": result.stderr}
if result.returncode == 0:
    record.update({"binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(), "binaryBytes": binary.stat().st_size,
                   "bundleBytes": sum(p.stat().st_size for p in bundle.rglob("*") if p.is_file()),
                   "resourceSHA256": {str(p.relative_to(bundle)): hashlib.sha256(p.read_bytes()).hexdigest()
                                     for p in sorted((bundle / "Contents/Resources").rglob("*")) if p.is_file()}})
(build / "mcp-leads-candidate-verification.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
result.check_returncode()
assert before == after, "Candidate inputs changed during build"
print(json.dumps({"optimizedCandidate": True, "binaryBytes": record["binaryBytes"], "bundleBytes": record["bundleBytes"], "stableSourceFiles": len(before)}))
