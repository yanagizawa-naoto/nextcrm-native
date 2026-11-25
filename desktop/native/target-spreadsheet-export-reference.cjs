const fs = require('fs');
const path = require('path');
const ts = require('typescript');
const vm = require('vm');
const ExcelJS = require('exceljs');
const Papa = require('papaparse');
const root = path.resolve(__dirname, '../..');
const output = process.argv[2];
const sources = ['lib/spreadsheet/export-targets.ts', 'lib/spreadsheet/target-fields.ts'];
function load(file) {
  const filename = path.join(root, file);
  const code = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,esModuleInterop:true}}).outputText;
  const module = {exports:{}};
  const request = name => name === './target-fields' ? load('lib/spreadsheet/target-fields.ts') : require(name);
  vm.runInThisContext('(function(require,module,exports){' + code + '\n})', {filename})(request,module,module.exports);
  return module.exports;
}
async function cells(file, count) {
  const book = new ExcelJS.Workbook(); await book.xlsx.readFile(file);
  const sheet=book.worksheets[0], result=[];
  for (let row=1;row<=count;row++) result.push(Array.from({length:21},(_,column) => sheet.getRow(row).getCell(column+1).text));
  return result;
}
async function main() {
  const original=load(sources[0]), fields=load(sources[1]).TARGET_FIELDS;
  const values=['普通の日本語','comma,value','double "quote"','line\nfeed',' tabs\tand spaces ','😀 𠮷 𝄞','0012300','=HYPERLINK("https://example.invalid")','<>&\'"','https://example.invalid/path','', 'ゼロ０'];
  const rows=values.map((_,i)=>fields.map((f,j)=>values[(i+j)%values.length]));
  // Corrective cases: original CSV omits CR quoting and ExcelJS strips control
  // characters / decodes literal _xHHHH_. Preserve the user's actual text.
  const edge=fields.map((_,i)=>['bare\rreturn','literal _x0041_ and _x005F_','control\u0000\u000b\u000c\u007f','noncharacters\ufffe\uffff'][i%4]);
  const records=rows.map(row=>Object.fromEntries(fields.map((field,i)=>[field.key,row[i]])));
  const fixture={headers:fields.map(f=>f.label),keys:fields.map(f=>f.key),rows:[...rows,edge],commonRows:rows.length,edge};
  fs.writeFileSync(path.join(output,'fixtures.json'),JSON.stringify(fixture));
  fs.writeFileSync(path.join(output,'original.csv'),original.buildTargetsCsv(records));
  fs.writeFileSync(path.join(output,'original.xlsx'),Buffer.from(await original.buildTargetsXlsxBuffer(records)));
  fs.writeFileSync(path.join(output,'original-cells.json'),JSON.stringify(await cells(path.join(output,'original.xlsx'),rows.length+1)));
}
async function verify() {
  const fixture=JSON.parse(fs.readFileSync(path.join(output,'fixtures.json')));
  const expected=[fixture.headers,...fixture.rows];
  const xlsx=await cells(path.join(output,'rows.xlsx'),expected.length);
  if(JSON.stringify(xlsx)!==JSON.stringify(expected)) {
    fs.writeFileSync(path.join(output,'native-cells.json'),JSON.stringify(xlsx));
    throw new Error('native XLSX did not preserve all cells');
  }
  const csv=fs.readFileSync(path.join(output,'rows.csv'),'utf8');
  const parsed=Papa.parse(csv,{skipEmptyLines:false}).data;
  if(JSON.stringify(parsed)!==JSON.stringify(expected))throw new Error('native CSV/Papa roundtrip differs');
  const prefix=csv.slice(0,csv.lastIndexOf('\n"bare\rreturn"'));
  if(prefix!==fs.readFileSync(path.join(output,'original.csv'),'utf8'))throw new Error('common CSV bytes differ from actual original exporter');
  const original=JSON.parse(fs.readFileSync(path.join(output,'original-cells.json')));
  if(JSON.stringify(xlsx.slice(0,fixture.commonRows+1))!==JSON.stringify(original))throw new Error('common ExcelJS values differ');
  const scale=await cells(path.join(output,'scale.xlsx'),10001);
  if(scale.length!==10001 || scale[10000][20]!=='日本語9999-20')throw new Error('scale workbook truncated');
  const large=await cells(path.join(output,'large.xlsx'),2);
  if(large[1][0]!=='大きな説明😀<&\r\n'.repeat(100000))throw new Error('large cell changed');
  for(const ext of ['csv','xlsx']) {
    const rows=ext==='csv'?Papa.parse(fs.readFileSync(path.join(output,'empty.csv'),'utf8')).data:await cells(path.join(output,'empty.xlsx'),1);
    if(JSON.stringify(rows)!==JSON.stringify([fixture.headers]))throw new Error('empty workbook lost header');
  }
  console.log(JSON.stringify({originalCSVByteMatch:true,originalXLSXCellsMatch:true,roundTripCells:expected.length*21,scaleRows:10000,largeCellCharacters:large[1][0].length,intentionalCorrections:['quote bare CR in CSV','preserve OOXML controls, CR and literal escape-like text']}));
}
(process.argv[3]==='verify'?verify():main()).catch(error=>{console.error(error);process.exitCode=1;});
