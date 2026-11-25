// Execute the original document enrichment handler and chunk iterator, with
// local fake storage and provider implementations. No network or downloads.
const fs=require('node:fs'),path=require('node:path'),Module=require('node:module'),ts=require('typescript');
function load(file,overrides={}) {
  const filename=path.resolve(__dirname,'../..',file),mod=new Module(filename,module);
  mod.filename=filename;mod.paths=Module._nodeModulePaths(path.dirname(filename));
  const fallback=mod.require.bind(mod);mod.require=name=>name in overrides?overrides[name]:fallback(name);
  mod._compile(ts.transpileModule(fs.readFileSync(filename,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,filename);return mod.exports;
}
async function main() {
  const textUtils=load('inngest/lib/document-text.ts'),embeddingUtils=load('inngest/lib/embedding-utils.ts');
  const encode=value=>Buffer.from(value,'utf8').toString('base64'),cases=[];
  const inputs=[
    {name:'請求書.txt',text:'',configured:true},
    {name:'契約.txt',text:'日本語の契約書です。\n契約期間は一年です。',configured:false},
    {name:'文書.txt',text:'日本語の契約書です。\n契約期間は一年です。',configured:true},
    {name:'境界.txt',text:'a'.repeat(32000),configured:true},
    {name:'長文.txt',text:'あ'.repeat(32001),configured:true},
    {name:'絵文字.txt',text:'a'.repeat(2047)+'😀'+'日か\u3099👩‍💻'.repeat(6000),configured:true},
    {name:'空白.txt',text:' \n\t\uFEFF'.repeat(8200),configured:true},
    {name:'null-summary.txt',text:'要約なしの分類',configured:true,summary:null,classification:'\u0085CONTRACT\u0085'},
  ];
  for(const item of inputs) {
    if(item.configured)process.env.OPENAI_API_KEY='qa-never-sent';else delete process.env.OPENAI_API_KEY;
    const document={id:'fixture',key:'synthetic.txt',document_name:item.name,document_file_mimeType:'text/plain',document_system_type:'OTHER'},embeddings=[],requests=[];
    let fullHash=null;
    const summary='summary' in item?item.summary:'日本語の要約です。内容を確認しました。';
    const category=item.classification??' \uFEFFcontract\n';
    class FakeOpenAI { constructor(){this.chat={completions:{create:async request=>{requests.push(request);return {choices:[{message:{content:requests.length===1?summary:category}}]};}}};} }
    const prisma={documents:{findUnique:async()=>({...document}),update:async({data})=>Object.assign(document,data)},crm_Document_Chunks:{deleteMany:async()=>{}},$executeRaw:async(strings,...args)=>{if(strings.join('').includes('crm_Embeddings_Documents'))fullHash=args[2];}};
    const worker=load('inngest/functions/documents/enrich-document.ts',{
      '@/inngest/client':{inngest:{createFunction:(_,handler)=>handler}},'@/lib/prisma':{prismadb:prisma},
      '@/inngest/lib/embedding-utils':{...embeddingUtils,generateEmbedding:async text=>{embeddings.push(encode(text));return [1];}},
      '@aws-sdk/client-s3':{GetObjectCommand:class{}},'@/lib/minio':{minioClient:{send:()=>{throw Error('unexpected storage request');}},MINIO_BUCKET:'unused'},
      '@/inngest/lib/document-text':{...textUtils,extractDocumentText:async()=>item.text||null},openai:{default:FakeOpenAI},
    });
    const result=await worker.enrichDocument({event:{data:{documentId:'fixture'}},step:{run:(_,action)=>action()}});
    cases.push({name:item.name,text:encode(item.text),configured:item.configured,utf16Count:item.text.length,hash:embeddingUtils.computeContentHash(item.text),embeddings,fullHash,requests:requests.map(r=>({...r,messages:r.messages.map(m=>({...m,content:encode(m.content)}))})),summary:document.summary??null,rawClassification:category,category:document.document_system_type,enriched:result.enriched});
  }
  fs.writeFileSync(process.argv[2],JSON.stringify({cases},null,2)+'\n');
}
main().catch(e=>{console.error(e);process.exitCode=1;});
