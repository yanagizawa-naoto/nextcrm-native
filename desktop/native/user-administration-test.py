#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,subprocess
n=Path(__file__).resolve().parent
names=['NativeDatabase','CRMModules','InvoiceModules','CatalogModules','LineItemModules','LineItemMath','CRMLineItems','CRMCatalog','ProductCSV','PricingEngine','CRMService','OrderModules','OrderWorkflow','OrderDraftStore','CRMOrders','InvoiceMath','NativeAPITokens','NativeUserAdministration', 'NativeUserCredentialCleanup','NativeUserAdministrationMail','NativeUserAdministrationTests', 'MailReview']
files=[n/(s+'.swift')for s in names]
watched=files+[n/'schema.json',n/'schema.sql',n/'user-administration-reference.cjs',n/'plugins-source-loader.cjs',n/'plugins-source-database.cjs',Path(__file__).resolve()]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before={p.name:sha(p)for p in watched}
ddl=n/'build/user-administration-prisma-ddl.sql'
# Prisma 7's schema engine requires datasource configuration even for an
# offline from-empty/schema diff. Never inherit the user's database config.
config=n/'build/user-administration-prisma.config.ts'
config.write_text('export default { datasource: { url: "postgresql://fixture:fixture@127.0.0.1:1/fixture" } };\n')
with ddl.open('w') as output:
 subprocess.run([str(n.parent.parent/'node_modules/.bin/prisma'),'migrate','diff','--from-empty','--to-schema',str(n.parent.parent/'prisma/schema.prisma'),'--script','--config',str(config)],stdout=output,check=True,cwd=n.parent.parent)
assert ddl.stat().st_size>0,'Locked Prisma schema diff produced no DDL'
subprocess.run(['node',str(n/'user-administration-reference.cjs'),str(n/'build/user-administration-reference.json')],check=True)
reference=json.loads((n/'build/user-administration-reference.json').read_text())
binary=n/'build/NativeUserAdministrationTests'
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','Security','-lsqlite3',*map(str,files),'-o',str(binary)],check=True)
r=subprocess.run([str(binary),str(n)],text=True,capture_output=True,timeout=90)
print(r.stdout,end='');print(r.stderr[:5000],end='')
stable=before=={p.name:sha(p)for p in watched} and all(sha(n.parent.parent/p)==h for p,h in reference['sourceSHA256'].items())
proof={'inputsSHA256':before,'inputsUnchanged':stable,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr[:5000],'binaryBytes':binary.stat().st_size,'sourceSHA256':reference['sourceSHA256'],'prismaDDL_SHA256':sha(ddl),'prismaConfigSHA256':sha(config),'databaseConnectionRequired':False,'originalScenarios':len(reference['scenarios']),'originalSteps':sum(len(x['steps'])for x in reference['scenarios']),'intentionalNativeDifferences':['Safe allow-listed user DTOs and bounded directory pages; thrown directory AuthenticationError translated for Japanese UI.','Current native identity includes banned/role/partner-account fence and reauth after await.','All native mutations have required safe audit and transactional rollback; original audit helper is best effort and most actions do not audit.','Activation retains ACTIVE on SMTP failure, reports failed/notConfigured explicitly; invitation configuration and send failure ordering follows source.','Notification gateway is injected, not a production mail worker; identity provider/native sign-in URL and runtime outbox remain integration gates.'],'scope':'Actual original TS actions/authz via synthetic Prisma and fake mail; real SQLite native constraints, nullification revisions/timestamps/hooks, transaction rollback, authority and token re-evaluation. No live PostgreSQL/SMTP/Resend/identity-provider/normal user data.'}
(n/'build/user-administration-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
assert r.returncode==0 and stable
