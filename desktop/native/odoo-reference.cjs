// Runs the checked-in connector itself. No service, database, credentials or network.
const fs=require('node:fs'),path=require('node:path'),Module=require('node:module'),crypto=require('node:crypto'),assert=require('node:assert/strict'),ts=require('typescript');
const root=path.resolve(__dirname,'../..'),cache=new Map(),hashes={};
function load(file){let f=path.resolve(root,file);if(!fs.existsSync(f)){if(fs.existsSync(f+'.ts'))f+='.ts';else if(fs.existsSync(f+'.tsx'))f+='.tsx';else f=path.join(f,'index.ts');}assert(f.startsWith(root+'/'));if(cache.has(f))return cache.get(f).exports;
 const source=fs.readFileSync(f,'utf8'),mod=new Module(f,module);mod.filename=f;mod.paths=module.paths;cache.set(f,mod);hashes[path.relative(root,f)]=crypto.createHash('sha256').update(source).digest('hex');
 mod.require=n=>{if(n==='@nextcrm/plugin-sdk')return load('packages/plugin-sdk/src/index.ts');if(n==='@nextcrm/plugin-sdk/testing')return load('packages/plugin-sdk/src/testing.ts');if(n.startsWith('.'))return load(path.resolve(path.dirname(f),n));if(['zod','react','node:crypto'].includes(n))return require(n);throw Error('Blocked original import '+n);};
 mod._compile(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.React}}).outputText,f);return mod.exports;
}
const map=load('plugins/odoo-connector/map.ts'),match=load('plugins/odoo-connector/match.ts'),catalog=load('plugins/odoo-connector/catalog-map.ts'),compare=load('plugins/odoo-connector/compare.ts'),status=load('plugins/odoo-connector/orders-status.ts'),orders=load('plugins/odoo-connector/orders-in.ts'),partners=load('plugins/odoo-connector/odoo-partners.ts'),settings=load('plugins/odoo-connector/settings.ts');
const cases=[],ctx={t:(key,args)=>key+':'+JSON.stringify(args)};
function run(op,input){switch(op){
case'account':return map.accountFields(input.partner,k=>input.countries[k]??null,input.defaultCountry);
case'contact':return map.contactFields(input);
case'name':return map.splitName(input);
case'changed':return map.changedFields(input.current,input.next);
case'number':return match.normalizeNumber(input.country,input.raw);
case'vat':return match.normalizeVat(input);
case'chosen':return settings.chosenLists({settings:{priceLists:input}});
case'fixed':return input.number.toFixed(input.digits);
case'address':return partners.sameAddress(input.a,input.b);
case'variant':return catalog.variantFields(input.variant,ids=>ids.length===1?input.taxes[ids[0]]??null:null);
case'categories':return catalog.categoryOrder(input);
case'rules':return catalog.mapRules(input.items,id=>input.variants[id]??[],new Set(input.known));
case'bases':return catalog.baseRefs(input);
case'lists':return catalog.orderLists(new Map(input.deps),input.max??Infinity);
case'sample':return compare.pickSample(input.rules,input.products,new Map(Object.entries(input.parents)),input.n??20);
case'status':return status.targetStatus(input.sale,input.moves);
case'invoices':return status.invoiceRows(input);
case'note':return orders.noteFor(ctx,input.html,input.missing);
case'time':return {day:settings.localDay({settings:{timeZone:input.zone}},new Date(input.iso)),time:settings.localTime({settings:{timeZone:input.zone}},input.iso)};
case'settings':{const r=settings.settingsSchema.safeParse(input);return r.success?{ok:true,data:r.data}:{ok:false};}
default:throw Error(op);}}
function add(op,input,label=''){try{cases.push({op,input,label,result:run(op,input)});}catch(e){cases.push({op,input,label,error:e.message});}}
const nul=[null,'',' ','\uFEFF','\u0085','  abc  ','日本語',' e\u0301 ','\u2028x\u2029','\tA\nB\t',false];
for(const v of nul){add('account',{partner:{id:1,name:v,company_registry:v,vat:v,street:v,street2:' x ',phone:v,mobile:' 123 ',country_id:[56,'CZ'],state_id:[4,' state ']},countries:{56:'CZ'},defaultCountry:'JP'});add('contact',{id:2,name:v,email:v,phone:v,mobile:v,function:v});}
for(const raw of [null,'',' ','123',' 123 456 ','000000000','ab 12','é ß','００１','\uFEFF12\u00A0','\u008512'])for(const country of [null,'CZ','cz','CZ ','JP'])add('number',{country,raw});
for(const v of nul.filter(x=>x!==false))add('vat',v);
for(const name of ['',' ','Madonna','山田 太郎','A  B\tC','\uFEFF A \uFEFF','A\u0085B','A\u2028B'])add('name',name);
for(const current of [{},{a:null,b:1,c:false,d:'x'},{a:'keep',b:'1',c:0,d:'x'},{a:{x:1},b:[1]}])for(const next of [{a:null},{b:1,c:false,d:'x'},{a:{x:1},b:[1]},{a:'new',b:'1',c:0}])add('changed',{current,next});
for(const text of ['','245, 234;245\n3','0,-1,1.5,+2,2e2,0x10,0b11,0o10','Infinity,NaN,01,1e21,9007199254740993','2\uFEFF3\u00854','+0x10,0XFF,-0,1_000,0o9','1e-5,1e-0,1e309'])add('chosen',text);
for(const number of [0,-0,1.005,2.675,-2.675,1.125,-.00001,1e-7,5e-324,1e20,1e21,9007199254740991,1000000000000000100,1.23445,-1.23445])for(const digits of [0,2,4])add('fixed',{number,digits});
for(const a of [{},{street:false,city:false,zip:false},{street:' Main  1 ',city:'PRÁHA',zip:'110 00'},{street:'\uFEFFmain 1',city:'práha',zip:'11000'},{street:null,city:'',zip:''}])for(const b of [{},{street:false,city:false,zip:false},{street:'main 1',city:'práha',zip:'11000'}])add('address',{a,b});
const variant={id:12,display_name:'商品',default_code:'SKU1',description_sale:false,type:'consu',active:true,sale_ok:true,lst_price:1.89,standard_price:.9,currency_id:[9,'CZK'],taxes_id:[27],uom_id:[1,'個'],categ_id:[7,'分類'],product_tmpl_id:[10,'品'],write_date:'2026-10-10 08:00:00'};
for(const price of [0,-0,1,1.89,1e-7,1e-6,1e20,1e21,-.0049,1000000000000000100])for(const taxes of [[],[27],[27,20]])add('variant',{variant:{...variant,lst_price:price,standard_price:-price,taxes_id:taxes},taxes:{27:'21',20:'12'}});
for(const v of [{type:'service'},{active:false},{sale_ok:false},{default_code:false,categ_id:false,uom_id:false,currency_id:false}])add('variant',{variant:{...variant,...v},taxes:{27:'21'}});
for(const cats of [[],[{id:3,parent_id:[2,'b']},{id:2,parent_id:[1,'a']},{id:1,parent_id:false}],[{id:3,parent_id:[9,'missing']},{id:1,parent_id:[2,'b']},{id:2,parent_id:[1,'a']}],[{id:3,parent_id:[3,'self']},{id:2,parent_id:false},{id:1,parent_id:false}]])add('categories',cats);
const rule={id:1,applied_on:'3_global',product_tmpl_id:false,product_id:false,categ_id:false,min_quantity:0,date_start:false,date_end:false,compute_price:'fixed',fixed_price:0,percent_price:0,base:'list_price',base_pricelist_id:false,price_discount:0,price_surcharge:0,price_round:0,price_min_margin:0,price_max_margin:0};
for(const compute of ['fixed','percentage','formula','unknown'])for(const base of ['list_price','standard_price','pricelist','unknown'])for(const apply of ['3_global','2_product_category','0_product_variant','1_product','4_combo'])add('rules',{items:[{...rule,compute_price:compute,base,applied_on:apply,categ_id:[7,'分類'],product_id:[500,'商品'],product_tmpl_id:[912,'型'],base_pricelist_id:[234,'基準'],fixed_price:-.0049,percent_price:12.5,price_markup:30,min_quantity:10,date_start:'2026-11-01 00:00:00',date_end:'2026-11-30 23:00:00'}],variants:{912:[500,501,502]},known:['500','501']});
for(const value of [null,0,-1,1e-7,1e21])add('rules',{items:[{...rule,id:7,base:'standard_price',price_markup:value,price_discount:4,price_round:value,price_min_margin:value,price_max_margin:value,min_quantity:value}],variants:{},known:[]});
const overlaps=[{...rule,id:30,applied_on:'1_product',product_tmpl_id:[912,'T']},{...rule,id:7,applied_on:'0_product_variant',product_id:[500,'V']},{...rule,id:12},{...rule,id:9,applied_on:'0_product_variant',product_id:[500,'V']}];
add('rules',{items:overlaps,variants:{912:[500,501]},known:['500','501']});
add('bases',[{...rule,base:'pricelist',base_pricelist_id:[234,'b']},{...rule,base:'pricelist',base_pricelist_id:[233,'a']},{...rule,base:'pricelist',base_pricelist_id:[234,'b']},rule]);
for(const deps of [[],[[1,[2]],[2,[1]],[3,[1]],[4,[]]],[[1,[2,3]],[2,[4]],[3,[4]],[4,[]]],[[1,[9]]],Array.from({length:13},(_,i)=>[i+1,i<12?[i+2]:[]])])for(const max of [0,1,3,11,null])add('lists',{deps,max});
let seed=0x47a834;function rand(n){seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed%n;}
for(let k=0;k<100;k++){const count=rand(25)+1,deps=Array.from({length:count},(_,i)=>[i+1,Array.from({length:rand(4)},()=>rand(count)+1)]);add('lists',{deps,max:rand(15)});}
const products=[{ref:'10',categoryRef:'7'},{ref:'2',categoryRef:'8'},{ref:'3',categoryRef:null},{ref:'4',categoryRef:'9'}],parents={7:null,8:'7',9:'9'};
for(const n of [0,1,3,20])add('sample',{rules:[{appliesTo:'PRODUCT',productRef:'10',minQuantity:'1000'},{appliesTo:'CATEGORY',categoryRef:'7',minQuantity:'10'},{base:'PRICE_LIST'}],products,parents,n});
const move={id:1,name:'INV/1',move_type:'out_invoice',state:'posted',payment_state:'not_paid',invoice_date:'2026-10-14',invoice_date_due:'2026-10-28',amount_total:242,amount_residual:242};
for(const state of ['cancel','draft','sent','sale','done'])for(const invoice_status of ['no','to invoice','invoiced'])for(const delivery_status of [false,'partial','full'])for(const moves of [[],[move],[{...move,payment_state:'paid'}],[{...move,payment_state:'in_payment'}],[{...move,payment_state:'reversed'}],[{...move,move_type:'out_refund',payment_state:'paid'}],[{...move,state:'draft'}],[{...move,payment_state:'paid'},move]])add('status',{sale:{state,invoice_status,delivery_status},moves});
add('invoices',[move,{...move,state:'draft'},{...move,move_type:'out_refund',invoice_date:false,invoice_date_due:false}]);
for(const html of [false,null,'','<p>A &amp; B<br>C</p>','<p>a</p> <p class="x">b</p>','<p>a &lt;script&gt;alert(1)&lt;/script&gt; <scr<script>ipt>b</p>','&amp;lt;x&amp;gt;','&nbsp;&quot;x&#39;','<br\n/>a\n\n\nb','\uFEFF名前\uFEFF'])for(const missing of [0,2])add('note',{html,missing});
for(const zone of ['UTC','Asia/Tokyo','Europe/Prague','America/New_York'])for(const iso of ['2026-10-12T22:30:00Z','2026-03-08T07:00:00Z','1582-10-31T14:45:00Z','0000-01-31T14:45:00Z','9999-12-31T23:00:00Z'])add('time',{zone,iso});
for(const more of [{},{url:'http://x'},{url:'https://x path'},{database:''},{syncMinutes:4},{syncMinutes:1441},{syncMinutes:5},{syncMinutes:5.5},{defaultCountry:'😀'},{defaultCountry:'🇯🇵'},{defaultCountry:'a\u0301'},{timeZone:'asia/tokyo'},{timeZone:'Mars/Base'},{timeZone:'+01:00'},{timeZone:'GMT'},{unknown:'strip'},{dryRun:null}])add('settings',{url:'https://odoo.example.invalid',database:'db',...more});
for(const [a,b] of [['é','e\u0301'],['Å','A\u030A'],['가','\u1100\u1161']]){add('changed',{current:{name:a},next:{name:b}});add('changed',{current:{name:b},next:{name:a}});for(const field of ['street','city','zip'])add('address',{a:{[field]:a},b:{[field]:b}});}
const zoneBoundaries=['+01:00','+0100','+01','+1','+00','-00:00','+23:59','-23:59','+24:00','+00:60','+01:00:00','UTC+1','GMT+1','GMT+01:00','US/Eastern','utc','gmt','jst','EST','CET','Etc/GMT+3','Etc/Unknown','Factory',' Asia/Tokyo '];
for(const timeZone of zoneBoundaries){add('settings',{url:'https://odoo.example.invalid',database:'db',timeZone});try{new Intl.DateTimeFormat('en-CA',{timeZone});for(const iso of ['2026-07-01T00:30:00Z','1900-01-01T00:30:00Z','1582-10-31T14:45:00Z'])add('time',{zone:timeZone,iso});}catch{}}
for(const f of ['node_modules/zod/package.json','node_modules/zod/v4/core/checks.cjs','plugins/odoo-connector/messages/ja.json'])hashes[f]=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,f))).digest('hex');
module.exports={load,hashes,root,cases};
if(require.main===module){const output=process.argv[2]??path.join(__dirname,'build/odoo-reference.json');fs.writeFileSync(output,JSON.stringify({cases,sourceSHA256:hashes},null,2)+'\n');console.log(JSON.stringify({cases:cases.length,sourceFiles:Object.keys(hashes).length,output}));}
