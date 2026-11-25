#!/usr/bin/env python3
"""Build the integrated native candidate without replacing the installed app."""
from pathlib import Path
import datetime
import hashlib
import json
import re
import subprocess

n = Path(__file__).resolve().parent
build = n / "build.sh"
inputs = {build, Path(__file__).resolve(), n / "MCPToolCatalog.json", n / "schema.json", n / "schema.sql"}
for script in [build, *(n / name for name in ["build-campaign-html.sh", "build-native-mail.sh", "build-native-mail-html.sh", "build-plugins-http.sh"])]:
    inputs.add(script)
    for name in re.findall(r'\$native_dir/([^"\n]+\.(?:swift|cjs|plist|py|c|h))(?=")', script.read_text()):
        inputs.add(n / name)
inputs.update([n / "NativeBridges.h", n / "CampaignHTML.h", n / "NativeMailTransport.h", n / "NativePluginsHTTP.h", n.parent.parent / "prisma/schema.prisma"])
inputs.update((n.parent.parent / "prisma/initial-data").glob("*.json"))
inputs = sorted(p.resolve() for p in inputs)


def hashes():
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}


before = hashes()
result = subprocess.run(["zsh", str(build)])
if result.returncode:
    raise SystemExit(result.returncode)
assert before == hashes(), "Build inputs changed; candidate is not a verified snapshot"
app = n / "build/NextCRM Native.app"
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
binary = app / "Contents/MacOS/NextCRMNative"
if not binary.exists():
    import plistlib
    name = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleExecutable"]
    binary = app / "Contents/MacOS" / name
proof = {
    "at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "sources": before,
    "inputsUnchanged": True,
    "buildExit": 0,
    "codesignExit": 0,
    "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "binaryBytes": binary.stat().st_size,
    "appBytes": sum(p.stat().st_size for p in app.rglob("*") if p.is_file()),
    "helpers": {
        str(p.relative_to(app)): {"sha256": hashlib.sha256(p.read_bytes()).hexdigest(), "bytes": p.stat().st_size}
        for p in sorted((app / "Contents/Helpers").glob("*")) if p.is_file()
    },
    "scope": "Optimized native app build with all MCP operations, signed session authorization, settings UI and runtime lifecycle. No installation, runtime GUI or memory measurement implied.",
}
(n / "build/mcp-app-build-verification.json").write_text(json.dumps(proof, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({k: v for k, v in proof.items() if k != "sources"}, ensure_ascii=False))
