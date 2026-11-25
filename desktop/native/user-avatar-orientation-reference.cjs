const fs=require('fs'),path=require('path'),crypto=require('crypto'),sharp=require('sharp');
const {chromium}=require('@playwright/test');
const native=__dirname,dir=path.join(native,'build/avatar-orientation'),repo=path.resolve(native,'../..');fs.mkdirSync(dir,{recursive:true});
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
const le=(v,n)=>{const b=Buffer.alloc(n);b.writeUIntLE(v,0,n);return b;};
const chunk=(tag,b)=>Buffer.concat([Buffer.from(tag),le(b.length,4),b,b.length%2?Buffer.alloc(1):Buffer.alloc(0)]);
function chunks(b){let p=12,a=[];while(p+8<=b.length){const size=b.readUInt32LE(p+4);a.push({tag:b.toString('ascii',p,p+4),body:b.subarray(p+8,p+8+size)});p+=8+size+size%2;}return a;}
function exif(o,big=false,prefix=false){const b=Buffer.alloc(26),u16=(v,p)=>big?b.writeUInt16BE(v,p):b.writeUInt16LE(v,p),u32=(v,p)=>big?b.writeUInt32BE(v,p):b.writeUInt32LE(v,p);b.write(big?'MM':'II');u16(42,2);u32(8,4);u16(1,8);u16(0x112,10);u16(3,12);u32(1,14);u16(o,18);return prefix?Buffer.concat([Buffer.from('Exif\0\0'),b]):b;}
const premult=b=>Buffer.from(b.map((v,i)=>i%4===3?v:Math.round(v*b[i-i%4+3]/255)));
async function patch(w,h,pixel){const b=Buffer.alloc(w*h*4);for(let y=0;y<h;y++)for(let x=0;x<w;x++)Buffer.from(pixel(x,y)).copy(b,(y*w+x)*4);const raw=await sharp(b,{raw:{width:w,height:h,channels:4}}).webp({lossless:true,effort:1}).toBuffer();return Buffer.concat(chunks(raw).filter(c=>['VP8 ','VP8L','ALPH'].includes(c.tag)).map(c=>chunk(c.tag,c.body)));}
async function build(){const defs=[
 {x:0,y:0,w:12,h:8,dispose:false,replace:true,pixel:(x,y)=>[[255,0,0,255],[0,255,0,255],[0,0,255,255],[255,255,0,255]][(x>=6?1:0)+(y>=4?2:0)]},
 {x:2,y:2,w:4,h:4,dispose:true,replace:false,pixel:()=>[0,255,255,128]},
 {x:8,y:0,w:4,h:4,dispose:false,replace:true,pixel:()=>[255,0,255,255]},
 {x:0,y:0,w:12,h:8,dispose:false,replace:false,pixel:(x,y)=>x<2?[255,0,0,128]:[0,0,0,0]}
 ];
 const frames=[];for(const f of defs){const body=Buffer.concat([le(f.x/2,3),le(f.y/2,3),le(f.w-1,3),le(f.h-1,3),le(400,3),Buffer.from([(f.dispose?1:0)|(f.replace?2:0)]),await patch(f.w,f.h,f.pixel)]);frames.push(chunk('ANMF',body));}
 const variants=[];
 for(let o=1;o<=8;o++){variants.push({name:'little-'+o,orientation:o,exif:exif(o),html:true});variants.push({name:'big-prefixed-'+o,orientation:o,exif:exif(o,true,true),html:o===6||o===2});}
 variants.push({name:'none',orientation:1,html:true});
 for(const [name,b]of [['zero',exif(0)],['nine',exif(9)],['short',Buffer.from([1,2,3])],['empty',Buffer.alloc(0)]])variants.push({name:'invalid-'+name,exif:b,html:true});
 variants.push({name:'between-frames-6',orientation:6,exif:exif(6),placement:'between',html:true});
 variants.push({name:'duplicate-2-6',orientation:6,exif:exif(2),extra:exif(6),html:true});
 variants.push({name:'static-6',orientation:6,exif:exif(6),static:true,single:true,html:true});
 variants.push({name:'single-6',orientation:6,exif:exif(6),single:true,html:true});
 const optimizer=require(path.join(repo,'node_modules/next/dist/server/image-optimizer/transform.js')).imageOptimizerTransform;
 for(const v of variants){const head=chunk('VP8X',Buffer.concat([Buffer.from([(v.static?0x10:0x12)|(v.exif?8:0),0,0,0]),le(11,3),le(7,3)])),anim=chunk('ANIM',Buffer.concat([Buffer.alloc(4),le(1,2)]));let parts=[Buffer.from('WEBP'),head,...(v.static?[]:[anim])];const selected=v.single?frames.slice(0,1):frames;
  selected.forEach((f,i)=>{parts.push(v.static?f.subarray(24):f);if(v.placement==='between'&&i===0)parts.push(chunk('EXIF',v.exif));});if(v.exif&&v.placement!=='between')parts.push(chunk('EXIF',v.exif));if(v.extra)parts.push(chunk('EXIF',v.extra));const body=Buffer.concat(parts),bytes=Buffer.concat([Buffer.from('RIFF'),le(body.length,4),body]);
  v.file=v.name+'.webp';fs.writeFileSync(path.join(dir,v.file),bytes);v.sha256=hash(bytes);v.bytes=bytes.length;delete v.exif;delete v.extra;
  try{const raw=await sharp(bytes,{animated:true}).ensureAlpha().raw().toBuffer({resolveWithObject:true});v.sharp={width:raw.info.width,height:raw.info.height,frames:[]};const h=raw.info.pageHeight||raw.info.height;for(let i=0;i<raw.info.height/h;i++)v.sharp.frames.push(premult(raw.data.subarray(i*h*raw.info.width*4,(i+1)*h*raw.info.width*4)).toString('base64'));const a=await sharp(bytes,{page:0,pages:1}).autoOrient().ensureAlpha().raw().toBuffer({resolveWithObject:true});v.sharpOrientedFirst={width:a.info.width,height:a.info.height,rgba:premult(a.data).toString('base64')};}catch(e){v.sharpError=e.message;}
  try{const result=await optimizer({buffer:bytes,etag:v.sha256,cacheControl:'max-age=0'},{href:'https://avatar.invalid/'+v.file,width:100,quality:100,mimeType:'image/webp'},{images:{minimumCacheTTL:0,dangerouslyAllowSVG:false},experimental:{}},{logger:{warnOnce(){},error(){}}});v.nextOptimizer={unchanged:Buffer.compare(result.buffer,bytes)===0,bytes:result.buffer.length,type:result.contentType,error:result.error?String(result.error):undefined};}catch(e){v.nextOptimizer={error:e.message};}
 }
 return variants;
}
(async()=>{const cases=await build();const browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--disable-background-networking','--disable-component-update','--no-first-run']});let version;
 try{version=browser.version();const page=await browser.newPage({viewport:{width:48,height:32},deviceScaleFactor:1});await page.route('**/*',r=>r.request().url()==='https://avatar.invalid/'?r.fulfill({contentType:'text/html',body:'<!doctype html><html></html>'}):r.abort());await page.goto('https://avatar.invalid/');
 for(const c of cases){const bytes=fs.readFileSync(path.join(dir,c.file));c.browserDecoder=await page.evaluate(async b=>{try{const decoder=new ImageDecoder({data:new Uint8Array(b),type:'image/webp',preferAnimation:true});await decoder.tracks.ready;const track=decoder.tracks.selectedTrack,frames=[];for(let i=0;i<track.frameCount;i++){const{image}=await decoder.decode({frameIndex:i});const canvas=new OffscreenCanvas(image.displayWidth,image.displayHeight),ctx=canvas.getContext('2d');ctx.drawImage(image,0,0);const rgba=ctx.getImageData(0,0,canvas.width,canvas.height).data;frames.push({width:canvas.width,height:canvas.height,duration:image.duration,rgba:[...rgba].map((v,j)=>j%4===3?v:Math.round(v*rgba[j-j%4+3]/255))});image.close();}decoder.close();return{frames,count:track.frameCount};}catch(e){return{error:String(e)}}},[...bytes]);
 if(c.html){await page.setContent(`<style>html,body{margin:0;background:transparent}img{display:block;position:absolute;border:0;padding:0}#full{left:0;top:0}#crop{left:16px;top:0;width:8px;height:8px;object-fit:cover}</style><img id="full" src="data:image/webp;base64,${bytes.toString('base64')}"><img id="crop" src="data:image/webp;base64,${bytes.toString('base64')}">`);try{await page.locator('#full').evaluate(i=>i.decode());await page.locator('#crop').evaluate(i=>i.decode());const start=Date.now(),natural=await page.locator('#full').evaluate(i=>[i.naturalWidth,i.naturalHeight]);c.htmlImage={naturalSize:natural,frames:[]};for(let i=0;i<(c.single?1:4);i++){const wait=i*400+80-(Date.now()-start);if(wait>0)await page.waitForTimeout(wait);const png=await page.screenshot({omitBackground:true});const rgba=premult(await sharp(png).extract({left:16,top:0,width:8,height:8}).ensureAlpha().raw().toBuffer()),full=premult(await sharp(png).extract({left:0,top:0,width:natural[0],height:natural[1]}).ensureAlpha().raw().toBuffer());c.htmlImage.frames.push({index:i,ms:Date.now()-start,rgba:rgba.toString('base64'),fullRGBA:full.toString('base64')});}}catch(e){c.htmlImage={error:String(e)}}}
 }
 }finally{await browser.close();}
 const tracked=['app/[locale]/(routes)/profile/components/ProfileHeroAvatar.tsx','app/[locale]/(routes)/profile/components/ProfilePhotoForm.tsx','components/ui/avatar.tsx','node_modules/next/dist/server/image-optimizer/transform.js'];
 const result={browserVersion:version,cases,sourceSHA256:Object.fromEntries(tracked.map(p=>[p,hash(fs.readFileSync(path.join(repo,p)))])),scope:'New local tiny fixtures only; installed headless Chrome ImageDecoder and source-style img/object-cover; real locked Next image optimizer and sharp. HTTP blocked except local in-memory document. All existing fixtures unchanged.'};fs.writeFileSync(path.join(dir,'reference.json'),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify({cases:cases.length,htmlCases:cases.filter(c=>c.html).length,browserVersion:version,bytes:cases.reduce((s,c)=>s+c.bytes,0)}));
})().catch(e=>{console.error(e.stack);process.exitCode=1});
