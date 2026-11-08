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
    count = text.count(marker)
    if count != 1:
        raise SystemExit(f'{path}: marker {marker!r} found {count} times, expected 1')
    start = text.index(marker)
    opening = text.find("{", start)
    if opening == -1:
        raise SystemExit(f'{path}: marker {marker!r} has no opening brace')
    depth, end = 1, opening + 1
    while depth and end < len(text):
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    if depth:
        raise SystemExit(f'{path}: marker {marker!r} has unbalanced braces at end of file')
    return text[start:end]


def main():
    if sys.flags.optimize:
        raise SystemExit("run without -O or PYTHONOPTIMIZE; fixture assertions must remain enabled")
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
    hydra = "Tivano/App/AppModel+Hydra.swift"
    source = (ROOT / "scripts/fixtures/local_control/DomainHarness.swift").read_text()
    replacements = {
        "TEXT_GENERATION_PRODUCTION": declaration(settings, "enum TextGenerationChoice:"),
        "TURN_UPDATE_PRODUCTION": declaration(service, "struct ControlTurnUpdate {"),
        "THREAD_CACHE_PRODUCTION": next(line.strip().replace("@ObservationIgnored ", "") for line in (ROOT / service).read_text().splitlines() if "private var cachedThreadIDs:" in line),
        "SETTINGS_PRODUCTION": "\n".join(declaration(settings, marker) for marker in [
            "    var alphaEnabled:", "    var externalControlEnabled:", "    var isExternalControlEnabled:",
            "    var alphaChimeraEnabled:", "    var isChimeraEnabled:", "    var hydraEnabled:", "    func hydraPair(for",
            "    var cliInstallationTarget:", "    var performanceMode:", "    var clearerBackdrop:",
            "    var showsSkylight:", "    var showsSkylightNow:", "    var antiSlopEnabled:", "    var textGeneration:"]),
        "APPMODEL_PRODUCTION": "\n".join(declaration(model, marker) for marker in [
            "    func controlWorkspace(", "    func requireExternalPersistence(", "    func commitExternalLibrary(",
            "    func createExternalThread(", "    static func requireControlDirectory(", "    func prepareExternalWorktree(",
            "    private func requireExternalWorkspaceOwner(", "    func executionDirectory(for", "    func ensureExecutionDirectory(for"]),
        "HYDRA_PRODUCTION": "\n".join(declaration(hydra, marker) for marker in [
            "    func hydraTeam(of", "    func runningHydraHeads(of"]),
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
    # Keep the classifier and its account/API error types real without initializing
    # provider services. Model support is real; prompt execution remains out of scope.
    text = "Tivano/Core/Support/Text.swift"
    source += "\n".join([
        declaration(text, "enum AppText {"),
        "extension String {\n" + declaration(text, "    var trimmed:") + "\n}",
        "extension HydraHeadInfo {\n" + declaration("Tivano/Core/Models/Hydra.swift", "    enum Status:") + "\n}",
        "enum TypeSafeAPI {\n" + declaration("Tivano/Services/Providers/TypeSafeAPI.swift", "    enum Failure:") + "\n}",
        declaration("Tivano/Services/Providers/ClaudeAccountCredentials.swift", "enum ClaudeCredentialError:"),
        declaration("Tivano/Services/Providers/PlanLimits.swift", "enum ResetCreditError:"),
        "extension ProviderKind { var displayName: String { rawValue } }",
        "struct HydraLaunch { var isChimera = false; var chimeraPresets: [String] = [] }",
        'enum HydraPrompts { @MainActor static var acceptsChimeraFence = false; static func v2Policy(_ launch: HydraLaunch) -> String { fatalError("Hydra prompts are outside domain checks") } }',
    ]) + "\n"
    generated.write_text(source)
    # Structural assertions supplement the executable front-door tests; they do not
    # stand in for executing provider delivery, updater or permission UI end-to-end.
    start_turn = declaration(runtime, "    private func startTurn(")
    # External turns retain their identity, reuse a session and skip UI model lookup.
    assert "externalTurnID: UUID? = nil" in start_turn
    assert "allowNewSession: externalTurnID == nil" in start_turn
    assert "if externalTurnID == nil { await ensureModel(initialThread) }" in start_turn
    # Await the has-started-turn library commit and synchronously persist the
    # external turn's snapshot before handing any input to the provider.
    assert start_turn.index("guard await app.beginThreadTurnAsync(threadID)") < start_turn.index("session.send(")
    assert start_turn.index("writeThreadSynchronously(snapshotForSave())") < start_turn.index("session.send(")
    # Both reservation and the post-history-await recheck share the production
    # running-head guard. Runtime errors use the same classifier as direct cases.
    reservation = declaration(runtime, "    func reserveExternalSubmission(")
    validation = declaration(runtime, "    private func validateExternalSubmission(")
    assert "try validateExternalRuntime(idle: true)" in reservation
    assert "try validateExternalRuntime(idle: idle)" in validation
    assert "guard app.runningHydraHeads(of: threadID) == 0 else { throw ControlFailure(code: .busy) }" in declaration(runtime, "    private func validateExternalRuntime(")
    assert "ControlFailureClassifier.classify(error)" in declaration(runtime, "    private static func controlFailure(")
    flush = declaration(model, "    func flushForQuit(")
    # Suspend admission before draining writes; refuse pending mutations and
    # restore admission when the shutdown flush cannot complete.
    assert flush.index("suspendForShutdown()") < flush.index("waitForQueuedWrites()")
    assert "!localControl.hasPendingMutations" in flush and "restoreAfterFailedShutdown()" in flush
    updater = declaration("Tivano/App/AppUpdater.swift", "    private func handOff(")
    # An updater-triggered quit must flush before launching the installer and
    # restore admission if the handoff fails.
    assert updater.index("flushForQuit(silently: silent)") < updater.index("try process.run()")
    assert "restoreAfterFailedShutdown()" in updater
    (output / "structural-results.json").write_text(json.dumps({"scope": "source-structure assertions only; behavioral cases are in domain-results.json", "checked": ["external delivery reuses startTurn", "no external session-start fallback", "no UI ensureModel await for external submission", "beginThreadTurn and thread persistence precede session.send", "reservation and submission recheck share runtime admission guards", "runtime failures delegate to production ControlFailureClassifier", "shutdown suspension precedes flush and restores on failure", "updater uses flush before installer and restores on failure"]}, indent=2) + "\n")
    swift = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    paths = ["Tivano/Core/Models/LocalControl.swift", "Tivano/Core/Support/Coding.swift", "Tivano/Core/Models/ProviderAccount.swift", "Tivano/Core/Models/Chimera.swift", "Tivano/Core/Models/Hydra2.swift", "Tivano/Core/Models/Library.swift", "Tivano/Core/Support/StoragePaths.swift", "Tivano/Services/Control/ControlLedger.swift", "Tivano/App/Runtime/ControlFailureClassifier.swift"]
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
