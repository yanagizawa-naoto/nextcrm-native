#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,subprocess,struct,zlib
n=Path(__file__).resolve().parent
names=['NativeDatabase', 'CRMModules', 'InvoiceModules', 'CatalogModules', 'LineItemModules', 'LineItemMath', 'CRMLineItems', 'CRMCatalog', 'ProductCSV', 'PricingEngine', 'CRMService', 'OrderModules', 'OrderWorkflow', 'OrderDraftStore', 'CRMOrders', 'InvoiceMath', 'NativeUserAvatarStore', 'NativeUserAvatarAnimation', 'NativeUserAvatarWebPAnimation', 'NativeUserAvatarAPNGAnimation', 'NativeUserAvatarWorkerProtocol', 'NativeUserAvatarWorkerClient', 'NativeUserAvatarView', 'NativeUserAvatarStoreTests', 'NativeOperationalAssets', 'MailReview']
files=[n/(x+'.swift')for x in names];watched=files+[n/'schema.json',n/'schema.sql',n/'user-avatar-reference.cjs',n/'plugins-source-loader.cjs',Path(__file__).resolve()]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before={p.name:sha(p)for p in watched}
subprocess.run(['node',str(n/'user-avatar-reference.cjs'),str(n/'build/user-avatar-reference.json')],check=True)
subprocess.run(['node','-e',"require('sharp')({create:{width:32,height:24,channels:4,background:'#00ff00'}}).webp({lossless:true}).toFile(process.argv[1])",str(n/'build/user-avatar-webp.webp')],check=True,cwd=n.parent.parent)
def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
compress=zlib.compressobj();compressed=bytearray();row=b'\0'+b'\0'*4096*4
for _ in range(4097):compressed.extend(compress.compress(row))
compressed.extend(compress.flush())
(n/'build/user-avatar-pixel-limit.png').write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',4096,4097,8,6,0,0,0))+chunk(b'IDAT',compressed)+chunk(b'IEND',b''))
binary=n/'build/NativeUserAvatarStoreTests'
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','AppKit','-framework','ImageIO','-framework','UniformTypeIdentifiers','-lsqlite3',*map(str,files),'-o',str(binary)],check=True)
r=subprocess.run([str(binary),str(n)],text=True,capture_output=True,timeout=90);print(r.stdout,end='');print(r.stderr[:5000],end='')
reference=json.loads((n/'build/user-avatar-reference.json').read_text());stable=before=={p.name:sha(p)for p in watched} and all(sha(n.parent.parent/p)==h for p,h in reference['sourceSHA256'].items())
proof={'inputsSHA256':before,'inputsUnchanged':stable,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr[:5000],'binaryBytes':binary.stat().st_size,'sourceSHA256':reference['sourceSHA256'],'sourceCases':len(reference['cases']),'limits':{'inputBytes':4194304,'sourcePixels':16777216,'sourceDimension':16384,'decodeThumbnailSide':512,'storedSquareSide':256,'storedFileBytes':1048576},'intentionalNativeDifferences':['Local immutable private files replace signed HTTP uploads; current identity and avatar-value CAS wrap metadata commit.','Actual content decoding, symlink/hardlink checks, 16,777,216-pixel/16384-dimension cap strengthen source MIME and client-only 4 MiB checks.','Exact input bytes remain in a private immutable original plus an orientation-corrected center-square 256px PNG derivative. The stored thumbnail is static; visibility-gated playback of the retained original is verified by separate animation runners.','Original and thumbnail publish before one metadata CAS; cancel/failure/replace/GC handle their bundle together. Replaced bytes remain while any Users.avatar references them; startup GC recovers crash orphans.','ImageUpload model is currently unused; no invented bookkeeping row.'],'scope':'Actual source presign/GET/content-type functions with mocked storage/session; real ImageIO/AppKit/SQLite/POSIX file effects using generated fixtures, no HTTP or normal application data. Profile sheet preview/save/clear hookup belongs to root integration.'}
(n/'build/user-avatar-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');assert r.returncode==0 and stable
