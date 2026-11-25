#!/usr/bin/env python3
"""Exercise production lead UI, app startup and local mail delivery in a QA bundle.

The app delegate is compiled unchanged with RESTORE_APP_HOST disabling only its @main. Provider requests
are captured by the existing guarded QA runtime. The installed app is untouched.
"""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

runtime_only = "--runtime-only" in sys.argv[1:]
compile_only = "--compile-only" in sys.argv[1:]
run_only = "--run-only" in sys.argv[1:]
assert not (compile_only and run_only), "Choose compile-only or run-only"
native = Path(__file__).resolve().parent
build = native / "build"
build.mkdir(exist_ok=True)
if not run_only:
    for script in ["build-campaign-html.sh", "build-native-mail.sh"]:
        subprocess.run(["zsh", str(native / script)], check=True)
    subprocess.run(["node", str(native / "generate-target-enrichment-agent.cjs")], check=True)
from native_build_inputs import app_sources, restore_host_bridge_inputs
sources = app_sources(native)
assert sources.count("CRMApp.swift") == 1
compiled = [str(native / s) for s in sources]
compiled.append(str(native / "NativeMCPLeadsUITests.swift"))
bundle = build / "NativeMCPLeadsQA.app"
contents = bundle / "Contents"
executable = contents / "MacOS" / "NativeMCPLeadsQA"
resources = contents / "Resources"
executable.parent.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
for name in ["schema.json", "schema.sql"]:
    shutil.copy2(native / name, resources / name)
shutil.copytree(native.parent.parent / "prisma/initial-data", resources / "initial-data", dirs_exist_ok=True)
shutil.copy2(build / "TargetEnrichmentAgent.mjs", resources / "TargetEnrichmentAgent.mjs")
with (contents / "Info.plist").open("wb") as stream:
    plistlib.dump({"CFBundleIdentifier": "local.nextcrm.native.mcp-leads-qa", "CFBundleName": "NativeMCPLeadsQA",
                  "CFBundleExecutable": executable.name, "CFBundlePackageType": "APPL", "LSUIElement": True}, stream)
inputs = sources + ["NativeMCPLeadsUITests.swift", "mcp-leads-ui-test.py", "build.sh", "schema.json", "schema.sql",
                    "build-campaign-html.sh", "build-native-mail.sh", "generate-target-enrichment-agent.cjs",
                    "NativeBridges.h", "CampaignHTML.c", "CampaignHTML.h", "CampaignHTMLEntities.inc",
                    "NativeMailTransport.c", "NativeMailTransport.h", "build/CampaignHTML.o", "build/NativeMailTransport.o",
                    "build/TargetEnrichmentAgent.mjs"]
if not run_only:
    subprocess.run(['zsh', str(native / 'build-plugins-http.sh')], check=True)
inputs += ['native_build_inputs.py', 'build.sh', 'NativePluginsHTTP.c', 'NativePluginsHTTP.h', 'build-plugins-http.sh', 'build/NativePluginsHTTP.o']
inputs += (['NativeRestoreHostBridge.c', 'NativeRestoreHostBridge.h', 'build-restore-host.sh', 'build/NativeRestoreHostBridge.o'] if run_only else restore_host_bridge_inputs(native))
before = {s: hashlib.sha256((native / s).read_bytes()).hexdigest() for s in inputs}
compile_command = ["swiftc", "-D", "RESTORE_APP_HOST", "-swift-version", "5", "-parse-as-library", "-whole-module-optimization", "-Onone", "-target", "arm64-apple-macos13.0",
                "-framework", "Security", "-framework", "AppKit", "-framework", "CoreText", "-lsqlite3", "-lxml2", "-lcurl", "-framework", "LocalAuthentication",
                "-import-objc-header", str(native / "NativeBridges.h"), str(build / "CampaignHTML.o"), str(build / "NativeMailTransport.o"), str(build / "NativePluginsHTTP.o"), str(build / "NativeRestoreHostBridge.o"),
                *compiled, "-o", str(executable)]
compile_record = build / "mcp-leads-ui-compile.json"
if run_only:
    saved = json.loads(compile_record.read_text())
    assert saved["sourcesSHA256"] == before and saved["command"] == compile_command, "Compile inputs changed; rebuild first"
    assert saved["binarySHA256"] == hashlib.sha256(executable.read_bytes()).hexdigest(), "Compiled test changed"
else:
    subprocess.run(compile_command, check=True)
    assert before == {s: hashlib.sha256((native / s).read_bytes()).hexdigest() for s in inputs}, "Compile inputs changed"
    compile_record.write_text(json.dumps({"sourcesSHA256": before, "command": compile_command, "binarySHA256": hashlib.sha256(executable.read_bytes()).hexdigest()}, indent=2)+"\n")
if compile_only:
    print("MCP leads UI: compile-only passed; no application started")
    raise SystemExit(0)
with tempfile.TemporaryDirectory(prefix="NextCRM-MCPLeads-UI-") as temporary:
    root = Path(temporary)
    (root / ".native-mail-test").write_text("NextCRM isolated mail QA\n")
    env = dict(os.environ, NEXTCRM_NATIVE_DATA_DIR=str(root), NEXTCRM_NATIVE_MAIL_TEST_MODE="success")
    result = subprocess.run([str(executable)] + (["--runtime-only"] if runtime_only else []), env=env, text=True, capture_output=True, timeout=180)
    print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="")
    evidence = {"kind": "actual AppKit controls and production app delegate with conditional-main test entry", "network": False,
                "normalAppDataTouched": False, "scope": "runtime lifecycle and links only" if runtime_only else "history/review controls and runtime lifecycle/links", "optimization": "Onone for behavior checks; candidate built separately with O", "delegateChanges": "RESTORE_APP_HOST; production source unchanged", "sourcesSHA256": before,
                "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(), "binaryBytes": executable.stat().st_size,
                "stdout": result.stdout, "stderr": result.stderr, "exit": result.returncode}
    (build / ("mcp-leads-runtime-verification.json" if runtime_only else "mcp-leads-ui-verification.json")).write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n")
    result.check_returncode()
assert before == {s: hashlib.sha256((native / s).read_bytes()).hexdigest() for s in inputs}, "App sources changed during verification"
