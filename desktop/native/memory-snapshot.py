"""Snapshot the native app and its descendants using macOS footprint."""
import json
from pathlib import Path
import subprocess
import sys

label = sys.argv[1]
artifacts = Path(__file__).resolve().parent.parent / 'artifacts'
executable = str(Path(sys.argv[2]).resolve()) if len(sys.argv) > 2 else str(Path.home() / 'Applications/NextCRM Native.app/Contents/MacOS/NextCRMNative')
all_processes = []
for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid=,rss=,command='], text=True).splitlines():
    row = line.strip().split(None, 3)
    if len(row) == 4:
        all_processes.append(dict(pid=int(row[0]), ppid=int(row[1]), rssKiB=int(row[2]), command=row[3]))
roots = [p for p in all_processes if p['command'] == executable]
if len(roots) != 1:
    raise SystemExit('Expected exactly one running native app')
selected = {roots[0]['pid']}
while True:
    children = {p['pid'] for p in all_processes if p['ppid'] in selected}
    if children <= selected:
        break
    selected.update(children)
processes = [p for p in all_processes if p['pid'] in selected]
output = artifacts / f'memory-{label}-footprint.json'
subprocess.run(['/usr/bin/footprint', '-j', str(output), *map(str, sorted(selected))],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
result = json.loads(output.read_text())
(artifacts / f'memory-{label}-processes.json').write_text(json.dumps(processes, indent=2))
print(json.dumps(dict(label=label, footprintMiB=round(result['total footprint'] / 1048576, 1),
                     scope='App and its current descendants; point snapshot, excludes shared WindowServer/system costs',
                     processes=[dict(name=p['name'], pid=p['pid'], MiB=round(p['footprint'] / 1048576, 1)) for p in result['processes']])))
