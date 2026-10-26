# Remote MCP (Alpha)

Remote MCP lets a cloud agent (Meta Muse, xAI Grok Bot, a Claude connector, any
MCP client with OAuth) drive this running edition of Tivano. It exposes the
[local-control](local-control.md) commands as MCP tools over Streamable HTTP. It is
off by default: Settings → Alpha → Remote MCP needs both Alpha and its own switch.

## Shape

- Tivano listens on `127.0.0.1:<port>` only. The port is picked once and saved
  (`remoteMCPPort`), so a tunnel's target stays put. Tivano never opens a public
  port and does not run a tunnel itself.
- The owner runs a tunnel (Cloudflare named tunnel, Tailscale Funnel, …) from a stable
  HTTPS address to that port and enters the address as **Public address**. Cloud
  agents connect from their own servers, so loopback alone only serves clients on
  this Mac. A quick tunnel whose address changes on each run invalidates every
  access token, because tokens are bound to the resource URL.
- The MCP endpoint is `<public address>/mcp`. Tivano is its own OAuth 2.1
  authorization server under the same address (MCP authorization spec: RFC 9728
  resource metadata, RFC 8414 server metadata, dynamic registration, client ID
  metadata documents, PKCE S256 only, `resource` binding, `iss` in the response).
- Every request runs through `AppControlService.handle(_:source: .remote)`: the same
  validation, ledger, tickets and limits as the CLI. Remote requests never reach
  settings writes.

Code: `Core/Models/RemoteMCP.swift` (shared types), `Services/RemoteMCP/`
(HTTP server, authority, endpoint, router, browser pages), `App/Control/RemoteMCPService.swift`
(lifecycle), `App/Control/RemoteMCPSettings.swift` and the approval alert in `RootView`.

## Connecting an agent

1. Turn on Remote MCP, enter the public address, and copy **Server URL** into the
   agent's custom connector or MCP settings.
2. The agent registers itself and opens Tivano's authorize page in the browser. That
   page only waits: it shows a code and refreshes itself.
3. Tivano shows an alert with the client's name, the same code and the host it returns
   to. Check the code, then choose **Allow full control**, **Allow read only** or
   **Deny**. Nothing on the web page can approve.
4. Connected agents are listed under Remote MCP with their scope and last use;
   **Disconnect** revokes the grant and its tokens at once.

Scopes: `tivano.read` (info, providers, projects, threads, history, operations) and
`tivano.write` (create_thread, send_message, interrupt_turn). A read-only grant does
not list write tools, and calls to them fail.

## Tools

`tivano_info`, `list_providers`, `list_projects`, `list_threads`, `get_thread`,
`get_history`, `get_operation`, `create_thread`, `send_message`, `interrupt_turn`.
Write tools mint their ticket at call time and return it as the string
`get_operation` accepts. All local-control semantics apply: new threads are
supervised (unless the full-access setting below is on) with Hydra off, approvals and questions wait in the App, and "completed"
is the provider's report, not proof that the task is correct. Failures are tool
results with `isError` and the control failure code.

## Security model

- Opening the gate makes Tivano reachable from wherever the tunnel is reachable. The
  protection is OAuth plus owner approval in the App, not network position. Leave it
  off when not in use.
- Approvals for tool use inside threads still require the owner in Tivano. A cloud
  agent can see `waitingForUI` but cannot approve, answer, log in or change settings.
- **Run remote threads without approval** (default off, `remoteMCPFullAccess`) makes
  threads that Remote MCP creates while it is on start in Full access, so commands and
  file changes run without asking. It never changes existing threads, threads created
  while it was off, or the owner's own threads, and agents still cannot change a
  thread's permissions. Questions still wait in Tivano. Pair it with worktree threads
  when the agent should not touch the project checkout directly.
- Host must be the public host or loopback; a foreign `Origin` is refused (DNS
  rebinding). Requests are one per connection, with head/body/time/connection limits.
- Only SHA-256 hashes of refresh tokens are persisted, owner-only, in
  `<library>/remote-mcp.json`. Access tokens (1 hour) and authorization codes (60 s,
  single use, consumed by any attempt) live in memory, so a restart makes clients refresh.
  Refresh tokens rotate on use and expire after 30 days.
- Client metadata documents are fetched over HTTPS only, with no redirects, a 5 s and
  64 KiB bound, and refused for loopback, private, link-local and `.local` hosts.
- Anyone who can reach the address can start an authorization, so up to four
  requests can wait at once and each raises an alert in Tivano. Deny anything you did
  not start; the code tells your request from someone else's.

## Validation so far

- Debug build of the App succeeds.
- A standalone harness compiled the real `Core/Models/RemoteMCP.swift`,
  `LocalControl.swift`, `JSONValue.swift` and `Services/RemoteMCP/*` against a fake
  control closure. It covered metadata, 401 discovery, registration, PKCE failure and
  single use, approval through the pending page, token exchange, initialize, tools/list,
  tools/call, read-only scope, Host and Origin refusal, refresh rotation, revocation
  and no raw tokens on disk. The App wiring, settings UI, approval alert and real agents
  (Muse, Grok Bot) through a real tunnel are not yet verified.
