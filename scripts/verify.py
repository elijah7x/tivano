#!/usr/bin/env python3
"""Local dev merge gate. Default mode runs matched fast checks and builds the app only when app-build inputs changed. Use --slow for matched slow checks, --all for all offline checks plus build, or --list to inspect selection without running checks."""
import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def paths(prefix, names):
    return tuple(prefix + name for name in names.split())


SUPPORT = 'Tivano/Core/Support/'
MODELS = 'Tivano/Core/Models/'
PROVIDERS = 'Tivano/Services/Providers/'
DOMAIN = ('scripts/local_control_domain_checks.py',)
TASK_SOURCES = (
    'Tivano/App/AppModel.swift', 'Tivano/Services/Store/Storage.swift',
    *paths(SUPPORT, 'Coding.swift StoragePaths.swift'),
    *paths(MODELS, 'LocalControl.swift Library.swift ProviderAccount.swift Chimera.swift Hydra.swift Hydra2.swift'),
    'Tivano/Core/Support/Text.swift',
)
ACP_SOURCES = (
    *paths(PROVIDERS, 'ACPSession.swift DshCLI.swift DshPatches.swift DshReportGuard.swift '
           'DshMarketplace.swift DshMarketplaceBootstrap.swift ACPQuestionForm.swift '
           'ProviderSession.swift SessionSupport.swift ProviderRegistry.swift'),
    *paths(SUPPORT, 'JSONRPC.swift StdioProcess.swift StdioFramer.swift JSONValue.swift '
           'StoragePaths.swift Text.swift Coding.swift'),
    *paths(MODELS, 'Provider.swift ModelFamilies.swift DshAgentMode.swift ZaiRegion.swift '
           'Requests.swift TokenSpend.swift Timeline.swift ProviderAccount.swift Voice.swift'),
)
SWIFT = ('macOS', 'xcrun')


@dataclass(frozen=True)
class Check:
    name: str
    layer: str
    arguments: tuple
    timeout: int
    prerequisites: tuple
    triggers: tuple
    output: str = 'temporary directory'

    def command(self, run, git, short=None):
        values = {'out': str(run / self.name), 'short': str(short), 'git': git}
        return [sys.executable, '-B', str(ROOT / 'scripts' / (self.name + '.py')),
                *(arg.format(**values) for arg in self.arguments)]


def check(name, layer, arguments, timeout, prerequisites, triggers, output='temporary directory'):
    return Check(name, layer, arguments, timeout, prerequisites,
                 ('scripts/' + name + '.py', *triggers), output)


