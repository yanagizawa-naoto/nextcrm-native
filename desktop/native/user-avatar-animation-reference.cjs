// Generated local fixtures only. No HTTP or package/browser downloads.
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const sharp = require('sharp');
const root = path.resolve(__dirname, '../..'), out = path.join(__dirname, 'build/avatar-animation');
fs.mkdirSync(out, {recursive:true});
const hash = p => crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const files = [
 'app/[locale]/(routes)/profile/components/ProfilePhotoForm.tsx',
 'app/[locale]/(routes)/profile/components/ProfileHeroAvatar.tsx',
 'app/api/profile/avatar/[filename]/route.ts', 'lib/upload-content-types.ts'
];
const sourceSHA256 = Object.fromEntries(files.map(p => [p, hash(path.join(root,p))]));
function pixels(w,h,frames,delta=false,transparent=false,translucent=false) {
 const data=Buffer.alloc(w*h*frames*4);
 for(let f=0;f<frames;f++)for(let y=0;y<h;y++)for(let x=0;x<w;x++){
   const i=((f*h+y)*w+x)*4, color=delta ? (x>=w/4&&x<3*w/4&&y>=h/4&&y<3*h/4?f%3:0):f%3;
   if(transparent && ((f%3===1 && !(x>=w/4&&x<3*w/4&&y>=h/4&&y<3*h/4)) || (f%3===2 && (x>=w/4||y>=h/4)))) continue;
   data[i+color]=255;data[i+3]=translucent && f%3===1 ? 128:255;
 }
 return data;
}
async function fixture(name,format,{w=32,h=32,frames=3,delay=[100,200,300],loop=2,delta=false,transparent=false,translucent=false,lossless=true}={}) {
 const p=path.join(out,name+'.'+format),input=pixels(w,h,frames,delta,transparent,translucent);
 let pipeline=sharp(input,{raw:{width:w,height:h*frames,channels:4,pageHeight:h}});
 await pipeline[format]({loop,delay,lossless,quality:100,effort:1}).toFile(p);
 const metadata=await sharp(p,{animated:true}).metadata();
 const decoded=await sharp(p,{animated:true}).ensureAlpha().raw().toBuffer();
 return {name,file:path.relative(__dirname,p),format,width:w,height:h,frameCount:frames,delay:metadata.delay,iterations:loop,tolerance:lossless?0:2,
   samples:Array.from({length:frames},(_,f)=>({center:[0,1,2,3].map(c=>decoded[((f*h+Math.floor(h/2))*w+Math.floor(w/2))*4+c]),corner:[0,1,2,3].map(c=>decoded[((f*h+1)*w+1)*4+c])})),sha256:hash(p),bytes:fs.statSync(p).size};
}
(async()=>{
 const fixtures=[];
 for(const format of ['gif','webp']) {
   for(const [name,options] of Object.entries({finite:{},infinite:{loop:0},once:{loop:1},delta:{delta:true},transparent:{transparent:true},fast:{delay:[0,10,20]},clamp:{delay:[10,200,300],loop:1},large:{w:1024,h:1024},oversize:{w:1025,h:2},many:{w:2,h:2,frames:501,delay:20},maxframes:{w:2,h:2,frames:500,delay:20,loop:1}})) fixtures.push(await fixture(format+'-'+name,format,options));
 }
 fixtures.push(await fixture('webp-alpha','webp',{transparent:true,translucent:true}));
 fixtures.push(await fixture('webp-lossy-alpha','webp',{transparent:true,translucent:true,lossless:false}));
 // Source delegates playback to <img>/Next Image. Check the installed browser's
 // actual current animation frame, not Canvas.drawImage's default-frame path.
 const {chromium}=require('@playwright/test');
 const browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--disable-background-networking','--disable-component-update','--no-first-run']});
 const browserCases=[];
 try {
   const page=await browser.newPage({viewport:{width:120,height:80},deviceScaleFactor:1});
   await page.route('**/*',route=>route.abort());
   // The first compositor capture can take seconds on a cold browser. Perform
   // that startup work before the timed image begins, preserving every frame,
   // finite-loop, 10 ms clamp and disposal assertion below.
   await page.setContent('<body style="margin:0;background:white"></body>');
   await page.screenshot();
   for(const format of ['gif','webp']) {
     const fixture=fixtures.find(f=>f.name===format+'-finite'), bytes=fs.readFileSync(path.join(__dirname,fixture.file));
     await page.setContent(`<body style="margin:0"><img width="32" height="32" src="data:image/${format};base64,${bytes.toString('base64')}"></body>`);
     const samples=[],start=Date.now();
     while(Date.now()-start<1550) {
       const screenshot=await page.screenshot();
       const rgba=await sharp(screenshot).extract({left:15,top:15,width:1,height:1}).ensureAlpha().raw().toBuffer();
       samples.push({ms:Date.now()-start,color:[...rgba]});await page.waitForTimeout(25);
     }
     const sequence=samples.map(s=>s.color.slice(0,3).indexOf(255)).filter((c,i,a)=>i===0||c!==a[i-1]);
     if(JSON.stringify(sequence)!=='[0,1,2,0,1,2]') throw Error(format+' unexpected browser loops '+JSON.stringify(sequence));
     browserCases.push({format,sequence,samples,final:samples.at(-1).color});
     const clamped=fixtures.find(f=>f.name===format+'-clamp');
     await page.setContent(`<body style="margin:0"><img width="32" height="32" src="data:image/${format};base64,${fs.readFileSync(path.join(__dirname,clamped.file)).toString('base64')}"></body>`);
     await page.waitForTimeout(35);
     const first=[...await sharp(await page.screenshot()).extract({left:15,top:15,width:1,height:1}).ensureAlpha().raw().toBuffer()];
     if(JSON.stringify(first)!=='[255,0,0,255]')throw Error(format+' did not clamp 10ms first frame');
     browserCases.push({format,case:'10ms clamped',after35ms:first});
     const transparent=fixtures.find(f=>f.name===format+'-transparent');
     await page.setContent(`<body style="margin:0;background:white"><img width="32" height="32" src="data:image/${format};base64,${fs.readFileSync(path.join(__dirname,transparent.file)).toString('base64')}"></body>`);
     await page.waitForTimeout(170);
     const corner=[...await sharp(await page.screenshot()).extract({left:1,top:1,width:1,height:1}).ensureAlpha().raw().toBuffer()];
     if(JSON.stringify(corner)!=='[255,255,255,255]')throw Error(format+' disposed corner not transparent');
     browserCases.push({format,case:'disposal-to-transparent',after170ms:corner});
   }
 } finally { await browser.close(); }
 const result={sourceSHA256,fixtures,browserCases,browser:'Installed isolated headless Google Chrome; source-style img; generated data URLs; HTTP blocked',scope:'Source avatar components retain browser-native animation; local original GIF/WebP stream is unchanged. No full app or remote storage used.'};
 fs.writeFileSync(path.join(__dirname,'build/user-avatar-animation-reference.json'),JSON.stringify(result,null,2)+'\n');
 console.log(JSON.stringify({fixtures:fixtures.length,browserCases:browserCases.length}));
})().catch(e=>{console.error(e.stack);process.exitCode=1});
