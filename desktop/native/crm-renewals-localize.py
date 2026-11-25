#!/usr/bin/env python3
"""Explicit source-template translation; never changes names, IDs or dates.

The unchanged TypeScript output stays in the explicit original path. This fixture
is a semantic/localization comparison, not verbatim original-output equality.
"""
from pathlib import Path
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
import json, copy, hashlib, sys

if len(sys.argv) != 3:
    raise SystemExit('Usage: crm-renewals-localize.py ORIGINAL OUTPUT')
original = Path(sys.argv[1])
output = Path(sys.argv[2])
ref = json.loads(original.read_text())
for case in ref['cases']:
    seeds = case['seeds']
    zone = ZoneInfo(case['zone'])
    def date(value):
        d = datetime.fromisoformat(value.replace('Z', '+00:00')).astimezone(zone)
        return f'{d.year:04}年{d.month}月{d.day}日（{"月火水木金土日"[d.weekday()]}）'
    translations = {}
    for row in seeds['crm_Contracts']:
        value = row['renewalReminderDate']
        if not value:
            continue
        cycle = value[:10]
        english = f'Renewal {cycle}: contract "{row["title"]}"'
        japanese = f'契約更新（{cycle}）：{row["title"]}'
        body = f'契約「{row["title"]}」の更新通知日は{date(value)}です。更新条件を取引先に確認してください。\n契約を開く：\nnextcrm-native://contracts/{row["id"]}'
        translations.setdefault(english, (japanese, body))
    for row in seeds['crm_AccountProducts']:
        value = row['renewal_date']
        if not value:
            continue
        account = next(x for x in seeds['crm_Accounts'] if x['id'] == row['accountId'])
        product = next((x for x in seeds['crm_Products'] if x['id'] == row['productId']), None)
        original_name = product.get('name') if product else None
        name = original_name if original_name is not None else '商品'
        canonical_name = original_name if original_name is not None else 'product'
        client, cycle = account['name'], value[:10]
        translations[f'Renewal {cycle}: {canonical_name} @ {client}'] = (
            f'利用契約の更新（{cycle}）：{name} / {client}',
            f'「{name}」の利用契約は{date(value)}に更新されます。取引先に更新予定を確認してください。')
    source_tasks = copy.deepcopy(case['tasks'])
    old_tasks = [{key: row.get(key) for key in ref['taskFields']} for row in seeds['crm_Accounts_Tasks']]
    for row in case['tasks']:
        # Imported existing tasks are not rewritten by a background scan.
        if row not in old_tasks:
            row['title'], row['content'] = translations[row['title']]
    localized_notices = []
    for notice in case['notices']:
        canonical = notice['subject'][len('New task - '):]
        task = next(row for row in source_tasks if row['title'] == canonical)
        title, content = translations[canonical]
        localized_notices.append({'recipient': notice['to'], 'title': title, 'content': content, 'due': task['dueDateAt']})
    case['notices'] = localized_notices
ref['localization'] = {
    'kind': 'explicit Japanese template mapping, source title alias retained for dedup',
    'originalReferenceSHA256': hashlib.sha256(original.read_bytes()).hexdigest(),
    'contractNavigation': 'typed native contract link; replaces original public Web origin',
    'unchanged': ['all user names/text interpolations', 'IDs', 'scope', 'assignees', 'statuses', 'instants', 'counts', 'recipients', 'existing tasks'],
}
output.write_text(json.dumps(ref, ensure_ascii=False, indent=2) + '\n')
print(f'Japanese renewal mapping: {len(ref["cases"])} original scenarios')
