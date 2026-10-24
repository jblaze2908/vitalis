// Run against a benchmark DB with VITALIS_DB=...; never point at production.
import { writeFileSync } from 'node:fs';
if(!process.env.VITALIS_DB)throw Error('VITALIS_DB must identify a synthetic benchmark DB');
const {app}=await import('../dist/src/server.js');const{createToken}=await import('../dist/src/tokens.js');
const token=createToken('concurrent synthetic read probe','write').token, headers={authorization:`Bearer ${token}`,'content-type':'application/json'};
const envelope=upserts=>({schema:1,batch_id:`read-${Date.now()}-${Math.random()}`,client:{install_id:'synthetic',app_version:'1',os:'iOS 26.1',model:'iPhone'},upserts,deletions:[],daily_stats:[]});
const send=raw=>app.request('/v2/samples',{method:'POST',headers,body:raw});
const warm=await send(JSON.stringify(envelope([])));if(!warm.ok)throw Error(await warm.text());await warm.text();
const metrics={health:[],status:[],freshness:[],batch:[]};let id=0;
for(let round=0;round<5;round++){
 const raw=JSON.stringify(envelope(Array.from({length:5000},(_,i)=>({uuid:`read-probe-${Date.now()}-${round}-${i}`,type:'HKQuantityTypeIdentifierStepCount',kind:'quantity',start:'2026-01-01T10:00:00Z',end:'2026-01-01T10:01:00Z',source:{name:'Read probe Watch',bundle_id:'synthetic'},value:20,unit:'count'}))));
 await new Promise(resolve=>setImmediate(resolve));
 const start=performance.now(),batch=send(raw).then(async r=>{const body=await r.json();if(!r.ok||body.counts.rejected)throw Error(JSON.stringify(body));metrics.batch.push(performance.now()-start);});
 const reads=new Promise((resolve,reject)=>setTimeout(async()=>{try{
  await Promise.all(Object.keys(metrics).filter(k=>k!=='batch').map(async name=>{
   const r=name==='health'?await app.request('/health'):name==='status'?await app.request('/v2/sync/status',{headers}):await app.request('/mcp',{method:'POST',headers:{...headers,accept:'application/json, text/event-stream','mcp-protocol-version':'2025-06-18'},body:JSON.stringify({jsonrpc:'2.0',id:++id,method:'tools/call',params:{name:'get_freshness',arguments:{}}})});
   const text=await r.text();if(!r.ok||text.includes('"isError":true'))throw Error(text);metrics[name].push(performance.now()-start);
  }));resolve();
 }catch(e){reject(e);}},1));
 await Promise.all([batch,reads]);
}
const report=Object.fromEntries(Object.entries(metrics).map(([key,v])=>{v.sort((a,b)=>a-b);return[key,{p50_ms:v[2],p95_ms:v[4],max_ms:v[4]}];}));
console.log(JSON.stringify(report,null,2));writeFileSync(process.env.READ_OUTPUT??'bench/results/read-latency.json',JSON.stringify(report,null,2)+'\n');
process.exit(0);
