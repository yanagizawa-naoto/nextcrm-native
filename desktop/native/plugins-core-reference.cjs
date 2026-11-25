// Executes the original TypeScript SDK/settings/state/key algorithms in process.
// No application bootstrap, environment files, database, network or credentials.
const fs=require('node:fs'),path=require('node:path'),Module=require('node:module'),crypto=require('node:crypto'),ts=require('typescript');
const root=path.resolve(__dirname,'../..'),cache=new Map(),hashes={};
function load(relative){
 let file=path.resolve(root,relative);if(!path.extname(file))file+='.ts';
 if(cache.has(file))return cache.get(file).exports;
 const source=fs.readFileSync(file,'utf8');hashes[path.relative(root,file)]=crypto.createHash('sha256').update(source).digest('hex');
 const mod=new Module(file,module);mod.filename=file;mod.paths=Module._nodeModulePaths(path.dirname(file));cache.set(file,mod);
 mod.require=id=>{
  if(id==='@nextcrm/plugin-sdk')return load('packages/plugin-sdk/src/index.ts');
  if(id==='@/lib/email-crypto')return {encrypt:()=>{throw Error('No secrets in source oracle')},decrypt:()=>{throw Error('No secrets in source oracle')}};
  if(id.startsWith('.'))return load(path.resolve(path.dirname(file),id));
  if(id.startsWith('@/'))return load(id.slice(2));
  return require(id);
 };
 mod._compile(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,esModuleInterop:true}}).outputText,file);return mod.exports;
}
const sdk=load('packages/plugin-sdk/src/index.ts'),state=load('plugins/account-protection/state.ts'),key=load('plugins/account-protection/key.ts'),settings=load('plugins/account-protection/settings.ts'),parser=load('lib/plugins/settings.ts');
const cases=[];
function add(kind,input,run){let result;try{result={ok:true,value:run()}}catch(e){result={ok:false,error:e.message}}cases.push({kind,input,...result})}
for(const value of [0,-0,1,1.2,1e-7,1e-6,1e20,1e21,1e22,12345678901234567,1000000000000000100,0.0000010000000000000002,-1e21])add('numberString',{value},()=>String(value));
for(const raw of ['{"input":"\\ufeffCZ"}','{"\\ufeffkey":"\\ufeff日本語","array":["\\ufeff",true,false,null,0,9007199254740993,0.0000010000000000000002]}','"\\ufeff"','["a\\u0000b","日本語😀"]'])add('parseJSON',{raw},()=>JSON.parse(raw));
for(const zone of ['asia/tokyo','jst','US/Eastern','us/eastern','EST','CET','UTC','utc','+01','-00:00','+0130','+23:59','-23:59','+24:00','+00:60','+1','+01:00:00','UTC+1','GMT+1','GMT+01:00','Factory','Etc/Unknown',' UTC'])for(const date of ['2026-01-01T12:00:00.000Z','2026-07-01T12:00:00.000Z'])add('timeZone',{zone,date},()=>{try{const parts=new Intl.DateTimeFormat('en-US',{timeZone:zone,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'}).formatToParts(new Date(date));const p=Object.fromEntries(parts.map(p=>[p.type,p.value]));return (Date.UTC(+p.year,+p.month-1,+p.day,+p.hour,+p.minute,+p.second)-Date.parse(date))/1000}catch{return null}});
for(const protectionDays of [100000001,9007199254740991])add('newRegistration',{at:'2026-01-01T00:00:00.000Z',settings:{protectionDays,contactDays:30}},()=>state.newRegistration('CZ:00000123','owner',new Date('2026-01-01T00:00:00.000Z'),{protectionDays,contactDays:30}));
for(const a of ['0.0.0','0.2.0','0.2.6','0.3.0','1.0.0','01.02.03','99999999999999999999999.0.0','1.0','-1.0.0','1.0.0-beta']){
 add('parseVersion',{value:a},()=>sdk.parseVersion(a));for(const b of ['0.2.0','0.2.6','1.0.0'])add('compareVersions',{a,b},()=>sdk.compareVersions(a,b));
}
for(const range of ['^0.2.0','^0.2.6','^0.2.7','^0.0.1','^1.0.0','0.2.0','~0.2.0','^bad'])add('satisfies',{range},()=>sdk.satisfiesSdkRange(range));
for(const raw of [null,{},[],0,'','CZ','cz','Czech Republic','Česká republika','Česko','Deutschland','Ukraine','Україна','日本','Japan','ZZ','XX','EU',' en ','\ufeffUS\ufeff'])for(const fallback of ['CZ','us','zz'])add('country',{raw,fallback},()=>key.countryCode(raw,fallback));
for(const company_id of [null,0,'','123','12345678','123456789','abc 123',' a\tB\nC ','12\u00a034','12\ufeff34','12\u008534','12\u200b34'])for(const billing_country of ['CZ','US',null])add('numberKey',{account:{company_id,billing_country},fallback:'CZ'},()=>key.numberKey({company_id,billing_country},'CZ'));
for(const value of [{},{contactTypes:'call,wrong,meeting'},{contactTypes:'wrong'},{protectionDays:0,contactDays:'3',warnDays:null,defaultCountry:'日本',requireNumber:1,orderMonths:-1},{protectionDays:9007199254740992},{defaultCountry:'😀'},{contactTypes:'\ufeffvisit\ufeff'}]){
 add('settings',{value},()=>{const warnings=[];return {parsed:parser.parseStoredSettings(settings.settingsSchema,value,(message,context)=>warnings.push({message,context})),warnings,description:parser.describeSettingsSchema(settings.settingsSchema),valid:settings.settingsSchema.safeParse(value).success}});
}
for(const day of ['2024-01-31','2023-01-31','2024-02-29','2026-08-31','0099-12-31','0000-02-29','1582-10-10'])for(const months of [0,1,2,12,13,-1])add('addMonths',{day,months},()=>state.addMonthsUtc(day,months).toISOString());
for(const at of ['2026-01-01T12:34:56.789Z','2024-02-29T00:00:00.000Z'])for(const protectionDays of [1,30,90])for(const contactDays of [1,30,120]){
 const settings={protectionDays,contactDays},reg=state.newRegistration('CZ:00000123','owner',new Date(at),settings);
 add('newRegistration',{at,settings},()=>reg);
 for(const last of [null,'2025-11-30','2026-01-01','2026-05-31'])for(const months of [0,1,12])add('withOrders',{reg,last,months},()=>{const value=state.withOrders(reg,last,months);return {reg:value,due:state.dueDay(value),since:state.contactSince(value).toISOString(),summary:state.summarize(true,value,value.contactAt??null),verdict:state.evaluate(value,new Date('2026-02-01T12:34:56.789Z'))}});
}
const names=['en','cs','de','uk'].map(locale=>new Intl.DisplayNames([locale],{type:'region',fallback:'none'})),regions={codes:[],names:{'czech republic':'CZ','česká republika':'CZ'}};
for(let a=65;a<=90;a++)for(let b=65;b<=90;b++){const code=String.fromCharCode(a,b),found=names.map(n=>n.of(code));if(!found.some(Boolean))continue;regions.codes.push(code);for(const name of found)if(name)regions.names[name.toLocaleLowerCase()]=code;}
const formats={};for(const locale of ['en','cz','de','uk','ja']){formats[locale]=[];for(let month=1;month<=12;month++){const date=`2026-${String(month).padStart(2,'0')}-02T00:00:00Z`;formats[locale].push(state.formatDay(date,locale));add('formatDay',{date,locale},()=>state.formatDay(date,locale));}}
const result={format:1,sourceHashes:hashes,cases,regions,formats};
fs.mkdirSync(path.join(__dirname,'build'),{recursive:true});fs.writeFileSync(path.join(__dirname,'build/plugins-core-reference.json'),JSON.stringify(result));
// Bundled ICU names keep the original country index stable across macOS locales.
const table=JSON.stringify(regions),literal='#"'+table+'"#',regionFile=path.join(__dirname,'NativeAccountProtectionRegions.swift'),generated='import Foundation\n\n// Derived locally from the source Intl.DisplayNames table; see plugins-core-reference.cjs.\nenum NativeAccountProtectionRegions {\n    static let table = try! NativePluginJSON.record('+literal+')\n    static let codes = Set(table["codes"] as! [String])\n    static let names = table["names"] as! [String:String]\n}\n';if(!fs.existsSync(regionFile)||fs.readFileSync(regionFile,'utf8')!==generated)fs.writeFileSync(regionFile,generated);
console.log(JSON.stringify({cases:cases.length,sourceFiles:Object.keys(hashes).length,countries:regions.codes.length,names:Object.keys(regions.names).length}));
module.exports={load,hashes};
