#!/usr/bin/env python3
"""Offline guard for transient Hydra-head retries and manual continuation."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
HYDRA = ROOT / 'Tivano/App/AppModel+Hydra.swift'
HYDRA2 = ROOT / 'Tivano/App/AppModel+Hydra2.swift'
PANEL = ROOT / 'Tivano/App/Views/Chat/HydraPanel.swift'


def function_body(text, marker):
    start = text.find(marker)
    if start < 0:
        return None
    opening = text.find('{', start + len(marker))
    if opening < 0:
        return None
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    return None


def require_markers(body, markers, scope, failures):
    for name, marker in markers.items():
        if marker not in body:
            failures.append(f'{scope} is missing the {name} marker: {marker}')


def main():
    failures = []
    hydra = HYDRA.read_text(encoding='utf-8')
    hydra2 = HYDRA2.read_text(encoding='utf-8')
    panel = PANEL.read_text(encoding='utf-8')

    body = function_body(hydra, 'func hydraHeadTurnFinished(_ head: ChatThread, status: TurnStatus)')
    if body is None:
        failures.append('could not extract hydraHeadTurnFinished(); update the extraction marker')
    else:
        require_markers(body, {
            'Antigravity provider guard': 'head.provider == .antigravity',
            'transient classifier': 'AntigravitySession.isTransientFailure(error)',
            'independent retry counter': 'HydraWatchdog.transientRetries',
            'retry limit': 'AutoContinue.transientRetryLimit',
            'abandoned-head exclusion': '!HydraWatchdog.abandonedHeadIDs.contains(head.id)',
            'same-turn continuation': 'sendContinuation(after: turnID, text: AutoContinue.failedTurnContinueMessage)',
        }, 'hydraHeadTurnFinished()', failures)
        transient = body.find('AntigravitySession.isTransientFailure(error)')
        launch = body.find('Self.isLaunchFailure(error ?? "")')
        if launch < 0:
            failures.append('hydraHeadTurnFinished() is missing the launch-failure marker')
        elif transient >= 0 and transient > launch:
            failures.append('the transient Antigravity retry must precede launch-failure handling')

    body = function_body(hydra2, 'func continueFailedHydraHead(_ id: UUID)')
    if body is None:
        failures.append('could not extract continueFailedHydraHead(); update the extraction marker')
    else:
        require_markers(body, {
            'lead continuation': 'continueHydraHead(named:',
            'continuation prompt': 'AutoContinue.failedTurnContinueMessage',
            'existing owned files': 'job.heads.first(where: { $0.headID == id })?.files',
            'closed-job continuation': 'headRuntime.sendContinuation(after: turnID,',
        }, 'continueFailedHydraHead()', failures)

    body = function_body(panel, 'fileprivate func panelMenu(_ head: ChatThread)')
    if body is None:
        failures.append('could not extract HydraPanel.panelMenu(); update the extraction marker')
    else:
        require_markers(body, {
            'Continue head item': 'Chrome.localized("Continue head")',
            'manual continuation action': 'model.continueFailedHydraHead(head.id)',
        }, 'HydraPanel.panelMenu()', failures)

    if failures:
        for failure in failures:
            print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    print('OK: Hydra heads retry transient agy failures and retain manual continuation')
    return 0


if __name__ == '__main__':
    sys.exit(main())
