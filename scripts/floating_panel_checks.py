#!/usr/bin/env python3
"""Offline source guards for floating panel Off mode and issue #56."""
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
TIMELINE = 'Tivano/App/Views/Chat/ThreadTimeline.swift'
SUBAGENT_PANEL = 'Tivano/App/Views/Chat/SubagentPanel.swift'
APP_SETTINGS = 'Tivano/App/AppSettings.swift'
APP_MODEL = 'Tivano/App/AppModel.swift'
APP_MODEL_HYDRA = 'Tivano/App/AppModel+Hydra.swift'
CHAT_VIEW = 'Tivano/App/Views/Chat/ChatView.swift'
RUNTIME = 'Tivano/App/Runtime/ThreadRuntime.swift'
PROGRESS_BAR = 'Tivano/App/Views/Chat/HydraProgressBar.swift'
ACTIVITY_TREE = 'Tivano/App/Views/Chat/ActivityTree.swift'
TIMELINE_ROWS = 'Tivano/App/Views/Chat/TimelineRows.swift'
SOURCES = (
    TIMELINE,
    SUBAGENT_PANEL,
    APP_SETTINGS,
    APP_MODEL,
    APP_MODEL_HYDRA,
    CHAT_VIEW,
    RUNTIME,
    PROGRESS_BAR,
    ACTIVITY_TREE,
    TIMELINE_ROWS,
)


def block(source, marker, label):
    count = source.count(marker)
    if count != 1:
        raise ValueError(f'{label}: marker {marker!r} found {count} times, expected 1')
    start = source.index(marker)
    opening = source.find('{', start)
    if opening < 0:
        raise ValueError(f'{label}: no opening brace after {marker!r}')
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise ValueError(f'{label}: no closing brace for {marker!r}')


def require(source, needle, label):
    if needle not in source:
        raise ValueError(f'{label}: missing {needle!r}')


def require_absent(source, needle, label):
    if needle in source:
        raise ValueError(f'{label}: unexpected {needle!r}')


def check_working_indicator_max_width(sources):
    label = '#56 WorkingIndicator card width'
    indicator = block(sources[TIMELINE], 'private struct WorkingIndicator: View {', label)
    require(indicator, '.frame(maxWidth: showsCard ? Self.cardWidth : nil)', label)
    require_absent(indicator, 'width: showsCard', label)


def check_working_indicator_toggle_unanimated(sources):
    label = 'WorkingIndicator toggle is unanimated'
    indicator = block(sources[TIMELINE], 'private struct WorkingIndicator: View {', label)
    body = block(indicator, '    var body: some View {', label)
    require(body, 'disablesAnimations = true', label)
    require_absent(body, 'withAnimation(.snappy(duration: 0.24))', label)


def check_subagent_panel_top_fade(sources):
    label = '#56 SubagentPanel timeline fade'
    panel = block(sources[SUBAGENT_PANEL], 'struct SubagentPanel: View {', label)
    require(panel, 'usesTimelineTopFade: true', label)
    require_absent(panel, '.chromeEdgeFade', label)


def check_off_default_and_spawn(sources):
    label = 'Off setting default and helper spawn'
    settings_init = block(sources[APP_SETTINGS], '    init() {', label)
    require(
        settings_init,
        'hydraAutoOpensPanels = defaults.object(forKey: Key.hydraAutoOpensPanels) as? Bool ?? true',
        label,
    )
    spawn = block(
        sources[APP_MODEL],
        '    func spawnSubagent(from parentID: UUID, title: String, prompt: String) -> ChatThread? {',
        label,
    )
    require(spawn, 'thread.isInPanel = settings.hydraAutoOpensPanels', label)


def check_off_hides_without_stopping(sources):
    label = 'Off setting hide handler'
    handler = block(
        sources[APP_MODEL],
        '        settings.onHydraAutoOpensPanelsChanged = { [weak self] in',
        label,
    )
    require(handler, '!self.settings.hydraAutoOpensPanels', label)
    require(handler, 'self.hideFloatingSubagentPanels()', label)
    hide = block(
        sources[APP_MODEL],
        '    private func hideFloatingSubagentPanels() {',
        label,
    )
    require(hide, 'updateThread(helper.id) { $0.isInPanel = false }', label)
    require(hide, 'runtime.isHydraPanelHidden = true', label)
    for source in (handler, hide):
        require_absent(source, 'closeSubagent(', label)
        require_absent(source, 'dismissHydraHeads(', label)


def check_hydra_unhide_respects_off(sources):
    label = 'Off setting insertHydraHead unhide'
    insert = block(sources[APP_MODEL_HYDRA], '    private func insertHydraHead(', label)
    unhide = 'leadRuntime.isHydraPanelHidden = false'
    if insert.count(unhide) != 1:
        raise ValueError(f'{label}: expected exactly one {unhide!r}')
    guard = block(insert, '        if settings.hydraAutoOpensPanels {', label)
    require(guard, unhide, label)


