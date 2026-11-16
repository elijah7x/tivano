#!/usr/bin/env python3
"""Offline check for Liquid Glass weather window gating, 3-state HeroWeather resolution, and idle/running pause invariants."""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]

HERO_WEATHER = ROOT / 'Tivano/Core/Models/HeroWeather.swift'
ACTIVITY_STATUS = ROOT / 'Tivano/Core/Models/ThreadActivityStatus.swift'
TIMELINE = ROOT / 'Tivano/Core/Models/Timeline.swift'
THEME_STYLE = ROOT / 'Tivano/UI/Theme/ThemeStyle.swift'
APP_SETTINGS = ROOT / 'Tivano/App/AppSettings.swift'
APP_MODEL_WEATHER = ROOT / 'Tivano/App/AppModel+Weather.swift'
GLOBAL_WEATHER_LAYER = ROOT / 'Tivano/App/Views/Layout/GlobalWeatherLayer.swift'
WEATHER_CANVAS = ROOT / 'Tivano/UI/Common/WeatherCanvas.swift'


def fail(message: str) -> None:
    print(f'FAIL: {message}', file=sys.stderr)
    raise SystemExit(1)


def extract_braced_block(source: str, header: str, label: str, include_header: bool) -> str:
    idx = source.find(header)
    if idx < 0:
        fail(f'missing marker {header!r} in {label}')
    if source.find(header, idx + len(header)) >= 0:
        fail(f'ambiguous marker {header!r} in {label}')
    brace_start = source.find('{', idx + len(header) - 1)
    if brace_start < 0:
        fail(f'missing opening brace after {header!r} in {label}')
    depth = 0
    for pos in range(brace_start, len(source)):
        ch = source[pos]
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                if include_header:
                    return source[idx:pos + 1]
                return source[brace_start + 1:pos]
    fail(f'unbalanced braces for {header!r} in {label}')
    return ''


def require_contains(source: str, needle: str, label: str) -> None:
    if needle not in source:
        fail(f'expected {needle!r} in {label}')


def require_absent(source: str, needle: str, label: str) -> None:
    if needle in source:
        fail(f'unexpected {needle!r} in {label}')


