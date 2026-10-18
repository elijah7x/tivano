"""Extract declarations verbatim; never patch the adapter or its deadlines."""
import hashlib
import json
import re
from pathlib import Path


def prepare(root, kit):
    files = [
        'Tivano/Services/Providers/ACPSession.swift',
        'Tivano/Services/Providers/DshCLI.swift',
        'Tivano/Services/Providers/DshPatches.swift',
        'Tivano/Services/Providers/DshReportGuard.swift',
        'Tivano/Services/Providers/DshMarketplace.swift',
        'Tivano/Services/Providers/DshMarketplaceBootstrap.swift',
        'Tivano/Services/Providers/ACPQuestionForm.swift',
        'Tivano/Services/Providers/ProviderSession.swift',
        'Tivano/Services/Providers/SessionSupport.swift',
        'Tivano/Core/Support/JSONRPC.swift',
        'Tivano/Core/Support/StdioProcess.swift',
        'Tivano/Core/Support/StdioFramer.swift',
        'Tivano/Core/Support/JSONValue.swift',
        'Tivano/Core/Support/StoragePaths.swift',
        'Tivano/Core/Support/Text.swift',
        'Tivano/Core/Support/Coding.swift',
        'Tivano/Core/Models/Provider.swift',
        'Tivano/Core/Models/ModelFamilies.swift',
        'Tivano/Core/Models/DshAgentMode.swift',
        'Tivano/Core/Models/ZaiRegion.swift',
        'Tivano/Core/Models/Requests.swift',
        'Tivano/Core/Models/TokenSpend.swift',
    ]
    extracted = {
        'Tivano/Core/Models/Timeline.swift': ['Attachment', 'ToolCall', 'FileEdit', 'TodoStep', 'Notice', 'LimitNotice', 'TurnStatus', 'ContextUsage'],
        'Tivano/Services/Providers/ProviderRegistry.swift': ['ProviderStatus'],
    }
    declarations = []
    for path, names in extracted.items():
        source = (root / path).read_text()
        for name in names:
            match = re.search(r'^(?:struct|enum) ' + name + r'\b.*?^}', source, re.M | re.S)
            if not match:
                raise RuntimeError('missing declaration: ' + name)
            declarations.append(match.group())
    (kit / 'Extracted.swift').write_text('import Foundation\nimport ImageIO\n\n' + '\n\n'.join(declarations) + '\n')
    sources = [root / p for p in files] + [kit / p for p in ['Extracted.swift', 'Shims.swift', 'Harness.swift']]
    manifest = {
        'reference_commit': '560e2ba677de45201cc95252fdaaab720d0e29cc',
        'compiled_sources': [str(p) for p in sources],
        'extracted_types': extracted,
        'sha256': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [root / p for p in extracted]},
        'shims': ['CaptureRun: isolated storage and ephemeral defaults', 'HydraLaunch and VoiceOrchestratorContext: unused empty context', 'LoginEnvironment: isolated HOME; no login shell', 'Shell: fail closed (version/patch preflight not exercised in Standard mode)', 'Storage: attachment import fails closed (no image fixtures)', 'MCPProviderConfig: static two-server fixture or empty list; never launches MCP'],
    }
    (kit / 'sources.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return [str(p) for p in sources]
