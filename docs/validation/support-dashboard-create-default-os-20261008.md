# Support dashboard create form defaults operator OS

- Commit: `0f39149` (`Remove operator OS selector from session creation`)
- Scope: remove the support operator OS selector from the dashboard's new-session form. New sessions initialize to Linux; the command page retains the per-command OS switcher.
- Automated verification: Python compilation and `python3 -m unittest discover -s support-session/tests` (97 tests passed); `git diff --check` passed.
- Target: control host `adam@192.168.2.52`
- Installed console SHA-256: `f776f23c5adeab0fc58cd1d923b09f8e4708cf88c6a9cd7ceecac4f6fb191a13`
- Release archive: `/srv/tsuite-deploy/releases/support-console-dashboard-no-os-f776f23c5ade/source.tar.gz`
- Pre-deploy backup: `/var/backups/tsuite-support-console/20261008T022353Z-pre-f776f23c5ade/console`
- Services `tsuite-support-console`, `nginx`, `tsuite-frpc`, and `tsuite-github-egress`: active.
- `nginx -t`: passed.
- Public endpoint checks: `/_tsuite-control-health` 200, `/support/` 401 (authentication required), `/support/operator-client` 200, `/support/operator-client.ps1` 200.
- Session inventory after deployment: 0 active sessions (77 records).
