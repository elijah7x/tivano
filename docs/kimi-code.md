# Kimi Code provider

Tivano runs the official `kimi acp` CLI over its existing ACP transport. This is the native Kimi Code agent, not a direct model-API integration or a Claude Code wrapper.

## Setup

Install the current [official Kimi Code CLI](https://moonshotai.github.io/kimi-code/en/guides/getting-started), then run `kimi login` in a terminal. Select Kimi Code in Settings → Providers. Tivano discovers `kimi` on the login PATH and common user installation paths; a custom executable path can override discovery.

Credentials and refresh remain owned by the CLI. ACP `authenticate` only validates existing credentials, so an authentication failure points the user back to `kimi login` rather than attempting an interactive login over stdio. Models, reasoning levels and commands come from the CLI, not a hard-coded catalog.

## Modes and questions

- Supervised → `default`.
- Auto-accept edits → `default`, with Tivano approving only calls identified as edits by ACP tool events.
- Auto → `auto`.
- Full access → `yolo`.
- Plan → `plan`; the next Build turn restores the selected permission mode.

Kimi's native form elicitation maps to Tivano's question UI, including multiple questions and multiple selections. Skip and turn cancellation resolve the reverse RPC as cancelled. The fallback permission-based question bridge and plan-choice requests never enter Tivano's automatic tool-approval path.

Model/mode configuration errors propagate instead of optimistically updating local selection state. Resume uses `session/load` and suppresses the replayed history because Tivano already owns its visible transcript.

Rewind and subscription-limit reporting are not exposed. `/compact` is forwarded as a CLI command rather than invoking a separate Tivano compaction method.

## Icon provenance

`Tivano/Resources/Assets.xcassets/provider-kimi.imageset/` uses the official “K Only” SVGs from the [Kimi Brand Guidelines](https://moonshotai.github.io/Branding-Guide/): [light](https://moonshotai.github.io/Branding-Guide/scenarios/04-k-only/k-only-light.svg) and [dark](https://moonshotai.github.io/Branding-Guide/scenarios/04-k-only/k-only-dark.svg). Both source files are unmodified, use a transparent background, retain the blue accent, and contain vector paths rather than embedded raster images. The asset catalog preserves vector representation and renders the mark in its original colors; enabled/hidden opacity follows the shared provider controls. `ProviderIcon` scales Kimi's artwork to 92% inside the unchanged icon slot for optical balance. These replace the original 48×48 favicon; converting that favicon to PNG did not restore its resolution.

## Verification

Verified against Kimi Code CLI **0.39.1**:

- Debug build and Developer ID-signed Dev package.
- Live authentication, catalog discovery and all four native modes.
- Actual `ACPSession` + stdio transport: streamed reply with native file reading, process restart, restored context and suppressed replay. Temporary probe sessions were deleted.
- Actual adapter with an in-memory RPC fixture: question/plan auto-approval guards, multi-question/multi-select response encoding, Skip, interrupt cancellation, edit-only approvals and retry after rejected configuration.
- Installed Dev UI: authentication-status and model-catalog presentation; private account contents are omitted.
- SVG icon revision: successful Debug build; native rendering from the compiled asset catalog at 14, 22 and 96 pt, in both light and dark appearances. The SVG revision was installed and visually checked in Dev.
- Optical/state alignment: successful Debug build; offscreen rendering of `ProviderIcon` in the shared `ChromeVisualTile`, comparing enabled and hidden Kimi, Codex and Grok in light and dark appearances. Installed Dev's provider selection popover was also visually checked after the owner-requested relaunch.

Image prompts and MCP forwarding reuse the existing ACP paths and declared CLI capabilities; end-to-end image/MCP and expired-token refresh have not been exercised in this verification.

Protocol reference: [official ACP documentation](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-acp), supplemented by the installed version's `acp-server` implementation.
