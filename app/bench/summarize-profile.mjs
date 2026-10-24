import { readFileSync, writeFileSync } from 'node:fs';
const path=process.argv[2];if(!path)throw Error('Pass a .cpuprofile path');
const p=JSON.parse(readFileSync(path)),nodes=new Map(p.nodes.map(n=>[n.id,n])),totals=new Map();
for(let i=0;i<p.samples.length;i++){const n=nodes.get(p.samples[i]),frame=n.callFrame,key=`${frame.functionName||'(anonymous)'} ${frame.url}:${frame.lineNumber+1}`;totals.set(key,(totals.get(key)??0)+(p.timeDeltas?.[i]??1000)/1000);}
const out={profile:path,duration_ms:(p.endTime-p.startTime)/1000,top_self_ms:[...totals].sort((a,b)=>b[1]-a[1]).slice(0,30).map(([frame,self_ms])=>({frame,self_ms}))};
console.log(JSON.stringify(out,null,2));if(process.argv[3])writeFileSync(process.argv[3],JSON.stringify(out,null,2)+'\n');
