import json,pathlib,re,hashlib,sys
C=pathlib.Path(sys.argv[1]).resolve()
r=json.loads((C/'reference.json').read_text());n=json.loads((C/'native-results.json').read_text());checks=0;errors=[]
def check(ok,label):
 global checks
 checks+=1
 if not ok and len(errors)<40:errors.append(label)
def canonical(x):return json.dumps(x,sort_keys=True,ensure_ascii=False,separators=(',',':'))
def values(row):
 row=dict(row)
 for k in ['createdAt','updatedAt','created_at','updated_at']:row.pop(k,None)
 for k,v in list(row.items()):
  if isinstance(v,str) and v.startswith(('[','{')):
   try:row[k]=json.loads(v)
   except ValueError:pass
 return row
for source,actual in zip(r['cases'],n['cases']):
 label=source['label'];check(actual['label']==label,label+' identity');after=source['after'];native=actual['after'];kind=source['kind']
 initial_ids={x['id'] for x in source['initial']['crm_TargetLists']};snew=[x for x in after['crm_TargetLists'] if x['id'] not in initial_ids];nnew=[x for x in native['crm_TargetLists'] if x['id'] not in initial_ids]
 idmap={}
 if snew and nnew:idmap[nnew[0]['id']]=snew[0]['id']
 for model in r['models']:
  expected=[values(x) for x in after[model]];got=[values(x) for x in native[model]]
  for x in got:
   for k in ['id','target_list_id']:
    if x.get(k) in idmap:x[k]=idmap[x[k]]
   if model=='crm_AuditLog':x.pop('id',None)
   if model=='crm_TargetLists' and x.get('id') not in initial_ids:
    check(x['description']=='自動管理：営業ステップ終了後、再開待ち期間を過ぎても反応のない営業対象です。',label+' JP list description')
    x['description']='Auto-managed: targets whose sequence finished with no response after the recycle window.'
    # Explicit original canonical English -> newly generated Japanese display name.
    check(x['name']=='再開対象',label+' JP list name');x['name']='Recycled'
  for x in expected:
   if model=='crm_AuditLog':
    x.pop('id',None)
    for change in x['changes']:
     if change['field']=='close_reason':
      days=int(re.fullmatch(r'(-?\d+)-day kill rule',change['new']).group(1));change['new']=f'最終顧客対応から{days}日経過したため終了'
  check(len(got)==len(expected),label+' '+model+' row count '+str((len(expected),len(got))))
  # Full original scalar projection; source schema defaults versus imported DB defaults
  # are part of this comparison, except automatically generated timestamps and IDs.
  ex=sorted(expected,key=canonical);go=sorted(got,key=canonical)
  for i,(a,b) in enumerate(zip(ex,go)):
   for key in a:check(a[key]==b.get(key),label+' '+model+f'[{i}].'+key+' '+repr((a[key],b.get(key)))[:240])
 jobs=actual['jobs'];scans=[j for j in jobs if j['event'].endswith('.scan')];children=[j for j in jobs if j['event'].endswith('.check')]
 results=[source['result']]+([source['second']] if source.get('second') is not None else [])
 if kind=='kill':
  check(sum(int(j['result']['checked']) for j in scans)==sum(x['checked'] for x in results),label+' source checked count')
  check(sum(j['result']['closed']=='true' for j in children)==sum(x['closed'] for x in results),label+' source closed count')
  selected=[json.loads(j['payload']['opportunity'])['id'] for j in children]
  if not source.get('rerun'):check(sorted(selected)==sorted(source['selected']),label+' actual source selected ID set')
 else:check(sum(int(j['result']['recycled']) for j in scans)==sum(x['recycled'] for x in results),label+' source recycle count')
 expected=[]
 for mail in source['sent']:
  if kind=='kill':
   match=re.fullmatch(r'Deal closed by (-?\d+)-day rule: ([\s\S]*)',mail['subject']);days=int(match[1]);name=match[2];oid=mail['text'].split('/crm/opportunities/')[-1]
   expected.append({'to':[mail['to']],'subject':f'{days}日間の未対応により商談を終了しました：{name}','text':f'商談「{name}」は顧客からの反応が{days}日間なかったため、失注として終了しました。\n必要な場合は商談を再開してください。\nnextcrm-native://opportunities/{oid}'})
  else:
   count=int(mail['subject'].split()[0]);lid=(snew[0] if snew else next(x for x in after['crm_TargetLists'] if x['name']=='Recycled' and x['deletedAt'] is None))['id']
   expected.append({'to':mail['to'],'subject':f'{count}件の営業対象を再開対象に追加しました','text':f'営業ステップ終了後も反応のなかった{count}件を「再開対象」リストに追加しました。\n新しいキャンペーンにこのリストを割り当ててください。\nnextcrm-native://target-lists/{lid}'})
 bodies=[]
 for body in actual['bodies']:
  check(body['from']=='sender@example.invalid',label+' synthetic sender');body={k:body[k] for k in ['to','subject','text']}
  for nativeid,originalid in idmap.items():body['text']=body['text'].replace(nativeid,originalid)
  bodies.append(body)
 check(sorted(map(canonical,bodies))==sorted(map(canonical,expected)),label+' explicit Japanese mapping/native destinations '+str((len(expected),len(bodies))))
 check(len(actual['notices'])==len(expected),label+' durable notice count')
 check(len(set(actual['keys']))==len(actual['keys']),label+' unique dispatch keys')
result={'sourceCases':len(r['cases']),'nativeChecks':n['checks'],'comparisonChecks':checks,'failures':errors,'sourceSHA256':r['sourceSHA256'],'limits':r['limits'],'languageMapping':{'newListName':['Recycled','再開対象'],'legacyAlias':'Recycled remains unchanged; both aliases excluded/reused','closeReason':['<days>-day kill rule','最終顧客対応から<days>日経過したため終了'],'notification':'Explicit sentence mapping preserves original day/count/user names and exact typed UUID destinations.'}}
(C/'comparison.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');print(json.dumps({k:v for k,v in result.items() if k not in ['sourceSHA256','limits','languageMapping']},ensure_ascii=False))
sys.exit(bool(errors))