SWIFT_HARNESS_TEMPLATE = '''import Foundation

{turn_status_decl}

private struct ShowsWeatherProbe {{
    var weatherWindowEnabled: Bool
    var themeStyle: ThemeStyle
    var reduceMotion: Bool

    var showsWeatherNow: Bool {{
        {shows_weather_body}
    }}
}}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {{
    if !condition() {{
        fputs("FAIL: \\(message)\\n", stderr)
        exit(1)
    }}
}}

@main
struct WeatherWindowChecks {{
    static func main() {{
        // 1. Empty, idle, and running threads stay completely quiet (.idle).
        expect(HeroWeather.resolve([]) == .idle, "empty thread list must resolve to .idle")
        expect(HeroWeather.resolve([.idle, .idle]) == .idle, "idle threads must resolve to .idle")
        expect(HeroWeather.resolve([.running]) == .idle, "single running thread must not trigger weather")
        expect(HeroWeather.resolve([.running, .running, .idle]) == .idle, "multiple running threads must stay .idle")

        // 2. Three active weather scenes: awaiting -> wind, done -> sun, failed -> rain.
        expect(HeroWeather.resolve([.approval]) == .awaiting(1), "approval must map to .awaiting(1)")
        expect(HeroWeather.resolve([.question]) == .awaiting(1), "question must map to .awaiting(1)")
        expect(HeroWeather.resolve([.approval, .question, .running]) == .awaiting(2), "approval + question must map to .awaiting(2)")
        expect(HeroWeather.resolve([.completed]) == .done(1), "completed must map to .done(1)")
        expect(HeroWeather.resolve([.completed, .running, .completed]) == .done(2), "completed count must ignore running threads")
        expect(HeroWeather.resolve([.failed]) == .failed(1), "failed must map to .failed(1)")
        expect(HeroWeather.resolve([.interrupted]) == .failed(1), "interrupted must map to .failed(1)")
        expect(HeroWeather.resolve([.failed, .interrupted, .running]) == .failed(2), "failed + interrupted must map to .failed(2)")

        // 3. Priority order: failed > awaiting > done > idle.
        expect(
            HeroWeather.resolve([.completed, .question, .failed, .running]) == .failed(1),
            "failed must outrank awaiting and done"
        )
        expect(
            HeroWeather.resolve([.completed, .approval, .completed, .running]) == .awaiting(1),
            "awaiting must outrank done"
        )

        // 4. End-to-end ThreadActivityStatus -> HeroWeather transitions.
        let activeStreaming = ThreadActivityStatus.resolve(
            lastStatus: .completed,
            hasUnread: true,
            needsApproval: false,
            needsAnswer: false,
            isWorking: true
        )
        expect(activeStreaming == .running, "working thread without pending prompt must be .running")
        expect(HeroWeather.resolve([activeStreaming]) == .idle, "working thread must not trigger weather")
        expect(
            HeroWeather.resolveSnapshot([activeStreaming]) == HeroWeatherSnapshot(weather: .idle, hasRunningWork: true),
            "working thread must surface hasRunningWork=true while weather stays .idle"
        )
        let readCompleted = ThreadActivityStatus.resolve(
            lastStatus: .completed,
            hasUnread: false,
            needsApproval: false,
            needsAnswer: false,
            isWorking: false
        )
        expect(
            HeroWeather.resolveSnapshot([readCompleted]) == HeroWeatherSnapshot(weather: .idle, hasRunningWork: false),
            "marking a completed thread read without new work must keep hasRunningWork=false so its pulse can finish"
        )

        let waitingQuestion = ThreadActivityStatus.resolve(
            lastStatus: .running,
            hasUnread: false,
            needsApproval: false,
            needsAnswer: true,
            isWorking: true
        )
        expect(waitingQuestion == .question, "thread waiting on answer must surface .question")
        expect(HeroWeather.resolve([waitingQuestion]) == .awaiting(1), "waiting question must trigger wind (.awaiting)")

        let waitingApproval = ThreadActivityStatus.resolve(
            lastStatus: .running,
            hasUnread: false,
            needsApproval: true,
            needsAnswer: false,
            isWorking: true
        )
        expect(waitingApproval == .approval, "thread waiting on approval must surface .approval")
        expect(HeroWeather.resolve([waitingApproval]) == .awaiting(1), "waiting approval must trigger wind (.awaiting)")

        // 5. Theme gating: weather runs strictly in ThemeStyle.liquidGlass with weatherWindowEnabled && !reduceMotion.
        expect(ThemeStyle.allCases.contains(.liquidGlass), "ThemeStyle must include .liquidGlass")
        expect(ThemeStyle.allCases.contains(.texture), "ThemeStyle must include .texture")
        expect(ThemeStyle.allCases.contains(.create), "ThemeStyle must include .create")

        for enabled in [false, true] {{
            for style in ThemeStyle.allCases {{
                for reduce in [false, true] {{
                    let probe = ShowsWeatherProbe(
                        weatherWindowEnabled: enabled,
                        themeStyle: style,
                        reduceMotion: reduce
                    )
                    let expected = enabled && style == .liquidGlass && !reduce
                    expect(
                        probe.showsWeatherNow == expected,
                        "showsWeatherNow mismatch for enabled=\\(enabled) style=\\(style) reduceMotion=\\(reduce)"
                    )
                }}
            }}
        }}
    }}
}}
'''


