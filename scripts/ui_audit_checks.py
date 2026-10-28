#!/usr/bin/env python3
"""Compile extracted UI/cache implementations in an isolated macOS 26 harness.

Usage: python3 scripts/ui_audit_checks.py
       python3 scripts/ui_audit_checks.py --render /absolute/fresh/external/folder

No Tivano App, Store, AppModel, Git executable or provider is started. Swift sources,
module cache, HOME and generated test files live in a TemporaryDirectory. --render
also opens a fixture window and retains PNGs/source/logs in a new external folder.
The fixture uses production views/tokens, not a mock drawing of those views.

Only the generated copy is instrumented: gates delay real parses/decodes; same-file
extensions inspect private state and age FileIndex timestamps. Production algorithms
are extracted afresh, never reimplemented here. Git detection and provider delivery
are explicitly synthetic boundaries. Full application interaction is not covered.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "scripts/fixtures/ui_audit"
INPUTS = {}


def read(path):
    text = (ROOT / path).read_text()
    INPUTS[path] = hashlib.sha256(text.encode()).hexdigest()
    return text


def declaration(path, marker):
    text = read(path)
    if text.count(marker) != 1:
        raise ValueError(f"Expected exactly one declaration {marker!r} in {path}")
    start = text.index(marker)
    # Keep offsets while ignoring braces in comments and string literals. The
    # extracted declarations use ordinary Swift strings, not regex/raw literals.
    masked = re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"""[\s\S]*?"""|"(?:\\.|[^"\\])*"',
                    lambda match: " " * len(match[0]), text)
    opening = masked.index("{", start)
    depth = 1
    end = opening + 1
    while depth and end < len(masked):
        depth += (masked[end] == "{") - (masked[end] == "}")
        end += 1
    if depth:
        raise ValueError(f"Unclosed declaration: {path}: {marker}")
    return text[start:end]


def line(path, marker):
    matches = [row for row in read(path).splitlines() if marker in row]
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one source line: {path}: {marker}")
    return matches[0]


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"Instrumentation site moved or became ambiguous: {old}")
    return text.replace(old, new)


def generated_source():
    runtime = "Tivano/App/Runtime/ThreadRuntime.swift"
    markdown = "Tivano/UI/Markdown/MarkdownView.swift"
    preview = "Tivano/UI/Common/AttachmentPreview.swift"
    thumbnails = "Tivano/UI/Common/AttachmentThumbnail.swift"
    questions = "Tivano/App/Views/Composer/QuestionTab.swift"
    popovers = "Tivano/UI/Chrome/Popovers.swift"
    cache = read("Tivano/Core/Support/ThumbnailCache.swift")
    cache = replace_once(cache, "Self.decode(version, pixels: pixels, fillingSquare: fillingSquare)",
                         "let decoded = Self.decode(version, pixels: pixels, fillingSquare: fillingSquare)\n"
                         "                    await AuditGate.decode.arrive(version.path)\n"
                         "                    return decoded")
    coordinator = declaration(markdown, "@MainActor\n@Observable\nprivate final class StreamingParseCoordinator")
    coordinator = replace_once(coordinator, "MarkdownParser.parse(text, extending: previous)",
                               "await AuditGate.parse.arrive(text)\n"
                               "                return MarkdownParser.parse(text, extending: previous)")
    interrupt = declaration(runtime, "    func interrupt(byUser:")
    reset_start = interrupt.index("        for draft in questionDrafts.values { draft.retire() }")
    draft_reset = "\n".join(interrupt[reset_start:].splitlines()[:2])
    if "questionDrafts.removeAll()" not in draft_reset:
        raise ValueError("Interrupted-draft reset moved; update fixture deliberately")
    parts = [
        "import AppKit\nimport SwiftUI\nimport Foundation\nimport Observation\nimport Darwin\nimport AVFoundation\n",
        read("Tivano/Core/Support/RecentCache.swift"), cache,
        read("Tivano/UI/Markdown/MarkdownParser.swift"),
        read("Tivano/Core/Models/Requests.swift"),
        "extension String {\n" + declaration("Tivano/Core/Support/Text.swift", "    var trimmed: String") + "\n}",
        "enum ToolTitles {\n" + declaration("Tivano/Services/Providers/ProviderSession.swift", "    static func relativePath(") + "\n}",
        declaration("Tivano/App/Views/Composer/ComposerView.swift", "@MainActor\n@Observable\nfinal class FileIndex"),
        coordinator,
        "struct MarkdownBlockView: Equatable {\n    let block: MarkdownBlock\n    var settled = false\n    var generation = 0\n"
        + declaration(markdown, "    nonisolated static func == (lhs: MarkdownBlockView,") + "\n}",
        declaration(runtime, "@MainActor\n@Observable\nfinal class QuestionDraft"),
        "@MainActor\n@Observable\nfinal class ThreadRuntime {\n",
        declaration(runtime, "    private(set) var questions: [QuestionRequest]"),
        line(runtime, "private var questionDrafts:"),
        "    func auditInterruptDrafts() {\n" + draft_reset + "\n}",
        declaration(runtime, "    func questionDraft(for request:"),
        declaration(runtime, "    func answer(_ request: QuestionRequest,"),
        "    @ObservationIgnored var session: AuditSession? = AuditSession()\n"
        "    @ObservationIgnored var deliveryFailures = 0\n"
        "    private func answerDeliveryHandler() -> @MainActor (Bool) -> Void {\n"
        "        { [weak self] succeeded in if !succeeded { self?.deliveryFailures += 1 } }\n"
        "    }\n}\n",
        declaration("Tivano/UI/Chrome/Chrome.swift", "enum Chrome {"),
        read("Tivano/UI/Theme/AppTheme.swift"),
        read("Tivano/UI/Theme/TypeScale.swift"),
        declaration(popovers, "final class PopoverCloseBox:"),
        declaration(popovers, "extension EnvironmentValues {\n    @Entry var closePopoverBox:"),
        declaration(thumbnails, "struct AttachmentFileTracker:"),
        declaration(thumbnails, "struct AttachmentMediaLoad:"),
        declaration(preview, "struct ToolImagePreview:"),
        declaration(preview, "private struct AttachmentPreviewFailure:"),
        declaration(questions, "struct QuestionSheet:"),
        declaration(questions, "private struct QuestionPage:"),
        declaration(questions, "private enum QuestionAnswers"),
        (FIXTURES / "Checks.swift").read_text(),
        (FIXTURES / "Render.swift").read_text(),
    ]
    return "\n\n".join(parts)


def source_roots():
    roots = {ROOT.resolve()}
    entry = ROOT / ".git"
    if entry.is_file():
        pointer = entry.read_text().strip()
        if pointer.startswith("gitdir: "):
            gitdir = (ROOT / pointer.removeprefix("gitdir: ")).resolve()
            common = gitdir / "commondir"
            if common.is_file():
                roots.add((gitdir / common.read_text().strip()).resolve().parent)
    return roots


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--render", type=Path, help="fresh external directory for isolated view captures")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("requires macOS 26 and an Xcode Swift 6.2+ toolchain")
    output = args.render.expanduser().absolute() if args.render else None
    if output:
        if output.exists() or output.is_symlink() or any(output.resolve().is_relative_to(root) for root in source_roots()):
            parser.error("--render must be a new directory outside all source checkouts")
        output.mkdir(parents=True, mode=0o700)
    swift = generated_source()
    with tempfile.TemporaryDirectory(prefix="tivano-ui-audit-") as directory:
        work = Path(directory)
        generated = work / "UIAudit.swift"
        generated.write_text(swift)
        sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
        machine = "arm64" if platform.machine() == "arm64" else "x86_64"
        command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                   "-target", f"{machine}-apple-macosx26.0", "-sdk", sdk,
                   "-module-cache-path", str(work / "ModuleCache"), str(generated), "-o", str(work / "checks")]
        result = subprocess.run(command, cwd=work, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        print(result.stdout, end="")
        if output:
            (output / "UIAudit.swift").write_text(swift)
            (output / "compile.log").write_text(result.stdout)
            (output / "sources.json").write_text(json.dumps({"sha256": INPUTS, "compile": command,
                "boundaries": ["synthetic Git detection and provider delivery", "generated-only scheduling gates",
                               "view captures exclude app chrome, popover positioning and provider lifecycle"],
                "visualReview": "pending"}, indent=2) + "\n")
        if result.returncode:
            raise SystemExit(result.returncode)
        data = work / "data"
        data.mkdir()
        home = work / "home"
        home.mkdir()
        env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), TMPDIR=str(work))
        run = [str(work / "checks"), str(data)] + ([str(output)] if output else [])
        result = subprocess.run(run, cwd=work, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        print(result.stdout, end="")
        if output:
            (output / "checks.log").write_text(result.stdout)
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
