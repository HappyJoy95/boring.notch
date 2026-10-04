import test from 'node:test'; import assert from 'node:assert/strict'; import { randomUUID } from 'node:crypto';
import { createRuntime } from '../../Integrations/MiMoDesktop/runtime.mjs';
const session={id:'ses_one',directory:'/tmp/project'};
function fixture(){
 const calls=[], state={type:'idle'}, pending=[];
 const input={directory:session.directory,client:{session:{
  get:async o=>({data:{...session,time:{},parentID:null},response:{status:200}}),
  status:async o=>({data:{ses_one:{...state}},response:{status:200}}),
  promptAsync:async o=>{calls.push(['send',o]);return {response:{status:204}}},
  abort:async o=>{calls.push(['stop',o]);return {data:true,response:{status:200}}},
 },_client:{get:async o=>({data:pending,response:{status:200}})}}};
 const runtime=createRuntime(input);
 const body={session,scope:[session],request_id:randomUUID(),prompt:'测试消息'};
 return {runtime,body,calls,state,pending,input};
}
test('send is accepted only for an authorized root session, with its own directory',async()=>{
 const f=fixture();assert.equal(await f.runtime.control('send',f.body),'submitted');
 assert.equal(f.calls[0][1].path.id,session.id);assert.equal(f.calls[0][1].query.directory,session.directory);
 assert.deepEqual(f.calls[0][1].body.parts,[{type:'text',text:'测试消息'}]);
 assert.equal(await f.runtime.control('send',{...f.body,scope:[],request_id:randomUUID()}),'notPinned');
});
test('concurrent duplicate delivery is exactly once; changed payload is rejected',async()=>{
 const f=fixture();assert.deepEqual(await Promise.all([f.runtime.control('send',f.body),f.runtime.control('send',f.body)]),['submitted','submitted']);
 assert.equal(f.calls.length,1);assert.equal(await f.runtime.control('send',{...f.body,prompt:'different'}),'invalid');
});
test('busy sessions do not accept another prompt; abort is scoped and waits for idle confirmation',async()=>{
 const f=fixture();f.state.type='busy';assert.equal(await f.runtime.control('send',f.body),'busy');
 assert.equal(await f.runtime.control('stop',{...f.body,request_id:randomUUID()}),'submitted');
 assert.equal(f.calls[0][1].query.directory,session.directory);
 assert.equal((await f.runtime.status([session])).ses_one,'running');
 f.state.type='idle';assert.equal((await f.runtime.status([session])).ses_one,'interrupted');
});
test('questions and permissions map to waiting without approval; resolution returns running',async()=>{
 const f=fixture();f.state.type='busy';f.pending.push({id:'p',sessionID:'ses_one'});
 assert.equal((await f.runtime.status([session])).ses_one,'waiting');
 f.pending.length=0;assert.equal((await f.runtime.status([session])).ses_one,'running');
 assert.equal(f.calls.length,0);
});
test('completed and aborted events are scoped to the newest run',async()=>{
 const f=fixture();f.runtime.event({type:'message.updated',properties:{info:{sessionID:'ses_one',role:'assistant',agentID:'main',time:{completed:1}}}});
 assert.equal((await f.runtime.status([session])).ses_one,'completed');
 f.runtime.event({type:'session.status',properties:{sessionID:'ses_one',status:{type:'busy'}}});f.state.type='busy';
 assert.equal((await f.runtime.status([session])).ses_one,'running');
 f.state.type='idle';assert.equal((await f.runtime.status([session])).ses_one,'idle');
});
test('unknown result is retained and not automatically retried',async()=>{
 const f=fixture();f.input.client.session.promptAsync=async()=>{f.calls.push('lost');throw Error('lost')};
 assert.equal(await f.runtime.control('send',f.body),'unknown');assert.equal(await f.runtime.control('send',f.body),'unknown');
 assert.equal(f.calls.length,1);
});
test('archived, child, mismatched directory and oversized prompts are rejected',async()=>{
 for(const data of [{...session,parentID:'ses_parent'},{...session,time:{archived:1}},{...session,directory:'/tmp/other'}]){
  const f=fixture();f.input.client.session.get=async()=>({data,response:{status:200}});
  assert.equal(await f.runtime.control('send',f.body),'notPinned');assert.equal(f.calls.length,0);
 }
 const f=fixture();assert.equal(await f.runtime.control('send',{...f.body,prompt:'字'.repeat(3000)}),'invalid');
});
test('acceptance before busy event does not expose the previous completed state',async()=>{
 const f=fixture();assert.equal(await f.runtime.control('send',f.body),'submitted');
 assert.equal((await f.runtime.status([session])).ses_one,'running');
});
test('an externally started run clears old completion even if the busy event was missed',async()=>{
 const f=fixture();f.runtime.event({type:'message.updated',properties:{info:{sessionID:'ses_one',role:'assistant',time:{completed:1}}}});
 f.state.type='busy';assert.equal((await f.runtime.status([session])).ses_one,'running');
 f.state.type='idle';assert.equal((await f.runtime.status([session])).ses_one,'idle');
});
test('abort before an accepted asynchronous prompt has started remains unconfirmed',async()=>{
 const f=fixture();assert.equal(await f.runtime.control('send',f.body),'submitted');
 assert.equal(await f.runtime.control('stop',{...f.body,request_id:randomUUID()}),'unknown');
 assert.equal(f.calls.length,1);
});
test('a failed preflight does not claim uncertain dispatch or send a message',async()=>{
 const f=fixture();f.input.client.session.get=async()=>{throw Error('offline')};
 assert.equal(await f.runtime.control('send',f.body),'unavailable');assert.equal(f.calls.length,0);
});
