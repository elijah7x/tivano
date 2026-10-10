# Domestic update mirror

## Endpoints and ownership

- Feed: `https://elijah.ac.cn/tivano/updates.json`
- Installer: `https://elijah.ac.cn/tivano/releases/vX.Y.Z/Tivano-X.Y.Z.dmg`
- Web root: `/var/www/tivano`, owned by `tivano-publisher`; Nginx only reads it.
- Server receiver: `/usr/local/libexec/tivano-publish-mirror.py`, owned by root.
- Publisher key lives on Hephaestus at `~/.ssh/tivano_mirror_ed25519`.
  Its `tivano-mirror` SSH alias selects the unprivileged publishing account.
  Never copy this private key to another machine or store it in the repository.
- The authorized key is restricted to the receiver: no remote shell, PTY,
  forwarding or arbitrary upload paths. SSH and the existing gateway were not changed.

## Publishing

After the notarized DMG and canonical GitHub feed are published, `publish_release.sh`
creates a canonical feed from that exact release and syncs the mirror. It does not
wait for the asynchronous Pages deployment. No GitHub token is sent to the mirror.
Direct publication uses `tivano-mirror`; machines without that alias route through
`hephaestus`. Override with `TIVANO_MIRROR_HOST` and `TIVANO_MIRROR_VIA` if needed.
Do not pretend a missing SSH route is a successful mirror publication.

A mirror failure occurs **after** the GitHub release is public. Retry only the
mirror command, never recreate or delete the release:

```sh
# On Hephaestus:
python3 scripts/publish_update_mirror.py --host tivano-mirror \
  --dmg /path/to/Tivano-X.Y.Z.dmg --feed /path/to/canonical-updates.json

# From Artemis, using Hephaestus's identity without transferring its key:
python3 scripts/publish_update_mirror.py --via hephaestus --host tivano-mirror \
  --dmg /path/to/Tivano-X.Y.Z.dmg --feed /path/to/canonical-updates.json
```

Without `--feed`, the command reads the public Pages feed; confirm that Pages
already contains the intended release. The receiver validates size, SHA256, tag,
name and canonical asset URL, rejects older feeds and replacement of an existing
installer with different bytes, and serializes publication. Installer bytes are
written and synced before the feed is atomically replaced. Input is capped at
64 MiB including base64 encoding. Larger future installers need a reviewed
streaming publication change, not removal of input limits.

## Nginx configuration and abuse limits

- `scripts/deploy/aliyun/tivano-zones.conf` -> `/etc/nginx/conf.d/00-tivano-zones.conf`
  (must precede the main vhost: log formats are resolved when parsing locations).
- `scripts/deploy/aliyun/tivano-locations.conf` -> `/etc/nginx/snippets/tivano-locations.conf`
- One include in the existing `elijah.ac.cn` HTTPS server; root page, ACME,
  preview and Sub2API routes remain unchanged.
- Strict routes, no directory listing or SPA fallback; unknown files return 404.
- Feed and installers accept GET/HEAD only. Other methods return 405.
- Per IP: 2 requests/s with burst 10; excess requests return 429.
- Installer: 4 concurrent requests per IP, 8 across the vhost; excess returns 429.
- Each installer request is limited from its first byte to 512 KiB/s; 8 slots give
  an approximately 4 MiB/s sustained payload budget. This is **not** a hard
  packet-level bandwidth cap: buffering, headers and rejected traffic add overhead.
  Shared-office IPs may hit the limit; the new client falls back to GitHub on
  download transport errors. Check actual traffic before changing thresholds.
- Range downloads are supported, limited to one range per request.
- Feed requires cache revalidation; immutable, versioned DMGs cache for a year.
- Dedicated `/var/log/nginx/tivano-mirror.log` contains timestamps, status,
  bytes, duration and limit outcomes, not client IPs or request contents.
  The existing global logrotate timer was disabled. A dedicated
  `tivano-mirror-logrotate.timer` now checks only this log hourly, with daily
  rotation or earlier above 10 MiB, seven archives and compression. The old
  global timer/configuration was not changed. No new notification service
  has been commissioned.

Verified with Nginx 1.30.2. Reference:
https://nginx.org/en/docs/http/ngx_http_limit_conn_module.html
https://nginx.org/en/docs/http/ngx_http_limit_req_module.html
https://nginx.org/en/docs/http/ngx_http_core_module.html#limit_rate
HTTP/2 concurrent requests count separately for connection limits.

## Emergency disable and rollback

A root operator can disable both feed and new downloads without a reload:

```sh
touch /var/www/tivano/.disabled  # endpoints return 503; clients use fallback
rm /var/www/tivano/.disabled    # resume
```

This does not stop downloads already in progress or mitigate upstream DDoS.
The marker is deliberately not accessible through HTTP.

`install.sh` backs up affected Nginx files in `/var/backups/tivano-mirror/<UTC time>`
and restores them on configuration/reload failure. The first successful installation's
backup is `/var/backups/tivano-mirror/20261010T072413Z`; it contains the original
main vhost before the mirror include. Before rollback, compare any later operator
changes; remove only the mirror include if restoring the whole backup would
clobber unrelated work. Remove the mirror-only zones/snippet, run `nginx -t`,
then reload Nginx. Disable
`tivano-mirror-logrotate.timer` if removing the mirror permanently. Preserve
installer bytes, publisher identity and backups until the removal is verified.
Never roll back by overwriting the feed with an older release.

## Security and client rollout boundaries

