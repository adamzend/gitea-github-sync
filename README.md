# Gitea GitHub Sync

Enrich all GitHub pull mirrors on your own Gitea instance with repository metadata,
topics, issues and comments that native Git mirroring does not synchronize.

The script discovers repositories automatically and derives each GitHub source
from the mirror URL. Source and destination repository names can differ.

## Features

- Automatic discovery, including private mirrors visible to the Gitea token.
- Description, website, default branch and topic synchronization.
- Issue titles, bodies, open/closed states and comment synchronization.
- Existing synchronization markers prevent duplicate imports on repeated runs.
- Foreground preview, foreground apply and quiet background apply modes.
- GitHub rate-limit diagnostics, bounded waits and account-level stop conditions.
- Repository isolation, a shared process lock and per-repository summaries.
- Optional native Gitea mirror-sync requests.

## Requirements

Linux, Bash 4.3+, jq 1.6+, curl 7.55+, util-linux and coreutils.

On Debian/Ubuntu:

```bash
sudo apt-get install bash curl jq util-linux coreutils
```

## Configuration

Use `gitea-github-sync.conf.example` as the template for
`/etc/gitea-github-sync.conf`. Update an existing configuration rather than
overwriting its tokens. Set your Gitea URL and token, the account owner, and a
GitHub token where needed. An empty `GITEA_OWNER` selects the token's account.

Set `GITEA_URL` to **your own Gitea instance** in the configuration:

```bash
GITEA_URL='https://gitea.example.com'
GITEA_OWNER=''
```

Replace the example address with your server's URL. For an installation under
a subdirectory, use e.g. `GITEA_URL='https://example.com/gitea'`.
Do not append `/api/v1`. There is no built-in Gitea server address; an absent or
empty `GITEA_URL` stops the script before any API request. `GITEA_OWNER` may be
left empty to detect the authenticated account, or set to an owner to scan.

Restrict the configuration to its owner:

```bash
sudo chmod 600 /etc/gitea-github-sync.conf
```

Never commit the populated configuration or tokens to this repository.

## Usage

```bash
# Preview without API writes (the default)
sudo bash ./gitea-github-sync.sh --dry-run

# Synchronize in the foreground
sudo bash ./gitea-github-sync.sh --apply

# Synchronize in the background without terminal output
sudo bash ./gitea-github-sync.sh --apply-quiet

# Enrich mirrors without queuing native Git synchronization
sudo bash ./gitea-github-sync.sh --apply --no-git
```

Use `--config FILE` for another configuration file and `--help` for all options.
Choose only one execution mode.

Quiet mode appends progress and errors to `/var/log/gitea-github-sync.log`,
configurable through `QUIET_LOG_FILE`. Its launcher returns immediately;
check the log's final `exit_status` to determine the actual result.

```bash
sudo tail -f /var/log/gitea-github-sync.log
```

## Weekly cron job

The release includes [`gitea-github-sync.cron`](gitea-github-sync.cron), which runs
the script **as root every Monday at 03:00 in the server's timezone**.
First configure `/etc/gitea-github-sync.conf` with your instance URL and tokens.
From the extracted release directory, install the script and cron entry:

```bash
sudo install -o root -g root -m 755 ./gitea-github-sync.sh /usr/local/bin/gitea-github-sync.sh
sudo install -o root -g root -m 644 ./gitea-github-sync.cron /etc/cron.d/gitea-github-sync
```

This does not overwrite your configuration or trigger an immediate sync. Check
for an existing equivalent job before installing, so it is not scheduled twice.
This file is for `/etc/cron.d`, where the `root` column is required; do not paste
it unchanged into a per-user `crontab -e`.

```bash
sudo cat /etc/cron.d/gitea-github-sync
systemctl is-active cron
systemctl is-enabled cron
timedatectl show -p Timezone
sudo tail -n 100 /var/log/gitea-github-sync.log
```

