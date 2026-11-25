const fs=require('fs'),path=require('path'),crypto=require('crypto');
const {createSourceLoader}=require('./plugins-source-loader.cjs');
let remote,updates,patches;
const activity={id:'activity',createdBy:'owner',type:'meeting',status:'scheduled',deletedAt:null,date:new Date('2050-01-01T10:00:00Z'),duration:30,title:'更新した予定',description:null,links:[]};
const loader=createSourceLoader({
 '@/inngest/client':{inngest:{createFunction:(_config,handler)=>handler}},
 '@/lib/prisma':{prismadb:{crm_Activities:{findUnique:async()=>activity},crm_CalendarEvents:{findMany:async()=>[{source:'google',externalId:'remote',status:'scheduled',connectionId:'connection',startAt:activity.date,rawPayload:{organizer:{self:true}}}],updateMany:async value=>{updates.push(value);return{count:1}}},calendarConnection:{findFirst:async()=>({id:'connection',userId:'owner',provider:'google',isActive:true,scopeLevel:'readwrite'})}}},
 '@/lib/crm/calendar/google':{getCalendarClientForConnection:()=>({events:{patch:async value=>{patches.push(value);return{data:remote}}}})},
 '@/inngest/functions/calendar/google-sync-connection':{isAuthRevocationError:()=>false}
},{root:process.cwd()});
const handler=loader.load('inngest/functions/calendar/outbound-sync.ts').calendarOutboundSync;
(async()=>{const cases=[];for(const bytes of [1048575,1048576,1048577]){
 remote={id:'remote',providerPayload:''};remote.providerPayload='x'.repeat(bytes-Buffer.byteLength(JSON.stringify(remote)));updates=[];patches=[];
 const result=await handler({event:{data:{activityId:'activity',action:'upsert'}},step:{run:(_name,fn)=>fn()}});
 cases.push({bytes,accepted:result.pushed===true&&result.did==='patch',providerWrites:patches.length,mappingWrites:updates.length,attendeesOmitted:!Object.hasOwn(patches[0].requestBody,'attendees')});
}
const out=process.argv[2]??__dirname;fs.writeFileSync(path.join(out,'push-reference.json'),JSON.stringify({cases,sourceHashes:loader.hashes,networkCalls:0},null,2)+'\n');console.log(JSON.stringify({originalOutboundCases:cases.length,accepted:cases.filter(c=>c.accepted).length}));})().catch(e=>{console.error(e);process.exitCode=1});
