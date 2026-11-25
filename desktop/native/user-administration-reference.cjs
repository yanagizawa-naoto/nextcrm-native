// Actual server actions/authz over the existing isolated Prisma adapter.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {createSourceDatabase}=require('./plugins-source-database.cjs');
const root=path.resolve(__dirname,'../..'),epoch='2026-11-20T03:00:00.000Z';
const id=n=>`b1000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const userFields=['id','name','email','username','account_name','avatar','role','userLanguage','userStatus','partnerAccountId'];
const schema=JSON.parse(fs.readFileSync(path.join(__dirname,'schema.json'),'utf8'));
const ddl=fs.readFileSync(path.join(__dirname,'build/user-administration-prisma-ddl.sql'),'utf8');
const refs=[...ddl.matchAll(/ALTER TABLE "(\w+)" ADD CONSTRAINT "[^"]+" FOREIGN KEY \("(\w+)"\) REFERENCES "Users"\("id"\) ON DELETE (SET NULL|RESTRICT|CASCADE)/g)].map(m=>({model:({session:'Session',account:'Account'})[m[1]]??m[1],field:m[2],action:({'SET NULL':'SetNull',RESTRICT:'Restrict',CASCADE:'Cascade'})[m[3]]}));
assert.equal(refs.length,40,'locked Prisma Users FKs');

let hashes={};
function fixture(extra={}){return {Users:[['admin','ACTIVE'],['user','ACTIVE'],['partner','ACTIVE'],['manager','ACTIVE'],['admin','ACTIVE'],['user','PENDING'],['user','INACTIVE']].map(([role,status],i)=>({id:id(i+1),email:`u${i+1}@fixture.invalid`,name:`利用者${i+1}`,role,userStatus:status,userLanguage:'ja',created_on:`2026-01-0${i+1}T00:00:00.000Z`,password:'must-not-leak'})),crm_Accounts:[{id:id(10),v:0,name:'公開取引先',assigned_to:id(2),partnerUserId:id(3)},{id:id(11),v:0,name:'削除済',deletedAt:epoch,partnerUserId:id(3)}],Session:[{id:id(20),token:'browser-must-not-leak',userId:id(2),expiresAt:'2027-01-01T00:00:00.000Z'}],ApiToken:[{id:id(30),name:'API',tokenHash:'hash-must-not-leak',tokenPrefix:'prefix',userId:id(2)},{id:id(31),name:'revoked',tokenHash:'hash2',tokenPrefix:'prefix2',userId:id(2),revokedAt:epoch}],...extra};}
function clean(d){const newIDs=new Map(d.state.Users.filter(u=>!u.id.startsWith('b100')).map(u=>[u.id,'new:'+u.email]));const v=x=>newIDs.get(x)??x;const pick=(row,fields)=>Object.fromEntries(fields.map(k=>[k,v(row[k]??null)]));return {users:d.state.Users.map(u=>pick(u,userFields)).sort((a,b)=>a.id.localeCompare(b.id)),accounts:d.state.crm_Accounts.map(a=>pick(a,['id','assigned_to','partnerUserId'])).sort((a,b)=>a.id.localeCompare(b.id)),sessions:d.state.Session.map(s=>s.id).sort(),tokens:d.state.ApiToken.map(t=>({id:t.id,revoked:t.revokedAt!=null})).sort((a,b)=>a.id.localeCompare(b.id))};}
function normalized(result,d){if(Array.isArray(result))return {ids:result.map(x=>x.id)};if(result===undefined)return {ok:true};if(result.error)return {error:result.error};if(result.language)return {language:result.language};if(result.data?.revoked!==undefined)return {revoked:result.data.revoked};if(result.data)return {id:result.data.id.startsWith('b100')?result.data.id:'new:'+result.data.email};return result;}
const scenarios=[];const add=(name,calls,options={})=>scenarios.push({name,actor:options.actor??id(1),mail:options.mail??'success',initial:options.initial??fixture(),calls});
for(const role of ['user','manager','partner','admin'])add('role-'+role,[{op:'role',id:id(2),role}]);
add('partner-leaves',[{op:'partner',id:id(3),accountID:id(10)},{op:'role',id:id(3),role:'manager'}]);
add('partner-stays',[{op:'partner',id:id(3),accountID:id(10)},{op:'role',id:id(3),role:'partner'},{op:'partner',id:id(3),accountID:null}]);
for(const [name,call]of Object.entries({badrole:{op:'role',id:id(2),role:'owner'},selfrole:{op:'role',id:id(1),role:'user'},selfdelete:{op:'delete',id:id(1)},selfdeactivate:{op:'deactivate',id:id(1)},missingrole:{op:'role',id:id(99),role:'user'},missingdelete:{op:'delete',id:id(99)},missingpartner:{op:'partner',id:id(99),accountID:null},wrongpartner:{op:'partner',id:id(2),accountID:id(10)},deletedaccount:{op:'partner',id:id(3),accountID:id(11)},missingaccount:{op:'partner',id:id(3),accountID:id(99)}}))add(name,[call]);
add('deactivate-repeat',[{op:'deactivate',id:id(2)},{op:'deactivate',id:id(2)}]);
add('revoke-repeat',[{op:'revoke',id:id(2)},{op:'revoke',id:id(2)},{op:'revoke',id:id(99)}]);
add('delete-cascade-null',[{op:'delete',id:id(2)}]);
for(const [model,row]of [['Boards',{id:id(40),v:0,description:'board',title:'board',user:id(2)}],['tasksComments',{id:id(41),v:0,comment:'comment',user:id(2)}]])add('delete-restrict-'+model,[{op:'delete',id:id(2)}],{initial:fixture({[model]:[row]})});
add('delete-partner',[{op:'delete',id:id(3)}]);
add('directory',[{op:'list'}]);
add('profile',[{op:'profile',id:id(2),name:' 空白を保持 ',username:'',accountName:'企業'},{op:'language',id:id(2),language:'en'},{op:'photo',avatar:'https://fixture.invalid/avatar.png'}]);
add('self-profile',[{op:'profile',id:id(2),name:'自己',username:'handle',accountName:'会社'},{op:'language',id:id(2),language:'ja'},{op:'photo',avatar:'/api/profile/avatar/example.png'}],{actor:id(2)});
add('profile-other',[{op:'profile',id:id(1),name:'x',username:'x',accountName:'x'},{op:'language',id:id(1),language:'en'}],{actor:id(2)});
add('partner-profile',[{op:'profile',id:id(3),name:'x',username:'x',accountName:'x'},{op:'photo',avatar:'x'},{op:'language',id:id(3),language:'en'}],{actor:id(3)});
add('bad-language',[{op:'language',id:id(2),language:''},{op:'language',id:id(2),language:'invalid'}]);
add('photo-empty',[{op:'photo',avatar:''}]);
for(const actor of [id(2),id(4),id(3),id(6),id(99)])add('authority-'+actor.slice(-2),[{op:'list'},{op:'role',id:id(2),role:'manager'},{op:'delete',id:id(2)},{op:'deactivate',id:id(2)},{op:'revoke',id:id(2)},{op:'partner',id:id(3),accountID:null},{op:'activate',id:id(6)},{op:'invite',name:'新規',email:'new@fixture.invalid',language:'ja'}],{actor});
for(const op of ['role','delete','deactivate','revoke','partner','activate','profile','language'])add('empty-id-'+op,[{op,id:'',role:'user',accountID:null,name:'x',username:'x',accountName:'x',language:'ja'}]);
for(const language of ['en','cz','ja']){const initial=fixture();initial.Users[5].userLanguage=language;add('activate-'+language,[{op:'activate',id:id(6)}],{initial});}
add('activate-send-reject',[{op:'activate',id:id(6)}],{mail:'fail'});
for(const mode of ['success','fail','unconfigured'])add('invite-'+mode,[{op:'invite',name:'招待先',email:'new@fixture.invalid',language:'ja'},{op:'invite',name:'再試行',email:'new@fixture.invalid',language:'ja'}],{mail:mode});
add('invite-config-first',[{op:'invite',name:'既存',email:'u2@fixture.invalid',language:'ja'}],{mail:'unconfigured'});
add('invite-input',[{op:'invite',name:'',email:'x',language:'ja'},{op:'invite',name:'x',email:'x',language:'invalid'}]);
add('deactivate-missing',[{op:'deactivate',id:id(99)},{op:'activate',id:id(99)}]);
(async()=>{const previousLog=console.log,previousError=console.error;console.log=console.error=()=>{};
try{for(const s of scenarios){let d;const messages=[];const mailsend=async x=>{messages.push(x);if(s.mail==='fail')throw Error('synthetic mail rejected');};
const mocks={
 '@/lib/auth-server':{getSession:async opts=>{const u=d.state.Users.find(u=>u.id===s.actor);return u?.userStatus==='ACTIVE'&&(u.role!=='partner'||opts?.partner)?{user:{...u}}:null;}},
 '@/lib/authz':()=>({...d.load('lib/authz/session.ts'),...d.load('lib/authz/errors.ts'),...d.load('lib/authz/roles.ts')}),
 'next/cache':{revalidatePath:()=>{}},
 nodemailer:{createTransport:()=>({sendMail:async x=>mailsend({kind:'activation',...x})})},
 '@/lib/resend':{__esModule:true,default:async()=>{if(s.mail==='unconfigured')throw Error('Resend API key is not configured. Please add it in Admin settings or set RESEND_API_KEY environment variable.');return {emails:{send:async x=>mailsend({kind:'invitation',to:x.to,from:x.from,subject:x.subject})}};}},
 '@/emails/InviteUser':{__esModule:true,default:props=>props},
};
d=createSourceDatabase({epoch,mocks});for(const [m,rows]of Object.entries(s.initial))for(const row of rows)d.seed(m,row);
// Referential actions at the synthetic boundary, derived from current schema.
const originalDelete=d.prisma.users.delete;d.prisma.users.delete=async args=>d.prisma.$transaction(async()=>{const u=d.state.Users.find(x=>x.id===args.where.id);if(u){for(const r of refs)if(r.action==='Restrict'&&d.state[r.model].some(x=>x[r.field]===u.id))throw Error('Foreign key restrict');for(const r of refs){if(r.action==='SetNull')for(const row of d.state[r.model])if(row[r.field]===u.id)row[r.field]=null;else{}else if(r.action==='Cascade')d.state[r.model]=d.state[r.model].filter(x=>x[r.field]!==u.id);}}return originalDelete(args);});
process.env.NEXT_PUBLIC_APP_NAME='NextCRM';process.env.NEXT_PUBLIC_APP_URL='https://fixture.invalid/login';process.env.EMAIL_FROM='crm@fixture.invalid';
s.steps=[];for(const call of s.calls){let result;try{result=await d.run(async()=>{const names={role:['set-role','setUserRole'],partner:['set-partner-account','setPartnerAccount'],delete:['delete-user','deleteUser'],deactivate:['deactivate-user','deactivateUser'],activate:['activate-user','activateUser'],revoke:['revoke-api-tokens','revokeUserApiTokens'],invite:['invite-user','inviteUser']};if(call.op==='list')return d.load('actions/get-users.ts').getUsers();if(call.op==='profile')return d.load('actions/user/update-profile.ts').updateProfile({userId:call.id,name:call.name,username:call.username,account_name:call.accountName});if(call.op==='language')return d.load('actions/user/set-language.ts').setLanguage({userId:call.id,language:call.language});if(call.op==='photo')return d.load('actions/user/update-profile-photo.ts').updateProfilePhoto(call.avatar);const [file,fn]=names[call.op],action=d.load(`actions/admin/users/${file}.ts`)[fn];if(call.op==='invite')return action(call);if(call.op==='role')return action(call.id,call.role);if(call.op==='partner')return action(call.id,call.accountID);return action(call.id);});}catch(e){result={error:e.message};}s.steps.push({result:normalized(result,d),state:clean(d),mail:JSON.parse(JSON.stringify(messages))});}
hashes={...hashes,...d.sourceHashes};}
}finally{console.log=previousLog;console.error=previousError;}
for(const p of ['prisma/schema.prisma','emails/InviteUser.tsx','lib/auth-permissions.ts'])hashes[p]=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,p))).digest('hex');
const out={epoch,scenarios,sourceSHA256:hashes,implicitSetNull:refs.filter(r=>r.action==='SetNull').map(x=>[x.model,x.field]),scope:'Actual server actions and authz/session; mocked active cookie getter and mail transports; schema-derived synthetic Prisma CRUD/referential actions; no live PostgreSQL or provider login. Native audit atomicity and safe DTOs are deliberate differences.'};
fs.writeFileSync(process.argv[2]??path.join(__dirname,'build/user-administration-reference.json'),JSON.stringify(out));console.log(JSON.stringify({cases:scenarios.length,steps:scenarios.reduce((n,s)=>n+s.steps.length,0),sources:Object.keys(hashes).length}));
})().catch(e=>{console.error(e);process.exitCode=1});
