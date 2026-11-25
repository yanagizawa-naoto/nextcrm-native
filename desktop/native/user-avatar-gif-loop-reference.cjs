const fs=require('fs'),path=require('path'),crypto=require('crypto'),sharp=require('sharp');
const {chromium}=require('@playwright/test');
const base=fs.readFileSync(path.join(__dirname,'build/avatar-animation/gif-finite.gif'));
const marker=base.indexOf('NETSCAPE2.0'),start=marker-3,end=marker+16,app=Buffer.from(base.subarray(start,end));app[16]=3;app[17]=0;
const alternate=Buffer.from(base);alternate.write('ANIMEXTS1.0',marker,'ascii');
const inputs=[base,alternate,Buffer.concat([base.subarray(0,start),app,base.subarray(start)]),Buffer.concat([base.subarray(0,base.length-1),app,base.subarray(base.length-1)])];
(async()=>{const browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--disable-background-networking','--disable-component-update','--no-first-run']});
 try { const page=await browser.newPage({viewport:{width:64,height:16},deviceScaleFactor:1});await page.route('**/*',r=>r.abort());
 // Warm the cold compositor before any short GIF starts. Preserve the existing
 // measured loop order, duration and metadata assertions without missed startup frames.
 await page.setContent('<body style="margin:0;background:white"></body>');await page.screenshot();
 await page.setContent('<body style="margin:0;display:flex">'+inputs.map(d=>`<img width="16" height="16" src="data:image/gif;base64,${d.toString('base64')}">`).join('')+'</body>');
 const sequence=inputs.map(()=>[]),samples=[],began=Date.now();
 while(Date.now()-began<2850){const pixels=await sharp(await page.screenshot()).ensureAlpha().raw().toBuffer();const colors=inputs.map((_,i)=>[...pixels.subarray((8*64+i*16+8)*4,(8*64+i*16+8)*4+3)].indexOf(255));for(let i=0;i<4;i++)if(sequence[i].at(-1)!==colors[i])sequence[i].push(colors[i]);samples.push({ms:Date.now()-began,colors});await page.waitForTimeout(20);}
 const cases=sequence.map((s,i)=>{if(s.length%3 || !s.every((c,n)=>c===n%3))throw Error('incomplete color sequence '+i+JSON.stringify(s));return {index:i,name:['standard','ANIMEXTS1.0','duplicate-before','duplicate-after'][i],iterations:s.length/3,sequence:s,sha256:crypto.createHash('sha256').update(inputs[i]).digest('hex')};});
 fs.writeFileSync(path.join(__dirname,'build/user-avatar-gif-loop-reference.json'),JSON.stringify({cases,samples,scope:'Actual source-style Chromium img playback of locally modified original GIF fixture; no network or normal app.'},null,2)+'\n');console.log(JSON.stringify(cases));
 }finally{await browser.close();}
})().catch(e=>{console.error(e.stack);process.exitCode=1});
