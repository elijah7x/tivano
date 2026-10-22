#!/usr/bin/env python3
"""Exercise selected production App/runtime contracts without initializing the App.

Production declarations are copied verbatim into a synthetic surrounding harness.
Provider execution, disk writer and framework dependencies are stubs, explicitly
not end-to-end evidence. Artifacts must be fresh and outside source.
"""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def declaration(path, marker):
    text = (ROOT / path).read_text()
    start = text.index(marker)
    opening = text.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", type=Path)
    args = parser.parse_args()
    output = args.artifacts.expanduser().absolute()
    if output == ROOT or ROOT in output.parents or output.exists():
        parser.error("use a fresh external artifact directory")
    output.mkdir(parents=True, mode=0o700)
    model = "Tivano/App/AppModel.swift"
    service = "Tivano/App/Control/AppControlService.swift"
    runtime = "Tivano/App/Runtime/ThreadRuntime.swift"
    settings = "Tivano/App/AppSettings.swift"
    source = (ROOT / "scripts/fixtures/local_control/DomainHarness.swift").read_text()
    replacements = {
        "TEXT_GENERATION_PRODUCTION": declaration(settings, "enum TextGenerationChoice:"),
        "TURN_UPDATE_PRODUCTION": declaration(service, "struct ControlTurnUpdate {"),
        "THREAD_CACHE_PRODUCTION": next(line.strip().replace("@ObservationIgnored ", "") for line in (ROOT / service).read_text().splitlines() if "private var cachedThreadIDs:" in line),
        "SETTINGS_PRODUCTION": "\n".join(declaration(settings, marker) for marker in [
            "    var alphaEnabled:", "    var externalControlEnabled:", "    var isExternalControlEnabled:",
            "    var cliInstallationTarget:", "    var performanceMode:", "    var clearerBackdrop:",
            "    var showsSkylight:", "    var showsSkylightNow:", "    var antiSlopEnabled:", "    var textGeneration:"]),
        "APPMODEL_PRODUCTION": "\n".join(declaration(model, marker) for marker in [
            "    func controlWorkspace(", "    func requireExternalPersistence(", "    func commitExternalLibrary(",
            "    func createExternalThread(", "    static func requireControlDirectory(", "    func prepareExternalWorktree(",
            "    private func requireExternalWorkspaceOwner(", "    func executionDirectory(for", "    func ensureExecutionDirectory(for"]),
        "SERVICE_PRODUCTION": "\n".join(declaration(service, marker) for marker in [
            "    func requireOrdinaryThread(", "    func requireAvailableProvider(", "    private func resolveContinuation(",
            "    static func supportsExactContinuation(", "    private func providerSummaries(", "    private func listThreads(",
            "    private func threadSummary(", "    private func settingsSnapshot(", "    private func applySetting("]),
        "RUNTIME_PRODUCTION": "\n".join(declaration(runtime, marker) for marker in [
            "    func reserveExternalSubmission(", "    func submitExternal(", "    private func validateExternalRuntime(",
            "    private func validateExternalSubmission(", "    private func failExternalBeforeTurn(", "    private static func controlFailure(",
            "    func interruptExternal(", "    private func publishControlEvent(", "    private func finishControlTurn(",
            "    private func completeControlSubmission(", "    private func deliverControlCompletion("]),
    }
    runtime_text = (ROOT / runtime).read_text()
    replacements["RUNTIME_STATE_PRODUCTION"] = runtime_text[runtime_text.index("    private struct ExternalSubmission {"):runtime_text.index("    func reserveExternalSubmission(")]
    for key, value in replacements.items():
        marker = "/* " + key + " */"
        assert source.count(marker) == 1, marker
        source = source.replace(marker, value)
    generated = output / "DomainChecks.swift"
    generated.write_text(source)
    # Structural assertions supplement the executable front-door tests; they do not
    # stand in for executing provider delivery, updater or permission UI end-to-end.
    start_turn = declaration(runtime, "    private func startTurn(")
    assert "externalTurnID: UUID? = nil" in start_turn
    assert "allowNewSession: externalTurnID == nil" in start_turn
    assert "if externalTurnID == nil { await ensureModel(initialThread) }" in start_turn
    assert start_turn.index("app.beginThreadTurn(threadID)") < start_turn.index("session.send(")
    assert start_turn.index("writeThreadSynchronously(snapshotForSave())") < start_turn.index("session.send(")
    flush = declaration(model, "    func flushForQuit(")
    assert flush.index("suspendForShutdown()") < flush.index("waitForQueuedWrites()")
    assert "!localControl.hasPendingMutations" in flush and "restoreAfterFailedShutdown()" in flush
    updater = declaration("Tivano/App/AppUpdater.swift", "    private func handOff(")
    assert updater.index("flushForQuit()") < updater.index("try process.run()")
    assert "restoreAfterFailedShutdown()" in updater
    (output / "structural-results.json").write_text(json.dumps({"scope": "source-structure assertions only", "checked": ["external delivery reuses startTurn", "no external session-start fallback", "no UI ensureModel await for external submission", "beginThreadTurn and thread persistence precede session.send", "shutdown suspension precedes flush and restores on failure", "updater uses flush before installer and restores on failure"]}, indent=2) + "\n")
    swift = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    paths = ["Tivano/Core/Models/LocalControl.swift", "Tivano/Core/Support/Coding.swift", "Tivano/Core/Models/Library.swift", "Tivano/Core/Support/StoragePaths.swift", "Tivano/Services/Control/ControlLedger.swift"]
    command = [swift, "-parse-as-library", "-swift-version", "6", "-target", "arm64-apple-macosx26.0", "-sdk", sdk,
               "-j", "4", "-module-cache-path", str(output / "ModuleCache"),
               *[str(ROOT / path) for path in paths], str(generated), "-o", str(output / "domain-checks")]
    record = {"started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "compile_command": command,
              "scope": "extracted production domain declarations, synthetic dependencies; no App/provider launch"}
    with (output / "compile.log").open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, cwd=ROOT)
    record["compile_exit_status"] = result.returncode
    if result.returncode == 0:
        run = [str(output / "domain-checks"), str(output / "data")]
        record["run_command"] = run
        with (output / "domain.log").open("w") as log:
            result = subprocess.run(run, stdout=log, stderr=subprocess.STDOUT, cwd=output, timeout=60)
        record["run_exit_status"] = result.returncode
    record["ended_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    (output / "commands.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record, indent=2))
    print((output / ("compile.log" if record["compile_exit_status"] else "domain.log")).read_text())
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
