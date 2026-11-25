const fs=require('fs'),path=require('path'),crypto=require('crypto');
const {createSourceLoader}=require('./plugins-source-loader.cjs');
const sha=x=>crypto.createHash('sha256').update(x).digest('hex');
let sourceEvents=[],saved=[],connection;let responses=[],index=0;
const loader=createSourceLoader({
 '@/inngest/client':{inngest:{createFunction:(_config,handler)=>handler,send:async e=>{saved.push(e.data)}}},
 '@/lib/prisma':{prismadb:{calendarConnection:{findUnique:async()=>connection,update:async({data})=>Object.assign(connection,data)}}},
 '@/lib/crm/calendar/google':{getCalendarClientForConnection:()=>({events:{list:async()=>({data:responses[index++]})}})},
 '@/lib/crm/calendar/sync':{upsertCalendarEvent:async e=>{saved.push(e);return{action:'created'}}},
 '@/lib/crm/calendar/calendly-settings':{getCalendlySettings:async()=>({signingKey:'synthetic'})},
 'next/server':{NextResponse:{json:(body,options)=>({body,status:options?.status??200})}}
},{root:process.cwd()});
const google=loader.load('inngest/functions/calendar/google-sync-connection.ts').googleCalendarSyncConnection;
const calendly=loader.load('app/api/crm/calendar/webhooks/calendly/route.ts').POST;
const event=id=>({id,summary:'日本語の予定😀',start:{dateTime:'2027-01-15T10:00:00.000Z'},attendees:[{email:'client@external.invalid'}]});
(async()=>{const googleCases=[],calendlyCases=[];
 for(const size of [1048575,1048576,1048577]){
  const e={...event('size-'+size),description:''};e.description='x'.repeat(size-Buffer.byteLength(JSON.stringify(e)));connection={id:'test',accountEmail:'rep@example.invalid',isActive:true,syncToken:null};responses=[{items:[e],nextSyncToken:'large'}];index=0;saved=[];
  const result=await google({event:{data:{connectionId:'test'}},step:{run:(_n,fn)=>fn()}});
  googleCases.push({id:e.id,bytes:Buffer.byteLength(JSON.stringify(e)),accepted:saved.length===1,descriptionSHA256:sha(saved[0].rawPayload.description),descriptionBytes:Buffer.byteLength(saved[0].rawPayload.description),title:saved[0].title,cursor:connection.syncToken,result});
 }
 connection={id:'test',accountEmail:'rep@example.invalid',isActive:true,syncToken:null};responses=[{items:Array.from({length:17},(_,i)=>({...event('page-'+i),description:'z'.repeat(1048576)})),nextSyncToken:'over16MiB'}];index=0;saved=[];
 const largeBytes=Buffer.byteLength(JSON.stringify(responses[0])),result=await google({event:{data:{connectionId:'test'}},step:{run:(_n,fn)=>fn()}});
 const largePage={bytes:largeBytes,accepted:saved.length===17,events:saved.length,descriptionBytes:saved.map(e=>Buffer.byteLength(e.rawPayload.description)),cursor:connection.syncToken,result};
 for(const size of [1048575,1048576,1048577,2097153]){
  const e={event:'invitee.created',payload:{uri:'large-'+size,name:'検証 予約',email:'client@external.invalid',scheduled_event:{name:'面談',start_time:'2027-01-15T10:00:00Z'}},padding:''};e.padding='x'.repeat(size-Buffer.byteLength(JSON.stringify(e)));const raw=JSON.stringify(e),t=String(Math.floor(Date.now()/1000)),signature='t='+t+',v1='+crypto.createHmac('sha256','synthetic').update(t+'.'+raw).digest('hex');saved=[];
  const response=await calendly({text:async()=>raw,headers:{get:()=>signature}});
  calendlyCases.push({id:e.payload.uri,bytes:Buffer.byteLength(raw),accepted:response.status===200&&saved.length===1,paddingSHA256:sha(saved[0].rawPayload.padding),paddingBytes:Buffer.byteLength(saved[0].rawPayload.padding),title:saved[0].title});
 }
 const proof={googleCases,largePage,calendlyCases,sourceHashes:loader.hashes,networkCalls:0};fs.writeFileSync(path.join(process.argv[2]||__dirname,'reference.json'),JSON.stringify(proof,null,2));console.log(JSON.stringify({google:googleCases.length,largePage:largePage.events,calendly:calendlyCases.length}));
})().catch(e=>{console.error(e);process.exitCode=1});
