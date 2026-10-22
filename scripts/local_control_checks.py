#!/usr/bin/env python3
"""Compile/run production local-control code against synthetic data, never the App.

Pass a fresh external artifact directory; no fixtures, binary, caches or logs are
written in source. Keep its path short enough for Darwin's 104-byte socket path.
This is isolated evidence, not signed build, provider, GUI or App performance proof.
"""
import argparse
import datetime
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import textwrap

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", type=Path)
    args = parser.parse_args()
    output = args.artifacts.expanduser().absolute()
    if not output.is_absolute() or output == ROOT or ROOT in output.parents:
        parser.error("artifacts must be outside the source checkout")
    if output.exists():
        parser.error("use a fresh artifact directory; failure evidence is never overwritten")
    if len(os.fsencode(output / "data/q/control.sock")) >= 104:
        parser.error("artifact path is too long for the isolated Unix socket")
    output.mkdir(parents=True, mode=0o700)
    os.chmod(output, 0o700)
    swift = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    sources = [
        "Tivano/Core/Models/LocalControl.swift",
        "Tivano/Services/Control/ControlSocket.swift",
        "Tivano/Services/Control/ControlClient.swift",
        "Tivano/Services/Control/ControlLedger.swift",
        "Tivano/Services/Control/ControlCLIInstaller.swift",
        "Tivano/Services/Store/ControlHistoryReader.swift",
        "scripts/fixtures/local_control/Checks.swift",
    ]
    command = [swift, "-parse-as-library", "-swift-version", "6", "-strict-concurrency=complete",
               "-target", "arm64-apple-macosx26.0", "-sdk", sdk, "-j", "4",
               "-module-cache-path", str(output / "ModuleCache"),
               *[str(ROOT / item) for item in sources], "-o", str(output / "checks")]
    record = {"started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "compile_command": command, "scope": "synthetic non-GUI; no App product/signing fallback"}
    with (output / "compile.log").open("w") as log:
        result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    record["compile_exit_status"] = result.returncode
    if result.returncode == 0:
        run = [str(output / "checks"), str(output / "data")]
        # Only this process's synthetic data is created, under the supplied artifact root.
        record["run_command"] = run
        with (output / "checks.log").open("w") as log:
            result = subprocess.run(run, cwd=output, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        record["run_exit_status"] = result.returncode
    parser_results = []
    if result.returncode == 0:
        cli = (ROOT / "TivanoCLI/main.swift").read_text()
        assert cli.endswith("exit(CLI.run())\n")
        generated = output / "main.swift"
        generated.write_text(cli.removesuffix("exit(CLI.run())\n") + (ROOT / "scripts/fixtures/local_control/CLIParserChecks.swift").read_text())
        # Validate the exact multiline English help key and every catalog object's key
        # uniqueness without rewriting or extracting strings into the source checkout.
        def unique(pairs):
            values = {}
            for key, value in pairs:
                assert key not in values, "duplicate catalog key: " + key
                values[key] = value
            return values
        catalog = json.loads((ROOT / "Tivano/Resources/Localizable.xcstrings").read_text(), object_pairs_hook=unique)
        usage = textwrap.dedent(cli.split('static let usage = """\n', 1)[1].split('\n    """', 1)[0])
        assert catalog["strings"][usage]["localizations"]["zh-Hans"]["stringUnit"]["state"] == "translated"
        core = (ROOT / "Tivano/Core/Models/LocalControl.swift").read_text()
        messages = re.findall(r'case \.[^:\n]+: "([^"]+)"', core)
        assert len(messages) == 24, "all protocol error message keys must be checked"
        for message in messages:
            assert catalog["strings"][message]["localizations"]["zh-Hans"]["stringUnit"]["state"] == "translated", message
        for edition in ["dev", "release"]:
            binary = output / ("cli-parser-" + edition)
            compile_cli = [swift, "-swift-version", "6", "-target", "arm64-apple-macosx26.0", "-sdk", sdk,
                           "-j", "4", "-module-cache-path", str(output / "ModuleCache"),
                           *(["-D", "DEBUG"] if edition == "dev" else []),
                           *[str(ROOT / item) for item in sources[:3]], str(generated), "-o", str(binary)]
            row = {"edition": edition, "compile_command": compile_cli}
            with (output / ("cli-" + edition + "-compile.log")).open("w") as log:
                result = subprocess.run(compile_cli, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
            row["compile_exit_status"] = result.returncode
            if result.returncode == 0:
                with (output / ("cli-" + edition + ".log")).open("w") as log:
                    result = subprocess.run([str(binary)], cwd=output, stdout=log, stderr=subprocess.STDOUT, timeout=30)
                row["run_exit_status"] = result.returncode
            parser_results.append(row)
            if result.returncode:
                break
        record["cli_parser_checks"] = parser_results
        record["localization_help_key"] = "exact English help/error keys have zh-Hans; no duplicate catalog keys"
    record["ended_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    (output / "commands.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record, indent=2))
    print((output / ("compile.log" if record["compile_exit_status"] else "checks.log")).read_text())
    for row in parser_results:
        path = output / ("cli-" + row["edition"] + ("-compile.log" if row["compile_exit_status"] else ".log"))
        print(path.read_text())
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
