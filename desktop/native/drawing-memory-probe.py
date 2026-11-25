"""Build the real native controllers once, then compare rendering modes offline.

No downloads, installation, normal database access, mail worker or external API.
WindowServer RSS is recorded only as a noisy whole-process observation.
"""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path
import re
import statistics
import subprocess
import time


def server_rss():
    rows = subprocess.check_output(["ps", "-axo", "pid=,rss=,comm="], text=True).splitlines()
    return [{"pid": int(p[0]), "rssKiB": int(p[1])} for row in rows
            if len(p := row.strip().split(None, 2)) == 3 and p[2].endswith("/WindowServer")]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    assert 1 <= args.runs <= 10
    native = Path(__file__).resolve().parent
    app = native / "build/NextCRM Drawing Probe.app"
    binary = app / "Contents/MacOS/DrawingMemoryProbe"
    binary.parent.mkdir(parents=True, exist_ok=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "local.nextcrm.native.drawing-probe", "CFBundleName": "NextCRM Drawing Probe",
        "CFBundleExecutable": "DrawingMemoryProbe", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1", "LSMinimumSystemVersion": "13.0", "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication"}))
    artifacts = native.parent / "artifacts/native-drawing-comparison"
    artifacts.mkdir(exist_ok=True)
    # Consume the existing production source manifest in build.sh; fail if it
    # no longer has the explicit quoted Swift paths, rather than silently omit UI.
    names = re.findall(r'"\$native_dir/([^"\n]+\.swift)"', (native / "build.sh").read_text())
    assert names.count("CRMApp.swift") == 1 and len(names) > 40
    sources = [native / n for n in names if n != "CRMApp.swift"] + [native / "DrawingMemoryProbe.swift"]
    sources += [native / n for n in ["NativeBridges.h", "CampaignHTML.h", "CampaignHTML.c", "CampaignHTMLEntities.inc", "NativeMailTransport.h", "NativeMailTransport.c"]]
    source_hash = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    source_hash["DrawingWindowObserver.swift"] = hashlib.sha256((native / "DrawingWindowObserver.swift").read_bytes()).hexdigest()
    manifest = native / "build/DrawingMemoryProbe.sources.json"
    window_observer = native / "build/DrawingWindowObserver"
    if not args.skip_build:
        subprocess.run(["zsh", str(native / "build-campaign-html.sh")], check=True)
        subprocess.run(["zsh", str(native / "build-native-mail.sh")], check=True)
        command = ["swiftc", "-swift-version", "5", "-parse-as-library", "-O", "-target", "arm64-apple-macos13.0",
                   "-framework", "Security", "-framework", "AppKit", "-framework", "CoreText", "-framework", "QuartzCore", "-framework", "LocalAuthentication", "-lsqlite3", "-lxml2", "-lcurl", "-import-objc-header", str(native / "NativeBridges.h"), str(native / "build/CampaignHTML.o"), str(native / "build/NativeMailTransport.o")]
        with (artifacts / "build.log").open("w") as log:
            subprocess.run(command + [str(p) for p in sources if p.suffix == ".swift"] + ["-o", str(binary)], stdout=log, stderr=subprocess.STDOUT, check=True)
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True, capture_output=True)
        subprocess.run(["swiftc", "-framework", "AppKit", str(native / "DrawingWindowObserver.swift"), "-o", str(window_observer)], check=True)
        manifest.write_text(json.dumps(source_hash, sort_keys=True) + "\n")
    else:
        assert json.loads(manifest.read_text()) == source_hash, "Sources changed; rebuild the probe"
    reports = []
    # Rotate order to reduce a fixed baseline-first warmup bias.
    modes = ["baseline", "static", "rows"]
    for run in range(args.runs):
        for mode in modes[run % 3:] + modes[:run % 3]:
            output = artifacts / f"{mode}-{run + 1}.json"
            before = server_rss()
            with (artifacts / f"{mode}-{run + 1}.log").open("w") as log:
                env = dict(os.environ, NEXTCRM_DRAWING_OBSERVER="1")
                process = subprocess.Popen([str(binary), str(native), str(output), mode], stdout=log, stderr=subprocess.STDOUT, env=env)
                seen = set()
                while process.poll() is None:
                    request = output.with_suffix(".request.json")
                    if request.exists():
                        data = json.loads(request.read_text())
                        phase = data["phase"]
                        if data["pid"] == process.pid and phase not in seen:
                            observation = json.loads(subprocess.check_output([str(window_observer), str(process.pid)], text=True))
                            onscreen = {w["kCGWindowNumber"] for w in observation["ours"] if w.get("kCGWindowIsOnscreen")}
                            response = {"phase": phase, "confirmedVisible": observation["totalWindowCount"] > 0 and set(data["expectedWindowNumbers"]).issubset(onscreen),
                                        "windowServerRSS": server_rss(), "observation": observation}
                            temporary = output.with_suffix(".response.tmp")
                            temporary.write_text(json.dumps(response) + "\n")
                            temporary.replace(output.with_suffix(".response.json"))
                            seen.add(phase)
                    time.sleep(0.05)
                if process.returncode:
                    raise subprocess.CalledProcessError(process.returncode, process.args)
            report = json.loads(output.read_text())
            report["run"] = run + 1
            report["windowServerBefore"] = before
            report["windowServerAfter"] = server_rss()
            output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
            reports.append(report)
            print(json.dumps({"mode": mode, "run": run + 1, "MiB": {s["phase"]: round(s["footprintBytes"] / 1048576, 3) for s in report["samples"]}}, ensure_ascii=False), flush=True)
    phases = [s["phase"] for s in reports[0]["samples"]]
    geometry = lambda r: [[(u["frame"], u["scale"], u["level"], u["keyWindow"]) for u in s["ui"]] for s in r["samples"]]
    assert all(geometry(r) == geometry(reports[0]) for r in reports), "Window geometry/scale changed between runs"
    summary = {mode: {phase: {"valuesMiB": values, "medianMiB": statistics.median(values)}
                         for phase in phases
                         for values in [[s["footprintBytes"] / 1048576 for r in reports if r["mode"] == mode for s in r["samples"] if s["phase"] == phase]]}
               for mode in modes}
    (artifacts / "comparison.json").write_text(json.dumps({"binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "sourcesSHA256": source_hash, "summary": summary, "runs": reports,
        "limitations": "Actual isolated CRM controllers with synthetic data; not whole app or peak. WindowServer RSS includes all apps and cannot prove attributable savings. Window estimates and layer geometry are not additive to physical footprint."}, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"summary": summary, "output": str(artifacts / "comparison.json")}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