# Register every new check and all its covered inputs here; this is the coverage source of truth.
CHECKS = (
    check('claude_usage_checks', 'fast', (), 300, SWIFT,
          (*paths(PROVIDERS, 'PlanLimits.swift'), *paths(SUPPORT, 'JSONValue.swift ISO8601.swift'), *DOMAIN)),
    check('activity_audit_checks', 'fast', (), 240, SWIFT,
          (*DOMAIN, 'Tivano/App/AppModel.swift', 'Tivano/App/Runtime/ThreadRuntime.swift',
           'Tivano/App/Runtime/VoiceController.swift', 'Tivano/Core/Models/Voice.swift')),
    check('standalone_task_checks', 'fast', (), 300, SWIFT, TASK_SOURCES),
    check('runtime_audit_checks', 'fast', (), 360, SWIFT,
          (*paths(PROVIDERS, 'ACPSession.swift PiSession.swift OmpSession.swift ClaudeSession.swift '
                  'CopilotSession.swift OpenAICompatibleSession.swift'),
           'Tivano/Core/Support/JSONValue.swift', 'Tivano/Services/MCP/MCPHub.swift',
           'Tivano/App/Runtime/ThreadRuntime.swift')),
    check('sse_framing_checks', 'fast', (), 480, SWIFT,
          (*paths(SUPPORT, 'SSEByteFramer.swift'),
           'Tivano/Services/Providers/OpenAICompatibleSession.swift',
           'Tivano/Services/MCP/MCPWire.swift', 'Tivano/Services/MCP/MCPProxy.swift')),
    check('claude_accounts_checks', 'fast', (), 600, SWIFT,
          (*DOMAIN, *paths(PROVIDERS, 'ClaudeAccountCredentials.swift ProviderRegistry.swift '
                           'ProviderRegistry+CLIUpdates.swift ClaudeSwapImport.swift ProviderAccounts.swift'),
           *paths(MODELS, 'ProviderAccount.swift Provider.swift'))),
    check('timeline_performance_checks', 'fast', (), 300, SWIFT,
          ('Tivano/App/Views/Chat/ThreadTimeline.swift',), 'build.noindex/timeline-performance-checks'),
    check('workspace_recovery_checks', 'fast', ('{out}',), 2100, SWIFT,
          (*DOMAIN, *TASK_SOURCES, 'scripts/fixtures/workspace_recovery/'), 'fresh external directory'),
    check('local_control_domain_checks', 'fast', ('{out}',), 600, (*SWIFT, 'arm64'),
          ('scripts/fixtures/local_control/', 'Tivano/App/AppModel.swift',
           'Tivano/App/Control/AppControlService.swift', 'Tivano/App/Runtime/ThreadRuntime.swift',
           'Tivano/App/AppSettings.swift', 'Tivano/App/AppUpdater.swift',
           'Tivano/App/AppModel+Hydra.swift', 'Tivano/App/Runtime/ControlFailureClassifier.swift',
           *paths(MODELS, 'LocalControl.swift Library.swift ProviderAccount.swift Chimera.swift Hydra.swift Hydra2.swift'),
           *paths(SUPPORT, 'Coding.swift StoragePaths.swift Text.swift'),
           *paths(PROVIDERS, 'ClaudeAccountCredentials.swift PlanLimits.swift'),
           'Tivano/Services/Control/ControlLedger.swift'),
          'fresh external directory'),
    check('localization_format_checks', 'fast', (), 240, (),
          ('Tivano/Resources/Localizable.xcstrings',), 'none (read-only)'),
    check('known_regions_checks', 'fast', (), 60, (),
          ('project.yml', 'Tivano.xcodeproj/project.pbxproj',
           'Tivano/Resources/Localizable.xcstrings',
           'scripts/xcodegen_generate.py', 'scripts/release.sh',
           'scripts/product_captures.py'),
          'none (read-only)'),
    check('legacy_macos_checks', 'fast', (), 60, (),
          ('project.yml', 'Tivano.xcodeproj/project.pbxproj', 'Tivano/'),
          'none (read-only)'),
    check('binding_removal_checks', 'fast', (), 60, (), ('Tivano/',), 'none (read-only)'),
    check('cursor_stack_checks', 'fast', (), 60, (), ('Tivano/',), 'none (read-only)'),
    check('hydra_idle_checks', 'fast', (), 60, (),
          ('Tivano/Services/Providers/AntigravitySession.swift',
           'Tivano/App/AppModel+Hydra.swift'), 'none (read-only)'),
    check('background_task_checks', 'fast', (), 60, (),
          ('Tivano/App/AppModel.swift', 'Tivano/App/Runtime/ThreadRuntime.swift',
           'Tivano/Services/Providers/ClaudeSession.swift',
           'Tivano/Resources/Localizable.xcstrings'), 'none (read-only)'),
    check('antigravity_effort_checks', 'fast', (), 60, SWIFT,
          (*paths(PROVIDERS, 'AntigravitySession.swift ProviderRegistry.swift'),
           'Tivano/App/Runtime/ThreadRuntime.swift'), 'none (read-only)'),
    check('antigravity_result_checks', 'fast', (), 60, SWIFT,
          (*paths(PROVIDERS, 'AntigravitySession.swift'),), 'none (read-only)'),
    check('pi_catalog_checks', 'fast', (), 60, (), (*paths(PROVIDERS, 'PiCLI.swift'),), 'none (read-only)'),
    check('upstream_channel_checks', 'fast', (), 60, (), (*paths(PROVIDERS, 'CLIUpdates.swift ACPSession.swift PiSession.swift'),), 'none (read-only)'),
    check('dsh_patch_checks', 'fast', (), 60, (), (*paths(PROVIDERS, 'DshPatches.swift DshMarketplaceBootstrap.swift ACPSession.swift'),), 'none (read-only)'),
    check('codex_protocol_checks', 'fast', (), 60, (), (*paths(PROVIDERS, 'CodexSession.swift'),), 'none (read-only)'),
    check('codex_one_shot_checks', 'fast', (), 60, (), (*paths(PROVIDERS, 'CodexSession.swift TextGeneration.swift'),), 'none (read-only)'),
    check('zcode_protocol_checks', 'fast', (), 60, (), (*paths(PROVIDERS, 'ZCodeCLI.swift ZCodeSession.swift'),), 'none (read-only)'),
    check('meta_model_checks', 'fast', (), 60, (), (*paths(PROVIDERS, 'MetaAPI.swift MetaSession.swift'),), 'none (read-only)'),
    check('turn_continue_checks', 'fast', (), 60, (), ('Tivano/App/Runtime/ThreadRuntime.swift', 'Tivano/App/Runtime/AutoContinue.swift', 'Tivano/App/Views/Chat/TimelineRows.swift', 'Tivano/App/Views/Chat/ThreadTimeline.swift', 'Tivano/Resources/Localizable.xcstrings'), 'none (read-only)'),
    check('hydra_head_retry_checks', 'fast', (), 60, (),
          ('Tivano/App/AppModel+Hydra.swift', 'Tivano/App/AppModel+Hydra2.swift',
           'Tivano/App/Views/Chat/HydraPanel.swift', 'Tivano/App/Runtime/ThreadRuntime.swift',
           'Tivano/Core/Models/Hydra.swift', 'Tivano/Core/Models/HydraPrompts+V2.swift'),
          'none (read-only)'),
    check('first_send_checks', 'fast', (), 60, (),
          ('Tivano/App/Runtime/ThreadRuntime.swift', 'Tivano/App/AppModel.swift'),
          'none (read-only)'),
    check('floating_panel_checks', 'fast', (), 60, (),
          ('Tivano/App/Views/Chat/ThreadTimeline.swift',
           'Tivano/App/Views/Chat/SubagentPanel.swift',
           'Tivano/App/AppSettings.swift',
           'Tivano/App/AppModel.swift',
           'Tivano/App/AppModel+Hydra.swift',
           'Tivano/App/Views/Chat/ChatView.swift',
           'Tivano/App/Runtime/ThreadRuntime.swift',
           'Tivano/App/Views/Chat/HydraProgressBar.swift',
           'Tivano/App/Views/Chat/ActivityTree.swift'),
          'none (read-only)'),
    check('markdown_link_checks', 'fast', (), 240, SWIFT,
          ('Tivano/UI/Markdown/MarkdownLinkTarget.swift',
           'Tivano/UI/Markdown/LinkParagraphView.swift')),
    check('markdown_typography_checks', 'fast', (), 120, SWIFT,
          ('Tivano/UI/Theme/TypeScale.swift',
           'Tivano/UI/Markdown/MarkdownView.swift',
           'Tivano/UI/Markdown/ProseRunView.swift',
           'Tivano/UI/Markdown/LinkParagraphView.swift',
           'Tivano/App/Views/Chat/TimelineRows.swift')),
    check('weather_window_checks', 'fast', (), 120, SWIFT,
          ('Tivano/Core/Models/HeroWeather.swift',
           'Tivano/Core/Models/ThreadActivityStatus.swift',
           'Tivano/Core/Models/Timeline.swift',
           'Tivano/App/AppModel+Weather.swift',
           'Tivano/App/Views/Layout/GlobalWeatherLayer.swift',
           'Tivano/UI/Common/WeatherCanvas.swift',
           'Tivano/UI/Theme/ThemeStyle.swift',
           'Tivano/App/AppSettings.swift')),
    check('ci_runner_checks', 'fast', (), 300, ('git',),
          ('scripts/thor_ci.py', 'scripts/ci_gate.py', 'scripts/verify.py'), 'temporary directory'),
    check('workspace_mode_checks', 'fast', (), 180, (*SWIFT, 'git'),
          ('Tivano/Core/Models/Provider.swift', 'Tivano/App/AppSettings.swift',
           'Tivano/App/AppModel.swift', 'Tivano/App/Runtime/ThreadRuntime.swift',
           'Tivano/App/QuickChat/QuickChatPanel.swift',
           'Tivano/App/Views/Settings/ConversationSettingsPage.swift',
           'Tivano/Resources/Localizable.xcstrings'),
          'temporary directory'),
    check('runtime_storage_checks', 'slow', (), 7200, (*SWIFT, 'unprivileged'),
          (*paths(SUPPORT, 'HangWatchdog.swift JSONValue.swift ISO8601.swift RuntimeStorageUsage.swift '
                  'CaptureRun.swift StoragePaths.swift Text.swift'),
           'Tivano/App/AppUpdater.swift', 'Tivano/App/UpdateChecker.swift',
           'Tivano/Services/Store/Storage+Diagnostics.swift',
           'Tivano/App/Views/Settings/StorageSettingsSections.swift'), 'build.noindex (temporary directory)'),
    check('data_safety_audit_checks', 'slow', ('{out}', '--git', '{git}'), 7200,
          (*SWIFT, 'git-cat-file-Z', 'unprivileged'),
          (*DOMAIN, 'Tivano/Services/Git/Git.swift', 'Tivano/Services/Git/TouchedPaths.swift',
           'Tivano/Services/Store/Storage.swift', 'Tivano/Services/Store/StorageUsage.swift',
           'Tivano/Core/Models/Timeline.swift', 'Tivano/App/AppModel+Hydra.swift',
           *paths(SUPPORT, 'Coding.swift Shell.swift SharedLibraryLease.swift SharedResourceLock.swift CheckoutClaims.swift')),
          'fresh external directory'),
    check('local_control_checks', 'slow', ('{short}',), 1200, (*SWIFT, 'arm64', 'short-socket-path'),
          ('scripts/fixtures/local_control/', 'Tivano/Core/Models/LocalControl.swift',
           *paths('Tivano/Services/Control/', 'ControlSocket.swift ControlLedger.swift ControlCLIInstaller.swift'),
           'Tivano/Services/Store/ControlHistoryReader.swift', 'TivanoCLI/main.swift', 'TivanoCLI/ControlClient.swift',
           'Tivano/Resources/Localizable.xcstrings'), 'fresh /tmp/tvlc-*/lc directory'),
    check('dsh_adapter_stress', 'slow', (), 3000, (*SWIFT, '/usr/bin/sandbox-exec'),
          ('scripts/fixtures/dsh_adapter/', *ACP_SOURCES), 'build.noindex/dsh-adapter/run-*'),
    check('omp_adapter_stress', 'slow', ('--fake-only', '--output', '{out}'), 300, SWIFT,
          ('scripts/fixtures/omp_adapter/',
           *paths(PROVIDERS, 'OmpSession.swift OmpCLI.swift ProviderSession.swift SessionSupport.swift '
                  'UsageLimitSignal.swift ProviderRegistry.swift'),
           *paths(SUPPORT, 'StdioProcess.swift StdioFramer.swift JSONValue.swift PendingReplies.swift '
                  'StoragePaths.swift Text.swift Coding.swift'),
           *paths(MODELS, 'Provider.swift Requests.swift TokenSpend.swift AntiSlopPolicy.swift Timeline.swift '
                  'ProviderAccount.swift DshAgentMode.swift Voice.swift ZaiRegion.swift')),
          'external directory/run-*'),
    check('minimax_adapter_stress', 'slow', (), 900, (*SWIFT, '/usr/bin/sandbox-exec'),
          ('scripts/fixtures/dsh_adapter/', 'scripts/dsh_adapter_stress.py', *ACP_SOURCES), 'build.noindex/minimax-code/offline-*'),
    check('kimi_adapter_stress', 'slow', (), 900, (*SWIFT, '/usr/bin/sandbox-exec'),
          ('scripts/fixtures/dsh_adapter/', 'scripts/dsh_adapter_stress.py', *ACP_SOURCES), 'build.noindex/kimi-code/offline-*'),
    check('consolidate_checkout_checks', 'slow', (), 900, ('git',),
          ('scripts/consolidate_checkout.py', 'scripts/consolidate_checkout_job.py')),
    check('reply_selection_checks', 'gui', (), 600, (*SWIFT, 'gui-session'),
          ('Tivano/App/Views/Chat/MessagePopoverMenu.swift', 'Tivano/UI/Chrome/Popovers.swift',
           'Tivano/App/Runtime/ThreadRuntime.swift', 'Tivano/App/Views/Chat/TimelineRows.swift')),
    check('selection_redraw_checks', 'gui', (), 600, (*SWIFT, 'gui-session'),
          ('Tivano/UI/Markdown/LinkParagraphView.swift',)),
    check('ui_audit_checks', 'gui', (), 420, (*SWIFT, 'gui-session'),
          ('scripts/fixtures/ui_audit/', 'Tivano/App/Runtime/ThreadRuntime.swift',
           'Tivano/UI/Markdown/MarkdownView.swift', 'Tivano/UI/Markdown/MarkdownParser.swift',
           'Tivano/UI/Common/AttachmentPreview.swift', 'Tivano/UI/Common/AttachmentThumbnail.swift',
           'Tivano/App/Views/Composer/QuestionTab.swift', 'Tivano/App/Views/Composer/ComposerView.swift',
           'Tivano/UI/Chrome/Popovers.swift', 'Tivano/UI/Chrome/Chrome.swift',
           'Tivano/UI/Theme/AppTheme.swift', 'Tivano/UI/Theme/ThemeStyle.swift', 'Tivano/UI/Theme/TypeScale.swift',
           *paths(SUPPORT, 'ThumbnailCache.swift RecentCache.swift Text.swift'),
           'Tivano/Core/Models/Requests.swift', 'Tivano/Services/Providers/ProviderSession.swift')),
)


