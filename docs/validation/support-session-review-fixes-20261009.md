# Support session review fixes — 2026-10-09

## Version and behavior

- Source commits: `e5f718e` (shared broker session lock, Linux confirmed lease persistence, direct Linux creation), `f51a01e` (Windows stdin BOM), and `f67ba6b` (Windows credential ownership).
- Broker platform changes, claims, closes and GC serialize on the existing per-session `.claim.lock`. A platform update cannot restore the consumed grant or bind it to another key.
- Linux operator clients atomically persist confirmed lease deadlines with mode `0600`. Restarting the watcher during an outage preserves credentials until the saved deadline.
- New sessions return customer and operator commands from one Linux creation operation. Manager, bridge and broker reject new `pending` creation before allocating resources. Previously saved pending sessions retain the `set-platform` recovery path; connected sessions require no migration.
- Windows command transport preserves binary stdin when the host uses UTF-8 with a BOM. Framework initializes an AutoFlush stdin writer using `Console.InputEncoding`; the relay temporarily suppresses the preamble during process creation and restores the host encoding. See [Microsoft reference source](https://github.com/microsoft/referencesource/blob/main/System/services/monitoring/system/diagnosticts/Process.cs#L2153).
- Files written by the Windows operator normalize their ACL and owner to the current user, including when launched with an elevated token.

## Verification

- 100 Python support-session tests passed, including a coordinated platform-change/claim concurrency regression, watcher restart/outage regression and rejection of pending creation before allocation.
- Real isolated OpenSSH integration passed: certificate authentication, Edge proxy, cross-session and shell rejection, host key enforcement, native expiry and revocation.
- Astra independently rechecked locking, lease persistence and creation changes; its 20 portable-support tests passed.
- [Windows CI for f67ba6b](https://github.com/transinfosh/tsuite_deploy/actions/runs/37906324386) passed: PowerShell 5.1, real key generation and ACLs, raw native binary pipes, unchanged host encoding, saved client loading, cleanup and OpenSSH 8.1/9.8.3 authentication.
- Earlier Windows CI exposed three excess bytes in raw stdin; after the BOM correction it advanced to the credential-owner assertion. Both regressions pass in the final run. The raw pipe fixture uses a native executable instead of a PowerShell script host.
- `git diff --check`, installed Python compilation, control `nginx -t` and Edge `sshd -t` passed.

## Deployment

- Control: `adam@192.168.2.52`; Edge: `ubuntu@edge.trinfo.net`, reached through the control host's dedicated key with strict host key checking.
- Archive: `/srv/tsuite-deploy/releases/support-review-f67ba6b/source.tar.gz`.
- Archive SHA-256: `d7a6df347fd9085e582248f31cae3b26c44f2b207098267fa35cb1f045488303`.
- Control backup: `/var/backups/tsuite-support-console/20261009T084213Z-pre-f67ba6b/`. The `targets.txt` file maps the numbered original files to their runtime destinations.
- Edge backup: `/var/backups/tsuite-support-session/20261009T084248Z-pre-f67ba6b/` (`manager`, `bridge`).
- Installed console, broker, Linux operator, Windows operator/relay and Edge manager/bridge hashes match the source archive. The publicly downloaded operator bundles also match the released sources; the Linux bundle compiles, and both download responses specify `Cache-Control: no-store`.
- Control console, nginx, FRPC, GitHub egress and broker GC timer are active. Edge Caddy, FRPS and support GC timer are active. Broker bridge/forced-proxy self-test passed after both nodes were updated.
- Public checks: `/_tsuite-control-health` 200, `/support/` 401, `/support/operator-client` 200, `/support/operator-client.ps1` 200.
- Session inventory remained 79 ended records, zero unfinished sessions. No customer sessions were created, closed or changed. Console error journal after deployment contained no entries.

## Compatibility and limits

Old clients already downloaded to support machines are not remotely overwritten; new sessions download the repaired version. Existing connected customer sessions and session schema remain unchanged. Actual public-Edge Windows interactive ConPTY operation was not exercised in this release; Windows CI uses isolated native fixtures. Existing control-plane backup/restore, alerting and history-retention follow-ups remain as listed in the deployment runbook.
