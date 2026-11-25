#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,subprocess
n=Path(__file__).resolve().parent
names=['NativeDatabase', 'CRMModules', 'InvoiceModules', 'CatalogModules', 'LineItemModules', 'LineItemMath', 'CRMLineItems', 'CRMCatalog', 'ProductCSV', 'PricingEngine', 'CRMService', 'OrderModules', 'OrderWorkflow', 'OrderDraftStore', 'CRMOrders', 'InvoiceMath', 'NativeAPITokens', 'NativeUserAdministration', 'NativeUserCredentialCleanup', 'NativeUserAdministrationMail', 'NativeUserAvatarStore', 'NativeUserAvatarAnimation', 'NativeUserAvatarWebPAnimation', 'NativeUserAvatarAPNGAnimation', 'NativeUserAvatarWorkerProtocol', 'NativeUserAvatarWorkerClient', 'NativeUserAvatarView', 'NativeUserAdministrationWindow', 'NativeSheetTermination', 'NativeUserAdministrationWindowTests', 'NativeOperationalAssets', 'MailReview']
files=[n/(x+'.swift')for x in names];watched=files+[n/'schema.json',n/'schema.sql',Path(__file__).resolve()]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before={p.name:sha(p)for p in watched};binary=n/'build/NativeUserAdministrationWindowTests'
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','AppKit','-framework','ImageIO','-framework','UniformTypeIdentifiers','-framework','Security','-lsqlite3',*map(str,files),'-o',str(binary)],check=True)
r=subprocess.run([str(binary),str(n)],text=True,capture_output=True,timeout=90);print(r.stdout,end='');print(r.stderr[:5000],end='')
stable=before=={p.name:sha(p)for p in watched}
(n/'build/user-administration-ui-verification.json').write_text(json.dumps({'inputsSHA256':before,'inputsUnchanged':stable,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr[:5000],'binaryBytes':binary.stat().st_size,'scope':'Real AppKit selectors/tables/forms against isolated SQLite; injected fake mail only, local photo preview/cancel/commit/reopen/delete/rollback/concurrent change guards with generated images. App menu wiring, animated codecs and live providers are verified separately.'},ensure_ascii=False,indent=2)+'\n')
assert r.returncode==0 and stable
