#!/usr/bin/env python3
"""Offline check for weather window modes (porthole/full/off), theme gating, 3-state HeroWeather resolution, and idle/running pause invariants."""
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

{weather_mode_decl}

private final class FakeDefaults {{
    var values: [String: Any] = [:]
    func set(_ value: Any?, forKey key: String) {{ values[key] = value }}
    func string(forKey key: String) -> String? {{ values[key] as? String }}
}}

struct AppModel {{
    struct SyntheticProject {{
        var id = UUID()
        var isShelved = false
    }}
    struct SyntheticThread {{
        var id = UUID()
        var projectID: UUID? = nil
        var parentThreadID: UUID? = nil
        var isArchived = false
        var isHydraHead = false
        var isInPanel = false
        var unreadStatus: TurnStatus? = nil
        var lastStatus: TurnStatus? = nil
        var hasUnread = false
    }}
    struct SyntheticRuntime {{
        var isRunning = false
        var isHydraMerging = false
        var approvals: [String] = []
        var questions: [String] = []
        var backgroundTasks: [String] = []
        var isWaitingForLimit = false
    }}
    var projects: [SyntheticProject] = []
    var threads: [SyntheticThread] = []
    var threadsUnobserved: [SyntheticThread] {{ threads }}
    var runtimes: [UUID: SyntheticRuntime] = [:]
    func existingRuntime(for id: UUID) -> SyntheticRuntime? {{ runtimes[id] }}
}}

private struct ShowsWeatherProbe {{
    private enum Key {{
        static let weatherWindow = "weatherWindow"
        static let weatherWindowMode = "weatherWindowMode"
        static let lastWeatherWindowMode = "lastWeatherWindowMode"
    }}

    let defaults = FakeDefaults()
{weather_mode_prop}
    var themeStyle: ThemeStyle
    var reduceMotion: Bool

{weather_enabled_prop}

    var showsWeatherNow: Bool {{
        {shows_weather_body}
    }}

{shows_porthole_prop}

{resolve_mode_decl}
}}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {{
    if !condition() {{
        fputs("FAIL: \\(message)\\n", stderr)
        exit(1)
    }}
}}

