'use strict';
// Old-server-only adapter, explicit configuration. No environment or URL fetching.
// MinIO protocol matches lib/minio.ts / lib/invoices/storage.ts. A test transport
// can inject send; the ordinary Mac application never links this module.
const {S3Client,HeadObjectCommand,GetObjectCommand}=require('@aws-sdk/client-s3');
function sourceObjects(config,send){
 if(!config||!['minio'].includes(config.kind)||typeof config.bucket!=='string'||!config.bucket)throw Error('objects.configuration');
 let client;if(!send){client=new S3Client({endpoint:config.endpoint,region:config.region||'us-east-1',forcePathStyle:true,credentials:config.credentials});send=command=>client.send(command);}
 return {async read(key){
  if(typeof key!=='string'||!key||Buffer.byteLength(key)>1024||key.includes('\0')||/^https?:\/\//.test(key))return null;
  try{
   const head=await send(new HeadObjectCommand({Bucket:config.bucket,Key:key}));
   if(!Number.isSafeInteger(head.ContentLength)||head.ContentLength<0||typeof head.ETag!=='string')throw Error('object.metadata');
   const got=await send(new GetObjectCommand({Bucket:config.bucket,Key:key,IfMatch:head.ETag,...(head.VersionId?{VersionId:head.VersionId}:{})}));
   if(got.ContentLength!==head.ContentLength||got.ETag!==head.ETag||(head.VersionId&&got.VersionId!==head.VersionId)||!got.Body?.[Symbol.asyncIterator]){got.Body?.destroy?.();throw Error('object.changed');}
   return {body:got.Body,bytes:got.ContentLength,contentType:got.ContentType,version:got.VersionId||null,etag:got.ETag};
  }catch(e){if(e.name==='NoSuchKey'||e.name==='NotFound'||e.$metadata?.httpStatusCode===404)return null;throw e;}
 },close(){client?.destroy()}};
}
module.exports={sourceObjects};
