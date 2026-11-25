const fs=require('fs'),path=require('path'),vm=require('vm'),crypto=require('crypto');
const root=path.resolve(__dirname,'../..'),out=path.resolve(process.argv[2]);
const localRequire=require('module').createRequire(path.join(root,'package.json'));
const ts=localRequire('typescript');
function evaluate(filename,requireFunction=localRequire){const module={exports:{}};vm.runInNewContext(ts.transpileModule(fs.readFileSync(filename,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS,esModuleInterop:true}}).outputText,{module,exports:module.exports,require:requireFunction,Buffer,console,process:{env:{}}});return module.exports;}
async function main(){
 const textPath=path.join(root,'inngest/lib/document-text.ts'),thumbPath=path.join(root,'inngest/functions/documents/generate-thumbnail.ts');
 const {extractDocumentText}=evaluate(textPath),inputs=JSON.parse(fs.readFileSync(path.join(out,'fixtures/inputs.json')));let current,thumbnail;
 const req=name=>{
  if(name==='@/inngest/client')return {inngest:{createFunction:(_options,handler)=>handler}};
  if(name==='@/lib/prisma')return {prismadb:{documents:{findUnique:async()=>({id:'synthetic',key:current.path,document_file_mimeType:current.mime}),update:async()=>({})}}};
  if(name==='@aws-sdk/client-s3')return {GetObjectCommand:class{constructor(x){this.get=x}},PutObjectCommand:class{constructor(x){this.put=x}}};
  if(name==='@/lib/minio')return {MINIO_BUCKET:'fixture',MINIO_PUBLIC_URL:'https://example.invalid',minioClient:{send:async command=>{if(command.put){thumbnail=command.put.Body;return {}}return {Body:fs.createReadStream(current.path)}}}};
  if(name==='@/lib/local-storage')return {usesLocalStorage:()=>false};
  if(name==='@/inngest/lib/temporary-input')return {withTemporaryInput:()=>{throw Error('unselected branch')}};
  return localRequire(name);
 };
 const {generateDocumentThumbnail}=evaluate(thumbPath,req);let results=[];
 for(const item of inputs){current=item;thumbnail=null;let result={...item};try{result.text=await extractDocumentText(item.mime,async()=>fs.createReadStream(item.path));result.thumbnailResult=await generateDocumentThumbnail({event:{data:{documentId:'synthetic'}}});if(thumbnail){let target=path.join(out,'fixtures',item.name+'.source.png');fs.writeFileSync(target,thumbnail);const m=await localRequire('sharp')(thumbnail).metadata();result.thumbnail={width:m.width,height:m.height,format:m.format};}}catch(error){result.error=String(error)}results.push(result)}
 const watched=[textPath,thumbPath,path.join(root,'pnpm-lock.yaml'),...['mammoth','sharp','typescript'].map(n=>path.join(root,'node_modules',n,'package.json'))];
 fs.writeFileSync(path.join(out,'source.json'),JSON.stringify({results,sourceSHA256:Object.fromEntries(watched.map(p=>[path.relative(root,p),crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex')])),scope:'Actual original document text/thumbnail handlers; synthetic Prisma/object adapters; installed parsers; no network.'},null,2)+'\n');
 console.log(JSON.stringify({sourceCases:results.length,errors:results.filter(x=>x.error).length}));
}
main().catch(e=>{console.error(e);process.exitCode=1});
