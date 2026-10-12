import re,json,hashlib,os
from pathlib import Path
root=Path(os.environ['T08_ROOT'])
out=Path(os.environ['T08_KIT'])
files=['Tivano/Services/Providers/OmpSession.swift','Tivano/Services/Providers/OmpCLI.swift','Tivano/Services/Providers/ProviderSession.swift','Tivano/Services/Providers/SessionSupport.swift','Tivano/Services/Providers/UsageLimitSignal.swift','Tivano/Core/Support/StdioProcess.swift','Tivano/Core/Support/StdioFramer.swift','Tivano/Core/Support/JSONValue.swift','Tivano/Core/Support/PendingReplies.swift','Tivano/Core/Support/StoragePaths.swift','Tivano/Core/Support/Text.swift','Tivano/Core/Support/Coding.swift','Tivano/Core/Models/Provider.swift','Tivano/Core/Models/Requests.swift','Tivano/Core/Models/TokenSpend.swift','Tivano/Core/Models/AntiSlopPolicy.swift']
text=(root/'Tivano/Core/Models/Timeline.swift').read_text()
types=[]
for name in ['Attachment','ToolCall','FileEdit','TodoStep','Notice','LimitNotice','TurnStatus','ContextUsage']:
 m=re.search(r'^(?:struct|enum) '+name+r'\b.*?^}',text,re.M|re.S)
 assert m,name
 types.append(m.group())
types.append(re.search(r'^struct ProviderStatus\b.*?^}',(root/'Tivano/Services/Providers/ProviderRegistry.swift').read_text(),re.M|re.S).group())
(out/'TimelineTypes.swift').write_text('import Foundation\nimport ImageIO\n\n'+'\n\n'.join(types)+'\n')
(out/'sources.json').write_text(json.dumps({'files':files,'sha256':{p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in files+['Tivano/Core/Models/Timeline.swift','Tivano/Services/Providers/ProviderRegistry.swift']},'extracted_types':['Attachment','ToolCall','FileEdit','TodoStep','Notice','LimitNotice','TurnStatus','ContextUsage','ProviderStatus'],'shims':['CaptureRun storage root','TokenLedger persistence','HydraLaunch/HydraPrompts text only','MCP installation (disabled)','Shell/LoginEnvironment (unexecuted catalog path)']},indent=2))
(out/'source-arguments.json').write_text(json.dumps([str(root/p) for p in files]))
