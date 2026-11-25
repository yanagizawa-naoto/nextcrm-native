#!/usr/bin/env python3
"""Capture the current source schema and feature inventory without runtime dependencies."""
from pathlib import Path
import hashlib
import json
import re

root = Path(__file__).resolve().parents[2]
destination = Path(__file__).resolve().parent
source = (root / 'prisma/schema.prisma').read_text()
blocks = list(re.finditer(r'^(model|enum)\s+(\w+)\s*\{\n(.*?)^\}', source, re.M | re.S))
model_names = {m[2] for m in blocks if m[1] == 'model'}
enums = {m[2]: [line.strip().split()[0] for line in m[3].splitlines()
                  if line.strip() and not line.strip().startswith('//')] for m in blocks if m[1] == 'enum'}
models = []
field_pattern = re.compile(r'^(\w+)\s+(Unsupported\("[^"\n]+"\)|\w+)(\[\]|\?)?\s*(.*)$')
for block in blocks:
    if block[1] != 'model':
        continue
    fields, relations, directives = [], [], []
    for raw in block[3].splitlines():
        line = raw.strip()
        if not line or line.startswith('//'):
            continue
        if line.startswith('@@'):
            directives.append(line)
            continue
        match = field_pattern.fullmatch(line)
        if not match:
            raise ValueError(f'Unparsed schema line in {block[2]}: {line}')
        name, kind, modifier, attributes = match.groups()
        db_name = re.search(r'@map\("([^"]+)"\)', attributes)
        field = dict(name=name, column=db_name[1] if db_name else name, type=kind,
                     optional=modifier == '?', array=modifier == '[]', attributes=attributes)
        if '@default(' in attributes:
            start = attributes.index('@default(') + len('@default(')
            depth, quoted, escaped = 1, False, False
            for end in range(start, len(attributes)):
                char = attributes[end]
                if escaped: escaped = False; continue
                if char == '\\' and quoted: escaped = True; continue
                if char == '"': quoted = not quoted
                if not quoted:
                    if char == '(': depth += 1
                    elif char == ')': depth -= 1
                if depth == 0: break
            field['defaultExpression'] = attributes[start:end]
        if kind in model_names:
            relations.append(field)
        else:
            fields.append(field)
    primary = [f['name'] for f in fields if re.search(r'@id\b', f['attributes'])]
    for directive in directives:
        if directive.startswith('@@id('): primary = re.search(r'\[([^]]+)\]', directive)[1].replace(' ', '').split(',')
    if not primary: raise ValueError(f'Model {block[2]} has no primary key')
    models.append(dict(name=block[2], fields=fields, relations=relations, directives=directives, primaryKey=primary))
catalog = dict(formatVersion=1, schemaSHA256=hashlib.sha256(source.encode()).hexdigest(), models=models, enums=enums)
(destination / 'schema.json').write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n')

def quote(value):
    return '"' + value.replace('"', '""') + '"'

def columns(model, names):
    return ','.join(quote(next(f['column'] for f in model['fields'] if f['name'] == name)) for name in names)

