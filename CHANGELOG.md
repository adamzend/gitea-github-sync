# Changelog

## v1.0.3 - 2026-10-27

### Progress and diagnostics

- Added configurable progress logs (PROGRESS_INTERVAL, default 60 seconds) with
  repository, stage, pages, processed counters and elapsed time. Quiet mode keeps
  all messages in its log. Slow operations may delay entries until a work boundary.
- Replaced the expected nonzero worker exit for unavailable GitHub sources with
  an explicit result marker. This removes the misleading ERR-trap Failure message
  without suppressing genuine exit-code-4 errors such as invalid JSON.
- The October 27 production candidate completed in 7h 49m: 59 repositories found,
  56 successful, one unavailable source, two filtered out, zero failed. This run
  validated the comment/redirect fixes; progress and diagnostic changes were
  subsequently validated with mock APIs before deployment.

### Fixed

- Read Gitea per-issue comments once as a complete list. This endpoint does not
  support page/limit; requesting further pages returned the same comments and
  incorrectly stopped synchronization. Paginated repository, issue and GitHub
  comment lists still use all pages and retain repeated-page protection.
- Follow GitHub GET redirects (301, 302, 303, 307, 308), including root-relative
  locations, up to five hops. Only the configured API origin is allowed, so
  credentials cannot be forwarded to another host or a downgraded protocol.
- Keep mutation requests non-retrying and non-redirecting. A missing GitHub
  source (404) is counted as unavailable, preserves the mirror and does not fail
  the run. A 404 can also mean a private source or insufficient token access.

### Validation

Mock API regression tests cover discovery pagination, unpaginated Gitea comments,
repeat-run idempotency, redirects, unsafe targets, loops, rate limits, isolation
and quiet background execution. Tests use local mock APIs, not production writes.

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

GitHub sources returning HTTP 404 are counted as `unavailable`, separately from
`failed` and discovery filters (`skipped`). Existing mirrors are preserved; the
run can succeed with unavailable sources. Check the source or access if unexpected.
