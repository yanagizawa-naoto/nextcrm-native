const fs=require('node:fs'),path=require('node:path'),Module=require('node:module'),ts=require('typescript'),{Decimal}=require('decimal.js');
const source=path.resolve(__dirname,'../../lib/line-items.ts');
const reference=new Module(source,module);reference.filename=source;reference.paths=Module._nodeModulePaths(path.dirname(source));
reference._compile(ts.transpileModule(fs.readFileSync(source,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,source);
const {calculateLineTotal}=reference.exports;
// The old implementation uses binary numbers. Retain its formula while checking
// exact decimal rounding independently, including known half-cent divergences.
Decimal.set({precision:50});
const inputs=[{quantity:1,price:'0.29',type:'PERCENTAGE',discount:'50'},{quantity:1,price:'0.57',type:'PERCENTAGE',discount:'50'},
 {quantity:3,price:'12500.25',type:'PERCENTAGE',discount:'10'},{quantity:1,price:'10',type:'FIXED',discount:'20'},
 {quantity:1,price:'9999999999999999.99',type:'PERCENTAGE',discount:'0'},{quantity:2147483647,price:'0.01',type:'PERCENTAGE',discount:'99.99'}];
let seed=8275;const random=()=>seed=(Math.imul(seed,1664525)+1013904223)>>>0;
for(let i=0;i<500;i++)inputs.push({quantity:1+random()%1000,price:new Decimal(random()%10000000).div(100).toFixed(),type:random()%2?'FIXED':'PERCENTAGE',discount:new Decimal(random()%10001).div(100).toFixed()});
let differences=0;
const fixtures=inputs.map(x=>{const base=new Decimal(x.quantity).mul(x.price);const total=base.minus(x.type==='FIXED'?new Decimal(x.discount):base.mul(x.discount).div(100));const expected=Decimal.max(0,total).toDecimalPlaces(2,Decimal.ROUND_HALF_UP).toFixed();const original=String(calculateLineTotal(x.quantity,Number(x.price),x.type,Number(x.discount)));if(!new Decimal(original).eq(expected))differences++;return {...x,expected,original};});
fs.writeFileSync(path.join(__dirname,'build/line-math-reference.json'),JSON.stringify(fixtures));
console.log(JSON.stringify({referenceCases:fixtures.length,binaryFloatDifferences: differences,formulaSource:'lib/line-items.ts',decimalReference:'decimal.js precision50, ROUND_HALF_UP'}));