GLOBAL_TRIGGERS = ('project.yml', 'Tivano.xcodeproj/', 'scripts/verify.py')
APP_BUILD_TRIGGERS = (
    'Tivano/',
    'TivanoCLI/',
    'project.yml',
    'Tivano.xcodeproj/',
    'config/',
    'LICENSE',
    'THIRD_PARTY_NOTICES.md',
    'TRADEMARK.md',
)


def truthy(value):
    return str(value or '').strip().lower() in ('1', 'true', 'yes', 'on')


def clean_git_env():
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
    for name in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE'):
        env.pop(name, None)
    return env


def git_output(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], env=clean_git_env(),
                                   stderr=subprocess.PIPE, timeout=30)


def git_config_value(key, repo=None):
    target = ROOT if repo is None else repo
    try:
        result = subprocess.run(
            ['git', '-C', str(target), 'config', '--get', key],
            env=clean_git_env(),
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def is_ci_owned(repo=None):
    return truthy(git_config_value('tivano.ci.owned', repo=repo))


def resolve_default_base(head=None, repo=None):
    target = ROOT if repo is None else Path(repo)
    env = clean_git_env()

    def run_git(*args):
        return subprocess.run(
            ['git', '-C', str(target), *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )

    try:
        if head:
            head_sha = head
        else:
            res = run_git('rev-parse', '--verify', 'HEAD^{commit}')
            if res.returncode != 0:
                return 'dev'
            head_sha = res.stdout.strip()
        dev_res = run_git('rev-parse', '--verify', '--quiet', 'refs/heads/dev^{commit}')
        preview_res = run_git('rev-parse', '--verify', '--quiet', 'refs/heads/preview^{commit}')
        dev_sha = dev_res.stdout.strip() if dev_res.returncode == 0 else None
        preview_sha = preview_res.stdout.strip() if preview_res.returncode == 0 else None
        if preview_sha and dev_sha:
            mb = run_git('merge-base', preview_sha, head_sha)
            if mb.returncode == 0:
                merge_base_sha = mb.stdout.strip()
                anc = run_git('merge-base', '--is-ancestor', merge_base_sha, dev_sha)
                if anc.returncode == 1:
                    return 'preview'
                if anc.returncode == 0:
                    return 'dev'
        elif preview_sha and not dev_sha:
            return 'preview'
    except (OSError, subprocess.SubprocessError):
        return 'dev'
    return 'dev'


def resolve_throttle_policy(args, repo=None, environ=None, cpu_count=None, platform_name=None):
    env = os.environ if environ is None else environ
    ncpu = (os.cpu_count() or 4) if cpu_count is None else cpu_count
    plat = sys.platform if platform_name is None else platform_name
    full_speed = bool(
        getattr(args, 'full_speed', False)
        or truthy(env.get('TIVANO_VERIFY_FULL_SPEED'))
        or truthy(git_config_value('tivano.verify.fullSpeed', repo=repo))
        or is_ci_owned(repo=repo)
    )
    raw_jobs = getattr(args, 'jobs', None)
    if raw_jobs is None:
        env_jobs = env.get('TIVANO_VERIFY_JOBS')
        if env_jobs is not None and str(env_jobs).strip():
            raw_jobs = str(env_jobs).strip()
        else:
            cfg_jobs = git_config_value('tivano.verify.jobs', repo=repo)
            if cfg_jobs is not None and cfg_jobs.strip():
                raw_jobs = cfg_jobs.strip()
    if raw_jobs is not None:
        try:
            jobs = int(raw_jobs)
        except (ValueError, TypeError) as error:
            raise ValueError('jobs must be >= 0') from error
        if jobs < 0:
            raise ValueError('jobs must be >= 0')
    elif full_speed:
        jobs = 0
    else:
        jobs = max(2, ncpu - 2) if ncpu >= 4 else 0
    low_priority = (not full_speed) and (plat == 'darwin')
    return {'full_speed': full_speed, 'low_priority': low_priority, 'jobs': jobs}


def low_priority_prefix(enabled, platform_name=None):
    plat = sys.platform if platform_name is None else platform_name
    if not enabled or plat != 'darwin':
        return []
    prefix = []
    if Path('/usr/sbin/taskpolicy').is_file():
        prefix.extend(['/usr/sbin/taskpolicy', '-c', 'utility'])
    if Path('/usr/bin/nice').is_file():
        prefix.extend(['/usr/bin/nice', '-n', '10'])
    return prefix


def acquire_derived_data(artifact_root_path, isolated=False, repo=None, environ=None):
    target = ROOT if repo is None else Path(repo)
    env = os.environ if environ is None else environ
    local_dir = str(Path(target) / 'build.noindex/verify-derived')
    if isolated or truthy(env.get('TIVANO_VERIFY_ISOLATED_DERIVED')) or is_ci_owned(repo=target):
        return (local_dir, None, 'worktree-local')
    shared_dir = Path(artifact_root_path) / 'private-artifacts/verify-derived.noindex'
    try:
        shared_dir.mkdir(parents=True, mode=0o700, exist_ok=True)
        fd = os.open(shared_dir / '.verify-build.lock', os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            return (local_dir, None, 'worktree-local (shared busy)')
        return (str(shared_dir), fd, 'shared')
    except OSError:
        return (local_dir, None, 'worktree-local (shared unavailable)')


def matches(path, trigger):
    return path == trigger.rstrip('/') or path.startswith(trigger.rstrip('/') + '/')


def selection(args, changed):
    broad = [p for p in changed if any(matches(p, t) for t in GLOBAL_TRIGGERS)]
    selected = {}
    for item in CHECKS:
        hits = [p for p in changed if any(matches(p, t) for t in item.triggers)]
        if args.only is not None:
            enabled = item.name in args.only
            reason = '--only' if enabled else 'excluded by --only'
        elif item.layer == 'gui':
            enabled, reason = args.gui, '--gui' if args.gui else 'requires --gui'
        elif args.all:
            enabled, reason = True, '--all'
        elif item.layer == 'slow' and not args.slow:
            if broad or hits:
                enabled, reason = False, 'slow: runs on build host (use --slow)'
            else:
                enabled, reason = False, 'no matching changed input'
        elif broad:
            enabled, reason = True, 'global trigger: ' + ', '.join(broad)
        else:
            enabled, reason = bool(hits), 'trigger: ' + ', '.join(hits) if hits else 'no matching changed input'
        selected[item.name] = {'selected': enabled, 'reason': reason}
    return selected


def build_selection(args, changed):
    if args.skip_build:
        return False, '--skip-build'
    if args.build:
        return True, '--build'
    if args.all or args.only is not None:
        return True, 'default build'
    hits = [p for p in changed if any(matches(p, t) for t in APP_BUILD_TRIGGERS)]
    if hits:
        return True, 'trigger: ' + ', '.join(hits)
    return False, 'no matching app-build input (use --build)'


def artifact_root():
    common = Path(os.fsdecode(git_output('rev-parse', '--git-common-dir')).strip())
    common = (ROOT / common).resolve()
    source = common.parent
    override = os.environ.get('TIVANO_ARTIFACTS_ROOT')
    root = Path(override) if override is not None else source.parent
    if not root.is_absolute():
        raise ValueError('TIVANO_ARTIFACTS_ROOT must be absolute')
    root = root.resolve()
    sources = {ROOT, source}
    for field in git_output('worktree', 'list', '--porcelain', '-z').split(b'\0'):
        if field.startswith(b'worktree '):
            sources.add(Path(os.fsdecode(field[9:])).resolve())
    if any(root == tree or tree in root.parents for tree in sources):
        raise ValueError('artifact root must be outside every source checkout')
    return root


def missing_prerequisites(requirements, run, git, short=None):
    missing = []
    for requirement in requirements:
        try:
            if requirement == 'macOS':
                ok = sys.platform == 'darwin'
            elif requirement == 'arm64':
                ok = platform.machine() == 'arm64'
            elif requirement == 'unprivileged':
                ok = hasattr(os, 'geteuid') and os.geteuid() != 0
            elif requirement == 'short-socket-path':
                ok = short is not None and len(os.fsencode(short / 'data/q/control.sock')) < 104
            elif requirement == 'gui-session':
                ok = subprocess.run(['/bin/launchctl', 'print', f'gui/{os.getuid()}'],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10).returncode == 0
            elif requirement == 'xcrun':
                ok = all(subprocess.run(['xcrun', *arguments], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, timeout=30).returncode == 0
                         for arguments in (('--find', 'swiftc'), ('--sdk', 'macosx', '--show-sdk-path')))
            elif requirement == 'git-cat-file-Z':
                result = subprocess.run([git, 'cat-file', '-h'], cwd=ROOT,
                                        capture_output=True, timeout=10)
                ok = b'-Z' in result.stdout + result.stderr
            else:
                ok = shutil.which(requirement) is not None
        except (OSError, subprocess.TimeoutExpired):
            ok = False
        if not ok:
            missing.append(requirement)
    return missing


def stop_process(process):
    # Some stress harnesses start their own sessions; include those descendants.
    descendants = {process.pid}
    try:
        rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid='], timeout=5, text=True)
        pairs = [tuple(map(int, line.split())) for line in rows.splitlines()]
        while True:
            children = {pid for pid, parent in pairs if parent in descendants}
            if children <= descendants:
                break
            descendants |= children
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    for pid in descendants:
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    for pid in descendants:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    process.wait()


def execute(name, command, timeout, prerequisites, run, git, short=None, low_priority=False):
    started = time.monotonic()
    log_path = run / (name + '.log')
    row = {'command': command, 'timeout': timeout, 'log': str(log_path)}
    missing = missing_prerequisites(prerequisites, run, git, short)
    with log_path.open('w') as log:
        if short is not None:
            row['artifacts'] = str(short)
            log.write('Check artifacts: ' + str(short) + '\n')
            log.flush()
        if missing:
            row.update(status='MISSING-PREREQ', missing_prerequisites=missing)
            log.write('Missing prerequisites: ' + ', '.join(missing) + '\n')
            if 'short-socket-path' in missing:
                log.write('The isolated /tmp socket path must be shorter than 104 bytes.\n')
        else:
            try:
                env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
                process = subprocess.Popen([*low_priority_prefix(low_priority), *command],
                                           cwd=ROOT, env=env, stdout=log,
                                           stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    code = process.wait(timeout=timeout)
                    row.update(status='PASS' if code == 0 else 'FAIL', exit_code=code)
                except subprocess.TimeoutExpired:
                    stop_process(process)
                    row.update(status='TIMEOUT')
                except KeyboardInterrupt:
                    stop_process(process)
                    row.update(status='FAIL', error='interrupted', interrupted=True)
            except OSError as error:
                row.update(status='FAIL', error=str(error))
                log.write(str(error) + '\n')
    row['seconds'] = round(time.monotonic() - started, 3)
    return row


def print_build_errors(log_path):
    following_failures = False
    printed = 0
    with Path(log_path).open(errors='replace') as log:
        for line in log:
            if 'The following build commands failed' in line:
                following_failures = True
            if 'error:' in line or (following_failures and line.strip()):
                print(line.rstrip())
                printed += 1
                if printed == 10:
                    break


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    if sys.flags.optimize:
        parser.error('run without -O or PYTHONOPTIMIZE; assertions must remain enabled')
    parser.add_argument('--base', default=None, help='git base commit/ref for changed-file detection (default: auto-detect dev or preview)')
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--all', action='store_true', help='run build and all fast and slow checks (plus GUI checks with --gui)')
    group.add_argument('--only', help='comma-separated check names to run; GUI checks also require --gui')
    parser.add_argument('--slow', action='store_true', help='include slow checks matched by changed paths in default selection')
    parser.add_argument('--gui', action='store_true', help='include checks requiring a logged-in graphical session')
    parser.add_argument('--fail-fast', action='store_true', help='stop after the first FAIL or TIMEOUT check and mark remaining selected checks NOT-RUN')
    parser.add_argument('--list', action='store_true', help='print selection, arguments, coverage and reasons; execute nothing')
    parser.add_argument('--full-speed', action='store_true', help='disable low-priority background scheduling and default parallel job limit')
    parser.add_argument('--jobs', type=int, default=None, help='xcodebuild parallel jobs override (0 lets Xcode decide)')
    parser.add_argument('--isolated-derived-data', '--isolated-derived', dest='isolated_derived_data', action='store_true', help='use worktree-local DerivedData instead of the shared verify cache')
    build_group = parser.add_mutually_exclusive_group()
    build_group.add_argument('--build', action='store_true', help='force the app build even when no app-build inputs changed')
    build_group.add_argument('--skip-build', action='store_true', help='skip the app build')
    args = parser.parse_args()
    if args.only is not None:
        args.only = args.only.split(',')
        unknown = set(args.only) - {c.name for c in CHECKS}
        if unknown:
            parser.error('unknown check names: ' + ', '.join(sorted(unknown)))
        if not args.gui and any(c.layer == 'gui' and c.name in args.only for c in CHECKS):
            parser.error('GUI checks require --gui even with --only')
    try:
        policy = resolve_throttle_policy(args)
        head = git_output('rev-parse', 'HEAD').decode().strip()
        if args.base is None:
            args.base = resolve_default_base(head=head)
        try:
            base_ref = git_output('rev-parse', '--verify', '--end-of-options',
                                  args.base + '^{commit}').decode().strip()
            base = git_output('merge-base', base_ref, 'HEAD').decode().strip()
        except subprocess.CalledProcessError:
            parser.error('--base must name a commit with a common ancestor of HEAD')
        committed = git_output('diff', '--name-only', '--no-renames', '-z', base, 'HEAD', '--')
        staged = git_output('diff', '--cached', '--name-only', '--no-renames', '-z', 'HEAD', '--')
        working = git_output('diff', '--name-only', '--no-renames', '-z', '--')
        untracked = git_output('ls-files', '--others', '--exclude-standard', '-z')
        changed = sorted({os.fsdecode(p) for p in (committed + staged + working + untracked).split(b'\0') if p})
        dirty = bool(git_output('status', '--porcelain', '-z', '--untracked-files=all'))
        root = artifact_root()
    except ValueError as error:
        parser.error(str(error))
    except (OSError, subprocess.SubprocessError) as error:
        print(f'FAIL: cannot inspect repository: {error}', file=sys.stderr)
        return 1
    selected = selection(args, changed)
    build_selected, build_reason = build_selection(args, changed)
    if args.list:
        for item in CHECKS:
            entry = selected[item.name]
            print(f"{item.name} [{item.layer}]: {'selected' if entry['selected'] else 'not selected'} — {entry['reason']}")
            print(f'  args={item.arguments!r}; timeout={item.timeout}s; prerequisites={item.prerequisites!r}; output={item.output}')
            print('  triggers: ' + ', '.join(item.triggers))
        print(f"build: {'selected' if build_selected else 'not selected'} — {build_reason}")
        print('  triggers: ' + ', '.join(APP_BUILD_TRIGGERS))
        print(f'base: {args.base} (merge-base {base})')
        print(f"scheduling: full_speed={policy['full_speed']} low_priority={policy['low_priority']} jobs={policy['jobs']}")
        return 0
    stamp = datetime.now(timezone.utc).strftime('%y%m%dT%H%M%SZ')
    suffix = hashlib.sha256(uuid.uuid4().bytes).hexdigest()[:6]
    run = root / 'private-artifacts/verify' / (stamp + '-' + suffix)
    run.mkdir(parents=True, mode=0o700, exist_ok=False)
    git = shutil.which('git') or 'git'
    report = {'head': head, 'dirty': dirty, 'base': args.base, 'merge_base': base,
              'changed_files': changed, 'artifacts': str(run), 'throttle': policy,
              'checks': {},
              'build': {'status': 'pending' if build_selected else 'not selected',
                        'reason': build_reason}}
    for item in CHECKS:
        entry = selected[item.name]
        report['checks'][item.name] = dict(entry, layer=item.layer, seconds=0, log=None,
                                         status='pending' if entry['selected'] else 'not selected')

    def save():
        (run / 'summary.json').write_text(json.dumps(report, indent=2, ensure_ascii=True) + '\n')

    save()
    # Fail before the build, not after it and every earlier check, when a selected
    # check cannot run here (e.g. no logged-in GUI session on the build host).
    preflight = {}
    for item in CHECKS:
        if selected[item.name]['selected']:
            needs = tuple(r for r in item.prerequisites if r != 'short-socket-path')
            missing = missing_prerequisites(needs, run, git)
            if missing:
                preflight[item.name] = missing
    if preflight:
        for name, missing in preflight.items():
            report['checks'][name].update(status='MISSING-PREREQ', missing_prerequisites=missing)
            print(f'{name}: missing prerequisites: ' + ', '.join(missing), file=sys.stderr)
        for row in report['checks'].values():
            if row['status'] == 'pending':
                row.update(status='NOT-RUN', reason='missing prerequisites')
        if build_selected:
            report['build'].update(status='NOT-RUN', reason='missing prerequisites')
        save()
        print('Artifacts: ' + str(run))
        return 1
    if build_selected:
        derived_path, derived_lock_fd, derived_mode = acquire_derived_data(
            root, isolated=args.isolated_derived_data)
        try:
            print(f'Running build (derivedData: {derived_mode})', flush=True)
            build_cmd = ['xcodebuild', '-project', 'Tivano.xcodeproj',
                         '-scheme', 'Tivano', '-configuration', 'Debug',
                         '-derivedDataPath', derived_path]
            if policy['jobs'] > 0:
                build_cmd.extend(['-jobs', str(policy['jobs'])])
            build_cmd.extend(['-skipPackagePluginValidation', '-skipMacroValidation', 'build'])
            report['build'] = execute('build', build_cmd, 3600, ('macOS', 'xcodebuild'),
                                      run, git, low_priority=policy['low_priority'])
            report['build']['derived_data_mode'] = derived_mode
            report['build']['derived_data_path'] = derived_path
        finally:
            if derived_lock_fd is not None:
                os.close(derived_lock_fd)
        save()
    build_failed = build_selected and report['build']['status'] != 'PASS'
    if build_failed:
        for row in report['checks'].values():
            if row['selected']:
                row.update(status='NOT-RUN', reason='build failed')
        save()
        print_build_errors(report['build']['log'])
    interrupted = False
    failed_fast = False
    for item in CHECKS:
        if not selected[item.name]['selected'] or build_failed:
            continue
        if interrupted:
            report['checks'][item.name].update(status='NOT-RUN', reason='interrupted')
            continue
        if failed_fast:
            report['checks'][item.name].update(status='NOT-RUN', reason='fail-fast')
            continue
        print('Running ' + item.name, flush=True)
        short = None
        try:
            if 'short-socket-path' in item.prerequisites:
                # Retain this separate artifact tree, including on failure.
                short = Path(tempfile.mkdtemp(prefix='tvlc-', dir='/tmp')).resolve() / 'lc'
            result = execute(item.name, item.command(run, git, short),
                             item.timeout, item.prerequisites, run, git, short,
                             low_priority=(policy['low_priority'] and item.layer != 'gui'))
        except OSError as error:
            log_path = run / (item.name + '.log')
            log_path.write_text(str(error) + '\n')
            result = {'status': 'FAIL', 'error': str(error), 'log': str(log_path)}
            if short is not None:
                result['artifacts'] = str(short)
                with log_path.open('a') as log:
                    log.write('Check artifacts: ' + str(short) + '\n')
        report['checks'][item.name].update(result)
        interrupted = bool(result.get('interrupted'))
        if args.fail_fast and not interrupted and result.get('status') in ('FAIL', 'TIMEOUT'):
            failed_fast = True
        save()
    if interrupted or failed_fast:
        save()
    print(f"{'Check':34} {'Status':16} Seconds")
    for name, row in [('build', report['build']), *report['checks'].items()]:
        print(f"{name:34} {row['status']:16} {row.get('seconds', 0):7.1f}  {row.get('reason', '')}")
    print('Artifacts: ' + str(run))
    if interrupted or report['build'].get('interrupted'):
        return 130
    return int(any(row['status'] not in ('PASS', 'not selected')
                   for row in [report['build'], *report['checks'].values()]))


if __name__ == '__main__':
    sys.exit(main())
