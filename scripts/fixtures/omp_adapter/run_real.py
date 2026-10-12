import json,sys,subprocess,threading,os,signal,http.server,io
from pathlib import Path
p=Path(__file__).resolve().parent;root=Path(os.environ['T08_ROOT'])
sys.path.insert(0,str(root/'scripts'))
from omp_gate_stress import ModelServer,PREFIX
class Handler(ModelServer):
 def do_POST(self):
  raw=self.rfile.read(int(self.headers.get('Content-Length','0')));body=json.loads(raw)
  user=next((m.get('content','') for m in reversed(body.get('messages',[])) if m.get('role')=='user'),'')
  if isinstance(user,list):user='\n'.join(part.get('text','') for part in user if isinstance(part,dict))
  case_prompt=False
  if PREFIX in str(user):
   suffix=str(user).split(PREFIX,1)[1].lstrip()
   try:
    _,end=json.JSONDecoder().raw_decode(suffix);case_prompt=not suffix[end:].strip()
   except json.JSONDecodeError:pass
  if case_prompt:self.rfile=io.BytesIO(raw);super().do_POST();return
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Connection','close');self.end_headers()
  chunk={'id':'ephemeral','object':'chat.completion.chunk','created':0,'model':'offline','choices':[{'index':0,'delta':{'role':'assistant','content':'Fixture title'},'finish_reason':None}]}
  self.wfile.write(('data: '+json.dumps(chunk)+'\n\n').encode());chunk['choices'][0]={'index':0,'delta':{},'finish_reason':'stop'};self.wfile.write(('data: '+json.dumps(chunk)+'\n\ndata: [DONE]\n\n').encode());self.wfile.flush()
out=p/'real';out.mkdir()
for d in ['live/project','live/home/.omp/agent/extensions','live/tmp']:(out/d).mkdir(parents=True,exist_ok=True)
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);server.daemon_threads=True
threading.Thread(target=server.serve_forever,daemon=True).start()
provider='''export default function(pi) { pi.registerProvider("tivano-offline", {baseUrl:"http://127.0.0.1:PORT/v1",apiKey:"offline-only",api:"openai-completions",models:[{id:"offline",name:"Offline real adapter",reasoning:false,input:["text"],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:1048576,maxTokens:4096}]});}'''.replace('PORT',str(server.server_port))
(out/'live/home/.omp/agent/extensions/offline.ts').write_text(provider)
(p/'Recorder.swift').write_text((p/'Harness.swift').read_text().split('@main struct Harness',1)[0])
files=json.loads((p/'source-arguments.json').read_text())
cmd=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-name','T08RealStress','-o',str(p/'real-adapter')]+files+[str(p/f) for f in ['TimelineTypes.swift','Shims.swift','Recorder.swift','RealHarness.swift']]
r=subprocess.run(cmd,capture_output=True,text=True,timeout=60);(p/'compile-real.log').write_text(r.stdout+r.stderr)
if r.returncode: print(r.stderr[-5000:]);raise SystemExit(r.returncode)
env={'PATH':os.environ['PATH'],'HOME':str(out/'live/home'),'T08_STORAGE':str(out)}
grouped=os.environ.get('T08_GROUPED')=='1'
child=subprocess.Popen([str(p/'real-adapter'),os.environ['T08_OMP']],env=env,start_new_session=not grouped,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
expired=False
try:text,_=child.communicate(timeout=150)
except subprocess.TimeoutExpired:
 expired=True
 if grouped:child.terminate()
 else:os.killpg(child.pid,signal.SIGTERM)
 try:text,_=child.communicate(timeout=5)
 except subprocess.TimeoutExpired:
  if grouped:child.kill()
  else:os.killpg(child.pid,signal.SIGKILL)
  text,_=child.communicate()
 print('Real adapter deadline; owned process group stopped.')
finally:
 # The outer runner owns the group in grouped mode; never signal that group here.
 if not grouped:
  try:os.killpg(child.pid,signal.SIGKILL)
  except ProcessLookupError:pass
 elif child.poll() is None:child.kill()
 if child.poll() is None:child.wait(timeout=5)
 server.shutdown();server.server_close()
(p/'real.log').write_text(text);print(text[-9000:]);print('exit',child.returncode)
if expired:raise SystemExit(124)
if child.returncode:raise SystemExit(child.returncode if child.returncode>0 else 1)
try:
 summary=json.loads((out/'summary-real.json').read_text())
 if not isinstance(summary,dict) or summary.get('passed') is not True:
  raise ValueError('real adapter summary did not pass')
except (OSError,ValueError) as error:
 print('Real adapter summary failed:',error);raise SystemExit(1)
