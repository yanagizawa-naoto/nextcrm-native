// In-process HTTP requests against the installed SDK used by mcp-handler.
// No listener, network, credentials or real CRM handler is involved.
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const assert = require('node:assert/strict');
const {z} = require('zod');
const {McpServer} = require('@modelcontextprotocol/sdk/server/mcp.js');
const {WebStandardStreamableHTTPServerTransport} = require('@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js');
const root = path.resolve(__dirname, '../..');
const request = (id, method, params) => ({jsonrpc:'2.0',id,method,...(params === undefined ? {} : {params})});
const cases = [
  {label:'initialize', body:request(1,'initialize',{protocolVersion:'2025-03-26',capabilities:{},clientInfo:{name:'native-reference',version:'1'}})},
  {label:'initialize-unknown-version', body:request(2,'initialize',{protocolVersion:'unsupported',capabilities:{},clientInfo:{name:'native-reference',version:'1'}})},
  {label:'list-without-session', body:request('list','tools/list')},
  {label:'call-without-session', body:request(3,'tools/call',{name:'fixture_echo',arguments:{text:'日本語'}})},
  {label:'invalid-arguments', body:request(4,'tools/call',{name:'fixture_echo',arguments:{text:3}})},
  {label:'unknown-tool', body:request(5,'tools/call',{name:'missing',arguments:{}})},
  {label:'unknown-method', body:request(6,'not/a/method')},
  {label:'ping', body:request(7,'ping')},
  {label:'notification', body:{jsonrpc:'2.0',method:'notifications/initialized'}},
  {label:'invalid-json', raw:'{'},
  {label:'empty-batch', body:[]},
  {label:'batch', body:[request(8,'ping'),request(9,'ping')]},
  {label:'bad-envelope', body:{method:'ping',id:10}},
  {label:'missing-sse-accept', accept:'application/json', body:request(11,'ping')},
  {label:'wrong-content-type', contentType:'text/plain', body:request(12,'ping')},
  {label:'unsupported-protocol-header', version:'unsupported', body:request(13,'ping')},
  {label:'get-stateless', method:'GET'},
  {label:'delete-stateless', method:'DELETE'},
];
(async () => {
  const output = [];
  for (const item of cases) {
    const transport = new WebStandardStreamableHTTPServerTransport({sessionIdGenerator:undefined});
    const server = new McpServer({name:'NextCRM native reference',version:'0'}, {capabilities:{tools:{}}});
    server.tool('fixture_echo','Echo a synthetic test value',{text:z.string()},async args => ({content:[{type:'text',text:JSON.stringify(args)}]}));
    await server.connect(transport);
    const headers = {'content-type':item.contentType ?? 'application/json',accept:item.accept ?? 'application/json, text/event-stream'};
    if (item.version) headers['mcp-protocol-version'] = item.version;
    const response = await transport.handleRequest(new Request('http://localhost/api/mcp/mcp', {
      method:item.method ?? 'POST', headers,
      ...(item.method ? {} : {body:item.raw ?? JSON.stringify(item.body)}),
    }));
    // A GET may start a standalone stream; do not await unbounded text.
    const text = item.method === 'GET' && response.status === 200 ? null : await response.text();
    if (text === null) await response.body?.cancel();
    let messages;
    if (response.headers.get('content-type')?.startsWith('text/event-stream')) {
      messages = text === null ? [] : text.split('\n').filter(s => s.startsWith('data: ')).map(s => JSON.parse(s.slice(6)));
    } else { try { messages = text ? [JSON.parse(text)] : []; } catch { messages = []; } }
    output.push({label:item.label,request:{method:item.method ?? 'POST',headers,body:item.method ? null : item.raw ?? JSON.stringify(item.body)},status:response.status,contentType:response.headers.get('content-type'),sessionID:response.headers.get('mcp-session-id'),messages,body:text});
    await server.close();
  }
  const by = Object.fromEntries(output.map(x => [x.label,x]));
  assert.equal(by.initialize.status,200);
  assert.equal(by['list-without-session'].messages[0].result.tools[0].name,'fixture_echo');
  assert.equal(by['call-without-session'].messages[0].result.content[0].text,'{"text":"日本語"}');
  assert.ok(output.every(x => x.sessionID === null));
  assert.equal(by.notification.status,202);
  assert.equal(by['missing-sse-accept'].status,406);
  assert.equal(by['wrong-content-type'].status,415);
  const watched = ['node_modules/mcp-handler/dist/index.js','node_modules/@modelcontextprotocol/sdk/dist/cjs/server/webStandardStreamableHttp.js'];
  const artifact = {scope:'Installed SDK stateless HTTP envelope/protocol only; original123 tool schemas/handlers, auth and native transport pending',cases:output,
    sourceSHA256:Object.fromEntries(watched.map(f => [f,crypto.createHash('sha256').update(fs.readFileSync(path.join(root,f))).digest('hex')]))};
  fs.writeFileSync(process.argv[2],JSON.stringify(artifact,null,2)+'\n');
  console.log(JSON.stringify({protocolCases:output.length,statuses:Object.fromEntries(output.map(x => [x.label,x.status]))}));
})().catch(error => {console.error(error);process.exitCode=1;});
