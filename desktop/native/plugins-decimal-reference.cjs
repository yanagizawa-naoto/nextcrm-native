const fs=require('node:fs'),path=require('node:path'),{Prisma}=require('@prisma/client');
const {createSourceDatabase}=require('./plugins-source-database.cjs');
async function main(){
 const db=createSourceDatabase(),api=db.data('decimal-test',['products:read','products:write']),cases=[];
 db.seed('Currency',{code:'JPY',name:'JPY',symbol:'¥',isDefault:true});
 const values=['0','-0','2.675','-2.675','2.674999999999999999999999999999999999','0.005','-0.005','0.004999999999999999999999999999999999','9999999999999999.994','9999999999999999.995','-9999999999999999.995','1e-100000','1e100000','123.456789','+2.675','.005','5.','0.00005','-0.00005','1.23455','1.23454999999999999',2.675,-2.675,1e-7,0.0000010000000000000002];
 for(let i=0;i<values.length;i++){
  const input=values[i];let expected=null,ok=true;
  try{const result=await db.run(()=>api.products.upsertExternal('decimal-'+i,{name:'Decimal '+i,unit_price:input,currency:'JPY',type:'PRODUCT',status:'ACTIVE',categoryRef:null}));expected=(await api.products.get(result.id)).unit_price.toString()}catch{ok=false}
  cases.push({model:'crm_Products',field:'unit_price',input,ok,expected,kind:'product'});
 }
 for(const input of values)for(const [model,field] of [['crm_PriceListRules','fixedPrice'],['crm_Opportunities','expected_revenue']]){
  const definition=db.definitions[model].fields.find(x=>x.name===field);if(!definition)throw Error('unknown decimal field '+field);
  const [,p,s]=definition.attributes.match(/@db.Decimal\((\d+),\s*(\d+)\)/);let ok=true,expected=null;
  try{let value=new Prisma.Decimal(input).toDecimalPlaces(+s,Prisma.Decimal.ROUND_HALF_UP);if(value.abs().gte(new Prisma.Decimal(10).pow(+p-+s)))throw Error('overflow');expected=value.toString()}catch{ok=false}
  cases.push({model,field,input,ok,expected,kind:'scalar'});
 }
 const output={cases,sourceHashes:db.sourceHashes,scope:'Actual plugin DataAPI/catalog writes with synthetic Prisma storage enforcing checked-in PostgreSQL Decimal precision; extra scale vectors use installed Prisma.Decimal. Not a live PostgreSQL integration test.'};
 fs.writeFileSync(path.join(__dirname,'build/plugins-decimal-reference.json'),JSON.stringify(output));console.log(JSON.stringify({cases:cases.length,sourceFiles:Object.keys(db.sourceHashes).length}));
}
main().catch(error=>{console.log(JSON.stringify({error:String(error)}));process.exit(1)});
