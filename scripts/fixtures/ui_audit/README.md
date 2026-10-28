# Isolated UI audit harness

Run from the checkout after integrating Walter's UI changes and Hank's runtime changes:

```sh
python3 scripts/ui_audit_checks.py
python3 scripts/ui_audit_checks.py --render /tmp/tivano-ui-audit-render-20261028-01
```

Use a new external directory for each render run. Requires macOS 26, Xcode's Swift
6.2+ toolchain and a logged-in graphical session. The second command runs the same
checks, then opens only standalone fixture windows and writes eight PNGs plus
`render-index.json`, generated Swift source, source hashes and logs. Inspect every
PNG against its manifest expectation; artifact creation is not visual acceptance.

The head prepared these files without running compilation, checks or captures.

## Implementations exercised

- Real `AttachmentFileVersion`, `ThumbnailCache` and `ThumbnailMemory`: same path,
  identical file length and pixel dimensions; in-place overwrite; atomic replacement
  retaining mtime/size; deletion; corrupt content; repair; overwrite/deletion after
  decoding but before publication. BMP fixtures and all paths are newly generated.
- Real `StreamingParseCoordinator` and `MarkdownParser`: a deterministic held parse
  with repeated appends; intermediate results advance before the newest completes;
  generation replacement; shortening; a newer synchronous parse overtaking an older
  async parse in the same generation. Only scheduling gates are inserted in the
  generated copy; the real parser still executes.
- Real `FileIndex` rebuild, sharing, cancellation and directory-generation logic:
  timestamps aged through a generated same-file extension, no production TTL change;
  repeated queries do not scan again; directory A's late result cannot replace B;
  returning to A reuses the cache; cancelled queries publish nothing. Git detection is
  a fake returning false, so the actual filesystem fallback enumerates temporary data.
- Real `QuestionDraft`, runtime question-property observer, `questionDraft(for:)` and
  `answer`: reopen shares choices/text/page; submission disables editing while retaining the draft;
  late field binding writes and old-sheet submissions cannot revive a draft; failed
  delivery restores the same choices/text/page; interruption replaces retired drafts;
  successful delivery/removal/changed questions retire
  old drafts. The provider boundary is an in-memory recorder; no provider is called.
- Real `ToolImagePreview`, `QuestionSheet` and their dependent view declarations are
  rendered with production Chrome/theme/font tokens. The existing product Recorder
  depends on AppModel and ScreenCaptureKit; standalone AppKit view capture keeps this
  fixture independent of application initialization, user libraries and screen capture.

## Boundaries

No production interfaces are added for tests. Extraction fails loudly if an expected
declaration or instrumentation site moves; update the extraction for a refactor rather
than copying the old implementation. `Checks.swift` and `Render.swift` are only joined
into a temporary generated compilation unit by the Python driver, not app sources.

The runtime shell has no AppModel, persistence or real session. Turn cancellation,
provider event ordering and teardown still need full-app regression. This harness
does not test Git-backed file listing, real popover dismissal/placement, mouse/keyboard
delivery, shared Markdown cache eviction, video decode/playback, or end-to-end timing.

Thumbnail tracking now reads only on mount, path change and a hidden chat column
becoming visible. Continuously mounted visible thumbnails intentionally retain their
snapshot after external edits; opening a preview reads the current version. Only the
open large attachment preview polls every two seconds, and closing it releases its
hosting controller. Inline tool images also refresh on mounting/reopening, not a timer.
Available metadata is not a content hash: an overwrite preserving every observed
metadata field cannot be detected. Lifecycle and long-list timer counts need full-app
profiling; the deterministic cache checks do not measure them.

Localization handoff: add `Preview unavailable` → `无法预览` to the catalog;
`Retry` → `重试` already exists. Fixture-only English sample questions are not product
strings. Catalog integration and Chinese layout remain the lead's checks.
