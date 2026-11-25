// Execute both original actions; reuse the independent relational fixture and
// actual TypeScript authorization helpers from the global-search oracle.
const fs=require('node:fs'), fixture=require('./native-search-reference.cjs');
const {records,labels,vectors,users,load,hydrate,matches,account,doc}=fixture;
const alice=users.find(x=>x.username==='alice');
for(let i=0;i<107;i++) account('picker-'+i,{name:`候補 ${String(i).padStart(3,'0')}`,assigned_to:alice.id});
account('late-name',{name:'長'.repeat(700)+'末尾候補',assigned_to:alice.id});
account('email-only',{name:'一致しない会社',email:'候補@example.invalid',assigned_to:alice.id});
records.Documents.find(x=>x.id===labels['semantic-doc']).visibility='public';
records.Documents.find(x=>x.id===labels['own-doc']).document_system_type='CONTRACT';
for(let i=0;i<6;i++) doc('extra-keyword-'+i,{document_name:'検索用の追加文書 '+i,summary:'日本語の要約',visibility:'public'});
for(let i=0;i<8;i++) {
  const row=doc('extra-semantic-'+i,{document_name:'別の資料 '+i,visibility:'public'});
  vectors.push({kind:'document',parentID:row.id,values:[4,3]});
}
for(const row of records.Documents)row.document_system_type??='OTHER';
(async()=>{
 const accounts=load('actions/crm/accounts/search-accounts.ts'),documents=load('actions/documents/search-documents.ts'),auth=load('lib/authz/scopes/crm.ts');
 const accountCases=[],documentCases=[];
 for(const user of users){
  fixture.setActor(user);
  for(const search of ['', '検索','候補','末尾候補','存在しない','%_'])for(const skip of [0,100]) {
   const result=await accounts.searchAccounts({search,skip,take:100});if(result.error)throw Error(result.error);
   accountCases.push({userId:user.id,role:user.role,partnerAccountId:user.partnerAccountId??null,search,skip,result:{accounts:result.accounts.map(({id,name})=>({id,name})),total:result.total,hasMore:result.hasMore}});
  }
  for(const semantic of [false,true])for(const query of ['検索','別の資料','存在しない']){
   fixture.setSemantic(semantic);const result=await documents.searchDocuments(query);
   // Do not reproduce the source's unscoped linked-account disclosure.
   for(const hit of result){const row=records.Documents.find(r=>r.id===hit.id),links=hydrate('Documents',row).accounts;hit.accountName=links.map(x=>x.account).find(a=>matches(a,auth.accountReadScopeWhere(user)))?.name??null;}
   documentCases.push({userId:user.id,role:user.role,partnerAccountId:user.partnerAccountId??null,semantic,query,result});
  }
 }
 fs.writeFileSync(process.argv[2],JSON.stringify({sourceSHA256:fixture.hashes,records,labels,vectors,accountCases,documentCases,intentionalCorrections:['Current account visibility also gates document account-name display','Stable ID order for unspecified document ties','Display names/summaries are bounded prefixes; matching uses complete fields','Literal wildcard matching, not SQL pattern expansion','Native reference picker uses100-row pages, source permits100','Semantic visibility applied before top-k; reference positive vectors are public to isolate source ranking']},null,2)+'\n');
 console.log(JSON.stringify({accountCases:accountCases.length,documentCases:documentCases.length}));
})().catch(error=>{console.error(error);process.exitCode=1;});
