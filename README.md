# Gitea GitHub Sync

Enrich all GitHub pull mirrors owned by a Gitea account with repository metadata,
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

The example contains deployment-specific defaults; replace them for your server.
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
The first release is **v1.0.0**.
