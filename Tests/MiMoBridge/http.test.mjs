import test from 'node:test';import assert from 'node:assert/strict';import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';import {tmpdir} from 'node:os';import path from 'node:path';import {randomUUID} from 'node:crypto';
import {startBridge} from '../../Integrations/MiMoDesktop/runtime.mjs';
test('private loopback bridge validates authentication, origins, content type, health and control receipts',async()=>{
 const dir=await mkdtemp(path.join(tmpdir(),'mimo-http-'));const file=path.join(dir,'config.json');const token='a'.repeat(64);const scope=[{id:'ses_test',directory:'/tmp/project'}];let calls=0;
 await writeFile(file,JSON.stringify({port:0,token}),{mode:0o600});
 const client={session:{get:async()=>({data:{...scope[0],time:{}},response:{status:200}}),status:async()=>({data:{},response:{status:200}}),promptAsync:async()=>{calls++;return {response:{status:204}}}},_client:{get:async()=>({data:[],response:{status:200}})}};
 const bridge=await startBridge({client},file);const config=JSON.parse(await readFile(file));const base='http://127.0.0.1:'+config.port;
 const headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'};
 try{
  assert.equal(bridge.server.address().address,'127.0.0.1');
  assert.equal((await fetch(base+'/v1/health')).status,403);
  assert.equal((await fetch(base+'/v1/health',{headers:{...headers,Origin:'https://example.com'}})).status,403);
  const health=await (await fetch(base+'/v1/health',{headers})).json();assert.deepEqual(health.capabilities,['send','stop','status']);
  const status=await (await fetch(base+'/v1/status',{method:'POST',headers,body:JSON.stringify({scope})})).json();assert.equal(status.statuses.ses_test,'idle');
  const request={action:'send',session:scope[0],scope,prompt:'测试',request_id:randomUUID()};
  const first=await (await fetch(base+'/v1/control',{method:'POST',headers,body:JSON.stringify(request)})).json();
  assert.equal(first.request_id,request.request_id);assert.equal(first.result,'submitted');
  const second=await (await fetch(base+'/v1/control',{method:'POST',headers,body:JSON.stringify(request)})).json();assert.deepEqual(first,second);assert.equal(calls,1);
  assert.equal((await fetch(base+'/v1/control',{method:'POST',headers:{Authorization:headers.Authorization},body:'{}'})).status,415);
 }finally{await new Promise(resolve=>bridge.server.close(resolve));await rm(dir,{recursive:true,force:true});}
});
