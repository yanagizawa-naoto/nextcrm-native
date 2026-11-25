from pathlib import Path
import re,subprocess,json,hashlib,time,os
n=Path(__file__).resolve().parent;c=n/'build/project-completion-test';c.mkdir(exist_ok=True)
subprocess.run(['node',str(n/'project-completion-reference.cjs'),str(c)],check=True)
core=re.findall(r'\$native_dir/([^" ]+\.swift)',(n/'documents-test.sh').read_text())
core=[x for x in core if x!='CRMDocumentsTests.swift']
commentSource=n/'CRMProjectWindow.swift'
(c/'CRMProjectCommentsWindow.actual.swift').write_text('import AppKit\n'+commentSource.read_text().split('final class CRMProjectCommentsWindow:',1)[1].join(['final class CRMProjectCommentsWindow:','']))
extra=['CRMAccountTasks.swift','CRMProjectCommentsWindow.actual.swift','CRMProjectKanban.swift','CRMProjectKanbanWindow.swift','CRMEditor.swift','FormDraft.swift','DeferredTextInput.swift','VirtualFormEditor.swift','LightweightTable.swift','MemoryBudget.swift','InvoiceJobRunner.swift','NativeDocumentProcessing.swift','CRMDocumentProcessing.swift']
paths=[c/x if x=='CRMProjectCommentsWindow.actual.swift' else n/x for x in dict.fromkeys(core+extra+['CRMDocumentsWindow.swift'])]
paths += [n/x for x in ['CRMProjectDocumentAssociations.swift','CRMProjectQuickAdd.swift','ProjectCompletionTests.swift']]
inputs=paths+[commentSource,n/'schema.json',n/'schema.sql',n/'project-completion-reference.cjs',c/'reference.json',n/'documents-test.sh',Path(__file__)]
def hashes():return {os.path.relpath(x,n):hashlib.sha256(x.read_bytes()).hexdigest() for x in inputs}
reference=json.loads((c/'reference.json').read_text())
for name,digest in reference['hashes'].items():
 source=n.parent.parent/name
 assert hashlib.sha256(source.read_bytes()).hexdigest()==digest, 'Original changed: '+name
 inputs.append(source)
inputs.append(n/'plugins-source-loader.cjs')
before=hashes();start=time.time();cmd=['swiftc','-swift-version','5','-parse-as-library','-whole-module-optimization','-O','-framework','AppKit','-framework','CoreText','-lsqlite3',*map(str,paths),'-o',str(c/'ProjectCompletionTests')]
p=subprocess.run(cmd,text=True,capture_output=True);(c/'compile.log').write_text(p.stdout+p.stderr)
if p.returncode: print((p.stdout+p.stderr)[-6500:]);p.check_returncode()
r=subprocess.run([str(c/'ProjectCompletionTests'),str(n),str(c)],text=True,capture_output=True);(c/'test.log').write_text(r.stdout+r.stderr)
proof={'sourceCases':26,'exit':r.returncode,'compileExit':p.returncode,'seconds':round(time.time()-start,2),'sourcesSHA256':before,'sourceStable':before==hashes(),'stdout':r.stdout,'stderr':r.stderr,'binarySHA256':hashlib.sha256((c/'ProjectCompletionTests').read_bytes()).hexdigest(),'sourceCount':len(paths)}
(c/'verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');print(json.dumps({k:v for k,v in proof.items() if k not in ['sourcesSHA256','stderr']},ensure_ascii=False));print(r.stderr[-2500:] if r.returncode else '');r.check_returncode();assert proof['sourceStable']
