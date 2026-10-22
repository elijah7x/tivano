#!/usr/bin/env python3
"""Run isolated workspace-recovery fixtures extracted from current product source.

No App launch, provider, credentials or real library access. Uses real model
coding, recovery I/O and executionDirectory with isolated paths/defaults and a
fixed recovery timestamp for deterministic backup/quarantine write failures.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
from local_control_domain_checks import declaration

ROOT = Path(__file__).resolve().parents[1]
CASES = (
    "missing", "null", "local", "local_unenforced", "preparing", "preparing_unenforced",
    "ready", "ready_unenforced", "wrong_type", "number", "array", "unknown_mode",
    "unknown_phase", "missing_mode", "missing_phase", "missing_enforcement",
    "ready_nil", "ready_empty", "ready_nil_unenforced", "ready_empty_unenforced",
    "only_bad", "other_bad_field", "mixed_skipped", "majority_bad",
    "backup_failure", "quarantine_failure", "previous_fallback",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", type=Path, help="fresh output directory outside the checkout")
    parser.add_argument("--case", choices=CASES, help="run only one condition")
    args = parser.parse_args()
    output = args.artifacts.expanduser().resolve()
    if output == ROOT or ROOT in output.parents or output.exists():
        parser.error("use a fresh external artifact directory")
    output.mkdir(parents=True, mode=0o700)
    store = "Tivano/Services/Store/Storage.swift"
    model = "Tivano/App/AppModel.swift"
    control = "Tivano/Core/Models/LocalControl.swift"
    coding = "Tivano/Core/Support/Coding.swift"
    library = "Tivano/Core/Models/Library.swift"
    paths = "Tivano/Core/Support/StoragePaths.swift"
    fixture = "scripts/fixtures/workspace_recovery/Recovery.swift"
    source = (ROOT / fixture).read_text()
    replacements = {
        "MODELS_PRODUCTION": "\n".join([
            (ROOT / coding).read_text(), (ROOT / library).read_text(),
            *(declaration(control, marker) for marker in (
                "enum ControlWorkspaceMode:", "enum ControlWorkspacePhase:",
                "struct ControlWorkspace:", "struct ControlFailure:")),
            declaration(store, "enum LibraryLoad:"),
        ]),
        "STORAGE_PRODUCTION": "\n".join(declaration(store, marker) for marker in (
            "    nonisolated static func loadLibraryRecovering(",
            "    private nonisolated static func recoverLibraryElements(",
            "    nonisolated static func prepareLibraryWrite(")),
        "EXECUTION_PRODUCTION": declaration(model, "    func executionDirectory(for"),
        "TASK_PATH_PRODUCTION": declaration(paths, "    nonisolated static func taskWorkspace("),
    }
    for key, value in replacements.items():
        marker = "/* " + key + " */"
        if source.count(marker) != 1:
            raise ValueError(f"expected one fixture marker: {marker}")
        source = source.replace(marker, value)
    generated = output / "Recovery.swift"
    generated.write_text(source)
    binary = output / "workspace-recovery-checks"
    command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-j", "4",
               "-module-cache-path", str(output / "ModuleCache"), str(generated), "-o", str(binary)]
    record = {
        "scope": "extracted production recovery, model coding and directory resolution; isolated dependencies, not App end-to-end proof",
        "compile_command": command,
        "sources": {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in (
            store, model, control, coding, library, paths, fixture,
            "scripts/local_control_domain_checks.py", "scripts/workspace_recovery_checks.py")},
        "generated_sha256": hashlib.sha256(source.encode()).hexdigest(),
        "cases": [],
    }

    def save_record():
        (output / "commands.json").write_text(json.dumps(record, indent=2) + "\n")

    with (output / "compile.log").open("w") as log:
        compiled = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, cwd=ROOT)
    record["compile_exit"] = compiled.returncode
    save_record()
    if compiled.returncode:
        print(f"Compilation failed: {output / 'compile.log'}", file=sys.stderr)
        return 1
    failed = False
    for name in (args.case,) if args.case else CASES:
        data = output / "data" / name
        run = [str(binary), str(data), name]
        entry = {"case": name, "command": run}
        with (output / f"{name}.log").open("w") as log:
            try:
                result = subprocess.run(run, stdout=log, stderr=subprocess.STDOUT, cwd=output, timeout=60)
                entry["exit"] = result.returncode
                report = json.loads((data / "results.json").read_text())
                entry["pass"] = result.returncode == 0 and report.get("pass") is True
            except (subprocess.TimeoutExpired, OSError, ValueError) as error:
                entry["pass"] = False
                entry["error"] = str(error)
        failed |= not entry["pass"]
        record["cases"].append(entry)
        save_record()
    print(f"{'FAIL' if failed else 'PASS'}: {len(record['cases'])} workspace recovery cases; evidence: {output}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
