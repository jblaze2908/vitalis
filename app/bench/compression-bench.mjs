// Compare retention codecs on the actual contract shapes; generation is outside compression timing.
import * as z from 'node:zlib';
import { writeFileSync } from 'node:fs';
const source={name:'Benchmark Watch',bundle_id:'com.apple.health',version:'26.1',product_type:'Watch7,1',os_version:'26.1'};
const base=(i,kind,type)=>({uuid:`${(Math.imul(i,2654435761)>>>0).toString(16).padStart(8,'0')}-0000-4000-8000-${i.toString(16).padStart(12,'0')}`,kind,type,start:new Date(1577836800000+i*300000).toISOString(),end:new Date(1577836800000+i*300000).toISOString(),source});
const results={};
for(const shape of ['heart_rate','cumulative','sleep','route','ecg']) {
 const upserts=Array.from({length:5000},(_,i)=>shape==='sleep'?{...base(i,'category','HKCategoryTypeIdentifierSleepAnalysis'),value:3+i%3,value_label:'asleepCore'}
  :{...base(i,'quantity',`HKQuantityTypeIdentifier${shape==='cumulative'?'StepCount':'HeartRate'}`),value:shape==='cumulative'?20+i%70:55+i%55,unit:shape==='cumulative'?'count':'count/min'});
 if(shape==='route')for(let i=0;i<10;i++)upserts[i]={...base(i,'route','HKWorkoutRoute'),workout_uuid:'parent',points:Array.from({length:2700},(_,j)=>[new Date(1577836800000+j*1000).toISOString(),37.7+j*0.00001,-122.4+Math.sin(j/20)*0.001,10+Math.sin(j/10),3,4,3,90])};
 if(shape==='ecg')upserts[0]={...base(0,'ecg','HKElectrocardiogramType'),classification:1,symptoms_status:0,avg_hr:68,sampling_hz:512,voltages_uv:Array.from({length:15000},(_,j)=>120*Math.sin(j/13)+5*Math.sin(j/3))};
 const raw=Buffer.from(JSON.stringify({schema:1,batch_id:shape,client:{install_id:'synthetic',app_version:'1',os:'iOS 26.1',model:'iPhone'},upserts,deletions:[],daily_stats:[]}));
 results[shape]={input_bytes:raw.length};
 for(const [codec,compress,decompress]of[['gzip',z.gzipSync,z.gunzipSync],...(typeof z.zstdCompressSync==='function'?[['zstd',z.zstdCompressSync,z.zstdDecompressSync]]:[])]) {
  const ms=[];let packed;
  for(let i=0;i<15;i++){const t=performance.now();packed=compress(raw);if(i>=3)ms.push(performance.now()-t);}
  if(!decompress(packed).equals(raw))throw Error('lossless round trip failed');
  ms.sort((a,b)=>a-b);results[shape][codec]={bytes:packed.length,p50_ms:ms[5],p95_ms:ms[11]};
 }
}
console.log(JSON.stringify(results,null,2));writeFileSync('bench/results/compression.json',JSON.stringify(results,null,2)+'\n');
