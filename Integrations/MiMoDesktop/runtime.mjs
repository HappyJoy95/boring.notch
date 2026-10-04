import http from 'node:http';
import { createHash, timingSafeEqual } from 'node:crypto';
import { readFile, writeFile, rename, lstat } from 'node:fs/promises';
import path from 'node:path';
export const VERSION='0.1.0';
const validID=id=>typeof id==='string' && /^ses_[A-Za-z0-9_-]{1,124}$/.test(id);
const validSession=s=>s && validID(s.id) && typeof s.directory==='string' && path.isAbsolute(s.directory) && s.directory.length<=4096;
const uuid=id=>typeof id==='string' && /^[a-f0-9-]{36}$/i.test(id) && /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(id);
const options=s=>({path:{id:s.id},query:{directory:s.directory},headers:{'x-mimocode-directory':encodeURIComponent(s.directory)}});
const ok=r=>r && !r.error && r.response?.status>=200 && r.response.status<300;
const timeout=(promise,ms=5000)=>new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('timeout')),ms);timer.unref?.();Promise.resolve(promise).then(value=>{clearTimeout(timer);resolve(value)},error=>{clearTimeout(timer);reject(error)});});

/** SDK client is supplied by the host. Model/account credentials never enter the bridge. */
export function createRuntime(input){
 let client=input.client;
 const events=new Map(), receipts=new Map(), locks=new Set();
 function attach(next){if(next?.client?.session)client=next.client;}
 function event(e){
  const p=e?.properties??{}, info=p.info??{}, id=p.sessionID??info.sessionID;
  if(!validID(id))return;
  let state=events.get(id)??{};
  if(e.type==='session.deleted'){events.delete(id);return;}
  if(e.type==='session.status' && ['busy','retry'].includes(p.status?.type)){state.terminal=null;state.pendingSend=null;}
  if(e.type==='session.error'){state.terminal='interrupted';state.pendingSend=null;}
  if(e.type==='message.updated' && info.role==='assistant' && (!info.agentID || info.agentID==='main') && info.time?.completed){
   state.terminal=info.error?'interrupted':'completed';state.pendingSend=null;
  }
  if(events.size>=1024 && !events.has(id))events.delete(events.keys().next().value);
  events.set(id,state);
 }
 async function inspect(s){
  const r=await timeout(client.session.get(options(s)));
  if(!ok(r))throw Error('unavailable');
  if(r.data?.id!==s.id || r.data.directory!==s.directory || r.data.parentID || r.data.time?.archived)return false;
  return true;
 }
 async function status(scope){
  if(!Array.isArray(scope) || scope.length>32 || !scope.every(validSession))throw Error('invalid');
  const grouped=new Map();for(const s of scope){const list=grouped.get(s.directory)??[];list.push(s);grouped.set(s.directory,list);}
  const result={};
  await Promise.all([...grouped.values()].map(async sessions=>{
   const opts=options(sessions[0]);
   const r=await timeout(client.session.status(opts));
   if(!ok(r) || !r.data || typeof r.data!=='object' || Array.isArray(r.data))throw Error('unavailable');
   if(typeof client._client?.get!=='function')throw Error('unsupported');
   const pending=await Promise.all(['/permission','/question'].map(url=>timeout(client._client.get({url,query:opts.query,headers:opts.headers}))));
   if(pending.some(value=>!ok(value)||!Array.isArray(value.data)))throw Error('unavailable');
   for(const s of sessions){
    const state=events.get(s.id)??{}, raw=r.data[s.id]?.type??'idle';
    if(!['busy','retry','notice','idle'].includes(raw))throw Error('unsupported');
    const waiting=pending.some(value=>value.data.some(p=>p.sessionID===s.id && (!p.actorID || p.actorID==='main')));
    if(waiting)result[s.id]='waiting';
    else if(raw==='busy'||raw==='retry'||raw==='notice'){state.pendingSend=null;state.terminal=null;result[s.id]='running';}
    else if(state.pendingSend && Date.now()-state.pendingSend<15000)result[s.id]='running';
    else if(state.pendingSend)result[s.id]='unavailable';
    else {
     if(state.stopping){state.stopping=false;state.terminal='interrupted';events.set(s.id,state);}
     result[s.id]=state.terminal??'idle';
    }
   }
  }));
  return result;
 }
 async function execute(action,b){
  const s=b.session;let dispatched=false;
  try{
   if(!await inspect(s))return 'notPinned';
   if(action==='send'){
    const current=(await status([s]))[s.id];
    if(current==='running'||current==='waiting')return 'busy';
    events.set(s.id,{terminal:null,pendingSend:Date.now()});
    dispatched=true;
    const response=await timeout(client.session.promptAsync({...options(s),body:{parts:[{type:'text',text:b.prompt.trim()}]}}),15000);
    if(response?.response?.status===204 && !response.error)return 'submitted';
    if(response?.response?.status===409)return 'busy';
    if([400,404].includes(response?.response?.status))return 'failed';
    return 'unknown';
   }
   const before=await timeout(client.session.status(options(s)));
   if(!ok(before) || !before.data || typeof before.data!=='object')return 'unknown';
   if((before.data[s.id]?.type??'idle')==='idle'){
    // If the asynchronous prompt has not started, abort cannot prove it was cancelled.
    return events.get(s.id)?.pendingSend?'unknown':'submitted';
   }
   dispatched=true;
   const response=await timeout(client.session.abort(options(s)),15000);
   if(ok(response) && response.data===true){
    const state=events.get(s.id)??{};state.stopping=true;state.pendingSend=null;events.set(s.id,state);return 'submitted';
   }
   return 'unknown';
  }catch{return dispatched?'unknown':'unavailable';}
 }
 async function control(action,b){
  if(!['send','stop'].includes(action)||!validSession(b?.session)||!uuid(b.request_id))return 'invalid';
  if(!Array.isArray(b.scope)||b.scope.length>32||!b.scope.every(validSession))return 'invalid';
  if(!b.scope.some(s=>s.id===b.session.id && s.directory===b.session.directory))return 'notPinned';
  if(action==='send' && (typeof b.prompt!=='string'||!b.prompt.trim()||Buffer.byteLength(b.prompt)>8192))return 'invalid';
  const signature=createHash('sha256').update(JSON.stringify([action,b.session.id,b.session.directory,action==='send'?b.prompt:''])).digest('hex');
  const prior=receipts.get(b.request_id);
  if(prior)return prior.signature===signature?await prior.promise:'invalid';
  // Preserve every uncertain receipt for this process lifetime; refuse when full instead of evicting it.
  if(receipts.size>=512 || locks.has(b.session.id))return 'busy';
  locks.add(b.session.id);
  const promise=execute(action,b).finally(()=>locks.delete(b.session.id));
  receipts.set(b.request_id,{signature,promise});return await promise;
 }
 return {attach,event,status,control};
}