Cron must be installed and running. On a system with an existing active cron
service, a new `/etc/cron.d` file is read automatically without a restart.
The log path can be overridden by `QUIET_LOG_FILE`. Look for
`Background worker finished: PID=..., exit_status=0` to confirm successful
completion. Starting the quiet worker alone does not confirm completion.
If using a scheduler that must track the final process exit code, use foreground
`--apply` instead. No additional shell output redirection is needed for quiet mode.

See the [changelog](CHANGELOG.md) for what changed and why. Quiet mode already
existed in v1.0.1; v1.0.2 adds the reusable scheduling setup and documentation.

**Depending on the number of repositories/mirrors and their issues/comments,
execution can take a very long time, potentially hours.** Quiet mode does not
speed up synchronization. GitHub limits may require a later run.

## YunoHost deployment

The original deployment uses Gitea installed through YunoHost. YunoHost manages
its own installation and data directories; repository storage paths can differ
from standalone Gitea examples. This script uses HTTP APIs and does not require
local repository paths. Include any web path prefix in `GITEA_URL`.

See the [full English guide](README.txt) for locating the effective configuration,
YunoHost path details, all settings, all Bash functions and troubleshooting.

## Scope and limitations

Pull requests, releases/assets, labels, milestones, reactions, assignments,
original authorship and timestamps are not copied. Source deletions do not delete
Gitea records. Unmarked local records are untouched; previous imports without
markers require separate mapping. Local edits to synchronized fields are replaced
by the GitHub source. Disabled internal issue trackers receive metadata updates
only. Native mirror-sync runs asynchronously in Gitea.

The script has been checked with Bash syntax validation, ShellCheck and local
mock API tests, including multiple mirrors, idempotency, throttling and quiet mode.

## Downloads

Download the script or the complete bundle from
[GitHub Releases](https://github.com/adamzend/gitea-github-sync/releases).
The latest release is **v1.0.3**, adding progress logs and fixing comment retrieval, redirects and unavailable-source diagnostics.

## License

This project is licensed under the GNU General Public License v3.0 (GPL-3.0-only).
See [LICENSE](LICENSE) for the full license text.

## Comment pagination and moved GitHub repositories (v1.0.3)

Gitea's per-issue comments endpoint returns the complete comment list without
pagination. The script reads it once, including lists longer than 50 comments.
Other paginated lists are read until an empty page, with repeated-page detection.
GitHub GET redirects are followed for up to five hops within the configured API
origin only. External origins, protocol downgrades and redirect loops fail safely.
HTTP 404 still requires checking the source URL and token access.

After upgrading, keep the existing configuration and tokens. A failed run may
have completed other repositories; synchronization markers make reruns idempotent.
Quiet mode secures its log with chmod 600 on each launch, which can mask an ACL
previously granted to a monitoring account. An administrator can restore that
account's read ACL after launch without making the log world-readable.

GitHub sources returning HTTP 404 are counted as `unavailable`, separately from
`failed` and discovery filters (`skipped`). Existing mirrors are preserved; the
run can succeed with unavailable sources. Check the source or access if unexpected.

## Progress logging

Progress is logged at the start of each stage and approximately every 60 seconds
while processing pages, indexing issues, reading Gitea comments, mapping GitHub
comments and comparing/applying updates. Entries include the repository, stage,
page or processed counts and elapsed seconds since script startup. Page counts
are completed pages; processed counts include the current item, not successful
writes. The final summaries report completed operations.
Set PROGRESS_INTERVAL to a positive integer in seconds (default 60, max 99999).
Progress is checked at work boundaries: a slow API request, retry or JSON operation
can delay the next entry. These messages are not a separate liveness watchdog.
In --apply-quiet mode all progress goes to QUIET_LOG_FILE, not the terminal.
An unavailable GitHub source is preserved and counted without a Failure diagnostic.
Other failures, including JSON validation errors, still fail the repository.
