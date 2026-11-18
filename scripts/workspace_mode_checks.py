#!/usr/bin/env python3
"""Exercise WorkspaceMode metadata, settings/localization wiring, and Auto worktree helpers offline."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

PROVIDER_PATH = "Tivano/Core/Models/Provider.swift"
APP_SETTINGS_PATH = "Tivano/App/AppSettings.swift"
APP_MODEL_PATH = "Tivano/App/AppModel.swift"
SETTINGS_VIEW_PATH = "Tivano/App/Views/Settings/ConversationSettingsPage.swift"
CATALOG_PATH = "Tivano/Resources/Localizable.xcstrings"

REQUIRED_ZH_HANS_KEYS = (
    "Auto",
    "Local",
    "New worktree",
    "Edits your project folder directly, and creates a Git worktree when another chat is already active there.",
    "Edits files directly in your project folder.",
    "Isolates each chat in its own Git worktree copy. Non-Git folders stay local.",
    "Another chat is active in this repository, and a separate Git worktree isn't available right now. Wait for it to finish, then send again.",
    "Created a new Git worktree and started its setup scripts in Terminal. Send again once setup finishes.",
)


def declaration(path: str, marker: str) -> str:
    text = (ROOT / path).read_text(encoding="utf-8")
    count = text.count(marker)
    if count != 1:
        raise SystemExit(f"{path}: marker {marker!r} found {count} times, expected 1")
    start = text.index(marker)
    opening = text.find("{", start)
    if opening == -1:
        raise SystemExit(f"{path}: marker {marker!r} has no opening brace")
    depth, end = 1, opening + 1
    while depth and end < len(text):
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    if depth:
        raise SystemExit(f"{path}: marker {marker!r} has unbalanced braces at end of file")
    return text[start:end]


def check_sources_and_localizations() -> None:
    failures: list[str] = []

    app_settings = (ROOT / APP_SETTINGS_PATH).read_text(encoding="utf-8")
    expected_default = 'defaultWorkspaceMode = WorkspaceMode(rawValue: defaults.string(forKey: Key.workspaceMode) ?? "") ?? .auto'
    if expected_default not in app_settings:
        failures.append(f"{APP_SETTINGS_PATH}: missing {expected_default!r}")

    settings_view = (ROOT / SETTINGS_VIEW_PATH).read_text(encoding="utf-8")
    for snippet in ("detail: settings.defaultWorkspaceMode.summary", "Image(systemName: mode.symbol)"):
        if snippet not in settings_view:
            failures.append(f"{SETTINGS_VIEW_PATH}: missing {snippet!r}")

    try:
        catalog = json.loads((ROOT / CATALOG_PATH).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"FAIL: {CATALOG_PATH}: {error}")

    strings = catalog.get("strings")
    if not isinstance(strings, dict):
        raise SystemExit(f"FAIL: {CATALOG_PATH}: missing top-level 'strings' object")

    for key in REQUIRED_ZH_HANS_KEYS:
        entry = strings.get(key)
        localizations = entry.get("localizations", {}) if isinstance(entry, dict) else {}
        for locale in ("zh-Hans", "zh-Hant", "ja", "ko", "fr"):
            string_unit = localizations.get(locale, {}).get("stringUnit", {})
            state = string_unit.get("state") if isinstance(string_unit, dict) else None
            value = string_unit.get("value") if isinstance(string_unit, dict) else None
            if state != "translated" or not isinstance(value, str) or not value.strip():
                failures.append(
                    f"{CATALOG_PATH}: {key!r} must have a non-empty {locale} translation with state == 'translated' "
                    f"(got state={state!r}, value={value!r})"
                )

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        raise SystemExit(1)


def run_git(git: str, cwd: Path, args: list[str], env: dict[str, str]) -> str:
    result = subprocess.run(
        [git, *args],
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} in {cwd} failed ({result.returncode}): {result.stderr or result.stdout}")
    return result.stdout


def create_git_fixtures(repos: Path, git: str, env: dict[str, str]) -> dict[str, str]:
    non_git = repos / "non-git"
    non_git.mkdir()

    empty_repo = repos / "empty-repo"
    empty_repo.mkdir()
    run_git(git, empty_repo, ["init"], env)

    clean_repo = repos / "clean-repo"
    clean_repo.mkdir()
    run_git(git, clean_repo, ["init"], env)
    (clean_repo / "README.md").write_text("hello\n", encoding="utf-8")
    subdir = clean_repo / "Sources"
    subdir.mkdir()
    (subdir / "file.txt").write_text("source\n", encoding="utf-8")
    run_git(git, clean_repo, ["add", "README.md", "Sources/file.txt"], env)
    run_git(git, clean_repo, ["commit", "-m", "Initial commit"], env)

    dirty_repo = repos / "dirty-repo"
    dirty_repo.mkdir()
    run_git(git, dirty_repo, ["init"], env)
    (dirty_repo / "README.md").write_text("clean\n", encoding="utf-8")
    run_git(git, dirty_repo, ["add", "README.md"], env)
    run_git(git, dirty_repo, ["commit", "-m", "Initial commit"], env)
    (dirty_repo / "README.md").write_text("dirty\n", encoding="utf-8")
    (dirty_repo / "untracked.txt").write_text("untracked\n", encoding="utf-8")

    merging_repo = repos / "merging-repo"
    merging_repo.mkdir()
    run_git(git, merging_repo, ["init"], env)
    (merging_repo / "README.md").write_text("merge\n", encoding="utf-8")
    run_git(git, merging_repo, ["add", "README.md"], env)
    run_git(git, merging_repo, ["commit", "-m", "Initial commit"], env)
    head_sha = run_git(git, merging_repo, ["rev-parse", "HEAD"], env).strip()
    (merging_repo / ".git" / "MERGE_HEAD").write_text(head_sha + "\n", encoding="utf-8")

    symlink_repo = repos / "clean-repo-link"
    symlink_repo.symlink_to(clean_repo)

    sibling_wt1 = repos / "wt-alpha"
    sibling_wt2 = repos / "wt-beta"
    run_git(git, clean_repo, ["worktree", "add", "-b", "wt-alpha", str(sibling_wt1)], env)
    run_git(git, clean_repo, ["worktree", "add", "-b", "wt-beta", str(sibling_wt2)], env)

    prefix_sibling = repos / "clean-repo-sibling"
    prefix_sibling.mkdir()

    return {
        "nonGit": str(non_git),
        "emptyRepo": str(empty_repo),
        "cleanRepo": str(clean_repo),
        "dirtyRepo": str(dirty_repo),
        "subdir": str(subdir),
        "mergingRepo": str(merging_repo),
        "symlinkRepo": str(symlink_repo),
        "siblingWT1": str(sibling_wt1),
        "siblingWT2": str(sibling_wt2),
        "prefixSibling": str(prefix_sibling),
    }


def build_swift_checks_source() -> str:
    workspace_mode = declaration(PROVIDER_PATH, "enum WorkspaceMode:")
    canonical = declaration(APP_MODEL_PATH, "nonisolated static func canonicalWorkspacePath(")
    overlap = declaration(APP_MODEL_PATH, "nonisolated static func workspacePathsOverlap(")
    eligibility_enum = declaration(APP_MODEL_PATH, "enum AutoWorktreeEligibility:")
    eligibility_func = declaration(APP_MODEL_PATH, "nonisolated static func autoWorktreeEligibility(")
    can_auto = declaration(APP_MODEL_PATH, "nonisolated static func canAutoCreateWorktree(")

    return f'''import Foundation
import Darwin

enum AppText {{
    static func localized(_ key: String) -> String {{ key }}
}}

extension String {{
    var nilIfEmpty: String? {{ isEmpty ? nil : self }}
    var trimmed: String {{ trimmingCharacters(in: .whitespacesAndNewlines) }}
}}

enum StdioProcess {{
    final class DescendantTracker: @unchecked Sendable {{
        func start(_ pid: pid_t) {{}}
        func terminate() {{}}
    }}
}}

struct DiffFile: Identifiable, Hashable, Sendable {{
    var path: String
    var oldPath: String?
    var id: String {{ path }}
}}

enum SharedResourceLock {{
    static func url(resource: String) -> URL {{
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tivano-workspace-mode-locks", isDirectory: true)
            .appendingPathComponent("unused.lock")
    }}
}}

final class SharedLibraryLease: Sendable {{
    init(at url: URL, wait: Bool = false) throws {{
        throw CocoaError(.fileWriteNoPermission)
    }}
}}

struct CursorOriginRemote: Equatable, Sendable {{
    let fullName = ""
    var webURL: URL {{ URL(string: "https://cursor.com")! }}
    init?(remote: String) {{ return nil }}
}}

struct MergeRequestLink: Equatable, Sendable {{
    enum Forge: Sendable {{ case gitlab, github, cursorOrigin, gitea }}
    var url: URL
    var forge: Forge
    var number: Int
    var originRepository: String? {{ nil }}
    init?(url: URL) {{ return nil }}
}}

struct RevertPreview: Sendable {{
    struct File: Identifiable, Sendable {{
        let path: String
        let additions: Int
        let deletions: Int
        let isBinary: Bool
        var isKept = false
        var id: String {{ path }}
    }}
    var files: [File]
    init(files: [File]) {{ self.files = files }}
    init(numstat: String) throws {{ self.files = [] }}
}}

final class WorkingTreeWatch: Sendable {{
    static func shared(for directory: String, gitDirectory: String) -> WorkingTreeWatch? {{ nil }}
    func commit(of tree: String) -> String? {{ nil }}
    func remember(commit: String, of tree: String) {{}}
    func currentTree(
        indexPath: String,
        capture: @escaping @Sendable (_ scratch: URL?, _ paths: [String]?) async throws -> String
    ) async throws -> String {{
        try await capture(nil, nil)
    }}
}}

{workspace_mode}

enum AppModel {{
{canonical}

{overlap}

{eligibility_enum}

{eligibility_func}

{can_auto}
}}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {{
    precondition(condition(), message)
}}

@main struct WorkspaceModeChecks {{
    static func main() async throws {{
        setbuf(stdout, nil)
        let fixturesData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let fixtures = try JSONDecoder().decode([String: String].self, from: fixturesData)
        func path(_ key: String) -> String {{
            guard let value = fixtures[key] else {{
                preconditionFailure("Missing fixture path: \\(key)")
            }}
            return value
        }}

        // (a) WorkspaceMode cases and non-empty metadata
        check(WorkspaceMode.allCases == [.auto, .local, .worktree], "WorkspaceMode.allCases mismatch")
        for mode in WorkspaceMode.allCases {{
            check(!mode.title.trimmed.isEmpty, "WorkspaceMode.\\(mode).title is empty")
            check(!mode.summary.trimmed.isEmpty, "WorkspaceMode.\\(mode).summary is empty")
            check(!mode.symbol.trimmed.isEmpty, "WorkspaceMode.\\(mode).symbol is empty")
        }}
        print("PASS (a): WorkspaceMode.allCases and non-empty title, summary, symbol")

        // (b) Non-Git folder -> .nonGit / false
        let nonGitEligibility = await AppModel.autoWorktreeEligibility(in: path("nonGit"))
        check(nonGitEligibility == .nonGit,
              "autoWorktreeEligibility(in:) must return .nonGit on a non-Git folder")
        let nonGitAllowed = await AppModel.canAutoCreateWorktree(in: path("nonGit"))
        check(nonGitAllowed == false,
              "canAutoCreateWorktree(in:) must return false on a non-Git folder")
        print("PASS (b): non-Git folder returns .nonGit / false")

        // (c) git init with 0 commits -> .unavailable / false
        let emptyRepoEligibility = await AppModel.autoWorktreeEligibility(in: path("emptyRepo"))
        check(emptyRepoEligibility == .unavailable,
              "autoWorktreeEligibility(in:) must return .unavailable on a repository with 0 commits")
        let emptyRepoAllowed = await AppModel.canAutoCreateWorktree(in: path("emptyRepo"))
        check(emptyRepoAllowed == false,
              "canAutoCreateWorktree(in:) must return false on a repository with 0 commits")
        print("PASS (c): 0-commit repository returns .unavailable / false")

        // (d) Committed root Git repository (clean and dirty) -> .eligible / true
        let cleanRepoEligibility = await AppModel.autoWorktreeEligibility(in: path("cleanRepo"))
        check(cleanRepoEligibility == .eligible,
              "autoWorktreeEligibility(in:) must return .eligible on a committed root Git repository")
        let cleanRepoAllowed = await AppModel.canAutoCreateWorktree(in: path("cleanRepo"))
        check(cleanRepoAllowed == true,
              "canAutoCreateWorktree(in:) must return true on a committed root Git repository")
        let dirtyRepoEligibility = await AppModel.autoWorktreeEligibility(in: path("dirtyRepo"))
        check(dirtyRepoEligibility == .eligible,
              "autoWorktreeEligibility(in:) must return .eligible when uncommitted dirty files are present")
        let dirtyRepoAllowed = await AppModel.canAutoCreateWorktree(in: path("dirtyRepo"))
        check(dirtyRepoAllowed == true,
              "canAutoCreateWorktree(in:) must return true when uncommitted dirty files are present")
        print("PASS (d): committed root Git repository returns .eligible / true (clean and dirty)")

        // (e) Subdirectory inside committed Git repository -> .unavailable / false
        let subdirEligibility = await AppModel.autoWorktreeEligibility(in: path("subdir"))
        check(subdirEligibility == .unavailable,
              "autoWorktreeEligibility(in:) must return .unavailable on a subdirectory inside a Git repository")
        let subdirAllowed = await AppModel.canAutoCreateWorktree(in: path("subdir"))
        check(subdirAllowed == false,
              "canAutoCreateWorktree(in:) must return false on a subdirectory inside a Git repository")
        print("PASS (e): repository subdirectory returns .unavailable / false")

        // (f) .git/MERGE_HEAD exists -> .unavailable / false
        let mergingRepoEligibility = await AppModel.autoWorktreeEligibility(in: path("mergingRepo"))
        check(mergingRepoEligibility == .unavailable,
              "autoWorktreeEligibility(in:) must return .unavailable when .git/MERGE_HEAD exists")
        let mergingRepoAllowed = await AppModel.canAutoCreateWorktree(in: path("mergingRepo"))
        check(mergingRepoAllowed == false,
              "canAutoCreateWorktree(in:) must return false when .git/MERGE_HEAD exists")
        print("PASS (f): repository with .git/MERGE_HEAD returns .unavailable / false")

        // (g) workspacePathsOverlap(_:_:) and canonicalWorkspacePath(_:)
        let cleanRepo = path("cleanRepo")
        let symlinkRepo = path("symlinkRepo")
        let subdir = path("subdir")
        let siblingWT1 = path("siblingWT1")
        let siblingWT2 = path("siblingWT2")
        let prefixSibling = path("prefixSibling")

        check(AppModel.workspacePathsOverlap(cleanRepo, cleanRepo),
              "Identical paths must overlap")
        check(AppModel.workspacePathsOverlap(cleanRepo, cleanRepo + "/"),
              "Identical paths with trailing slash must overlap")
        check(AppModel.canonicalWorkspacePath(symlinkRepo) == AppModel.canonicalWorkspacePath(cleanRepo),
              "canonicalWorkspacePath(_:) must normalize symlinked paths to the same canonical path")
        check(AppModel.workspacePathsOverlap(symlinkRepo, cleanRepo),
              "Symlinked path and target must overlap")
        check(AppModel.workspacePathsOverlap(cleanRepo, symlinkRepo),
              "Target and symlinked path must overlap")
        check(AppModel.workspacePathsOverlap(cleanRepo, subdir),
              "Parent and child paths must overlap")
        check(AppModel.workspacePathsOverlap(subdir, cleanRepo),
              "Child and parent paths must overlap")
        check(!AppModel.workspacePathsOverlap(siblingWT1, siblingWT2),
              "Sibling worktree paths must not overlap")
        check(!AppModel.workspacePathsOverlap(cleanRepo, siblingWT1),
              "Main checkout and sibling worktree must not overlap")
        check(!AppModel.workspacePathsOverlap(cleanRepo, prefixSibling),
              "Sibling path sharing a string prefix must not overlap")
        print("PASS (g): workspacePathsOverlap(_:_:) and canonicalWorkspacePath(_:)")
    }}
}}
'''


def main() -> int:
    if sys.flags.optimize:
        raise SystemExit("run without -O or PYTHONOPTIMIZE; fixture assertions must remain enabled")

    check_sources_and_localizations()
    swift_source = build_swift_checks_source()

    git = shutil.which("git")
    if not git:
        raise SystemExit("FAIL: git executable not found on PATH")
    swiftc = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()

    with tempfile.TemporaryDirectory(prefix="tivano-workspace-mode-checks-") as temporary:
        root = Path(temporary).resolve()
        home = root / "home"
        tmp = root / "tmp"
        repos = root / "repos"
        module_cache = root / "ModuleCache"
        for directory in (home, tmp, repos, module_cache):
            directory.mkdir(mode=0o700)

        path_entries = [str(Path(git).resolve().parent)]
        if current_path := os.environ.get("PATH"):
            path_entries.append(current_path)
        env = {
            "PATH": ":".join(path_entries),
            "HOME": str(home),
            "TMPDIR": str(tmp) + "/",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_ATTR_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_AUTHOR_NAME": "Tivano Test",
            "GIT_AUTHOR_EMAIL": "tivano-test@example.com",
            "GIT_COMMITTER_NAME": "Tivano Test",
            "GIT_COMMITTER_EMAIL": "tivano-test@example.com",
            "LC_ALL": "C",
        }

        fixtures = create_git_fixtures(repos, git, env)
        fixtures_json = root / "fixtures.json"
        fixtures_json.write_text(json.dumps(fixtures, indent=2) + "\n", encoding="utf-8")

        checks_swift = root / "Checks.swift"
        checks_swift.write_text(swift_source, encoding="utf-8")
        binary = root / "workspace-mode-checks"

        compile_command = [
            swiftc,
            "-parse-as-library",
            "-swift-version", "6",
            "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
            "-sdk", sdk,
            "-j", "4",
            "-module-cache-path", str(module_cache),
            str(ROOT / "Tivano/Core/Support/Shell.swift"),
            str(ROOT / "Tivano/Services/Git/TouchedPaths.swift"),
            str(ROOT / "Tivano/Services/Git/Git.swift"),
            str(checks_swift),
            "-o", str(binary),
        ]
        subprocess.run(compile_command, check=True, cwd=root, env=env, timeout=120)
        subprocess.run([str(binary), str(fixtures_json)], check=True, cwd=root, env=env, timeout=60)

    print("OK: workspace_mode_checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
