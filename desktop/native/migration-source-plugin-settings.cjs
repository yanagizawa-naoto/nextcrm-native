'use strict';
// Use the actual four built-in schemas; preserve their original JSON bytes.
// Parsing is classification only, not applying Zod defaults or rewriting data.
const {createSourceLoader}=require('./plugins-source-loader.cjs');
const loader=createSourceLoader({'@nextcrm/plugin-sdk':{z:require('zod')}}),schemas=new Map();
for(const id of ['account-protection','odoo-connector','oxo-erp-connector'])schemas.set(id,loader.load('plugins/'+id+'/settings.ts').settingsSchema.strict());
function nonsecret(id,text){let value;try{value=JSON.parse(text)}catch{return false}if(value===null||Array.isArray(value)||typeof value!=='object')return false;if(id==='registry-ares')return Object.keys(value).length===0;const schema=schemas.get(id);if(!schema?.safeParse(value).success)return false;if(typeof value.url==='string'){try{let u=new URL(value.url);if(u.username||u.password||u.search||u.hash)return false}catch{return false}}return true;}
module.exports={nonsecret,sourceHashes:loader.hashes};