def main() -> None:
    required = (
        HERO_WEATHER,
        ACTIVITY_STATUS,
        TIMELINE,
        THEME_STYLE,
        APP_SETTINGS,
        APP_MODEL_WEATHER,
        GLOBAL_WEATHER_LAYER,
        WEATHER_CANVAS,
    )
    for path in required:
        if not path.is_file():
            fail(f'missing source file: {path.relative_to(ROOT)}')

    hero_src = HERO_WEATHER.read_text(encoding='utf-8')
    require_absent(hero_src, 'case running', 'HeroWeather.swift')

    model_weather_src = APP_MODEL_WEATHER.read_text(encoding='utf-8')
    require_contains(model_weather_src, 'HeroWeather.resolveSnapshot(', 'AppModel+Weather.swift')
    require_contains(model_weather_src, 'ThreadActivityStatus.resolve(', 'AppModel+Weather.swift')
    require_contains(model_weather_src, 'workingParents', 'AppModel+Weather.swift')

    layer_src = GLOBAL_WEATHER_LAYER.read_text(encoding='utf-8')
    require_contains(layer_src, 'model.settings.showsWeatherNow', 'GlobalWeatherLayer.swift')
    require_contains(layer_src, 'displayedWeather: HeroWeather = .idle', 'GlobalWeatherLayer.swift')
    require_contains(layer_src, 'WeatherCanvas(', 'GlobalWeatherLayer.swift')
    require_contains(layer_src, 'pulseStart: pulseStart', 'GlobalWeatherLayer.swift')
    require_contains(layer_src, 'releaseStart: releaseStart', 'GlobalWeatherLayer.swift')
    require_contains(layer_src, 'backdropOpacity: model.settings.backdropOpacity', 'GlobalWeatherLayer.swift')
    require_contains(layer_src, 'isPausedExternal: liveResize.isActive', 'GlobalWeatherLayer.swift')
    require_contains(layer_src, 'onChange(of: hasRunningWork)', 'GlobalWeatherLayer.swift')
    require_contains(layer_src, 'if hasRunningWork || !canAnimate', 'GlobalWeatherLayer.swift')
    require_contains(layer_src, 'else if case .awaiting = oldValue', 'GlobalWeatherLayer.swift')

    canvas_src = WEATHER_CANVAS.read_text(encoding='utf-8')
    require_contains(
        canvas_src,
        'TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isPaused))',
        'WeatherCanvas.swift',
    )
    require_contains(canvas_src, 'pulseStart', 'WeatherCanvas.swift')
    for marker in ('case .idle:', 'case .awaiting:', 'case .done:', 'case .failed:'):
        require_contains(canvas_src, marker, 'WeatherCanvas.swift')
    require_absent(canvas_src, 'Animatable', 'WeatherCanvas.swift')
    require_absent(canvas_src, 'case .running', 'WeatherCanvas.swift')
    require_absent(canvas_src, 'drawClouds', 'WeatherCanvas.swift')
    require_absent(canvas_src, 'TrickleDrop', 'WeatherCanvas.swift')
    require_absent(canvas_src, 'drawWaterBead', 'WeatherCanvas.swift')
    require_absent(canvas_src, 'SillRipple', 'WeatherCanvas.swift')
    require_absent(canvas_src, 'unitDropletPath', 'WeatherCanvas.swift')

    timeline_src = TIMELINE.read_text(encoding='utf-8')
    turn_status_decl = extract_braced_block(
        timeline_src,
        'enum TurnStatus: String, Codable, Sendable {',
        'Timeline.swift',
        include_header=True,
    )

    settings_src = APP_SETTINGS.read_text(encoding='utf-8')
    shows_weather_raw = extract_braced_block(
        settings_src,
        'var showsWeatherNow: Bool {',
        'AppSettings.swift',
        include_header=False,
    ).strip()
    motion_expr = 'NSWorkspace.shared.accessibilityDisplayShouldReduceMotion'
    if shows_weather_raw.count(motion_expr) != 1:
        fail(f'expected exactly one {motion_expr!r} in AppSettings.showsWeatherNow, got {shows_weather_raw.count(motion_expr)}')
    shows_weather_body = shows_weather_raw.replace(motion_expr, 'reduceMotion', 1)

    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True, timeout=30).strip()
    if not sdk:
        fail('xcrun returned an empty macosx SDK path')

    with tempfile.TemporaryDirectory(prefix='tivano-weather-window-') as temp:
        temp_dir = Path(temp)
        harness_path = temp_dir / 'checks.swift'
        binary_path = temp_dir / 'weather-window-checks'
        harness_path.write_text(
            SWIFT_HARNESS_TEMPLATE.format(
                turn_status_decl=turn_status_decl,
                shows_weather_body=shows_weather_body,
            ),
            encoding='utf-8',
        )

        compile_cmd = [
            'xcrun', 'swiftc', '-O', '-parse-as-library', '-sdk', sdk,
            str(HERO_WEATHER),
            str(ACTIVITY_STATUS),
            str(THEME_STYLE),
            str(harness_path),
            '-o', str(binary_path),
        ]
        compiled = subprocess.run(compile_cmd, capture_output=True, text=True, timeout=90)
        if compiled.returncode != 0:
            fail(f'swiftc failed:\n{compiled.stdout}\n{compiled.stderr}')

        executed = subprocess.run([str(binary_path)], capture_output=True, text=True, timeout=30)
        if executed.returncode != 0:
            fail(f'check binary failed:\n{executed.stdout}\n{executed.stderr}')

    print('PASS: weather_window_checks')


if __name__ == '__main__':
    main()