def check_auto_pop_respects_off(sources):
    label = 'Off setting ChatView automatic independent panels'
    require(
        sources[CHAT_VIEW],
        'if model.settings.hydraAutoOpensPanels && model.settings.hydraAutoPopsHeads, showsHydra, members.heads.count > 1 {',
        label,
    )


def check_runtime_hidden_from_off(sources):
    label = 'Off setting ThreadRuntime initialization'
    runtime_init = block(sources[RUNTIME], '    init(threadID: UUID, app: AppModel) {', label)
    require(runtime_init, 'isHydraPanelHidden = !app.settings.hydraAutoOpensPanels', label)


def check_panel_stream_flush_floor(sources):
    label = '#56 visible in-panel stream flush floor'
    queue_delta = block(
        sources[RUNTIME],
        '    private func queueDelta(_ id: String, _ kind: DeltaKind, _ text: String) {',
        label,
    )
    require(
        queue_delta,
        'if !offscreen, app?.selectedThreadID != threadID, thread?.isInPanel == true { delay = max(delay, 90) }',
        label,
    )


def require_animation_floor(source, marker, label, floor):
    view = block(source, marker, label)
    matches = list(re.finditer(
        r'TimelineView\(\s*\.animation\(\s*minimumInterval:\s*'
        r'([0-9]+(?:\.[0-9]+)?)\s*/\s*([0-9]+(?:\.[0-9]+)?)',
        view,
    ))
    if len(matches) != 1:
        raise ValueError(f'{label}: expected one numeric animation interval, found {len(matches)}')
    numerator, denominator = (float(value) for value in matches[0].groups())
    if denominator == 0:
        raise ValueError(f'{label}: animation interval has a zero denominator')
    interval = numerator / denominator
    if interval + 1e-9 < floor:
        raise ValueError(f'{label}: {interval:g}s is faster than the {floor:g}s floor')


def check_working_title_animation_floor(sources):
    # The breathing title once ran a SwiftUI clock that re-rendered the whole window on
    # every tick (about 30% of a core while a chat ran). It must stay a Core Animation
    # layer animation drawn over the hidden original Text, which keeps the layout.
    label = 'working title Core Animation breath'
    body = block(sources[PROGRESS_BAR], 'struct HydraWorkingTitle: View {', label)
    require_absent(body, 'TimelineView', label)
    require(body, 'BreathingTitle(', label)
    require(body, '.hidden()', label)
    require(sources[PROGRESS_BAR], 'CAKeyframeAnimation(keyPath: "opacity")', label)


def check_activity_shimmer_animation_floor(sources):
    require_animation_floor(
        sources[ACTIVITY_TREE],
        'private struct ActivityShimmer: ViewModifier {',
        '#56 activity shimmer 1/30s floor',
        1.0 / 30.0,
    )


def check_close_folds_without_stopping(sources):
    label = 'panel close folds a working helper into the stream pill'
    close = block(sources[APP_MODEL], '    func closeSubagent(_ id: UUID) {', label)
    require_absent(close, 'interrupt(', label)
    require(close, 'updateThread(id) { $0.isInPanel = false }', label)
    require_absent(sources[SUBAGENT_PANEL], 'ClosePanelPopover', label)
    require(sources[TIMELINE], 'HelpersWorkingRow.shows(runtime: runtime, model: model) ? [.helpersWorking] : []', label)
    require(sources[TIMELINE_ROWS], 'return helper.isHydraHead ? runtime.isHydraPanelHidden : !helper.isInPanel', label)


CHECKS = (
    ('working_indicator_max_width', check_working_indicator_max_width),
    ('working_indicator_toggle_unanimated', check_working_indicator_toggle_unanimated),
    ('subagent_panel_top_fade', check_subagent_panel_top_fade),
    ('off_default_and_spawn', check_off_default_and_spawn),
    ('off_hides_without_stopping', check_off_hides_without_stopping),
    ('hydra_unhide_respects_off', check_hydra_unhide_respects_off),
    ('auto_pop_respects_off', check_auto_pop_respects_off),
    ('runtime_hidden_from_off', check_runtime_hidden_from_off),
    ('panel_stream_flush_floor', check_panel_stream_flush_floor),
    ('working_title_animation_floor', check_working_title_animation_floor),
    ('activity_shimmer_animation_floor', check_activity_shimmer_animation_floor),
    ('close_folds_without_stopping', check_close_folds_without_stopping),
)


def main():
    sources = {}
    for name in SOURCES:
        try:
            sources[name] = (ROOT / name).read_text(encoding='utf-8')
        except OSError as error:
            print(f'FAIL: floating panel Off/#56 could not read {name}: {error}', file=sys.stderr)
            return 1

    failures = []
    for name, check in CHECKS:
        try:
            check(sources)
        except ValueError as error:
            failures.append(f'{name}: {error}')
    if failures:
        for failure in failures:
            print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    print(f'OK: {len(CHECKS)} floating panel Off/#56 source guards are intact')
    return 0


if __name__ == '__main__':
    sys.exit(main())
