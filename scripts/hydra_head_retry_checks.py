#!/usr/bin/env python3
"""Offline guard for transient Hydra-head retries and manual continuation."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
HYDRA = ROOT / 'Tivano/App/AppModel+Hydra.swift'
HYDRA2 = ROOT / 'Tivano/App/AppModel+Hydra2.swift'
PANEL = ROOT / 'Tivano/App/Views/Chat/HydraPanel.swift'
RUNTIME = ROOT / 'Tivano/App/Runtime/ThreadRuntime.swift'
MODELS = ROOT / 'Tivano/Core/Models/Hydra.swift'
PROMPTS = ROOT / 'Tivano/Core/Models/HydraPrompts+V2.swift'


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
    runtime = RUNTIME.read_text(encoding='utf-8')
    models = MODELS.read_text(encoding='utf-8')
    prompts = PROMPTS.read_text(encoding='utf-8')

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

    start_turn = function_body(runtime, 'private func startTurn(')
    if start_turn is None:
        failures.append('could not extract startTurn(); update the extraction marker')
    else:
        require_markers(start_turn, {
            'headBudget non-user interrupt': 'self.interrupt(byUser: false)',
            'headBudget stop flag': 'self.headBudgetStop = true',
            'final-report start preservation': 'if turns.count > 1, !isFinalReport',
        }, 'startTurn()', failures)

    stop_reason = function_body(models, 'enum StopReason:')
    if stop_reason is None:
        failures.append('could not extract HydraHeadInfo.StopReason; update the extraction marker')
    else:
        require_markers(stop_reason, {
            'stalled case': 'case stalled',
            'budget case': 'case budget',
        }, 'HydraHeadInfo.StopReason', failures)

    finish_head = function_body(hydra, 'func finishHydraHead(')
    if finish_head is None:
        failures.append('could not extract finishHydraHead(); update the extraction marker')
    else:
        require_markers(finish_head, {
            'budget stop consumption': 'consumeHeadBudgetStop()',
            'budget StopReason assignment': '$0.stopReason = stalled ? .stalled : (budget ? .budget : nil)',
        }, 'finishHydraHead()', failures)

    stop_head = function_body(hydra, 'func stopHydraHead(')
    if stop_head is None:
        failures.append('could not extract stopHydraHead(); update the extraction marker')
    else:
        require_markers(stop_head, {
            'manual stop clears budget flag': 'clearHeadBudgetStop()',
        }, 'stopHydraHead()', failures)

    report_message = function_body(prompts, 'static func v2ReportMessage(')
    if report_message is None:
        failures.append('could not extract v2ReportMessage(); update the extraction marker')
    else:
        require_markers(report_message, {
            'budget stopped case': 'case .budget:',
            'budget outcome wording': 'ran out of its time budget before finishing',
            'user-only stop closing guard': '$0.status == .stopped && $0.stopReason == nil',
            'budget closing guidance': '$0.status == .stopped && $0.stopReason == .budget',
        }, 'v2ReportMessage()', failures)
        budget_pos = report_message.find('case .budget:')
        nil_pos = report_message.find('case nil:')
        user_stopped_pos = report_message.find('stopped by the user before finishing')
        if budget_pos >= 0 and nil_pos >= 0 and user_stopped_pos >= 0:
            if budget_pos < user_stopped_pos < nil_pos:
                failures.append('v2ReportMessage() must not emit "stopped by the user" for StopReason.budget')
        elif user_stopped_pos < 0 or nil_pos < 0:
            failures.append('v2ReportMessage() is missing the user-stopped nil branch')

    status_text = function_body(panel, 'enum HydraStatusText')
    if status_text is None:
        failures.append('could not extract HydraStatusText; update the extraction marker')
    else:
        require_markers(status_text, {
            'budget status case': 'case .budget:',
            'budget footer label': '"Out of time"',
            'budget short/long label': '"out of time"',
        }, 'HydraStatusText', failures)

    settle_job = function_body(hydra2, 'func settleHydraJob(')
    release_copies = function_body(hydra2, 'func releaseHydraJobCopies(')
    if settle_job is None:
        failures.append('could not extract settleHydraJob(); update the extraction marker')
    else:
        require_markers(settle_job, {
            'completed branch releases via filtered helper': 'await releaseHydraJobCopies(of: leadID, jobID: job.id)',
        }, 'settleHydraJob()', failures)
    if release_copies is None:
        failures.append('could not extract releaseHydraJobCopies(); update the extraction marker')
    else:
        require_markers(release_copies, {
            'completed status check': 'info.status == .completed',
            'landed check': 'info.landing?.landed == true',
            'unchanged tree check': '(try? await Git(copy).currentTree()) == base',
        }, 'releaseHydraJobCopies()', failures)

    if failures:
        for failure in failures:
            print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    print('OK: Hydra heads retry transient agy failures and retain manual continuation')
    return 0


if __name__ == '__main__':
    sys.exit(main())
