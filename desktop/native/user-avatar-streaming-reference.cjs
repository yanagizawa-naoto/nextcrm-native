const fs=require('fs'),path=require('path'),crypto=require('crypto'),sharp=require('sharp');
const dir=path.join(__dirname,'build/avatar-streaming');fs.mkdirSync(dir,{recursive:true});
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
function premultiply(data){for(let i=0;i<data.length;i+=4)for(let c=0;c<3;c++)data[i+c]=Math.round(data[i+c]*data[i+3]/255);return data;}
function image(w,h,frames,kind){const b=Buffer.alloc(w*h*frames*4);for(let f=0;f<frames;f++)for(let y=0;y<h;y++)for(let x=0;x<w;x++){
 const i=((f*h+y)*w+x)*4;if(kind==='tiny'){b[i+f%3]=255;b[i+3]=255;continue;}
 const quadrant=(x>=w/2?1:0)+(y>=h/2?2:0),colors=[[255,0,0],[0,255,0],[0,0,255],[255,255,0]],c=colors[(quadrant+f)%4];
 b[i]=c[0];b[i+1]=c[1];b[i+2]=c[2];b[i+3]=(f===1&&x<w/4&&y<h/4)?0:(kind==='alpha'&&f===1?128:255);
}return b;}
async function make(name,format,w,h,frames,kind){let input=image(w,h,frames,kind);const file=path.join(dir,name+'.'+format);await sharp(input,{raw:{width:w,height:h*frames,channels:4,pageHeight:h}})[format]({lossless:true,effort:1,loop:1,delay:500}).toFile(file);input=null;global.gc?.();return {name,format,file,width:w,height:h,frames};}
async function reference(f){const selected=f.frames>10?[0,499,500,999,1000]:Array.from({length:f.frames},(_,i)=>i),checks=[];
 for(const frame of selected){const {data,info}=await sharp(f.file,{page:frame,pages:1}).ensureAlpha().raw().toBuffer({resolveWithObject:true});const p=premultiply(data);checks.push({index:frame,sha256:hash(p),pixels:p.length<=65536?p.toString('base64'):undefined,width:info.width,height:info.height});}
 return {...f,file:path.relative(__dirname,f.file),bytes:fs.statSync(f.file).size,sha256:hash(fs.readFileSync(f.file)),checks};}
(async()=>{
 const cases=[];
 for(const format of ['webp','gif']){cases.push(await reference(await make(format+'-1001',format,2,2,1001,'tiny')));global.gc?.();cases.push(await reference(await make(format+'-16mp',format,4096,4096,2,'large')));global.gc?.();}
 const small=await make('webp-alpha','webp',64,32,3,'alpha');cases.push(await reference(small));
 const base=await make('webp-orientation-base','webp',32,16,3,'large');
 for(let o=1;o<=8;o++){const file=path.join(dir,'webp-orientation-'+o+'.webp');await sharp(base.file,{animated:true}).withMetadata({orientation:o}).webp({lossless:true,loop:1,delay:500}).toFile(file);
  const f=await reference({name:'webp-orientation-'+o,format:'webp',file,width:32,height:16,frames:3,orientation:o});const display=await sharp(file,{page:0,pages:1}).autoOrient().resize(16,16,{fit:'cover',kernel:'nearest'}).ensureAlpha().raw().toBuffer();f.display=premultiply(display).toString('base64');cases.push(f);
 }
 // Validate orientation against source-style browser <img>, including mirrored cases.
 const {chromium}=require('@playwright/test'),browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--disable-background-networking','--disable-component-update','--no-first-run']});
 const browserCases=[];
 try{const page=await browser.newPage({viewport:{width:16,height:16},deviceScaleFactor:1});await page.route('**/*',r=>r.abort());for(const f of cases.filter(x=>x.orientation)){
   const data=fs.readFileSync(path.join(__dirname,f.file));await page.setContent(`<style>body{margin:0;background:transparent}img{width:16px;height:16px;object-fit:cover}</style><img src="data:image/webp;base64,${data.toString('base64')}">`);
   const pixel=premultiply(await sharp(await page.screenshot({omitBackground:true})).ensureAlpha().raw().toBuffer()),expected=Buffer.from(f.display,'base64');
   const max=Math.max(...pixel.map((x,i)=>Math.abs(x-expected[i])));
   f.browserDisplay=pixel.toString('base64');browserCases.push({orientation:f.orientation,sha256:hash(pixel),matchesDeclaredOrientation:max===0,maxDifferenceToDeclaredOrientation:max,naturalSize:await page.locator('img').evaluate(i=>[i.naturalWidth,i.naturalHeight])});
 }}finally{await browser.close();}
 fs.writeFileSync(path.join(__dirname,'build/user-avatar-streaming-reference.json'),JSON.stringify({cases,browserCases,scope:'Generated local fixtures, locked sharp/libwebp decoder reference, installed isolated Chromium img orientation. No external data.'},null,2)+'\n');
 console.log(JSON.stringify({cases:cases.length,browserCases:browserCases.length,compressedBytes:cases.reduce((a,f)=>a+f.bytes,0)}));
})().catch(e=>{console.error(e.stack);process.exitCode=1});
