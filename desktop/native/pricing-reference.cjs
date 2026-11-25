// Execute the original engine with the repository's existing, locked dependencies.
const fs = require('node:fs'), path = require('node:path'), Module = require('node:module');
const ts = require('typescript'), { Decimal } = require('decimal.js');
const previous = require.extensions['.ts'];
require.extensions['.ts'] = (m, file) => m._compile(ts.transpileModule(fs.readFileSync(file,'utf8'), {
  compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}
}).outputText,file);
const {computePrice} = require('../../lib/pricing/engine.ts');
require.extensions['.ts'] = previous;
const decimalKeys = ['minQuantity','fixedPrice','percentPrice','priceDiscount','priceSurcharge','priceRound','priceMinMargin','priceMaxMargin'];
const rule = (id, fields={}) => ({id,appliesTo:'ALL',categoryId:null,productId:null,minQuantity:'0',dateStart:null,dateEnd:null,computePrice:'FIXED',fixedPrice:'25',percentPrice:null,base:'LIST_PRICE',basePriceListId:null,priceDiscount:'0',priceSurcharge:'0',priceRound:null,priceMinMargin:null,priceMaxMargin:null,createdAt:'2026-01-01T00:00:00Z',...fields});
const product = {id:'product',unitPrice:'100.25',unitCost:'42.30',currency:'JPY',categoryId:'child'};
const examples=[];
function add(rules, options={}) {
  examples.push({product,categoryChain:['child','parent'],quantity:'10',date:'2026-06-15T13:00:00Z',listID:'main',lists:[{id:'main',currency:'JPY',rules}],rates:[],...options});
}
add([]); add([rule('fixed')]); add([rule('zero',{fixedPrice:'0'})]);
add([rule('negative',{computePrice:'FORMULA',priceDiscount:'150',priceRound:'0.1',priceSurcharge:'-1.3'})]);
add([rule('half-away',{computePrice:'FORMULA',priceDiscount:'0',priceRound:'0.5'})]);
add([rule('half-away-negative',{computePrice:'FORMULA',base:'COST',priceRound:'0.5'})],{product:{...product,unitCost:'-100.25'}});
add([rule('low',{minQuantity:'1',fixedPrice:'80'}),rule('high',{minQuantity:'10',fixedPrice:'70'}),rule('above',{minQuantity:'10.0001',fixedPrice:'60'})]);
add([rule('all',{minQuantity:'99'}),rule('parent',{appliesTo:'CATEGORY',categoryId:'parent',fixedPrice:'12'}),rule('child',{appliesTo:'CATEGORY',categoryId:'child',fixedPrice:'11'}),rule('product',{appliesTo:'PRODUCT',productId:'product',fixedPrice:'10'})],{quantity:'100'});
add([rule('parent',{appliesTo:'CATEGORY',categoryId:'parent',fixedPrice:'12'}),rule('child',{appliesTo:'CATEGORY',categoryId:'child',fixedPrice:'11'})]);
add([rule('parent',{appliesTo:'CATEGORY',categoryId:'parent',minQuantity:'5',fixedPrice:'12'}),rule('child',{appliesTo:'CATEGORY',categoryId:'child',fixedPrice:'11'})]);
add([rule('old',{fixedPrice:'1'}),rule('new',{createdAt:'2026-01-02T00:00:00+09:00',fixedPrice:'2'})]);
add([rule('a',{fixedPrice:'1'}),rule('z',{fixedPrice:'2'})]);
add([rule('expired',{dateEnd:'2026-06-14T23:59:59Z'}),rule('future',{dateStart:'2026-06-16T00:00:00Z'})]);
add([rule('boundary',{dateStart:'2026-06-15T23:59:59Z',dateEnd:'2026-06-15T23:59:59Z'})]);
add([rule('both-margins',{computePrice:'FORMULA',priceDiscount:'10',priceRound:'3',priceSurcharge:'2',priceMinMargin:'5',priceMaxMargin:'7'})]);
add([rule('zero-is-unset',{computePrice:'FORMULA',priceDiscount:'10',priceRound:'0',priceMinMargin:'0',priceMaxMargin:'0'})]);
add([rule('cost',{computePrice:'PERCENTAGE',percentPrice:'5',base:'COST'})],{product:{...product,unitCost:null}});
add([],{lists:[{id:'main',currency:'USD',rules:[]}],rates:[{from:'USD',to:'JPY',rate:'150.12345678'}]});
add([],{lists:[{id:'main',currency:'JPY',rules:[rule('nested',{computePrice:'FORMULA',base:'PRICE_LIST',basePriceListId:'base',priceDiscount:'-10'})]},{id:'base',currency:'USD',rules:[rule('basefixed',{fixedPrice:'3.3333'})]}],rates:[{from:'USD',to:'JPY',rate:'150.12345678'}]});
add([],{product:{...product,unitPrice:'9999999999999999.99',currency:'USD'},rates:[{from:'USD',to:'JPY',rate:'9999999999.99999999'}]});
add([],{product:{...product,unitPrice:'0.01'},lists:[{id:'main',currency:'USD',rules:[]}],rates:[{from:'USD',to:'JPY',rate:'9999999999.99999999'}]});
add([rule('large-formula',{computePrice:'FORMULA',priceDiscount:'-999.9999',priceRound:'0.0001',priceSurcharge:'99999999999999.9999'})],{product:{...product,unitPrice:'9999999999999999.99'}});
add([rule('inverse-formula',{computePrice:'FORMULA',priceDiscount:'33.3333',priceRound:'0.05'})],{product:{...product,unitPrice:'100.00',currency:'USD'},rates:[{from:'JPY',to:'USD',rate:'3'}]});
let seed=57653; const random=()=> seed=(Math.imul(seed,1664525)+1013904223)>>>0;
for(let i=0;i<220;i++) {
  const rules=Array.from({length:1+random()%16},(_,n)=>{
    const mode=['FIXED','PERCENTAGE','FORMULA'][random()%3];
    const r=rule(String(n),{appliesTo:['ALL','CATEGORY','PRODUCT'][random()%3],categoryId:['child','parent','other'][random()%3],productId:random()%2?'product':'other',minQuantity:String(random()%20),computePrice:mode,fixedPrice:new Decimal(random()%100000).div(10000).toString(),percentPrice:new Decimal(random()%1000000).div(10000).toString(),base:random()%2?'COST':'LIST_PRICE',priceDiscount:new Decimal(random()%2000000-1000000).div(10000).toString(),priceSurcharge:new Decimal(random()%20000-10000).div(100).toString(),priceRound:['0.01','1','3','0.05',null][random()%5]});
    if(random()%3===0)r.dateEnd='2026-06-14T00:00:00Z'; return r;
  });
  add(rules,{quantity:new Decimal(random()%200000).div(10000).toString(),product:{...product,unitPrice:new Decimal(random()%100000000).div(100).toString(),unitCost:new Decimal(random()%10000000).div(100).toString()}});
}
const out=examples.map(x=>{
  const lists=new Map(x.lists.map(l=>[l.id,{...l,rules:l.rules.map(r=>({...r,...Object.fromEntries(decimalKeys.map(k=>[k,r[k]==null?null:new Decimal(r[k])])),dateStart:r.dateStart?new Date(r.dateStart):null,dateEnd:r.dateEnd?new Date(r.dateEnd):null,createdAt:new Date(r.createdAt)}))}]));
  const rate=(from,to)=>{if(from===to)return new Decimal(1);const d=x.rates.find(r=>r.from===from&&r.to===to);if(d)return new Decimal(d.rate);const inv=x.rates.find(r=>r.from===to&&r.to===from);if(inv)return new Decimal(1).div(inv.rate);throw Error('missing rate');};
  const result=computePrice({lists,categoryChain:x.categoryChain,product:{...x.product,unitPrice:new Decimal(x.product.unitPrice),unitCost:x.product.unitCost==null?null:new Decimal(x.product.unitCost)},rate},x.listID,new Decimal(x.quantity),new Date(x.date));
  return {...x,expected:{...result,price:result.price.toFixed(),listPrice:result.listPrice.toFixed(),steps:result.steps.map(s=>({...s,value:s.value.toFixed()}))}};
});
fs.writeFileSync(path.join(__dirname,'build/pricing-reference.json'),JSON.stringify(out));
console.log(JSON.stringify({referenceCases:out.length,source:'lib/pricing/engine.ts'}));
