// Read-only TypeScript loader for original-source tests. All external boundaries
// must be supplied as mocks; importing this file never writes generated files.
const fs=require('node:fs'),path=require('node:path'),Module=require('node:module'),crypto=require('node:crypto'),ts=require('typescript');
function createSourceLoader(mocks={},options={}){
 const root=options.root??path.resolve(__dirname,'../..'),cache=new Map(),hashes={};
 function load(relative){
  if(Object.hasOwn(mocks,relative))return typeof mocks[relative]==='function'?mocks[relative]():mocks[relative];
  let file=relative.startsWith('@/')?path.join(root,relative.slice(2)):relative==='@nextcrm/plugin-sdk'?path.join(root,'packages/plugin-sdk/src/index.ts'):path.resolve(root,relative);
  if(!path.extname(file))file+='.ts';if(cache.has(file))return cache.get(file).exports;
  const logical=path.relative(root,file);if(Object.hasOwn(mocks,logical))return typeof mocks[logical]==='function'?mocks[logical]():mocks[logical];
  const source=fs.readFileSync(file,'utf8');hashes[path.relative(root,file)]=crypto.createHash('sha256').update(source).digest('hex');
  if(file.endsWith('.json'))return JSON.parse(source);
  const mod=new Module(file,module);mod.filename=file;mod.paths=Module._nodeModulePaths(path.dirname(file));cache.set(file,mod);
  mod.require=id=>{
   if(Object.hasOwn(mocks,id))return typeof mocks[id]==='function'?mocks[id]():mocks[id];
   if(id.startsWith('.'))return load(path.resolve(path.dirname(file),id));
   if(id.startsWith('@/')||id==='@nextcrm/plugin-sdk')return load(id);
   if(options.resolve){const result=options.resolve(id,file);if(result!==undefined)return result;}
   return require(id);
  };
  mod._compile(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,esModuleInterop:true,jsx:ts.JsxEmit.ReactJSX}}).outputText,file);
  return mod.exports;
 }
 return {load,hashes,cache,root};
}
module.exports={createSourceLoader};
