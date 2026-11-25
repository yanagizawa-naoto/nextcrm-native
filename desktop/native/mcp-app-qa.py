#!/usr/bin/env python3
"""Launch and seed only an isolated, marked native app QA directory."""
from pathlib import Path
import datetime
import hashlib
import json
import os
import plistlib
import secrets
import shutil
import sqlite3
import subprocess
import sys
import time
import uuid

n = Path(__file__).resolve().parent
command = sys.argv[1]
base = n.parent / "artifacts/native-mcp-app-qa"
progress = base / "progress.json"


def stamp(seconds=0):
    return (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=seconds)).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def private_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    path.chmod(0o600)


def isolated_app():
    # Distinct IDs are required while the user's installed app is also running:
    # otherwise the system file picker and UI automation may address the wrong
    # instance. Preserve the source binary hash separately from the re-signature.
    source = n / "build/NextCRM Native.app"
    app = n / "build/NextCRM QA.app"
    identifier = "local.nextcrm.native.qa"
    executable = app / "Contents/MacOS/NextCRMNative"
    running = subprocess.check_output(["ps", "-axo", "comm="], text=True).splitlines()
    if str(executable) in [item.strip() for item in running]:
        raise RuntimeError("Quit the isolated QA copy before refreshing it")
    if app.exists():
        existing = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        assert existing.get("CFBundleIdentifier") == identifier
        shutil.rmtree(app)
    source_hash = hashlib.sha256((source / "Contents/MacOS/NextCRMNative").read_bytes()).hexdigest()
    shutil.copytree(source, app)
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info.update(CFBundleIdentifier=identifier, CFBundleName="NextCRM QA")
    # A test copy must not register itself as the user's normal deep-link target.
    info.pop("CFBundleURLTypes", None)
    info_path.write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True, capture_output=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, capture_output=True)
    return app, {"sourceBinarySHA256": source_hash, "bundleIdentifier": identifier,
                 "binarySHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
                 "urlSchemeRegistration": "disabled in QA copy"}


if command == "start":
    os.umask(0o077)
    base.mkdir(parents=True, exist_ok=True)
    if progress.exists():
        previous = json.loads(progress.read_text())
        try:
            os.kill(previous["pid"], 0)
        except ProcessLookupError:
            pass
        else:
            raise RuntimeError("The previous isolated QA app is still running")
    root = base / ("run-" + uuid.uuid4().hex)
    root.mkdir()
    (root / ".native-mail-test").write_text("NextCRM isolated mail QA\n")
    app, provenance = isolated_app()
    binary = app / "Contents/MacOS/NextCRMNative"
    log = open(root / "app.log", "wb")
    child = subprocess.Popen([str(binary)], env={**os.environ, "NEXTCRM_NATIVE_DATA_DIR": str(root), "NEXTCRM_NATIVE_MAIL_TEST_MODE": "success"}, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    state = {"pid": child.pid, "root": str(root), "app": str(app), **provenance}
    private_json(progress, state)
    deadline = time.monotonic() + 30
    while True:
        try:
            db = sqlite3.connect(root / "crm.sqlite", timeout=10)
            db.row_factory = sqlite3.Row
            actor = db.execute("SELECT value FROM native_metadata WHERE key='localActor'").fetchone()[0]
            break
        except (sqlite3.Error, TypeError):
            if "db" in locals(): db.close()
            if child.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("Isolated app did not initialize; inspect its private QA log")
            time.sleep(0.1)

    def insert(table, values):
        columns = ",".join('"' + x + '"' for x in values)
        db.execute('INSERT INTO "' + table + '" (' + columns + ') VALUES (' + ",".join("?" for _ in values) + ")", list(values.values()))

    recipient = dict(db.execute("SELECT * FROM Users WHERE id=?", [actor]).fetchone())
    recipient.update(id=str(uuid.uuid4()), name="通知確認の担当者", email="recipient@example.invalid", role="user", created_on=stamp(), updated_at=stamp(), _native_revision=1)
    insert("Users", recipient)
    raw = "nxtc__" + secrets.token_hex(24)
    insert("ApiToken", {"id": str(uuid.uuid4()), "name": "隔離アプリ統合検証", "userId": actor, "tokenHash": hashlib.sha256(raw.encode()).hexdigest(), "tokenPrefix": raw[-8:], "createdAt": stamp(), "_native_search": "", "_native_revision": 1})
    session_id, session_value = str(uuid.uuid4()), "isolated-app-session-" + uuid.uuid4().hex
    insert("Session", {"id": session_id, "token": session_value, "userId": actor, "createdAt": stamp(-172800), "updatedAt": stamp(-172800), "expiresAt": stamp(86400), "_native_search": "", "_native_revision": 1})
    db.commit()
    private_json(root / "synthetic-inputs.json", {"actor": actor, "recipient": recipient["id"], "bearer": raw, "sessionID": session_id, "sessionValue": session_value})
    db.close()
    print(json.dumps(state, ensure_ascii=False))
elif command == "status":
    state = json.loads(progress.read_text())
    root = Path(state["root"])
    db = sqlite3.connect("file:" + str(root / "crm.sqlite") + "?mode=ro", uri=True)
    row = db.execute("SELECT value FROM native_metadata WHERE key='mcp.settings.v1'").fetchone()
    settings = json.loads(row[0]) if row else None
    # Never include the synthetic client credentials in tool output.
    print(json.dumps({**state, "settings": {k: settings[k] for k in ["enabled", "port", "maximumConnections", "revision"]} if settings else None}, ensure_ascii=False))
elif command == "restart":
    state = json.loads(progress.read_text())
    try:
        os.kill(state["pid"], 0)
    except ProcessLookupError:
        pass
    else:
        raise RuntimeError("Quit the isolated app before restarting it")
    root = Path(state["root"])
    assert (root / ".native-mail-test").read_text() == "NextCRM isolated mail QA\n"
    log = open(root / "app.log", "ab")
    app, provenance = isolated_app()
    binary = app / "Contents/MacOS/NextCRMNative"
    state.update(app=str(app), **provenance)
    child = subprocess.Popen([str(binary)], env={**os.environ, "NEXTCRM_NATIVE_DATA_DIR": str(root), "NEXTCRM_NATIVE_MAIL_TEST_MODE": "success"}, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    state["pid"] = child.pid
    private_json(progress, state)
    print(json.dumps(state, ensure_ascii=False))
else:
    raise SystemExit("Use start, status, or restart")
