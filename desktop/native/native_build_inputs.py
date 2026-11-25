"""Read the main app's Swift inputs without including helper executable targets."""
from pathlib import Path
import shlex


def app_sources(native: Path) -> list[str]:
    commands = []
    for line in (native / "build.sh").read_text().replace("\\\n", " ").splitlines():
        if not line.lstrip().startswith("swiftc "):
            continue
        args = shlex.split(line, comments=True)
        if "$native_dir/CRMApp.swift" in args:
            commands.append(args)
    if len(commands) != 1:
        raise ValueError("build.sh must contain exactly one CRMApp.swift compile command")
    sources = [arg.removeprefix("$native_dir/") for arg in commands[0]
               if arg.startswith("$native_dir/") and arg.endswith(".swift")]
    if len(sources) != len(set(sources)):
        raise ValueError("The app compile command contains duplicate Swift inputs")
    if not all((native / source).is_file() for source in sources):
        raise ValueError("The app compile command references a missing Swift source")
    return sources


def restore_host_bridge_inputs(native: Path) -> list[str]:
    """Build and hash the same dedicated restore-process bridge as the app."""
    import subprocess
    subprocess.run(['zsh', str(native / 'build-restore-host.sh')], check=True)
    return ['NativeRestoreHostBridge.c', 'NativeRestoreHostBridge.h',
            'build-restore-host.sh', 'build/NativeRestoreHostBridge.o']