sql = ['-- Generated from prisma/schema.prisma; decimal values remain exact text.', 'PRAGMA foreign_keys=ON;']
by_name = {model['name']: model for model in models}
for model in models:
    definitions = []
    for field in model['fields']:
        kind = field['type']
        sql_type = 'TEXT' if field['array'] else 'INTEGER' if kind in ('Int','BigInt','Boolean') else 'REAL' if kind == 'Float' else 'BLOB' if kind == 'Bytes' or kind.startswith('Unsupported("vector') else 'TEXT'
        definition = quote(field['column']) + ' ' + sql_type
        if not field['optional']: definition += ' NOT NULL'
        if kind == 'Boolean': definition += ' CHECK (' + quote(field['column']) + ' IN (0,1))'
        if kind in enums:
            definition += ' CHECK (' + quote(field['column']) + ' IN (' + ','.join("'" + v.replace("'", "''") + "'" for v in enums[kind]) + '))'
        if '@unique' in field['attributes']: definition += ' UNIQUE'
        definitions.append(definition)
    definitions.extend(['"_native_revision" INTEGER NOT NULL DEFAULT 1', '"_native_search" TEXT NOT NULL DEFAULT \'\'', 'PRIMARY KEY (' + columns(model, model['primaryKey']) + ')'])
    for relation in model['relations']:
        match = re.search(r'fields:\s*\[([^]]+)\].*?references:\s*\[([^]]+)\]', relation['attributes'])
        if match:
            local, remote = (part.replace(' ', '').split(',') for part in match.groups())
            deleted = re.search(r'onDelete:\s*(\w+)', relation['attributes'])
            action = {'Cascade':'CASCADE','SetNull':'SET NULL','Restrict':'RESTRICT','NoAction':'NO ACTION','SetDefault':'SET DEFAULT'}.get(deleted[1] if deleted else '', 'NO ACTION')
            definitions.append('FOREIGN KEY (' + columns(model, local) + ') REFERENCES ' + quote(relation['type']) + '(' + columns(by_name[relation['type']], remote) + ') ON DELETE ' + action + ' ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED')
    sql.append('CREATE TABLE IF NOT EXISTS ' + quote(model['name']) + ' (\n  ' + ',\n  '.join(definitions) + '\n);')
    for index, directive in enumerate(model['directives']):
        if directive.startswith(('@@index(', '@@unique(')):
            names = [part.strip().split('(')[0] for part in re.search(r'\[([^]]+)\]', directive)[1].split(',')]
            unique = 'UNIQUE ' if directive.startswith('@@unique') else ''
            sql.append('CREATE ' + unique + 'INDEX IF NOT EXISTS ' + quote('native_' + model['name'] + '_' + str(index)) + ' ON ' + quote(model['name']) + '(' + columns(model, names) + ');')
(destination / 'schema.sql').write_text('\n'.join(sql) + '\n')

groups = {
    'crm': ('取引先・連絡先・リード・商談・契約・活動・営業対象', ['actions/crm']),
    'projects': ('プロジェクト・ボード・タスク・コメント', ['actions/projects']),
    'invoices': ('請求書・採番・税計算・入金・PDF・送信', ['actions/invoices', 'lib/invoices']),
    'documents': ('文書・添付・バージョン・プレビュー・取り込み', ['actions/documents']),
    'mail': ('メールアカウント・同期・検索・送受信・関連付け', ['actions/emails']),
    'campaigns': ('キャンペーン・テンプレート・配信・停止', ['actions/campaigns']),
    'reports': ('集計・帳票・定期レポート', ['actions/reports']),
    'admin': ('ユーザー・権限・設定・監査・認証・秘密情報', ['actions/admin', 'actions/user', 'lib/auth.ts']),
    'search': ('統合検索・ベクトル検索・類似検索', ['actions/fulltext', 'actions/crm/similarity']),
    'jobs': ('バックグラウンド処理・再試行・AI・カレンダー・連携', ['inngest/functions', 'lib/crm/calendar']),
    'mcp': ('MCPツール・トランスポート・APIトークン', ['lib/mcp', 'actions/api-tokens.ts']),
    'plugins': ('プラグイン・外部サービス連携', ['plugins', 'lib/plugins']),
}
inventory = []
for key, (title, locations) in groups.items():
    files = set()
    for location in locations:
        path = root / location
        if path.is_file():
            files.add(path)
        elif path.exists():
            files.update(p for p in path.rglob('*') if p.suffix in ('.ts', '.tsx') and p.is_file())
    inventory.append(dict(id=key, title=title, sourceFiles=sorted(str(p.relative_to(root)) for p in files),
                          implementationStatus='pending', verificationStatus='pending'))
(destination / 'source-inventory.json').write_text(json.dumps(dict(
    schemaSHA256=catalog['schemaSHA256'], modelCount=len(models),
    routes=sorted(str(p.relative_to(root)) for p in (root / 'app/[locale]/(routes)').rglob('page.tsx')),
    allActions=sorted(str(p.relative_to(root)) for p in (root / 'actions').rglob('*.ts') if '__tests__' not in p.parts),
    allAPIHandlers=sorted(str(p.relative_to(root)) for p in (root / 'app/api').rglob('route.ts')),
    groups=inventory), ensure_ascii=False, indent=2) + '\n')
print(json.dumps(dict(models=len(models), fields=sum(len(m['fields']) for m in models), enums=len(enums), featureGroups=len(inventory))))
