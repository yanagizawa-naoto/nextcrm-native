const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),ts=require('typescript'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'../..'),source=fs.readFileSync(path.join(root,'lib/campaigns/render-email.ts'),'utf8');const m={exports:{}};
vm.runInNewContext(ts.transpileModule(source+'\nexport function nativeReference(html: string) { return sanitizeHtml(html, SANITIZE_OPTIONS); }',{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,esModuleInterop:true}}).outputText,{module:m,exports:m.exports,require:n=>{if(n==='sanitize-html')return require(n);if(n==='react-dom/static')return{};if(n==='@/emails/CampaignLayout')return()=>{};throw Error(n);}});
const cases=[
 ['japanese','<p>日本語😀 &amp; お知らせ</p>'],['format','<h1>見出し</h1><p><b>太字</b><em>斜体</em><u>下線</u><s>削除</s><code>コード</code><br>改行</p><blockquote>引用</blockquote><pre>a\n b</pre>'],
 ['table','<table width="500" style="border: 1px solid #ddd"><thead><tr><th align="left">商品</th></tr></thead><tbody><tr><td style="padding: 8px">価格😀</td></tr></tbody></table>'],
 ['image','<img src="https://example.invalid/a.png?x=1&amp;y=2" alt="日本語 &quot;引用&quot;" width="80" height="20" onerror="evil()">'],
 ['links','<a href="https://example.invalid/a" target="_blank" rel="noopener">開く</a><a href="mailto:user@example.invalid">連絡</a><a href="/relative">相対</a>'],
 ['js','<a href="javascript:alert(1)" onclick="evil()">リンク</a><img src="data:text/html,evil">'],
 ['control-scheme','<a href="java&#10;script:evil()">危険</a><a href="JAVASCRIPT&#58;evil()">危険</a>'],
 ['entity-scheme','<a href="javascript&colon;evil()">危険</a><a href="https&colon;//example.invalid">安全</a>'],
 ['comment-scheme','<a href="java<!--comment-->script:evil()">危険</a>'],
 ['discard','前<script>alert(1)</script><style>body{color:red}</style><textarea>秘密</textarea><option>隠す</option><xmp><img src=x onerror=evil()></xmp>後'],
 ['unknown','<article><section><p>残す</p></section></article><!--消す--><iframe src="https://evil.invalid">文字</iframe>'],
 ['svg','<svg onload="evil()"><script>alert(1)</script><a href="javascript:evil()">SVGリンク</a></svg><p>本文</p>'],
 ['entities','<p>&lt;b&gt; &quot; &#39; &apos; &nbsp; &copy; &colon; &CounterClockwiseContourIntegral; &amp;colon;</p>'],
 ['attributes','<p id="x" class="x" data-v="a" style="color: red; font-size: 14px;" align="center" width="300">本文</p>'],
 ['invalid-style','<p style="color:red; broken">本文</p>'],['css-functions','<div style="width:calc(100% - 5px);font-family:\'Noto Sans JP\';background-image:url(https://example.invalid/a.png)">本文</div>'],
 ['css-quotes','<span style="font-family:\'a;b:c\';color: red !important">文字</span>'],
 ['full-document','<!doctype html><html><head><title>題名</title><style>p{color:red}</style></head><body><p>本文😀</p></body></html>'],
 ['wrong-charset','<meta charset="iso-8859-1"><p>日本語😀</p>'],
 ['xml-entity','<!DOCTYPE html [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><p>&xxe;安全</p>'],
 ['misnested','<p>ひとつ<b>太字<p>ふたつ</b>末尾'],['unclosed','<div><p>本文<br>続き'],['empty',''],['plain','こんにちは😀 < & > "引用"'],
 ['urls','<a href="tel:123">電話</a><a href="ftp://example.invalid/x">FTP</a><a href="//example.invalid/path">相対ホスト</a><img src="file:///private/tmp/x">'],
 ['chunk-boundary','<p>'+('日本語😀 &amp; ').repeat(8000)+'</p>'],
 ['no-semicolon','<p>&copy &notit; &amp; &AMP; &amp;lt;</p>'],
 ['url-newline-entity','<a href="java&NewLine;script:evil()">危険</a>'],
 ['escaped-markup','<p>&lt;script&gt;表示用&lt;/script&gt;</p>'],
 ['fragment-closing','</div></body></html><p>末尾</p><div>続き</div>'],
 ['document-tail','<html><body><p>本文</p></body></html><p>末尾</p>'],
 ['numeric-html5','<p>&#128; &#x80; &#0; &#xD800; &#1114112; &#999999999999999999999999999; &#65終</p>'],
 ['legacy-attribute','<a href="https://example.invalid/?a=&copycat&copy=3&copy;z">&copycat &ampx</a>'],
 ['entity-double','<a href="java&amp;NewLine;script&amp;colon;evil()">&amp;lt; &amp;amp;</a>'],
 ['entity-two-scalars','<p>&NotEqualTilde; &fjlig; &acE; &nparsl;</p>'],
 ['styles-comment','<p style="color:/*注釈*/red;padding: 3px">本文</p>'],
 ['style-expression','<p style="width:expression(alert(1))">本文</p>'],
 ['style-escaped-expression','<p style="width:e\\78 pression(alert(1))">本文</p>'],
 ['style-escaped-url','<p style="background:url(j\\61vascript:evil)">本文</p>'],
 ['style-behavior','<p style="behavior : url(x)">本文</p>'],
 ['duplicate-attribute','<a href="javascript:evil()" href="https://example.invalid">リンク</a>'],
 ['text-less-than','<p>a < b & c > d << test</p>'],
 ['attributes-newline','<a href="https://example.invalid/?a=1&amp;b=2" title="除外">日本語</a>'],
 ['large-attribute','<img alt="'+('日本語😀').repeat(18000)+'" src="https://example.invalid/x">']
].map(([id,html])=>({id,html,expected:m.exports.nativeReference(html)}));
// Deliberate native differences, each with a concrete independent expectation.
// Valid HTML must still compare with the actual source sanitizer above.
for(const c of cases){
 if(c.id==='misnested'){c.nativeExpected='<p>ひとつ<b>太字</b></p><p>ふたつ末尾</p>';c.reason='libxml repairs invalid nested paragraphs; all text survives';}
 if(c.id.startsWith('style-expression')||c.id.startsWith('style-escaped-')||c.id==='style-behavior'){c.nativeExpected='<p>本文</p>';c.reason='native additionally removes legacy executable CSS, including escapes';}
}
const out={sourceSHA256:crypto.createHash('sha256').update(source).digest('hex'),cases};fs.writeFileSync(path.join(__dirname,'build/campaign-html-reference.json'),JSON.stringify(out));console.log(JSON.stringify({suite:'actual campaign sanitizer',cases:cases.length}));
