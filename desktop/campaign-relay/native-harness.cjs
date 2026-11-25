// Local-only native transport test process. All keys and IDs here are fixtures.
const {RelayStore,createHTTPServer}=require('./relay.cjs');
const store=new RelayStore(process.argv[2]);
const clock=process.argv[3]==='realtime'?Date.now:()=>Date.parse('2026-11-14T10:00:00.125Z');
const server=createHTTPServer({store,authKey:Buffer.alloc(32,7).toString('base64url'),webhookSecret:'whsec_'+Buffer.from('relay-fixture-signing-key-not-real').toString('base64'),basePath:'/crm',clock});
server.listen(0,'127.0.0.1',()=>process.stdout.write(JSON.stringify({port:server.address().port,instanceId:store.meta('instance_id')})+'\n'));
process.on('SIGTERM',()=>{server.close(()=>{store.close();process.exit(0);});server.closeAllConnections();});
