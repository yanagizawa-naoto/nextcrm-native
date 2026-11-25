'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),readline=require('node:readline');
const {CalendarRelayStore,createHTTPServer}=require('../calendar-relay/relay.cjs');
const root=path.resolve(process.argv[2]),authKey=Buffer.alloc(32,31).toString('base64url');fs.mkdirSync(root,{recursive:true,mode:0o700});
const store=new CalendarRelayStore(path.join(root,'relay.sqlite'),authKey),server=createHTTPServer({store,basePath:'/crm'});let index=store.head();
const ordinary=server.listeners('request')[0];server.removeAllListeners('request');server.on('request',(req,res)=>{if(req.url==='/slow'){res.writeHead(200,{'Content-Type':'application/json'});let chunks=0;const timer=setInterval(()=>{res.write(Buffer.alloc(65536,32));if(++chunks===512){clearInterval(timer);res.end();}},5);res.on('close',()=>clearInterval(timer));}else ordinary(req,res);});
server.listen(Number(process.argv[3]??0),'127.0.0.1',()=>console.log(JSON.stringify({url:`http://127.0.0.1:${server.address().port}/crm`,instanceId:store.identity().instanceId})));
function payload(i,kind='invitee.created',size=0){let object={event:kind,payload:{uri:`https://api.calendly.com/scheduled_events/testing/invitees/${i}`,email:'customer@external.invalid',name:'日本語のお客様',scheduled_event:{name:'Calendly予約 '+i,start_time:'2027-01-15T10:00:00.000Z',end_time:'2027-01-15T10:30:00.000Z',event_memberships:[{user_email:'host@example.invalid'}]}}};object.padding='';object.padding='x'.repeat(Math.max(0,size-Buffer.byteLength(JSON.stringify(object))));return Buffer.from(JSON.stringify(object));}
const lines=readline.createInterface({input:process.stdin});let queue=Promise.resolve();
lines.on('line',line=>{queue=queue.then(async()=>{const command=JSON.parse(line);if(command.action==='stop'){lines.close();server.close(()=>{store.close();process.exit(0);});server.closeAllConnections();return;}
 if(command.action==='seed'||command.action==='cancel'){
  const count=command.action==='cancel'?1:command.count,key=store.open(store.meta('signing_key'),'signing-key').toString();
  for(let n=0;n<count;n++){const raw=payload(command.action==='cancel'?command.id:++index,command.action==='cancel'?'invitee.canceled':'invitee.created',command.bytes||0),t=String(Math.floor(Date.now()/1000)),signature=`t=${t},v1=${crypto.createHmac('sha256',key).update(t+'.').update(raw).digest('hex')}`;
   const response=await fetch(`http://127.0.0.1:${server.address().port}/crm/api/crm/calendar/webhooks/calendly`,{method:'POST',headers:{'calendly-webhook-signature':signature},body:raw});if(response.status!==200)throw Error('callback status '+response.status);await response.arrayBuffer();
  }
 }
 console.log(JSON.stringify({head:store.head(),instanceId:store.identity().instanceId}));}).catch(error=>{console.error(error.message);process.exitCode=1;lines.close();server.close(()=>{store.close();process.exit(1);});server.closeAllConnections();});});