export async function startBridge(input,configurationURL){
 const stat=await lstat(configurationURL);
 if(!stat.isFile() || stat.isSymbolicLink() || stat.size>4096 || (stat.mode&0o077)!==0 || stat.uid!==process.getuid())throw Error('invalid configuration');
 const config=JSON.parse(await readFile(configurationURL,'utf8'));
 if(!/^[a-f0-9]{64}$/.test(config.token))throw Error('invalid configuration');
 const runtime=createRuntime(input);
 const server=http.createServer(async(req,res)=>{
  const reply=(status,value)=>{if(res.destroyed)return;res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value));};
  const expected=Buffer.from('Bearer '+config.token), received=Buffer.from(req.headers.authorization??'');
  if(req.headers.origin || received.length!==expected.length || !timingSafeEqual(received,expected)){reply(403,{error:'unauthorized'});return;}
  if(req.url==='/v1/health' && req.method==='GET'){reply(200,{schema_version:1,bridge:'boring-notch-mimo',version:VERSION,capabilities:['send','stop','status']});return;}
  if(req.method!=='POST'||!['/v1/status','/v1/control'].includes(req.url)){reply(404,{error:'not_found'});return;}
  if(!/^application\/json(?:;|$)/i.test(req.headers['content-type']??'')){reply(415,{error:'content_type'});return;}
  try{
   let size=0, chunks=[];
   for await(const chunk of req){size+=chunk.length;if(size>180000){reply(413,{error:'too_large'});req.destroy();return;}chunks.push(chunk);}
   const body=JSON.parse(Buffer.concat(chunks).toString('utf8'));
   if(req.url==='/v1/status')reply(200,{schema_version:1,statuses:await runtime.status(body.scope)});
   else reply(200,{schema_version:1,request_id:body.request_id,result:await runtime.control(body.action,body)});
  }catch{reply(503,{error:'unavailable'});}
 });
 server.requestTimeout=20000;server.headersTimeout=10000;server.maxConnections=16;
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve)});
 const actual={schema_version:1,version:VERSION,port:server.address().port,token:config.token,pid:process.pid};
 const staging=configurationURL+'.'+process.pid+'.tmp';
 try{await writeFile(staging,JSON.stringify(actual),{mode:0o600});await rename(staging,configurationURL);}
 catch(error){server.close();throw error;}
 return {runtime,server};
}
