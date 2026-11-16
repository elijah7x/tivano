# Token river

Feature spec for the token usage page in Tivano 3.0 preview. Data ownership, refresh, storage and motion rules are settled. The chosen hero is the watershed Tint variant in `v3-watershed.html`, with a time strip and brush; `v1-directions.html` preserves the earlier candidates. Source references describe the preview layout at the time of this spec.

## Goal and non-goals

Show how token usage changes over time, which tools and models account for it, and when the data was last fetched. The hero is a picture of real usage; exact totals remain readable without animation or pointer interaction.

Tivano reads data already collected by an external tracker. It does not parse CLI logs, install collection hooks, collect tokens itself, reconcile subscription bills, or attribute external usage to Tivano threads. Context occupancy, provider limits and remaining credits keep their existing meanings.

## Data source contract and states

v1 supports [TokenTracker](https://github.com/xiufengsun/TokenTracker) through its
local HTTP server at `127.0.0.1:7680`, reading
`GET /functions/tokentracker-usage-model-breakdown` once per day (measured below).

Tokscale is the planned second source; `tokscale models --json ...` is the interface to investigate later, not an executable path in v1. Exactly one source is active. Never add sources together: they read the same CLI logs. Source changes replace the active dataset after a successful refresh; they never append to it.

Tivano detects external tools but never launches or installs them, starts their servers, or runs `npx`. A closed port alone does not prove a tool is not installed. Keep detection evidence separate from server reachability.

| State | Page behavior |
|---|---|
| Source not installed | Explain that TokenTracker is required; link to its setup instructions. No installer or shell execution in Tivano. |
| Installed, server not running | Explain: open the installed TokenTracker app yourself, or run `tokentracker` in Terminal if its CLI is installed; leave it running, then press Refresh. Link to TokenTracker's instructions. Tivano does not perform that action. |
| Fetching | Show progress and disable duplicate Refresh actions. A previous snapshot may remain visible with its original source, range and update time. |
| Success | Show the validated snapshot, source name and `Updated <relative time>`. Warnings remain visible beside the affected totals. |
| Schema changed | Say which required fields could not be read. Do not substitute zero, guess mappings or publish a partially decoded snapshot. Keep any previous snapshot explicitly labelled as saved data. |
| Empty range | Show “No token usage in this range” for a successful, complete empty response, with range, scope, source and update time. Offer another range and Refresh. |

Other HTTP failures and timeouts show a retryable error without becoming an empty range or changing `fetchedAt`. Server reachability is not proof of a compatible schema. Detection and field rules follow the request plan below.

### Request plan

Measured on 2026-11-08 against the installed TokenTracker 1.4.4 (app and embedded server; upstream main is 1.5.15). All reads are GETs over existing collected data; none triggers TokenTracker's own sync.

No endpoint returns day × tool × model in one response. `usage-daily` has days with model totals but no tool; `usage-model-breakdown` has tool × model with every token category and cost but no days. Neither parses a `source` filter. Both accept a single day (`from=to=D`, inclusive), and their single-day token totals agree. The plan is therefore one breakdown call per day:

```text
GET http://127.0.0.1:7680/functions/tokentracker-usage-model-breakdown
    ?from=D&to=D&tz=<IANA zone>[&scope=personal]
```

| Range | Calls | Serial estimate (≈15 ms per call) |
|---|---:|---:|
| 7 days | 7 | 0.1 s |
| 30 days | 30 | 0.4 s |
| 90 days | 90 | 1.3 s |
| 12 months | 365 | 5.4 s |

Estimates extrapolate one measured call. Each refresh fetches the most recent 365 calendar days, regardless of the displayed range, with progress shown while the calls complete. Range selection and the time-strip brush operate locally on that snapshot. The calls are not an atomic snapshot: TokenTracker may sync or reprice between them.

Field mapping, where `s` is `sources[]` and `m` is `s.models[]`; validate that the response's `from` and `to` equal the requested day:

| Snapshot field | TokenTracker field | Notes |
|---|---|---|
| day | requested day | Not present in model entries |
| tool | `s.source` | Keep `s.source_scope` for the scope explanation |
| model | `m.model_id`, falling back to `m.model` | Opaque string |
| inputTokens | `m.totals.input_tokens` | Already excludes cached input |
| cachedInputTokens | `m.totals.cached_input_tokens` | Do not subtract again |
| cacheWriteTokens | `m.totals.cache_creation_input_tokens` | |
| outputTokens | `m.totals.output_tokens` | Whether it includes reasoning depends on the tool |
| reasoningTokens | `m.totals.reasoning_output_tokens` | Subset of output for codex, acode, every-code, omo, cline and muse in 1.4.4 |
| totalTokens | `m.totals.total_tokens` | Authoritative; never recompute from categories |
| costUSD | `m.totals.total_cost_usd` | JSON string with six decimals; decode as Decimal |

Keep `m.pricing.status` and `m.cost_source`: an `unpriced` model's zero cost becomes `nil`. Use the server's per-model cost; its base rates cannot reproduce long-context or priority pricing from aggregates. The response field `days` is always 0 and carries no meaning.

Detection: there is no version or health GET without the local auth token, which Tivano must not read. The first breakdown call is the probe: HTTP 200 plus the expected structure means available; `NSURLErrorCannotConnectToHost` means the server is not running; a missing required field is a schema change. Installation can be detected from `/Applications/TokenTracker.app` and its `CFBundleShortVersionString`, which also fills `source.version`.

`personal` and `all` are source scopes, not Tivano account or project filters. Without `scope`, TokenTracker returns `all`. `scope=personal` excludes account-level sources (`cursor`, `trae-cn` in 1.4.4) fetched from the cloud; `all` includes the source's broader coverage. Explain that difference alongside the scope picker and retain it in the snapshot.

## Snapshot model

`TokenUsageSnapshot` is a `Codable` model in Core, with `schemaVersion: 1`. The source adapter and cache I/O belong in Services; page composition and state belong in `App/Views/Usage`. Core has no dependency on providers, settings or views.

```text
TokenUsageSnapshot {
  schemaVersion: 1
  source: {
    id: String
    displayName: String
    version: String?
    fetchedFrom: String
  }
  fetchedAt: Date
  range: { from: "YYYY-MM-DD", to: "YYYY-MM-DD", timeZone: String }
  scope: personal | all
  rows: [{
    day: "YYYY-MM-DD"
    tool: String
    model: String
    inputTokens: Int64
    cachedInputTokens: Int64
    cacheWriteTokens: Int64
    outputTokens: Int64
    reasoningTokens: Int64
    totalTokens: Int64
    costUSD: Decimal?
  }]
  warnings: [String]
}
```

Dates describe inclusive calendar days in `range.timeZone`; the adapter translates the source's confirmed boundary convention. `fetchedAt` is an absolute timestamp for the completed fetch, not a promise that the tracker's own collection is current. `fetchedFrom` records the local source origin. Keep tool/model identifiers stable and untranslated. Rows represent one day/tool/model combination without duplicates.

Token counts must be nonnegative integers. Preserve the source's confirmed total; do not add cached or reasoning tokens again when they are already included in input/output totals. Missing required counts are a schema error. Validate the whole snapshot before exposing it to views or replacing the cache.

Cost is an **API-equivalent estimate from the source**, not a bill. Tivano does not price models itself. A missing price is `nil` and displays “Unpriced”, never `$0`. When only some rows are priced, label the aggregate as a partial estimate and show the unpriced coverage; do not present it as the range's complete cost.

## Refresh and storage

- Refresh is manual. No polling, file watching, scheduled sync or background timers.
  The full page may fetch once on opening if no snapshot exists; opening the
  composer popover does not fetch token history. Each refresh fetches 365 days.
- Range and scope changes never start requests. A covered range can be derived
  locally from the same snapshot and scope. Otherwise show that Refresh is needed;
  do not relabel old rows as the newly selected range or scope.
- One refresh owns one source/range/scope request. Ignore superseded results; a
  result for old selections cannot replace the current selection's data.
- Commit a complete valid result together. A failed request or decode keeps the
  previous cache and timestamp; a valid empty result is a successful snapshot.
- Display source name, scope, dates and `Updated <relative time>` with saved data.
  Recompute relative text on presentation and user-driven updates; it needs no
  dedicated repeating timer. Expose the absolute fetch time in accessible detail.
- Store `token-usage/snapshot.json` below `StoragePaths.root`, using an atomic write.
  That root already resolves the edition's Application Support directory and the
  isolated capture override (`Tivano/Core/Support/StoragePaths.swift:6`). Preview,
  Dev and Release never share or import each other's snapshot.
- This is a rebuildable cache, not a ledger. An unreadable or unsupported snapshot
  shows a refresh-needed state, not fabricated history. Report write failures;
  a result available only in memory must not be described as saved.

The existing `UsagePanel.onAppear` refreshes provider limits and credits (`Tivano/App/Views/Usage/UsagePanel.swift:67`). It must not become a token-history refresh hook. Those provider requests are separate from this feature's contract.

## Page layout and entry points

### Main page

“Tokens” is the third app space in the 3.0 module rail, after Threads and Teru.
It uses the existing `ModuleRailEntry`, the `chart.bar.xaxis` symbol and the same
selection animation (`Tivano/App/Views/Layout/ModuleRailView.swift`).

`AppModel` owns one `TokenUsageModel`. `TokenUsagePage` is mounted alongside
`TeruSpaceView` and the session trays in `PrototypeLayoutView`'s ZStack, using
the same opacity, hit-testing and accessibility gates. It fills the main area
while the rail remains visible; the session sidebar belongs to the hidden
session space. This is a peer app space, not a Voice-style overlay.

Keep the underlying chat, draft and runtime mounted. Selecting Threads returns
to chat, and a change to a non-nil selected thread also returns from Tokens to
the session space. The page receives an explicit `isActive` flag so hidden
content can pause. While Voice is open, Tokens cannot receive input or
accessibility focus; changing spaces does not end an ongoing call. Settings may
cover the page and must pause it.

Page order:

1. Title, source name, update time and Refresh.
2. `GlassPickerButton` controls for 7 / 30 / 90 days / 12 months and Personal / All
   scope, defaulting to 30 days, with the selected date span and time zone readable.
3. The watershed Tint hero from `v3-watershed.html`, showing the selected range's
   token distribution with total tokens and a tool/model legend. A time strip and
   brush select the visible range from the fetched 365 days. Empty and error
   states occupy this same region.
4. Exact tool/model totals and the selected day's token categories in
   `ChromeSection`, `ChromeCard` and `ChromeRow`. A `SettingsSwitch` controls “Show
   estimated cost”; it is on by default, with cost labelled as an estimate.

Use existing Chrome typography, spacing and surfaces. Tool colors come from the theme accent family; labels and hatching distinguish series without color alone. No new palette, fonts or custom picker/switch styles. At narrow widths, controls wrap and detail sections stack without clipping dates or exact values.

Every new user-facing string, including state messages, hover text, warnings and accessibility templates, gets a zh-Hans entry in `Localizable.xcstrings`. Follow `docs/i18n/CONVENTIONS.md`; localize complete templates, keeping source/tool/model names and identifiers as values.

### Settings and setup

Settings › Token usage appears after Providers. Its Data source section explains
that TokenTracker is an external, open-source app and that Tivano reads its
existing local history. It re-detects installation on appear, shows the installed
version when available, and reports the shared model's last refresh time or
“Never”. A failed refresh because the local server is not running asks the user
to open TokenTracker, then refresh. A link opens TokenTracker's GitHub project.

“Set up with an AI” is expanded when TokenTracker is absent and remains available
through a disclosure when installed. It presents a selectable, monospaced prompt
inside a ChromeCard. “Copy prompt” copies that same localized text and briefly
becomes “Copied”. The prompt asks the user's AI coding agent to read the upstream
README, install the recommended macOS app into `/Applications`, open it for its
first scan, and confirm the local usage-summary endpoint returns JSON. It forbids
enabling cloud sync, signing in or changing other settings. Tivano only displays
and copies the prompt; it never executes commands, installs or launches anything.
The prompt is one localization key; translations preserve its URL, commands and
app names.

### Composer summary — second batch

The “Today” token line and “View token usage” action in `UsagePanel` are deferred
to a second batch. When added, keep them separated
from its context, limits and credits sections (`Tivano/App/Views/Usage/UsagePanel.swift:30`).
The existing context ring opens that panel
(`Tivano/App/Views/Composer/ComposerView.swift:832`); its eligibility depends on
context/limits/credits (`ComposerView.swift:808`), so the rail remains the reliable
entry even when no ring is available.

Today means the current calendar day in the snapshot's time zone, across the
active source and scope, not this chat or its provider. Show that scope, source and
update time. If the snapshot does not cover today, show that a refresh is needed;
yesterday's last row is not today's usage. The action dismisses the popover and
opens the full page. Keep plan limits and balances in `UsageViews.swift:7` and
`UsageViews.swift:127` separate from historical token totals and estimated cost.

## Visualization contract

All directions consume the same validated rows, range, time zone, scope and selection. Aggregate once per data/selection change; the drawing receives prepared daily series and tool/model totals. Source failures are never encoded as zero. Only a confirmed complete range permits absent activity days to appear as zero.

| Direction | Encoding |
|---|---|
| A — River | Streamgraph with one tributary per tool; band width at each day equals that tool's daily tokens. Hand-drawn lines and hatching follow the sidebar hero. |
| B — Clouds | Model cloud masses with area proportional to tokens in the selected range or day. A linked daily selector keeps time inspectable. Tool contribution remains available in detail. |
| C — Ticks | Daily scale ticks whose height encodes daily tokens; they rise on arrival like HydraProgressBar. Tool/model contributions appear in the selected day's detail. |

The table preserves the earlier candidates. The selected direction is the
watershed Tint variant in `v3-watershed.html`, paired with a time strip and brush.
It needs a labelled scale or size key and exact totals; decorative drift must not
alter the encoded quantity. Hover a watershed region or day for exact date,
tool/model, token categories, total and estimated cost. Day and series selections
remain available through keyboard-accessible controls and rows; no information
is hover-only.

Give the hero an accessibility summary naming range, source, scope and total tokens. Expose daily and tool/model totals as readable elements, with category labels and unpriced warnings. Decorative strokes are hidden from accessibility. The static frame and detail rows convey everything the animated version does.

## Motion and performance budget

- On appear and after a successful refresh, let data flow into place over roughly
  1–2 seconds. Do not replay on hover, ordinary redraw, theme change or resize.
  Hydra's arrival-only tick rise is the reference
  (`Tivano/App/Views/Chat/HydraProgressBar.swift:777`), not its recurring work sweep.
- At rest, remain static or use a very slow idle drift. Use `TimelineView` + `Canvas`
  for animated drawing, capped at 30 fps; pause the timeline completely when idle
  motion is absent. Animation scheduling never triggers data fetching.
- Pause when hidden, covered by Voice/Settings, outside the visible page, window
  occluded or minimized, or app inactive. Reuse HeroWeather's explicit content
  visibility propagation (`Tivano/UI/Common/HeroWeatherView.swift:21`, `:847`),
  window observation (`:630`) and static-frame fallback (`:621`). A mounted view
  with zero opacity is not visible. Add an explicit app-active gate: HeroWeather's
  current `canAnimate` (`:595`) checks hidden state, not application activity.
- Reduce Motion and Tivano performance mode always show the final static frame.
  Retain HeroWeather's low-power and serious/critical thermal suppression. Resume
  without replaying arrivals or accumulating hidden animation work.
- Precompute aggregation, paths and hatching outside frame callbacks. Keep decoding
  and cache I/O off the drawing path; a frame changes drawing phase only, without
  rebuilding the page, hitting the network or writing storage.

## Settled choices

- Hero: watershed Tint (`v3-watershed.html`), with a time strip and brush.
- Initial visible range: 30 days; each refresh fetches 365 days.
- Estimated cost: shown by default and explicitly labelled as an estimate.
