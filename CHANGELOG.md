# Changelog

## v1.0.2 - 2026-10-19

### Changes

- Added `gitea-github-sync.cron`, a system cron example for Monday at 03:00,
  running as root with `--apply-quiet`.
- Documented installing the script at a stable absolute path, installing the
  cron file with the required ownership/permissions, and checking service/logs.
- Clarified that quiet mode detaches the worker and records its final exit
  status in the log; the launcher's exit status does not confirm sync success.
- Included the existing GPL-3.0-only license in the release bundle.

### Why

The original server still had an older script without `--apply-quiet`, and the
expected weekly cron entry had not been installed. Deploying the already
published script and adding the system cron entry resolved those deployment
gaps. The reusable cron example and verification instructions make these steps
explicit for other installations.

`--apply-quiet` was already included in v1.0.0 and v1.0.1. The synchronization
script in v1.0.2 is byte-for-byte identical to v1.0.1; this release documents and
packages the scheduling setup rather than claiming a new quiet-mode code change.

### Verification

- Confirmed that the deployed script matches the published v1.0.1 script.
- Confirmed the installed weekly root cron entry, active/enabled cron service,
  required commands, script syntax and successful read-only API access.
- The scheduled synchronization itself was not manually triggered during these
  checks; successful completion must be confirmed in the log after execution.

## v1.0.1 - 2026-10-04

- Required an explicit `GITEA_URL` and removed the deployment-specific fallback.
- Added base-URL validation and documented custom hosts and web path prefixes.
- Made the example configuration independent of a specific Gitea account.

## v1.0.0 - 2026-10-04

- First public release: automatic discovery of GitHub mirrors and enrichment
  with metadata, topics, issues and comments.
- Included dry-run, foreground apply and quiet background apply modes,
  rate-limit handling, locking and English/YunoHost documentation.
