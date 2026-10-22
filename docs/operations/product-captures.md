# Product captures

`scripts/product_captures.py` builds an isolated Debug app, captures the existing product scenes and writes resized PNGs. Run it only when the owner explicitly authorizes launching a capture instance. A request to edit, merge, build or validate code does not authorize captures or an app launch.

## Output location

Each invocation reserves a new directory before building or launching anything:

```text
<artifact-root>/private-artifacts/product-captures/<run-id>/
```

The run ID contains a UTC timestamp, process ID and random suffix. Raw PNGs, JSON framing sidecars and `run.log` live in that directory; resized PNGs go in its `processed/` subdirectory. Printed output paths are absolute.

By default, the script obtains the shared Git directory with:

```sh
git -C <checkout> rev-parse --path-format=absolute --git-common-dir
```

The parent of that shared `.git` directory is the long-lived source checkout; its parent is the artifact root (the wrapper containing the checkout). This also works from a linked worktree: the artifact root is not derived from the worktree's parent, so captures do not accumulate under `.tivano/worktrees`.

Build products remain local to the current checkout/worktree in `build.noindex/product-captures-build`. The Debug app path and capture scenes, isolated app storage/defaults, app arguments and timeout behavior are unchanged. Production libraries and credentials must not be imported into the capture instance.

## Choosing another location

Set `TIVANO_ARTIFACTS_ROOT` to an absolute wrapper path to change the default artifact root. Relative values, including an empty value, are rejected. Both the configured root and the final output location must be outside the current worktree and the long-lived source checkout; checks resolve symlinks as well as checking the supplied path.

Alternatively, use `--output-dir <new-directory>` to select the exact run directory. Relative arguments are interpreted from the working directory. The environment root, if set, must still satisfy its contract. The selected directory must not already exist, even if empty; an existing file, symlink or dangling symlink is also rejected. Parent directories may already exist and missing parents are created as needed.

Path rejection happens before any build or app launch. The final directory is created without `exist_ok`, so two runs selecting the same directory cannot both proceed. A collision is an error, not an instruction to reuse or clear it. Importing the module does not select output paths, create directories, build or launch an app.

## Existing archives

The script never clears a previous capture directory or the shared archive root. Completed and failed runs remain available for deliberate review or separately authorized cleanup. The old `build.noindex/product-captures` location, including any compatibility symlink left by migration, is not reused. Passing that historical symlink as `--output-dir` is an error; choose a fresh external directory instead.
