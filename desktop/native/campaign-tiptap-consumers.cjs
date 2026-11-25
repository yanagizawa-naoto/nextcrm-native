const fs=require('fs'),path=require('path'),crypto=require('crypto');const {createRequire}=require('module');
const root=path.resolve(__dirname,'../..'),output=path.join(__dirname,'build','campaign-tiptap'),req=createRequire(path.join(root,'package.json')),esbuild=createRequire(req.resolve('tsx'))('esbuild');
fs.mkdirSync(output,{recursive:true});
const sourceFiles=[
 'components/campaigns/TipTapEditor.tsx',
 'app/[locale]/(routes)/campaigns/templates/new/components/TemplateEditorForm.tsx',
 'app/[locale]/(routes)/campaigns/templates/[templateId]/page.tsx',
 'app/[locale]/(routes)/campaigns/new/components/Step2Template.tsx',
 'app/[locale]/(routes)/campaigns/new/components/WizardShell.tsx',
 'actions/campaigns/templates/create-template.ts','actions/campaigns/templates/update-template.ts','actions/campaigns/templates/get-template.ts','actions/campaigns/templates/get-templates.ts','actions/campaigns/templates/preview-template.ts',
 'inngest/functions/campaigns/send-step.ts','lib/campaigns/render-email.ts','emails/CampaignLayout.tsx','lib/mcp/tools/campaigns.ts','scripts/db-backup.sh',
 'desktop/native/CampaignMailWorker.swift','desktop/native/CampaignTemplateEditor.swift','desktop/native/CampaignStepEditor.swift','desktop/native/CRMCampaignDraft.swift','desktop/native/NativeMCPCampaigns.swift'
];const sha=f=>crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');const sourceSHA256=Object.fromEntries(sourceFiles.map(f=>[f,sha(path.join(root,f))]));
const review=[
 {kind:'editor_read',source:sourceFiles[0],observed:'useEditor receives HTML content. onUpdate publishes getHTML and getJSON together. No initial update was observed in actual DOM fixtures.'},
 {kind:'metadata_save',source:sourceFiles[1],observed:'Initial HTML and JSON states remain unchanged until editor onUpdate. Native omits body fields on metadata-only save.'},
 {kind:'template_selection',source:sourceFiles[3],observed:'Reads t.content_html, not content_json. Wizard stores HTML/JSON fields rather than generating HTML from JSON.'},
 {kind:'outbound_send',source:'inngest/functions/campaigns/send-step.ts',observed:'resolveMergeTags(sendRecord.step.template.content_html, ...) feeds renderCampaignEmail. content_json is not read.'},
 {kind:'preview',source:'actions/campaigns/templates/preview-template.ts',observed:'Calls renderCampaignEmail with supplied contentHtml only.'},
 {kind:'mcp_read_create_update',source:'lib/mcp/tools/campaigns.ts',observed:'Returns full template record including both fields; create/update preserve supplied fields. No JSON to HTML conversion. An external JSON-only consumer remains outside this guarantee.'},
 {kind:'export',source:'scripts/db-backup.sh',observed:'Database backup uses pg_dump of all fields. This script was read only and NEVER executed. No dedicated template-body export operation found; report CSV exports aggregates, not template content.'},
 {kind:'native_send',source:'desktop/native/CampaignMailWorker.swift',observed:'Selects content_html and passes it to CampaignMail.prepare; no content_json rendering.'},
 {kind:'native_copy',source:'desktop/native/CRMCampaignDraft.swift',observed:'Copies/stores content_html and content_json independently; actual SQLite clone/reopen tests cover exact fields.'}
];
esbuild.buildSync({entryPoints:[path.join(root,'lib/campaigns/render-email.ts')],bundle:true,packages:'external',platform:'node',format:'cjs',jsx:'automatic',outfile:path.join(output,'render-source.cjs'),define:{'process.env.NEXT_PUBLIC_APP_NAME':'"NextCRM QA"'},logLevel:'silent'});
(async()=>{const {renderCampaignEmail}=require(path.join(output,'render-source.cjs'));let checks=0;const cases=[];
for(const input of [
 {id:'table',html:'<table><tr><td>本文表のデータ</td></tr></table>',text:'本文表のデータ'},
 {id:'styles',html:'<p style="color:red">保持する本文</p>',text:'保持する本文'},
 {id:'custom_link',html:'<p><a href="https://example.invalid" target="_self">連絡はこちら</a></p>',text:'連絡はこちら'},
]){const html=await renderCampaignEmail({contentHtml:input.html,unsubscribeUrl:'https://example.invalid/unsubscribe',content_json:{type:'doc',content:[{type:'paragraph',attrs:{nativeRawHTML:input.html},content:[{type:'text',text:'［既存のHTMLを保持：表・画像・詳細な書式］'}]}]}});
 if(!html.includes(input.text)||html.includes('［既存のHTMLを保持'))throw Error('rendered JSON placeholder or lost HTML');checks+=2;cases.push({id:input.id,htmlSHA256:crypto.createHash('sha256').update(html).digest('hex'),bytes:Buffer.byteLength(html),bodyRetained:true,placeholderAbsent:true});}
if(!sourceFiles.every(f=>sourceSHA256[f]===sha(path.join(root,f))))throw Error('Consumer sources changed');
fs.writeFileSync(path.join(output,'consumer-verification.json'),JSON.stringify({checks,cases,review,sourceSHA256,scope:'Actual upstream render only; consumer routing reviewed read-only. No live send, PG, MCP transport or export execution.',downloads:false,network:false},null,2)+'\n');console.log('TipTap consumer review: '+checks+' actual render checks; '+sourceFiles.length+' hashed source files');
})().catch(e=>{console.error(e);process.exit(1)});
