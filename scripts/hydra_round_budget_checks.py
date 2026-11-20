#!/usr/bin/env python3
"""Offline guard for the Hydra per-request round budget: cap, failed-round refunds and user resets."""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MODELS = ROOT / 'Tivano/Core/Models/Hydra.swift'
RUNTIME = ROOT / 'Tivano/App/Runtime/ThreadRuntime.swift'


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


def call_expression(text, marker):
    start = text.find(marker)
    if start < 0:
        return None
    opening = text.find('(', start)
    if opening < 0:
        return None
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == '(':
            depth += 1
        elif text[index] == ')':
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    return None


def require_markers(body, markers, scope, failures):
    for name, marker in markers.items():
        if marker not in body:
            failures.append(f'{scope} is missing the {name} marker: {marker}')


def resolve_swiftc_command():
    try:
        probe = subprocess.run(
            ['xcrun', '--find', 'swiftc'],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except FileNotFoundError:
        probe = None
    except subprocess.TimeoutExpired:
        return None, 'timed out locating swiftc via xcrun'
    if probe is not None and probe.returncode == 0 and probe.stdout.strip():
        return ['xcrun', 'swiftc'], None
    fallback = shutil.which('swiftc')
    if fallback:
        return [fallback], None
    detail = f' ({probe.stderr.strip()})' if probe is not None and probe.stderr.strip() else ''
    return None, f'swiftc is required for behavioural round-budget checks but was not found{detail}'


REPORT_STUBS = r'''
struct HydraHeadInfo {
    enum Status {
        case running
        case completed
        case failed
        case stopped
    }
}

struct HydraLanding {}

struct HydraReport {
    var status: HydraHeadInfo.Status
    var landing: HydraLanding?
    var copyPath: String? = "/copy"
    var startupFailure = false
}
'''

REPORT_CHECKS = r'''
        let failedEmpty = HydraReport(status: .failed, landing: nil)
        let stoppedEmpty = HydraReport(status: .stopped, landing: nil)
        let completedEmpty = HydraReport(status: .completed, landing: nil)
        let runningEmpty = HydraReport(status: .running, landing: nil)
        let failedLanded = HydraReport(status: .failed, landing: HydraLanding())
        let stoppedLanded = HydraReport(status: .stopped, landing: HydraLanding())

        precondition(failedEmpty.producedNothing, "failed head with nil landing must count as producedNothing")
        precondition(stoppedEmpty.producedNothing, "stopped head with nil landing must count as producedNothing")
        precondition(!completedEmpty.producedNothing, "completed head must not count as producedNothing")
        precondition(!runningEmpty.producedNothing, "running head must not count as producedNothing")
        precondition(!failedLanded.producedNothing, "failed head with a landing must not count as producedNothing")
        precondition(!stoppedLanded.producedNothing, "stopped head with a landing must not count as producedNothing")
        let inPlaceFailed = HydraReport(status: .failed, landing: nil, copyPath: nil)
        let inPlaceStartupFailure = HydraReport(status: .failed, landing: nil, copyPath: nil, startupFailure: true)
        precondition(!inPlaceFailed.producedNothing, "an in-place head may have edited the checkout: it must not count as producedNothing")
        precondition(inPlaceStartupFailure.producedNothing, "an in-place head that failed before any tool ran changed nothing")
        precondition(!HydraPrompts.refundsRound([failedEmpty, inPlaceFailed]), "a round with an in-place failed head must not refund")

        precondition(!HydraPrompts.refundsRound([]), "empty report list must not refund a round")
        precondition(HydraPrompts.refundsRound([failedEmpty]), "single failed empty report must refund")
        precondition(HydraPrompts.refundsRound([failedEmpty, stoppedEmpty]), "all failed/stopped empty reports must refund")
        precondition(!HydraPrompts.refundsRound([failedEmpty, completedEmpty]), "any completed report must prevent refund")
        precondition(!HydraPrompts.refundsRound([failedEmpty, failedLanded]), "any landed report must prevent refund")
'''

HARNESS_MAIN = r'''
@main
enum HydraRoundBudgetChecks {
    static func main() {
        var budget = HydraDelegationBudget()
        precondition(HydraPrompts.maxDelegationRounds == 5, "expected maxDelegationRounds == 5")

        var chargedGeneration = budget.generation
        for round in 0..<HydraPrompts.maxDelegationRounds {
            precondition(budget.canDelegate, "fresh budget must allow delegation before charge \(round + 1)")
            chargedGeneration = budget.chargeRound()
            precondition(budget.rounds == round + 1, "rounds must be \(round + 1) after charge, got \(budget.rounds)")
            precondition(chargedGeneration == budget.generation, "chargeRound must return current generation")
        }
        precondition(budget.rounds == 5, "expected 5 charged rounds, got \(budget.rounds)")
        precondition(!budget.canDelegate, "budget must refuse delegation after 5 charges")

        precondition(budget.refundRound(generation: chargedGeneration), "first refund with current generation must succeed")
        precondition(budget.rounds == 4 && budget.refunds == 1, "first refund must set rounds=4 and refunds=1")
        precondition(budget.canDelegate, "refund after 5 charges must allow one more round")
        precondition(budget.chargeRound() == chargedGeneration, "charge after refund must keep current generation")
        precondition(budget.rounds == 5 && !budget.canDelegate, "charging after first refund must hit cap again")

        precondition(budget.refundRound(generation: chargedGeneration), "second refund with current generation must succeed")
        precondition(budget.rounds == 4 && budget.refunds == 2, "second refund must set rounds=4 and refunds=2")
        precondition(budget.canDelegate, "second refund must allow one more round")
        _ = budget.chargeRound()
        precondition(budget.rounds == 5 && !budget.canDelegate, "charging after second refund must hit cap again")

        precondition(!budget.refundRound(generation: chargedGeneration), "third refund in the same request must be refused (max 2)")
        precondition(budget.rounds == 5 && budget.refunds == 2 && !budget.canDelegate, "refused third refund must leave state unchanged")

        _ = budget.refuse("blocked")
        let generationBeforeNonUser = budget.generation
        budget.beginTurn(userAuthored: false)
        precondition(budget.rounds == 5, "beginTurn(userAuthored: false) must keep rounds")
        precondition(budget.refunds == 2, "beginTurn(userAuthored: false) must keep refunds")
        precondition(budget.refusals == 1, "beginTurn(userAuthored: false) must keep refusals")
        precondition(budget.generation == generationBeforeNonUser, "beginTurn(userAuthored: false) must keep generation")
        precondition(!budget.canDelegate, "beginTurn(userAuthored: false) must not re-enable delegation at cap")

        let staleGeneration = chargedGeneration
        budget.beginTurn(userAuthored: true)
        precondition(budget.rounds == 0, "beginTurn(userAuthored: true) must reset rounds")
        precondition(budget.refunds == 0, "beginTurn(userAuthored: true) must reset refunds")
        precondition(budget.refusals == 0, "beginTurn(userAuthored: true) must reset refusals")
        precondition(budget.generation != staleGeneration, "beginTurn(userAuthored: true) must advance generation")
        precondition(budget.canDelegate, "beginTurn(userAuthored: true) must allow delegation again")

        precondition(!budget.refundRound(generation: budget.generation), "refund with 0 rounds must be refused")
        precondition(budget.rounds == 0 && budget.refunds == 0, "refused zero-round refund must leave state unchanged")

        let freshGeneration = budget.chargeRound()
        precondition(freshGeneration == budget.generation && freshGeneration != staleGeneration, "charge after reset must carry new generation")
        precondition(!budget.refundRound(generation: staleGeneration), "refund with stale generation must be refused")
        precondition(budget.rounds == 1 && budget.refunds == 0, "stale refund must not mutate rounds or refunds")
        precondition(budget.refundRound(generation: freshGeneration), "refund with fresh generation must succeed")
        precondition(budget.rounds == 0 && budget.refunds == 1, "fresh refund must decrement rounds and increment refunds")
__REPORT_CHECKS__
    }
}
'''


def build_swift_harness(budget_body, max_rounds, report_ext, refunds_round_fn):
    include_reports = report_ext is not None and refunds_round_fn is not None
    parts = []
    if include_reports:
        parts.append(REPORT_STUBS)
        parts.append(report_ext)
    prompts_lines = [
        'enum HydraPrompts {',
        f'    static let maxDelegationRounds = {max_rounds}',
        '    static func droppedBlockNotice(_ message: String) -> String { message }',
    ]
    if include_reports:
        prompts_lines.append('    ' + refunds_round_fn)
    prompts_lines.append('}')
    parts.append('\n'.join(prompts_lines))
    parts.append(budget_body)
    parts.append(HARNESS_MAIN.replace('__REPORT_CHECKS__', REPORT_CHECKS if include_reports else ''))
    return '\n\n'.join(parts) + '\n'


def run_behavioural_checks(budget_body, max_rounds, report_ext, refunds_round_fn, failures):
    swiftc_cmd, error = resolve_swiftc_command()
    if swiftc_cmd is None:
        failures.append(error)
        return
    source = build_swift_harness(budget_body, max_rounds, report_ext, refunds_round_fn)
    with tempfile.TemporaryDirectory(prefix='tivano-hydra-round-budget-') as temp:
        directory = Path(temp)
        swift_file = directory / 'Checks.swift'
        binary = directory / 'checks'
        swift_file.write_text(source, encoding='utf-8')
        try:
            build = subprocess.run(
                [*swiftc_cmd, '-swift-version', '6', '-parse-as-library', str(swift_file), '-o', str(binary)],
                capture_output=True,
                text=True,
                timeout=90,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            failures.append(f'failed to invoke swiftc: {exc}')
            return
        if build.returncode != 0:
            detail = (build.stderr or build.stdout).strip()
            failures.append(f'extracted HydraDelegationBudget harness failed to compile:\n{detail}')
            return
        try:
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as exc:
            failures.append(f'failed to execute compiled round-budget harness: {exc}')
            return
        if run.returncode != 0:
            detail = (run.stderr or run.stdout).strip()
            failures.append(f'round-budget behavioural assertions failed:\n{detail}')


def main():
    failures = []
    models = MODELS.read_text(encoding='utf-8')
    runtime = RUNTIME.read_text(encoding='utf-8')

    max_rounds = None
    refunds_round_fn = None
    prompts_body = function_body(models, 'enum HydraPrompts')
    if prompts_body is None:
        failures.append('could not extract enum HydraPrompts; update the extraction marker')
    else:
        rounds_match = re.search(r'\bstatic\s+let\s+maxDelegationRounds\s*=\s*(\d+)\b', prompts_body)
        if rounds_match is None:
            failures.append('enum HydraPrompts is missing static let maxDelegationRounds = <int>')
        else:
            max_rounds = int(rounds_match.group(1))
            if max_rounds != 5:
                failures.append(f'HydraPrompts.maxDelegationRounds must be 5, got {max_rounds}')
        refunds_round_fn = function_body(prompts_body, 'static func refundsRound(')
        if refunds_round_fn is None:
            failures.append('could not extract HydraPrompts.refundsRound(); update the extraction marker')
        else:
            require_markers(refunds_round_fn, {
                'non-empty reports guard': '!reports.isEmpty',
                'producedNothing predicate': r'allSatisfy(\.producedNothing)',
            }, 'HydraPrompts.refundsRound()', failures)

    report_ext = function_body(models, 'extension HydraReport')
    if report_ext is None:
        failures.append('could not extract extension HydraReport; update the extraction marker')
    else:
        require_markers(report_ext, {
            'producedNothing property': 'var producedNothing: Bool',
            'failed status check': 'status == .failed',
            'stopped status check': 'status == .stopped',
            'nil landing check': 'landing == nil',
        }, 'extension HydraReport', failures)

    budget_body = function_body(models, 'struct HydraDelegationBudget')
    if budget_body is None:
        failures.append('could not extract struct HydraDelegationBudget; update the extraction marker')
    else:
        refunds_match = re.search(r'\bstatic\s+let\s+maxRefundedRounds\s*=\s*(\d+)\b', budget_body)
        if refunds_match is None:
            failures.append('struct HydraDelegationBudget is missing static let maxRefundedRounds = <int>')
        else:
            max_refunds = int(refunds_match.group(1))
            if max_refunds != 2:
                failures.append(f'HydraDelegationBudget.maxRefundedRounds must be 2, got {max_refunds}')
        require_markers(budget_body, {
            'generation counter': 'private(set) var generation = 0',
            'refunds counter': 'private(set) var refunds = 0',
        }, 'struct HydraDelegationBudget', failures)
        if re.search(r'@discardableResult\s+mutating\s+func\s+chargeRound\(\)\s*->\s*Int', budget_body) is None:
            failures.append('struct HydraDelegationBudget is missing @discardableResult mutating func chargeRound() -> Int')

        begin_turn = function_body(budget_body, 'mutating func beginTurn(userAuthored: Bool)')
        if begin_turn is None:
            failures.append('could not extract HydraDelegationBudget.beginTurn(userAuthored:); update the extraction marker')
        else:
            require_markers(begin_turn, {
                'rounds reset': 'rounds = 0',
                'refunds reset': 'refunds = 0',
                'refusals reset': 'refusals = 0',
                'generation bump': 'generation &+= 1',
            }, 'HydraDelegationBudget.beginTurn()', failures)

        charge_round = function_body(budget_body, 'mutating func chargeRound() -> Int')
        if charge_round is None:
            failures.append('could not extract HydraDelegationBudget.chargeRound(); update the extraction marker')
        else:
            require_markers(charge_round, {
                'rounds increment': 'rounds += 1',
                'generation return': 'return generation',
            }, 'HydraDelegationBudget.chargeRound()', failures)

        refund_round = function_body(budget_body, 'func refundRound(')
        if refund_round is None:
            failures.append('could not extract HydraDelegationBudget.refundRound(); update the extraction marker')
        else:
            require_markers(refund_round, {
                'charged generation signature': 'generation charged: Int) -> Bool',
                'generation match guard': 'charged == generation',
                'positive rounds guard': 'rounds > 0',
                'refund cap guard': 'refunds < Self.maxRefundedRounds',
                'guard false return': 'return false',
                'rounds decrement': 'rounds -= 1',
                'refunds increment': 'refunds += 1',
                'success return': 'return true',
            }, 'HydraDelegationBudget.refundRound()', failures)

    batch_struct = function_body(runtime, 'private struct HydraBatch')
    if batch_struct is None:
        failures.append('could not extract HydraBatch; update the extraction marker')
    else:
        require_markers(batch_struct, {
            'budgetGeneration property': 'var budgetGeneration: Int? = nil',
        }, 'HydraBatch', failures)

    spawn_v2 = function_body(runtime, 'private func spawnV2DelegatedHeads(')
    if spawn_v2 is None:
        failures.append('could not extract spawnV2DelegatedHeads(); update the extraction marker')
    else:
        require_markers(spawn_v2, {
            'chargeRound generation capture': 'let budgetGeneration = hydraBudget.chargeRound()',
        }, 'spawnV2DelegatedHeads()', failures)
        batch_call = call_expression(spawn_v2, 'HydraBatch(')
        if batch_call is None:
            failures.append('spawnV2DelegatedHeads() is missing the HydraBatch( construction call')
        elif 'budgetGeneration: budgetGeneration' not in batch_call:
            failures.append('spawnV2DelegatedHeads() must pass budgetGeneration: budgetGeneration into HydraBatch(')

    settle_batches = function_body(runtime, 'private func settleBatches(')
    if settle_batches is None:
        failures.append('could not extract settleBatches(); update the extraction marker')
    else:
        require_markers(settle_batches, {
            'failed-round refund predicate': 'HydraPrompts.refundsRound(batch.reports)',
            'budget refund call': 'hydraBudget.refundRound(generation:',
        }, 'settleBatches()', failures)

    start_turn = function_body(runtime, 'private func startTurn(')
    if start_turn is None:
        failures.append('could not extract startTurn(); update the extraction marker')
    else:
        require_markers(start_turn, {
            'userInitiated parameter': 'userInitiated: Bool = false',
            'user-authored budget reset': 'hydraBudget.beginTurn(userAuthored: hydraHeads == nil && userInitiated)',
        }, 'startTurn()', failures)

    open_bg = function_body(runtime, 'private func openBackgroundTurn(')
    if open_bg is None:
        failures.append('could not extract openBackgroundTurn(); update the extraction marker')
    else:
        require_markers(open_bg, {
            'voice user-authored budget reset': 'hydraBudget.beginTurn(userAuthored: true)',
        }, 'openBackgroundTurn()', failures)

    if 'userAuthored: hydraHeads == nil && !continuesHydraJob)' in runtime:
        failures.append('ThreadRuntime.swift still contains the old expression userAuthored: hydraHeads == nil && !continuesHydraJob)')
    if 'userAuthored: !continuesJob)' in runtime:
        failures.append('ThreadRuntime.swift still contains the old expression userAuthored: !continuesJob)')

    send_fn = function_body(runtime, 'func send(preservesHeadTiming: Bool = false)')
    if send_fn is None:
        failures.append('could not extract send(preservesHeadTiming:); update the extraction marker')
    else:
        composer_call = call_expression(send_fn, 'startTurn(text: outgoing, attachments: attachments')
        if composer_call is None:
            failures.append('send() is missing the startTurn(text: outgoing, attachments: attachments call')
        elif 'userInitiated: true' not in composer_call:
            failures.append('send() composer startTurn call must pass userInitiated: true')

    send_cont = function_body(runtime, 'func sendContinuation(')
    if send_cont is None:
        failures.append('could not extract sendContinuation(); update the extraction marker')
    else:
        cont_call = call_expression(send_cont, 'startTurn(')
        if cont_call is None:
            failures.append('sendContinuation() is missing its startTurn( call')
        elif 'userInitiated: true' in cont_call:
            failures.append('sendContinuation() startTurn call must not pass userInitiated: true')

    wake_bg = function_body(runtime, 'private func wakeAfterLostBackgroundTasks(')
    if wake_bg is None:
        failures.append('could not extract wakeAfterLostBackgroundTasks(); update the extraction marker')
    else:
        wake_call = call_expression(wake_bg, 'startTurn(')
        if wake_call is None or 'backgroundWake: true' not in wake_call:
            failures.append('wakeAfterLostBackgroundTasks() is missing its backgroundWake: true startTurn call')
        elif 'userInitiated: true' in wake_call:
            failures.append('wakeAfterLostBackgroundTasks() backgroundWake startTurn call must not pass userInitiated: true')

    if 'userInitiated || !continuesHydraJob' in runtime:
        failures.append('automatic turns must not reset the budget when a job has closed: drop "userInitiated || !continuesHydraJob"')
    for marker, scope in (('enqueueFollowUp(text: text, attachments: attachments, flushesIfIdle: false, automatic: !userInitiated)', 'startTurn() race re-queue keeps provenance'),
                          ('merged.automatic = members.allSatisfy { $0.automatic == true } ? true : nil', 'mergedBundle() provenance'),
                          ('startTurn(text: next.text, attachments: next.attachments, userInitiated: next.automatic != true)', 'drainFollowUps() provenance'),
                          ('sendContinuation(after: turnID, text: text, userInitiated: userInitiated)', 'sendLimitContinuation() forwards userInitiated')):
        if marker not in runtime:
            failures.append(f'{scope}: missing marker {marker}')
    auto_continue = (ROOT / 'Tivano/App/Runtime/AutoContinue.swift').read_text()
    now_body = function_body(auto_continue, 'func continueNow(')
    if now_body is None or 'sendLimitContinuation(Self.continueMessage, userInitiated: true)' not in now_body:
        failures.append('AutoContinue.continueNow() (the usage-limit Continue button) must pass userInitiated: true')
    if 'var automatic: Bool? = nil' not in (ROOT / 'Tivano/Core/Models/Timeline.swift').read_text():
        failures.append('FollowUpPrompt must carry an optional automatic provenance field')

    if budget_body is not None and max_rounds is not None:
        run_behavioural_checks(budget_body, max_rounds, report_ext, refunds_round_fn, failures)

    if failures:
        for failure in failures:
            print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    print('OK: Hydra round budget enforces 5-round cap, bounded failed-round refunds, and user resets')
    return 0


if __name__ == '__main__':
    sys.exit(main())
