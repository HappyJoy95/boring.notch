import json, sqlite3, struct, pathlib, sys
root=pathlib.Path(sys.argv[1]); root.mkdir(parents=True,exist_ok=True)
key=b'_app://-\0\x01mimo.pinned'
def var(n):
 b=bytearray()
 while n>=128:b.append((n&127)|128);n>>=7
 b.append(n);return bytes(b)
def string(b):return var(len(b))+b
def crc(b):
 c=0xffffffff
 for x in b:
  c^=x
  for _ in range(8):c=(c>>1)^(0x82f63b78 if c&1 else 0)
 return c^0xffffffff
def masked(b):
 c=crc(b);return struct.pack('<I',(((c>>15)|(c<<17))+0xa282ead8)&0xffffffff)
def log(records):
 out=bytearray()
 for payload in records:
  first=True
  while payload:
   rem=32768-len(out)%32768
   if rem<7:out+=bytes(rem);rem=32768
   chunk=payload[:rem-7];payload=payload[len(chunk):]
   typ=1 if first and not payload else (2 if first else (3 if payload else 4))
   out+=masked(bytes([typ])+chunk)+struct.pack('<HB',len(chunk),typ)+chunk;first=False
 return bytes(out)
def batch(seq,value):return struct.pack('<QI',seq,1)+(b'\0'+string(key) if value is None else b'\1'+string(key)+string(value))
def block(rows):
 b=b''
 for k,v in rows:b+=var(0)+var(len(k))+var(len(v))+k+v
 return b+struct.pack('<II',0,1)
def snappy(b):
 n=len(b)-1
 return var(len(b))+bytes([((59+(n.bit_length()+7)//8)<<2)])+n.to_bytes((n.bit_length()+7)//8,'little')+b
# Create a real table with one compressed data block and a standard footer.
def table(seq,value,compressed=True):
 raw=block([(key+struct.pack('<Q',(seq<<8)|1),value)])
 payload=snappy(raw) if compressed else raw;typ=1 if compressed else 0
 data=payload+bytes([typ])+masked(payload+bytes([typ]))
 index=block([(key+struct.pack('<Q',(seq<<8)|1),var(0)+var(len(payload)))])
 handle=var(len(data))+var(len(index))
 return data+index+b'\0'+masked(index+b'\0')+(var(0)+var(0)+handle).ljust(40,b'\0')+struct.pack('<Q',0xdb4775248b80fb57)
def store(name,wal=None):
 p=root/name;p.mkdir()
 (p/'CURRENT').write_text('MANIFEST-000001\n')
 # log number 3, table number2; table99 is obsolete and must be ignored
 edit=var(2)+var(3)+var(7)+var(0)+var(2)+var(1)+string(key)+string(key)
 (p/'MANIFEST-000001').write_bytes(log([edit]))
 (p/'000002.ldb').write_bytes(table(10,b'\x01["ses_one","ses_two"]'))
 (p/'000099.ldb').write_bytes(table(999,b'\x01["ses_obsolete"]'))
 if wal is not None:(p/'000003.log').write_bytes(log([batch(20,wal)]))
 return p
store('table')
store('wal',b'\x01["ses_two"]')
store('deleted',None).joinpath('000003.log').write_bytes(log([batch(20,None)]))
store('empty',b'\x01[]')
store('mixed',b'\x01["ses_child","ses_archived","ses_one","ses_one","local_draft"]')
store('tie',b'\x01["ses_tie"]')
store('fragmented',b'\x01'+b' '*40000+b'["ses_two"]')
p=store('partial',b'\x01["ses_two"]');p.joinpath('000003.log').write_bytes(p.joinpath('000003.log').read_bytes()+b'\0\0')
p=store('bad');p.joinpath('000002.ldb').write_bytes(b'broken')
p=store('badcrc');b=bytearray(p.joinpath('000002.ldb').read_bytes());b[10]^=1;p.joinpath('000002.ldb').write_bytes(b)
p=store('utf16',b'\0'+json.dumps(['ses_two']).encode('utf-16-le'))
c=sqlite3.connect(root/'mimocode.db')
c.executescript('''CREATE TABLE session(id TEXT PRIMARY KEY,title TEXT,directory TEXT,parent_id TEXT,time_updated INTEGER,time_archived INTEGER);
CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT,agent_id TEXT,time_created INTEGER,data TEXT);
CREATE TABLE part(id TEXT PRIMARY KEY,message_id TEXT,session_id TEXT,time_created INTEGER,data TEXT);''')
for id,parent,archived in [('ses_one',None,None),('ses_two',None,None),('ses_unpinned',None,None),('ses_child','ses_one',None),('ses_archived',None,1),('ses_tie',None,None)]:
 c.execute('INSERT INTO session VALUES(?,?,?,?,?,?)',(id,id,'/tmp/project',parent,100000,archived))
 for i in range(70):
  role='user' if i%2==0 else 'assistant';mid=f'{id}_{i:03}'
  c.execute('INSERT INTO message VALUES(?,?,?,?,?)',(mid,id,'main',1000 if id=='ses_tie' else 1000+i,json.dumps({'role':role,'time':{'completed':1000+i} if role=='assistant' else {}})))
  for typ,text in [('text',f'body-{i}'),('tool','tool-secret'),('reasoning','reasoning-secret')]:
   c.execute('INSERT INTO part VALUES(?,?,?,?,?)',(mid+typ,mid,id,1000+i,json.dumps({'type':typ,'text':text})))
 # Subagent text must never be exposed.
 mid=id+'_sub';c.execute('INSERT INTO message VALUES(?,?,?,?,?)',(mid,id,'worker',9999,'{"role":"assistant"}'))
 c.execute('INSERT INTO part VALUES(?,?,?,?,?)',(mid,mid,id,9999,'{"type":"text","text":"subagent-secret"}'))
c.commit();c.close()
