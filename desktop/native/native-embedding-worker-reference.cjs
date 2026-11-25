// Run original worker handlers with fake Prisma/provider; never access network.
const fs = require('node:fs'), path = require('node:path'), Module = require('node:module'), ts = require('typescript');
function load(file, overrides = {}) {
  const filename = path.resolve(__dirname, '../..', file), mod = new Module(filename, module);
  mod.filename = filename; mod.paths = Module._nodeModulePaths(path.dirname(filename));
  const fallback = mod.require.bind(mod); mod.require = name => name in overrides ? overrides[name] : fallback(name);
  mod._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8'), {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText, filename);
  return mod.exports;
}
async function main() {
  process.env.OPENAI_API_KEY = 'qa-never-sent';
  const utils = load('inngest/lib/embedding-utils.ts'), cases = [];
  const fields = {account:['name','description','email'],contact:['first_name','last_name','position','email'],lead:['firstName','lastName','description'],opportunity:['name','description','stage'],email:['subject','bodyText','fromEmail']};
  for (const [kind,names] of Object.entries(fields)) for (const values of [[' 株式会社 日本 ',null,'担当者\n山田','営業@example.invalid'],['\uFEFF','\u0085','か\u3099 👩‍💻','　']]) {
    const input = Object.fromEntries(names.map((name,i)=>[name,values[i]])), row = {id:'fixture',...input};
    for (const required of ['last_name','lastName']) if (required in input && input[required] === null) input[required] = row[required] = '山田';
    if (kind === 'opportunity') row.assigned_sales_stage = {name:input.stage};
    let text, hash;
    const prisma = new Proxy({}, {get:(_,name)=>name === '$executeRaw' ? async (_, ...args) => {hash=args[2];} : {findUnique:async ()=>String(name).toLowerCase().includes('embedding') ? null : row}});
    const result = load(`inngest/functions/${kind === 'email' ? 'emails/' : ''}embed-${kind}.ts`, {
      '@/inngest/client':{inngest:{createFunction:(_,fn)=>fn}}, '@/lib/prisma':{prismadb:prisma},
      '@/inngest/lib/embedding-utils':{...utils,generateEmbedding:async value=>{text=value;return [1];}},
    });
    await Object.values(result)[0]({event:{data:{record_id:'fixture',emailId:'fixture'}}});
    if (text === undefined || hash === undefined) throw Error('Original worker did not embed fixture');
    cases.push({kind,input,text,hash});
  }
  fs.writeFileSync(process.argv[2],JSON.stringify({cases},null,2)+'\n');
}
main().catch(error=>{console.error(error);process.exitCode=1;});
