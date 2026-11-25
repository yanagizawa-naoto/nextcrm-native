const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),{createRequire}=require('node:module');
const output=path.resolve(process.argv[2]);fs.mkdirSync(output,{recursive:true});
const root=path.resolve(__dirname,'../..'),req=createRequire(path.join(root,'package.json')),esbuild=createRequire(req.resolve('tsx'))('esbuild');
const files=['lib/campaigns/render-email.ts','emails/CampaignLayout.tsx','actions/campaigns/templates/preview-template.ts','components/campaigns/TipTapEditor.tsx','pnpm-lock.yaml'];
const sha=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const hashes=Object.fromEntries(files.map(f=>[f,sha(path.join(root,f))]));
const fixtures=[
 {id:'japanese',input:'<h1>ご案内 🌸</h1><p>{{first_name}}様、日本語 &amp; 絵文字😀のご案内です。</p>',resolved:'<h1>ご案内 🌸</h1><p>花子様、日本語 &amp; 絵文字😀のご案内です。</p>'},
 {id:'table',input:'<table style="border-collapse:collapse;width:360px"><thead><tr><th>商品</th><th>金額</th></tr></thead><tbody><tr><td style="background-color:rgb(240,245,250);padding:12px">日本語サポート</td><td>12,000円</td></tr></tbody></table>'},
 {id:'style',input:'<div style="color:rgb(17,34,51)"><span style="font-weight:700;background-color:rgb(250,240,230)">特別なご案内</span></div>'},
 {id:'remote_image',input:'<p>商品写真</p><img src="http://127.0.0.1:9/template-preview-fixture.png" alt="商品画像" width="32" height="16">'},
 {id:'data_image_source_denied',input:'<p>埋め込み形式は元の許可対象外</p><img src="data:image/png;base64,iVBORw0KGgo=" alt="元仕様でsrcが除かれる画像" width="32" height="16">'},
 {id:'active_markup',input:'<p>本文を保持</p><script>window.previewExecuted=true</script><iframe src="http://127.0.0.1:9/frame"></iframe><form action="http://127.0.0.1:9/post"><input value="private"></form><a href="javascript:alert(1)" onclick="alert(1)">危険URL</a><p style="color:red">赤字</p>'}
];
esbuild.buildSync({entryPoints:[path.join(root,files[0])],bundle:true,packages:'external',platform:'node',format:'cjs',jsx:'automatic',outfile:path.join(output,'render-source.cjs'),define:{'process.env.NEXT_PUBLIC_APP_NAME':'"NextCRM"'},logLevel:'silent'});
(async()=>{
 const {renderCampaignEmail}=require(path.join(output,'render-source.cjs'));
 for(const f of fixtures)f.sourceHTML=await renderCampaignEmail({contentHtml:f.resolved??f.input,unsubscribeUrl:'#'});
 if(!files.every(f=>sha(path.join(root,f))===hashes[f]))throw Error('Source changed');
 fs.writeFileSync(path.join(output,'reference.json'),JSON.stringify({fixtures,sourceHashes:hashes,oracleSHA256:sha(__filename),scope:'Actual upstream renderCampaignEmail; synthetic HTML only, no provider. Japanese fixture applies existing native sample substitution before comparing the shared render input.'},null,2)+'\n');
 console.log(JSON.stringify({originalRenderFixtures:fixtures.length,sourceFiles:files.length}));
})().catch(error=>{console.error(error);process.exitCode=1});
