#!/usr/bin/env python3
"""Add synthetic presentation fixtures to a stopped, explicitly marked QA app."""
from pathlib import Path
import datetime
import hashlib
import json
import os
import sqlite3
import uuid

n = Path(__file__).resolve().parent
base = n.parent / 'artifacts/native-mcp-app-qa'
state = json.loads((base / 'progress.json').read_text())
root = Path(state['root']).resolve()
assert root.parent == base.resolve() and root.name.startswith('run-')
assert (root / '.native-mail-test').read_text() == 'NextCRM isolated mail QA\n'
try:
    os.kill(state['pid'], 0)
except ProcessLookupError:
    pass
else:
    raise RuntimeError('Quit the isolated QA app before adding fixtures')
proof = json.loads((n / 'build/mcp-app-build-verification.json').read_text())
binary = n / 'build/NextCRM Native.app/Contents/MacOS/NextCRMNative'
assert hashlib.sha256(binary.read_bytes()).hexdigest() == proof['binarySHA256'] == state['binarySHA256']
assert proof['inputsUnchanged'] and proof['buildExit'] == 0
assert not (root / 'plugin-presentation-fixtures.json').exists()
now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
db = sqlite3.connect(root / 'crm.sqlite')
db.execute('PRAGMA foreign_keys=ON')
actor = db.execute("SELECT value FROM native_metadata WHERE key='localActor'").fetchone()[0]
def insert(table, values):
    columns = ','.join('"' + x + '"' for x in values)
    db.execute('INSERT INTO "' + table + '" (' + columns + ') VALUES (' + ','.join('?' for _ in values) + ')', list(values.values()))
def store(plugin, key, value):
    insert('PluginData', {'id': str(uuid.uuid4()), 'pluginId': plugin, 'entityType': '', 'entityId': '', 'key': key, 'value': json.dumps(value, ensure_ascii=False), 'updatedAt': now})
ids = {key: str(uuid.uuid4()) for key in ['account', 'otherAccount', 'product', 'order']}
with db:
    for key, name in [('account', '連携画面の確認株式会社'), ('otherAccount', '移動先の確認株式会社')]:
        insert('crm_Accounts', {'id': ids[key], '__v': 0, 'createdAt': now, 'updatedAt': now, 'name': name, 'company_id': '12345678', 'createdBy': actor, 'case_study_candidate': 0, 'case_study_approved': 0, '_native_search': name})
    insert('crm_Products', {'id': ids['product'], 'name': '連携確認の商品', 'type': 'PRODUCT', 'status': 'ACTIVE', 'unit_price': '100', 'currency': 'JPY', 'is_recurring': 0, 'source': 'EXTERNAL', 'externalRef': '700', '__v': 0, 'createdAt': now, 'updatedAt': now, '_native_search': '連携確認の商品'})
    series = db.execute("SELECT id FROM NumberSeries WHERE scope='order' LIMIT 1").fetchone()[0]
    insert('crm_Orders', {'id': ids['order'], 'number': 'QA-PLUGIN-001', 'seriesId': series, 'status': 'DRAFT', 'source': 'CRM', 'accountId': ids['account'], 'ownerId': actor, 'currency': 'JPY', 'orderDate': now, 'subtotal': '0', 'vatTotal': '0', 'grandTotal': '0', 'createdAt': now, 'updatedAt': now, '_native_search': 'QA-PLUGIN-001'})
    for plugin, version in [('account-protection', '0.1.0'), ('odoo-connector', '0.4.2'), ('oxo-erp-connector', '0.1.0')]:
        settings = {} if plugin == 'account-protection' else {'url': 'https://erp.example.invalid', 'database': 'qa', 'timeZone': 'Asia/Tokyo', 'currency': 'JPY', 'dryRun': True, 'sendOrders': False}
        # Use the built definition's account-protection version, avoiding a spurious upgrade.
        if plugin == 'account-protection':
            import re
            source = (n / 'NativeAccountProtectionJobs.swift').read_text()
            version = re.search(r'version:\s*"([^"]+)"', source).group(1)
        insert('InstalledPlugin', {'id': plugin, 'version': version, 'status': 'ENABLED', 'settings': json.dumps(settings), 'installedAt': now, 'updatedAt': now})
    for plugin in ['odoo-connector', 'oxo-erp-connector']:
        for key in ['account', 'otherAccount']:
            store(plugin, 'account:' + ids[key], {'partnerId': 50 if key == 'account' else 51, 'customerId': 50 if key == 'account' else 51, 'syncedAt': now, 'salesperson': '確認用営業担当', 'archived': False})
        store(plugin, 'meta:lastRun', {'at': now, 'ok': True, 'created': 2, 'updated': 0, 'unchanged': 0, 'skipped': 0, 'conflicts': 0, 'failed': 0})
        store(plugin, 'product:' + ('700' if plugin == 'odoo-connector' else ids['product']), {'productId': ids['product'], 'oxoId': 700, 'ref': 'QA-700'})
        store(plugin, 'order:' + ids['order'], {'odooId': 900, 'oxoId': 900, 'name': 'S00900', 'number': 'S00900', 'state': 'draft'})
    store('account-protection', 'conflict:' + ids['account'], {'key': 'CZ:12345678', 'otherAccountId': ids['otherAccount']})
    store('account-protection', 'freed:' + now[:10] + ':' + ids['account'], {})
    assert not db.execute('PRAGMA foreign_key_check').fetchall()
db.close()
record = {'ids': ids, 'at': now, 'scope': 'Synthetic local records only. External provider HTTP blocked by isolated app QA mode.'}
path = root / 'plugin-presentation-fixtures.json'
path.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n'); path.chmod(0o600)
print(json.dumps({'seeded': True, 'root': str(root), 'records': len(ids), 'plugins': 3}))
