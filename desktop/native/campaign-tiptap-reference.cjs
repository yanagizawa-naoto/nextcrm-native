const fs=require('fs'),path=require('path'),crypto=require('crypto');
const {createRequire}=require('module');const root=path.resolve(__dirname,'../..');const output=path.join(__dirname,'build','campaign-tiptap');fs.mkdirSync(output,{recursive:true});const req=createRequire(path.join(root,'package.json'));
const ts=req('typescript'),esbuild=createRequire(req.resolve('tsx'))('esbuild');
const src=path.join(root,'components/campaigns/TipTapEditor.tsx'),text=fs.readFileSync(src,'utf8'),ast=ts.createSourceFile(src,text,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX);
let extensions;function visit(n){if(ts.isPropertyAssignment(n)&&n.name.getText(ast)==='extensions')extensions=n.initializer.getText(ast);ts.forEachChild(n,visit)}visit(ast);if(!extensions)throw Error('Actual extensions not found');
let imports=[];for(const n of ast.statements){if(ts.isImportDeclaration(n)&&n.moduleSpecifier.text.startsWith('@tiptap/')&&n.moduleSpecifier.text!=='@tiptap/react') imports.push(n.getText(ast));}
const coreFile=path.join(path.dirname(createRequire(req.resolve('@tiptap/react')).resolve('@tiptap/core')),'index.js');
const core='./'+path.relative(root,coreFile).split(path.sep).join('/');
const entry=imports.join('\n')+`\nimport {Editor} from ${JSON.stringify(core)};\nconst extensions=${extensions};\n`+String.raw`
window.runTipTap=(fixtures)=>{
 const out=[];
 const snapshot=content=>{const editor=new Editor({element:document.createElement('div'),extensions,content});const result={html:editor.getHTML(),json:editor.getJSON()};editor.destroy();return result;};
 for(const f of fixtures){
 let updates=0;const editor=new Editor({element:document.createElement('div'),extensions,content:f.html??'',onUpdate(){updates++}});
 const canonical={html:editor.getHTML(),json:editor.getJSON()};
 const row={id:f.id,source:canonical,initialUpdates:updates};
 if(f.nativeHTML!==undefined)row.nativeHTML=snapshot(f.nativeHTML);
 if(f.nativeJSON!==undefined){try{const doc=editor.schema.nodeFromJSON(JSON.parse(f.nativeJSON));doc.check();row.nativeJSON={valid:true,...snapshot(doc.toJSON())};}catch(e){row.nativeJSON={valid:false,error:String(e)}}}
 if(f.knownURLNormalization){const a=document.createElement('a'),b=document.createElement('a');a.href=f.knownURLNormalization.from;b.href=f.knownURLNormalization.to;row.urlSemantics={sourceURL:a.href,nativeURL:b.href,equal:a.href===b.href};}
 row.sourceJSONRound=snapshot(canonical.json);row.sourceHTMLRound=snapshot(canonical.html);
 editor.commands.insertContentAt(editor.state.doc.content.size,{type:'paragraph',content:[{type:'text',text:'追記'}]});row.edited={html:editor.getHTML(),json:editor.getJSON(),updates};
 editor.destroy();out.push(row);
 }return {rows:out,userAgent:navigator.userAgent};
};`;
const built=esbuild.buildSync({stdin:{contents:entry,resolveDir:root,sourcefile:'actual-extensions.ts',loader:'ts'},bundle:true,write:false,platform:'browser',format:'iife',target:'es2020',metafile:true,logLevel:'silent'});
fs.writeFileSync(path.join(output,'source.js'),built.outputFiles[0].contents);
const sha=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');const hashes={};for(const n of Object.keys(built.metafile.inputs)){if(n==='actual-extensions.ts')continue;const f=path.resolve(root,n);if(fs.existsSync(f))hashes[path.relative(root,f)]=sha(f)}
for(const f of [src,path.join(root,'pnpm-lock.yaml')])hashes[path.relative(root,f)]=sha(f);
fs.writeFileSync(path.join(output,'source-inputs.json'),JSON.stringify({extensions,imports,sourceHashes:hashes,sourceBundleSHA256:sha(path.join(output,'source.js')),downloads:false},null,2)+'\n');
console.log('Actual TipTap extensions bundled: '+Object.keys(hashes).length+' installed/source inputs');
