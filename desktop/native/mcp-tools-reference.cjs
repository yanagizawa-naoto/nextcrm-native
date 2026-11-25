// Load only the source MCP definitions and helpers. All other application
// imports are blocked, and no CRM handler is ever invoked by this generator.
const fs = require('node:fs'), path = require('node:path'), Module = require('node:module');
const ts = require('typescript'), crypto = require('node:crypto'), assert = require('node:assert/strict');
const {McpServer} = require('@modelcontextprotocol/sdk/server/mcp.js');
const {WebStandardStreamableHTTPServerTransport} = require('@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js');
const root = path.resolve(__dirname, '../..'), allowed = path.join(root,'lib/mcp') + path.sep;
const cache = new Map(), hashes = {};
function load(filename) {
  filename = path.resolve(filename);
  assert.ok(filename.startsWith(allowed) && filename.endsWith('.ts'));
  if (cache.has(filename)) return cache.get(filename).exports;
  const source = fs.readFileSync(filename,'utf8'), mod = new Module(filename,module);
  cache.set(filename,mod); mod.filename = filename;
  hashes[path.relative(root,filename)] = crypto.createHash('sha256').update(source).digest('hex');
  mod.require = name => {
    if (name === 'zod') return require('zod');
    if (name.startsWith('.')) return load(path.resolve(path.dirname(filename),name + '.ts'));
    return new Proxy({}, {get(_,field) {
      if (field === '__esModule') return true;
      // Activity definitions store permission functions in a dispatch table.
      // Taking those references is safe; invoking one is still prohibited.
      if (name === '@/lib/authz/scopes/crm' && /^assertCanWrite(Account|Contact|Contract|Lead|Opportunity|Task)$/.test(String(field))) {
        return () => { throw Error('Reference invoked blocked permission handler: ' + String(field)); };
      }
      throw Error('Blocked runtime dependency during schema extraction: ' + name + '.' + String(field));
    }});
  };
  mod._compile(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,filename);
  return mod.exports;
}
async function main() {
  const {allTools} = load(path.join(root,'lib/mcp/tools/index.ts'));
  const inventory = JSON.parse(fs.readFileSync(path.join(__dirname,'mcp-api-next.json'),'utf8'));
  const expected = inventory.sourceInventory.flatMap(x => x.groups.flatMap(g => g.toolNames)).sort();
  assert.deepEqual(allTools.map(x => x.name).sort(),expected);
  assert.equal(new Set(expected).size,123);
  const transport = new WebStandardStreamableHTTPServerTransport({sessionIdGenerator:undefined});
  const server = new McpServer({name:'NextCRM source schema reference',version:'0'},{capabilities:{tools:{}}});
  for (const tool of allTools) server.tool(tool.name,tool.description,tool.schema.shape,async () => { throw Error('Reference must never call a tool'); });
  await server.connect(transport);
  const response = await transport.handleRequest(new Request('http://localhost/api/mcp/mcp',{method:'POST',
    headers:{accept:'application/json, text/event-stream','content-type':'application/json'},
    body:JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/list'})}));
  assert.equal(response.status,200);
  const events = (await response.text()).split('\n').filter(x => x.startsWith('data: ')).map(x => JSON.parse(x.slice(6)));
  const tools = events[0].result.tools;
  assert.deepEqual(tools.map(x => x.name).sort(),expected);
  const samples = [{}, {limit:0,offset:-1}, {limit:100,offset:0,__unknown:'strip-me'}];
  const validation = allTools.map(tool => ({name:tool.name,cases:samples.map(input => {
    const result = tool.schema.safeParse(input);
    return result.success ? {input,data:result.data} : {input,issues:result.error.issues};
  })}));
  await server.close();
  const artifact = {scope:'Actual source schemas through original server.tool registration and installed SDK; handlers never executed and native dispatch remains pending',
    toolCount:tools.length,tools,validation,sourceSHA256:hashes};
  fs.writeFileSync(process.argv[2],JSON.stringify(artifact,null,2)+'\n');
  console.log(JSON.stringify({registeredTools:tools.length,uniqueTools:new Set(tools.map(x=>x.name)).size,sourceModules:Object.keys(hashes).length,validationSamples:validation.length*samples.length}));
}
module.exports = { load, root, hashes, getTools: () => load(path.join(root, 'lib/mcp/tools/index.ts')).allTools };
if (require.main === module) main().catch(error => {console.error(error);process.exitCode=1;});
