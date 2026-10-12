#!/usr/bin/env python3
import json,sys,os,time
from pathlib import Path
root=Path(os.environ['T08_CASE_ROOT'])
root.mkdir(parents=True,exist_ok=True)
session=root/'session-1.jsonl';session.touch()
active=None;pending={}
def emit(**e):print(json.dumps(e,ensure_ascii=False),flush=True)
def response(m,ok=True,data=None,error='fixture rejection'):
 emit(type='response',id=m.get('id'),success=ok,**({'data':data or {}} if ok else {'error':error}))
def done(status='completed',error=None):
 global active
 emit(type='prompt_result',id=active,status=status,**({'error':{'message':error}} if error else {}));active=None

def text(value,parts=1):
 emit(type='message_start',message={'role':'assistant'})
 step=max(1,len(value)//parts)
 for i in range(0,len(value),step):emit(type='message_update',assistantMessageEvent={'type':'text_delta','delta':value[i:i+step]})
 emit(type='message_end',message={'role':'assistant','content':[{'type':'text','text':value}], 'usage':{'totalTokens':7,'input':3,'output':4},'model':'fixture'})
def approval(n):
 ident='approval-'+str(n);tid='tool-'+str(n)
 emit(type='tool_execution_start',toolCallId=tid,toolName='bash',args={'command':'printf fixture'})
 emit(type='extension_ui_request',id=ident,method='select',title='tivano-gate '+json.dumps({'toolName':'bash','toolCallId':tid,'input':{'command':'printf fixture'},'kind':'command'}),options=['Approve','Deny'])
 pending[ident]=n
for line in sys.stdin:
 m=json.loads(line);kind=m['type'];mode=os.environ.get('T08_START','')
 if kind=='get_available_commands':
  response(m,data={'commands':[] if mode=='missing-gate' else [{'name':'tivano-gate'}]})
 elif kind=='get_state':
  if mode=='waiting-state':continue
  response(m,ok=mode!='bad-state',data={'sessionFile':str(session),'model':{'contextWindow':100000}})
 elif kind=='get_branch_messages':response(m,data={'messages':[{'entryId':'a','text':'first prompt'},{'entryId':'b','text':'remove target'}]})
 elif kind=='branch':
  if os.environ.get('T08_BRANCH')=='deny':response(m,ok=False)
  else:session=root/'session-fork.jsonl';session.touch();response(m,data={'cancelled':False})
 elif kind in ('set_model','set_thinking_level'):response(m,ok=False)
 elif kind=='compact':response(m,data={})
 elif kind=='abort':
  response(m)
  if active:done('aborted')
 elif kind=='extension_ui_response':
  response(m)
  n=pending.pop(m['id'],None)
  if n is not None:
   emit(type='tool_execution_end',toolCallId='tool-'+str(n),result={'content':[{'type':'text','text':'ok' if m.get('value')=='Approve' else 'Declined: the user declined this command.'}]},isError=m.get('value')!='Approve')
   if n==1 and os.environ.get('T08_APPROVAL')=='always':approval(2)
   else:done()
 elif kind=='prompt':
  msg=m.get('message','')
  if msg=='/rename':
   emit(type='session_info_update',title='Fixture title');emit(type='command_output',text='rename done');response(m,data={'agentInvoked':False});continue
  active=m['id'];response(m)
  if msg=='abort':continue
  if msg=='exit':sys.exit(7)
  if msg=='approval':approval(1);continue
  if msg=='usage':
   emit(type='auto_retry_start',errorId=0x00080000,errorMessage='usage limit; provider requested 1800000ms wait')
   done('error','usage limit; provider requested 1800000ms wait');continue
  if msg=='retry':emit(type='agent_end');time.sleep(.05)
  if msg=='wrong-id':emit(type='prompt_result',id='not-this-turn',status='completed');time.sleep(.05)
  refusals={
   'direct-decline':('Declined: the user declined this command.',True),
   'wrapped-decline':('Error: Declined: the user declined this command.',True),
   'wrapped-decline-stack':('Error: Declined: the user declined this command.\n    at fixture\nCommand exited with code 1',True),
   'quoted-decline':('Execution failed while quoting Error: Declined: in a log.',True),
   'successful-decline-text':('Error: Declined: the user declined this command.',False),
  }
  if msg in refusals:
   output,is_error=refusals[msg]
   emit(type='tool_execution_start',toolCallId='refusal-1',toolName='eval',args={})
   emit(type='tool_execution_end',toolCallId='refusal-1',result={'content':[{'type':'text','text':output}]},isError=is_error)
  if msg=='todo':
   emit(type='tool_execution_start',toolCallId='todo-1',toolName='todo',args={})
   emit(type='tool_execution_end',toolCallId='todo-1',result={'details':{'phases':[{'tasks':[{'content':'one','status':'in_progress'},{'content':'two','status':'blocked'},{'content':'three','status':'completed'}]}]}},isError=False)
  if msg=='cancel':
   emit(type='extension_ui_request',id='q',method='confirm',title='fixture?')
   emit(type='extension_ui_request',id='q',method='cancel')
  if msg=='tool':
   target=root/'edited.txt';target.write_text('old')
   emit(type='tool_execution_start',toolCallId='edit-1',toolName='write',args={'path':str(target),'content':'new'})
   target.write_text('new')
   emit(type='tool_execution_end',toolCallId='edit-1',result={'content':[{'type':'text','text':'written'}],'details':{}},isError=False)
  value=''.join(str(i)+':中文🙂e\u0301\n' for i in range(20000)) if msg=='large' else '中文🙂' * 1000 if msg=='flood' else 'ok'
  text(value,1000 if msg=='flood' else 1);done()