private func withIsolatedDefaults(_ index: Int, _ body: (UserDefaults) -> Void) {{
    let base = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory()
    let domain = URL(fileURLWithPath: base, isDirectory: true)
        .appendingPathComponent("defaults-\\(index)-\\(UUID().uuidString)").path
    guard let defaults = UserDefaults(suiteName: domain) else {{
        fputs("FAIL: could not create isolated UserDefaults suite\\n", stderr)
        exit(1)
    }}
    defaults.removePersistentDomain(forName: domain)
    defer {{ defaults.removePersistentDomain(forName: domain) }}
    body(defaults)
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

        // 3. Priority order: failed > awaiting > done > idle, with per-state snapshot counts preserved.
        expect(
            HeroWeatherSnapshot.idle == HeroWeatherSnapshot(weather: .idle, hasRunningWork: false, failed: 0, awaiting: 0, done: 0),
            "HeroWeatherSnapshot.idle must have zeroed counts"
        )
        expect(
            HeroWeather.resolve([.completed, .question, .failed, .running]) == .failed(1),
            "failed must outrank awaiting and done"
        )
        expect(
            HeroWeather.resolve([.completed, .approval, .completed, .running]) == .awaiting(1),
            "awaiting must outrank done"
        )
        let mixedSnapshot = HeroWeather.resolveSnapshot([
            .completed, .completed, .completed,
            .approval, .question,
            .failed, .interrupted,
            .running, .idle,
        ])
        expect(
            mixedSnapshot == HeroWeatherSnapshot(
                weather: .failed(2),
                hasRunningWork: true,
                failed: 2,
                awaiting: 2,
                done: 3
            ),
            "resolveSnapshot must fill failed, awaiting and done counts while keeping failed > awaiting > done > idle priority for weather"
        )
        let awaitingDoneSnapshot = HeroWeather.resolveSnapshot([.completed, .completed, .approval])
        expect(
            awaitingDoneSnapshot == HeroWeatherSnapshot(
                weather: .awaiting(1),
                hasRunningWork: false,
                failed: 0,
                awaiting: 1,
                done: 2
            ),
            "resolveSnapshot must fill awaiting and done counts while keeping awaiting > done priority for weather"
        )
        let doneOnlySnapshot = HeroWeather.resolveSnapshot([.completed, .idle])
        expect(
            doneOnlySnapshot == HeroWeatherSnapshot(
                weather: .done(1),
                hasRunningWork: false,
                failed: 0,
                awaiting: 0,
                done: 1
            ),
            "resolveSnapshot must fill done count when only completed threads exist"
        )

        // 4. End-to-end ThreadActivityStatus -> HeroWeather transitions and AppModel.globalWeatherSnapshot filtering.
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
            HeroWeather.resolveSnapshot([activeStreaming]) == HeroWeatherSnapshot(weather: .idle, hasRunningWork: true, failed: 0, awaiting: 0, done: 0),
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
            HeroWeather.resolveSnapshot([readCompleted]) == HeroWeatherSnapshot(weather: .idle, hasRunningWork: false, failed: 0, awaiting: 0, done: 0),
            "marking a completed thread read without new work must keep hasRunningWork=false so its pulse can finish"
        )

        let activeProject = AppModel.SyntheticProject(isShelved: false)
        let shelvedProject = AppModel.SyntheticProject(isShelved: true)
        let parentWithUnloadedRuntime = AppModel.SyntheticThread(
            projectID: activeProject.id,
            unreadStatus: .completed,
            lastStatus: .completed,
            hasUnread: true
        )
        let runningHead = AppModel.SyntheticThread(
            projectID: activeProject.id,
            parentThreadID: parentWithUnloadedRuntime.id,
            isHydraHead: true,
            isInPanel: true
        )
        let archivedFailed = AppModel.SyntheticThread(
            isArchived: true,
            unreadStatus: .failed,
            lastStatus: .failed,
            hasUnread: true
        )
        let panelHelperDone = AppModel.SyntheticThread(
            parentThreadID: UUID(),
            isInPanel: true,
            unreadStatus: .completed,
            lastStatus: .completed,
            hasUnread: true
        )
        let shelvedFailed = AppModel.SyntheticThread(
            projectID: shelvedProject.id,
            unreadStatus: .failed,
            lastStatus: .failed,
            hasUnread: true
        )
        let visibleDone = AppModel.SyntheticThread(
            projectID: activeProject.id,
            unreadStatus: .completed,
            lastStatus: .completed,
            hasUnread: true
        )
        var weatherModel = AppModel(
            projects: [activeProject, shelvedProject],
            threads: [parentWithUnloadedRuntime, runningHead, archivedFailed, panelHelperDone, shelvedFailed, visibleDone],
            runtimes: [runningHead.id: AppModel.SyntheticRuntime(isRunning: true)]
        )
        expect(
            weatherModel.globalWeatherSnapshot == HeroWeatherSnapshot(
                weather: .done(1),
                hasRunningWork: true,
                failed: 0,
                awaiting: 0,
                done: 1
            ),
            "globalWeatherSnapshot must exclude archived, hydra head, isInPanel and shelved-project threads, and treat workingParents as working even when parent runtime is nil"
        )
        weatherModel.runtimes = [:]
        expect(
            weatherModel.globalWeatherSnapshot == HeroWeatherSnapshot(
                weather: .done(2),
                hasRunningWork: false,
                failed: 0,
                awaiting: 0,
                done: 2
            ),
            "once working helper finishes, parent thread's unread status must contribute again"
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

        // 5. WeatherWindowMode cases, legacy Bool migration, and default.
        expect(WeatherWindowMode.allCases == [.porthole, .full, .off], "WeatherWindowMode cases must be [.porthole, .full, .off]")
        expect(WeatherWindowMode.porthole.rawValue == "porthole", "porthole rawValue")
        expect(WeatherWindowMode.full.rawValue == "full", "full rawValue")
        expect(WeatherWindowMode.off.rawValue == "off", "off rawValue")

        withIsolatedDefaults(0) {{ defaults in
            expect(ShowsWeatherProbe.resolveWeatherWindowMode(defaults) == .porthole, "absent keys must default to .porthole")
        }}
        withIsolatedDefaults(1) {{ defaults in
            defaults.set(true, forKey: "weatherWindow")
            expect(ShowsWeatherProbe.resolveWeatherWindowMode(defaults) == .full, "legacy weatherWindow=true must migrate to .full")
        }}
        withIsolatedDefaults(2) {{ defaults in
            defaults.set(false, forKey: "weatherWindow")
            expect(ShowsWeatherProbe.resolveWeatherWindowMode(defaults) == .off, "legacy weatherWindow=false must migrate to .off")
        }}
        withIsolatedDefaults(3) {{ defaults in
            defaults.set(true, forKey: "showsSkylight")
            expect(ShowsWeatherProbe.resolveWeatherWindowMode(defaults) == .full, "legacy showsSkylight=true must migrate to .full")
        }}
        withIsolatedDefaults(4) {{ defaults in
            defaults.set(false, forKey: "showsSkylight")
            expect(ShowsWeatherProbe.resolveWeatherWindowMode(defaults) == .off, "legacy showsSkylight=false must migrate to .off")
        }}
        withIsolatedDefaults(5) {{ defaults in
            defaults.set(false, forKey: "weatherWindow")
            defaults.set(true, forKey: "showsSkylight")
            expect(ShowsWeatherProbe.resolveWeatherWindowMode(defaults) == .off, "weatherWindow=false must outrank showsSkylight=true")
        }}
        withIsolatedDefaults(6) {{ defaults in
            defaults.set("porthole", forKey: "weatherWindowMode")
            defaults.set(false, forKey: "weatherWindow")
            expect(ShowsWeatherProbe.resolveWeatherWindowMode(defaults) == .porthole, "stored weatherWindowMode=porthole must win over legacy Bool")
        }}
        withIsolatedDefaults(7) {{ defaults in
            defaults.set("off", forKey: "weatherWindowMode")
            defaults.set(true, forKey: "weatherWindow")
            expect(ShowsWeatherProbe.resolveWeatherWindowMode(defaults) == .off, "stored weatherWindowMode=off must win over legacy Bool")
        }}
        withIsolatedDefaults(8) {{ defaults in
            defaults.set("bogus", forKey: "weatherWindowMode")
            defaults.set(false, forKey: "weatherWindow")
            expect(ShowsWeatherProbe.resolveWeatherWindowMode(defaults) == .off, "invalid weatherWindowMode must fall back to legacy Bool")
        }}
        withIsolatedDefaults(9) {{ defaults in
            defaults.set("bogus", forKey: "weatherWindowMode")
            expect(ShowsWeatherProbe.resolveWeatherWindowMode(defaults) == .porthole, "invalid weatherWindowMode without legacy Bool must default to .porthole")
        }}

        // 6. Computed weatherWindowEnabled getter/setter contract and remembered mode.
        var mutableProbe = ShowsWeatherProbe(weatherWindowMode: .porthole, themeStyle: .liquidGlass, reduceMotion: false)
        expect(mutableProbe.weatherWindowEnabled, ".porthole must report weatherWindowEnabled=true")
        mutableProbe.weatherWindowEnabled = true
        expect(mutableProbe.weatherWindowMode == .porthole, "setting weatherWindowEnabled=true while .porthole must preserve .porthole")
        mutableProbe.weatherWindowEnabled = false
        expect(!mutableProbe.weatherWindowEnabled && mutableProbe.weatherWindowMode == .off, "setting weatherWindowEnabled=false must set .off")
        expect(
            mutableProbe.defaults.values["weatherWindowMode"] as? String == "off"
                && mutableProbe.defaults.values["lastWeatherWindowMode"] as? String == "porthole"
                && mutableProbe.defaults.values["weatherWindow"] == nil,
            "weatherWindowEnabled=false must persist weatherWindowMode and lastWeatherWindowMode without writing weatherWindow"
        )
        mutableProbe.weatherWindowEnabled = true
        expect(
            mutableProbe.weatherWindowEnabled && mutableProbe.weatherWindowMode == .porthole,
            "weatherWindowEnabled false->true round trip must restore remembered .porthole"
        )
        expect(
            mutableProbe.defaults.values["weatherWindowMode"] as? String == "porthole" && mutableProbe.defaults.values["weatherWindow"] == nil,
            "weatherWindowEnabled=true must persist restored weatherWindowMode without writing weatherWindow"
        )

        var noMemoryGlass = ShowsWeatherProbe(weatherWindowMode: .off, themeStyle: .liquidGlass, reduceMotion: false)
        noMemoryGlass.weatherWindowEnabled = true
        expect(
            noMemoryGlass.weatherWindowEnabled && noMemoryGlass.weatherWindowMode == .full,
            "setting weatherWindowEnabled=true from .off with no memory on .liquidGlass must default to .full"
        )

        var noMemoryTexture = ShowsWeatherProbe(weatherWindowMode: .off, themeStyle: .texture, reduceMotion: false)
        noMemoryTexture.weatherWindowEnabled = true
        expect(
            noMemoryTexture.weatherWindowEnabled && noMemoryTexture.weatherWindowMode == .porthole,
            "setting weatherWindowEnabled=true from .off with no memory on .texture must default to .porthole"
        )

        // 7. Theme gating: showsWeatherNow strictly for .full + .liquidGlass + !reduceMotion;
        // showsPortholeNow for .porthole in .liquidGlass and .texture, never .create, and independent of reduceMotion.
        expect(ThemeStyle.allCases.contains(.liquidGlass), "ThemeStyle must include .liquidGlass")
        expect(ThemeStyle.allCases.contains(.texture), "ThemeStyle must include .texture")
        expect(ThemeStyle.allCases.contains(.create), "ThemeStyle must include .create")

        for mode in WeatherWindowMode.allCases {{
            for style in ThemeStyle.allCases {{
                for reduce in [false, true] {{
                    let probe = ShowsWeatherProbe(
                        weatherWindowMode: mode,
                        themeStyle: style,
                        reduceMotion: reduce
                    )
                    expect(
                        probe.weatherWindowEnabled == (mode != .off),
                        "weatherWindowEnabled mismatch for mode=\\(mode)"
                    )
                    let expectedFull = mode == .full && style == .liquidGlass && !reduce
                    expect(
                        probe.showsWeatherNow == expectedFull,
                        "showsWeatherNow mismatch for mode=\\(mode) style=\\(style) reduceMotion=\\(reduce)"
                    )
                    let expectedPorthole = mode == .porthole && (style == .liquidGlass || style == .texture)
                    expect(
                        probe.showsPortholeNow == expectedPorthole,
                        "showsPortholeNow mismatch for mode=\\(mode) style=\\(style) reduceMotion=\\(reduce)"
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
    require_contains(model_weather_src, 'isInPanel', 'AppModel+Weather.swift')
    require_contains(model_weather_src, 'isShelved', 'AppModel+Weather.swift')
    require_absent(model_weather_src, 'runtime != nil && workingParents', 'AppModel+Weather.swift')

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
    require_contains(layer_src, '\nstruct WeatherMotionObserver: NSViewRepresentable {', 'GlobalWeatherLayer.swift')
    require_absent(layer_src, 'private struct WeatherMotionObserver', 'GlobalWeatherLayer.swift')
    motion_observer_src = extract_braced_block(
        layer_src,
        'final class MotionView: NSView {',
        'GlobalWeatherLayer.swift MotionView',
        include_header=True,
    )
    if 'NSApp.isActive' not in motion_observer_src or 'NSApplication.didResignActiveNotification' not in motion_observer_src:
        fail('expected MotionView to check NSApp.isActive and register NSApplication.didResignActiveNotification')
    for marker in (
        'override func hitTest(_ point: NSPoint) -> NSView? { nil }',
        'setAccessibilityElement(false)',
        'NSWorkspace.screensDidSleepNotification',
        'NSWorkspace.screensDidWakeNotification',
        'screensAsleep',
    ):
        require_contains(motion_observer_src, marker, 'GlobalWeatherLayer.swift MotionView')

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
    require_contains(settings_src, 'static let weatherWindow = "weatherWindow"', 'AppSettings.swift')
    require_contains(settings_src, 'static let weatherWindowMode = "weatherWindowMode"', 'AppSettings.swift')
    require_contains(settings_src, 'static let lastWeatherWindowMode = "lastWeatherWindowMode"', 'AppSettings.swift')
    init_src = extract_braced_block(
        settings_src,
        '    init() {',
        'AppSettings.swift init',
        include_header=True,
    )
    require_contains(init_src, 'weatherWindowMode = Self.resolveWeatherWindowMode(defaults)', 'AppSettings.swift init')

    weather_mode_decl = extract_braced_block(
        settings_src,
        'enum WeatherWindowMode: String, CaseIterable, Sendable {',
        'AppSettings.swift',
        include_header=True,
    )
    weather_mode_prop = extract_braced_block(
        settings_src,
        '    var weatherWindowMode: WeatherWindowMode {',
        'AppSettings.swift',
        include_header=True,
    )
    weather_enabled_prop = extract_braced_block(
        settings_src,
        '    var weatherWindowEnabled: Bool {',
        'AppSettings.swift',
        include_header=True,
    )
    shows_weather_raw = extract_braced_block(
        settings_src,
        '    var showsWeatherNow: Bool {',
        'AppSettings.swift',
        include_header=False,
    ).strip()
    motion_expr = 'NSWorkspace.shared.accessibilityDisplayShouldReduceMotion'
    if shows_weather_raw.count(motion_expr) != 1:
        fail(f'expected exactly one {motion_expr!r} in AppSettings.showsWeatherNow, got {shows_weather_raw.count(motion_expr)}')
    shows_weather_body = shows_weather_raw.replace(motion_expr, 'reduceMotion', 1)

    shows_porthole_prop = extract_braced_block(
        settings_src,
        '    var showsPortholeNow: Bool {',
        'AppSettings.swift',
        include_header=True,
    )
    if motion_expr in shows_porthole_prop:
        fail('AppSettings.showsPortholeNow must not gate on reduceMotion')

    resolve_mode_decl = extract_braced_block(
        settings_src,
        '    static func resolveWeatherWindowMode(_ defaults: UserDefaults) -> WeatherWindowMode {',
        'AppSettings.swift',
        include_header=True,
    )

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
                weather_mode_decl=weather_mode_decl,
                weather_mode_prop=weather_mode_prop,
                weather_enabled_prop=weather_enabled_prop,
                shows_weather_body=shows_weather_body,
                shows_porthole_prop=shows_porthole_prop,
                resolve_mode_decl=resolve_mode_decl,
            ),
            encoding='utf-8',
        )

        compile_cmd = [
            'xcrun', 'swiftc', '-O', '-parse-as-library', '-sdk', sdk,
            str(HERO_WEATHER),
            str(ACTIVITY_STATUS),
            str(THEME_STYLE),
            str(APP_MODEL_WEATHER),
            str(harness_path),
            '-o', str(binary_path),
        ]
        compiled = subprocess.run(compile_cmd, capture_output=True, text=True, timeout=90)
        if compiled.returncode != 0:
            fail(f'swiftc failed:\n{compiled.stdout}\n{compiled.stderr}')

        executed = subprocess.run([str(binary_path), str(temp_dir)], capture_output=True, text=True, timeout=30)
        if executed.returncode != 0:
            fail(f'check binary failed:\n{executed.stdout}\n{executed.stderr}')

    print('PASS: weather_window_checks')


if __name__ == '__main__':
    main()