The existing plan is unlimited traffic with 200 Mbps **peak**, not guaranteed
throughput. Basic DDoS protection is enabled; the observed cleaning triggers are
200 Mbps / 200K pps, not the maximum mitigation capacity. Nginx cannot prevent
upstream link saturation. The cloud firewall permits only TCP 22/80/443 and ICMP;
5355 has not been opened. Do not change SSH allowlists without preserving a
verified administration path.

Clients before this change do not discover the mirror. The new client requests
mirror, Pages and raw feeds concurrently with a two-second whole-resource deadline
per request. It chooses the highest successfully observed version; for the same
version it chooses the first responding valid feed. Feed latency is not a throughput
benchmark for its installer. A slow/unreachable source outside the window is still
unknown, so the UI says no newer update was found, not that this is globally latest.
All static sources failing, or being older than a known cached version, triggers
API fallback. Cached versions never downgrade or lose known integrity metadata.
Conflicting hashes/sizes for the highest observed version fail closed.

The installer accepts exact canonical GitHub or mirror paths from static feeds;
transport failures (including 429 and idle timeout) retry the other trusted origin
once, in either direction, only with a known checksum. The download idle deadline
is eight seconds; active transfers can take longer, up to the resource limit.
GitHub's HTTPS asset CDN redirects are allowed; foreign hosts, HTTP downgrade and
nonstandard ports are rejected. The mirror has no legitimate redirects. Cancellation
terminates the URLSession task, settles its continuation once and removes its file.
A checksum or signature failure stays a hard failure. Developer ID, bundle identifier,
version and Gatekeeper checks remain in place. SHA256 from the same server is an
integrity check, not independent proof of publisher authenticity; server access
and signing credentials must remain separate.

Server deployment does not authorize a client release, local integration into dev,
push, installation or relaunch. Build verification is not a real cross-version
update acceptance test.

## Deployment verification — 2026-10-10

- Published v1.0.3 through the forced-command publisher account. DMG: 6,348,243
  bytes; SHA256 `cdab001beb764b972d99e4db4df9e73c639d118d56eaef194462da829b793749`.
- Public JSON returned 200/application-json; full DMG download matched the
  canonical size/hash; a 32-byte Range request returned 206 and matching bytes.
- Unknown paths, a directory request and the private lock path returned 404;
  POST to the feed returned 405.
- A bounded five-request download check returned four 200 and one 429.
  A bounded sixteen-request feed burst returned eleven 200 and five 429.
  No high-volume load or DDoS test was performed; the eight-slot global limit
  was initially checked against the loaded configuration. Subsequent bounded
  verification used 12 simultaneous requests from three machines: eight were
  accepted and four rejected; error-log aggregation confirmed the four global
  `tivano_downloads` rejections.
- Disable marker made the feed and installer return 503 while the homepage
  remained 200; removing it restored the feed.
- Existing homepage stayed 200, gateway models endpoint 401 without an API key,
  and gateway root 404. Nginx configuration passed.
- An attempted remote shell command with the publishing key was forced into
  JSON validation instead of executing the shell command.
- Receiver checks covered valid/idempotent publication and rejection of a bad
  digest, traversal tag and foreign source. Release hook mock checks covered
  direct publication, relay selection, explicit relay and sync failure reporting.
- Mirror-only rotation timer is active; its oneshot service completed successfully.
- Client Debug build succeeded using the repository's existing
  `-skipPackagePluginValidation` build convention. The initial plain build was
  blocked by SwiftTerm's plugin trust validation, not a source compilation error.
- Client changes and release automation are task-worktree changes only. No dev
  integration, push, release, application installation/relaunch or real GUI
  cross-version update test was performed. Future full relay publication from
  Artemis has not been completed end-to-end; initial successful publication ran
  directly on Hephaestus.

### Initial client regression: failed (subsequently repaired below)

A standalone Swift harness extracted the actual current feed selection, parser,
Downloader and transport fallback code and used localhost HTTP fixtures.
18 of 21 cases passed. Three failed: a stale mirror masks a newer GitHub release,
a slow mirror delays a fast GitHub source because requests are sequential, and
cancelling a caller task does not cancel its URLSession download. The real
8-second request timeout fell back successfully, but still imposes that delay.

These findings blocked the original sequential source-selection policy.
No production source repair was made in that initial verification turn;
the subsequent authorized repairs are recorded below.
UI, persisted state, notification behavior, production API credentials and real
installation/Gatekeeper remain untested.

Evidence outside Git: `private-artifacts/update-regression-20261010/REPORT.md`
in the Tivano wrapper directory, with case results and the reproduction harness.
The bounded live workload preserved homepage 200 and unauthenticated gateway 401;
it is not an authenticated inference benchmark or DDoS resilience test.

### Authorized client repairs and post-fix regression

The subsequent repair replaced the failed sequential policy and added cancellation
handling. 59 component scenarios passed using extracted actual production code,
including the check controller with MainActor isolation and the Core ISO8601 parser.
A separate 120-iteration cancellation stress case passed without leaked files or
continuation errors. Real repaired-Downloader transfers from both public origins
matched the original 6,348,243-byte installer and SHA256; the GitHub asset-CDN
redirect was accepted. Debug build and six zh-Hans entries were validated.

The response-comparison contract is now explicitly bounded at two seconds. It waits
for a slower newer source within the window instead of promising an immediate
first-response result. The original provisional 200 ms assertion was replaced by
that contract and measured concurrent request-start timing. An unresponsive source
is not claimed current. This fixes the three demonstrated defects without claiming
the entire UI/install lifecycle has been accepted.

Evidence: `private-artifacts/update-regression-fixed-20261010/REPORT.md` in the
Tivano wrapper directory. Real preferences/notifications, native rendering,
Gatekeeper-enabled installation, replacement failure and restart remain untested.
No merge into dev, public release, installation or application launch occurred.
