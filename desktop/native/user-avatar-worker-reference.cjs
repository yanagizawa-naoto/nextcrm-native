const fs=require('fs'),path=require('path'),zlib=require('zlib'),crypto=require('crypto'),sharp=require('sharp');
const native=__dirname,dir=path.join(native,'build/avatar-worker');fs.mkdirSync(dir,{recursive:true});
const table=Array.from({length:256},(_,v)=>{for(let i=0;i<8;i++)v=(v>>>1)^((v&1)?0xedb88320:0);return v>>>0});
function crc(b){let v=0xffffffff;for(const x of b)v=table[(v^x)&255]^(v>>>8);return(v^0xffffffff)>>>0;}function n(v){const b=Buffer.alloc(4);b.writeUInt32BE(v);return b;}function chunk(t,b){const d=Buffer.concat([Buffer.from(t),b]);return Buffer.concat([n(b.length),d,n(crc(d))]);}
function chunks(b){let p=8,out=[];while(p<b.length){const size=b.readUInt32BE(p);out.push({type:b.toString('ascii',p+4,p+8),data:b.subarray(p+8,p+8+size)});p+=size+12;}return out;}
const signature=Buffer.from([137,80,78,71,13,10,26,10]);
(async()=>{const webp=path.join(native,'build/avatar-streaming/webp-16mp.webp'),gif=path.join(native,'build/avatar-streaming/gif-16mp.gif'),frames=[];
 for(let page=0;page<2;page++){const png=await sharp(webp,{page,pages:1}).ensureAlpha().png({palette:false,progressive:false,compressionLevel:9}).toBuffer();frames.push(chunks(png));}
 const header=frames[0].find(c=>c.type==='IHDR').data;let seq=0,parts=[signature,chunk('IHDR',header),chunk('acTL',Buffer.concat([n(2),n(1)]))];
 frames.forEach((frame,index)=>{const control=Buffer.concat([n(seq++),n(4096),n(4096),n(0),n(0),Buffer.from([0,1,0,10,0,0])]);parts.push(chunk('fcTL',control));for(const c of frame.filter(c=>c.type==='IDAT'))parts.push(chunk(index===0?'IDAT':'fdAT',index===0?c.data:Buffer.concat([n(seq++),c.data])));});parts.push(chunk('IEND',Buffer.alloc(0)));const apng=path.join(dir,'apng-16mp.png');fs.writeFileSync(apng,Buffer.concat(parts));
 const expected=['378c570cf4566b99c348a497b0cbc80610cdaf44c65fcd21fb0c259ef5e32dad','63517a062e1b90f36d73abf27645db97a085c19105960dbb3cb953bb868f14bd']; // Source-verified quadrant/alpha fixture 256px CG preview goldens.

 const oriented=[];
 for(const single of [false,true]){const source=fs.readFileSync(webp),parts=[Buffer.from('WEBP')];let p=12,frames=0;
  while(p<source.length){const size=source.readUInt32LE(p+4),tag=source.toString('ascii',p,p+4);let body=Buffer.from(source.subarray(p+8,p+8+size));p+=8+size+size%2;if(tag==='EXIF')continue;if(tag==='ANMF'&&single&&frames++>0)continue;if(tag==='VP8X')body[0]|=8;const len=Buffer.alloc(4);len.writeUInt32LE(body.length);parts.push(Buffer.from(tag),len,body,body.length%2?Buffer.alloc(1):Buffer.alloc(0));}
  const exif=Buffer.from('49492a0008000000010012010300010000000600000000000000','hex'),len=Buffer.alloc(4);len.writeUInt32LE(exif.length);parts.push(Buffer.from('EXIF'),len,exif);const body=Buffer.concat(parts),size=Buffer.alloc(4);size.writeUInt32LE(body.length);const name=single?'webp-oriented-single':'webp-oriented-16mp',file=path.join(dir,name+'.webp');fs.writeFileSync(file,Buffer.concat([Buffer.from('RIFF'),size,body]));oriented.push({name,file,expected:single?expected.slice(0,1):expected,expectedPoster:true});
 }
 const fixtures=[{name:'gif-16mp',file:gif,expected},{name:'webp-16mp',file:webp,expected},{name:'apng-16mp',file:apng,expected},{name:'gif-loop',file:path.join(native,'build/avatar-animation/gif-infinite.gif'),requested:7},{name:'apng-single-poster',file:path.join(native,'build/avatar-apng/singleExcluded.png'),expectedPoster:true}];
 fixtures.push(...oriented);
 for(const f of fixtures){const bytes=fs.readFileSync(f.file);f.bytes=bytes.length;f.sha256=crypto.createHash('sha256').update(bytes).digest('hex');}
 fs.writeFileSync(path.join(dir,'fixtures.json'),JSON.stringify({fixtures,sourceEvidence:'Existing source-verified 16MP GIF/WebP share full-canvas composition and exact CG preview; APNG assembled from locked sharp full-composited WebP frames.'},null,2)+'\n');console.log(JSON.stringify({fixtures:fixtures.length,apngBytes:fs.statSync(apng).size}));
})().catch(e=>{console.error(e.stack);process.exitCode=1});
