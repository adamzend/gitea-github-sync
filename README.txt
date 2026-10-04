GitHub mirror enrichment for a Gitea account
==========================================

Purpose and workflow
--------------------
This script complements Gitea's native GitHub pull mirrors. It discovers the
account's repositories through the Gitea REST API, identifies GitHub sources,
reads the source and destination data, compares their contents, and applies
missing or changed metadata, issues and comments. It processes one repository
at a time and can optionally queue Gitea's own background Git mirror job.

IMPORTANT: Depending on the number of repositories/mirrors and the number of
issues and comments, execution can take a very long time. Large accounts may
require hours. Network latency, API pagination, server load, rate-limit waits
and the number of required writes all affect duration. Dry-run also reads the
APIs and can take a long time. There is no fixed completion-time guarantee.
Quiet mode changes execution/output handling; it does not make the work faster.

Configuration
-------------
Linux requirements: Bash >= 4.3, jq >= 1.6, curl >= 7.55, flock (util-linux),
coreutils. On Debian/Ubuntu:
  sudo apt-get install bash curl jq util-linux coreutils

Save the example configuration as /etc/gitea-github-sync.conf, or update your
existing file. Set GITEA_URL, GITEA_TOKEN and GITEA_OWNER. An empty GITEA_OWNER
selects the account identified by GITEA_TOKEN. GITHUB_TOKEN is optional for
public sources and required for private sources. It is recommended for large
scans because of GitHub API rate limits.

GITEA_URL must be the address of YOUR Gitea instance, for example:
  GITEA_URL='https://gitea.example.com'
For a server mounted below a path:
  GITEA_URL='https://example.com/gitea'
Replace these examples with your actual server address. Do not append /api/v1.
There is no default Gitea server. A missing or empty GITEA_URL stops the script
before API requests. Existing configurations with GITEA_URL already set remain
valid. The example leaves GITEA_OWNER empty to detect the token's account.

The Gitea token must allow account/repository reads and repository settings,
issues and comment writes. Its account must be able to edit imported comments.
The configuration is trusted Bash code. Restrict its permissions:
  sudo chmod 600 /etc/gitea-github-sync.conf

Execution
---------
From the directory containing the downloaded script:
  sudo bash ./gitea-github-sync.sh --dry-run
  sudo bash ./gitea-github-sync.sh --apply
  sudo bash ./gitea-github-sync.sh --apply-quiet

Alternative configuration:
  bash ./gitea-github-sync.sh --config ./my-config.conf --dry-run

Dry-run is the default and makes no API writes. --no-git skips mirror-sync
requests while still enriching repositories. Non-root runs need LOCK_FILE in
a writable, trusted directory. All runs must use the same lock file.
No schedule is installed; the script can be invoked by cron or systemd.

Complete command-line reference
-------------------------------
--dry-run
  Foreground preview; reads APIs and reports planned changes. No API writes.
  This is the default if no execution mode is provided.
--apply
  Foreground synchronization. Logs are printed to the terminal. The command
  returns when synchronization ends and exposes the final exit status.
--apply-quiet
  Background synchronization with the same changes as --apply. The launcher
  returns immediately. The script prints nothing to the terminal and appends
  stdout/stderr, warnings and errors to QUIET_LOG_FILE. nohup protects the worker
  from ordinary terminal hangups; stdin is disconnected. No extra '&' is needed.
  Reboot, service/session policies that kill processes, and explicit termination
  can still stop it. This is not a system service and has no automatic restart.
--config FILE
  Use a different trusted Bash configuration file. Default:
  /etc/gitea-github-sync.conf (or CONFIG_FILE from the environment).
--no-git
  Do not queue native mirror-sync. Metadata, issue and comment enrichment still
  runs. It works with any execution mode.
--help / -h
  Display usage without synchronizing anything.

Choose only one execution mode. For example:
  sudo bash ./gitea-github-sync.sh --apply-quiet --no-git

Quiet-mode logs and completion
-----------------------------
Default log: /var/log/gitea-github-sync.log
Override it in the configuration with an absolute path:
  QUIET_LOG_FILE='/var/log/gitea-github-sync.log'

The parent directory must already exist and be writable by the executing user.
The script creates/appends the log with mode 600. For non-root runs, use a log
in a directory owned by that user. The log grows across runs; arrange log
rotation separately if needed. It is separate from Gitea's application logs.

Read progress when desired:
  sudo tail -n 100 /var/log/gitea-github-sync.log
  sudo tail -f /var/log/gitea-github-sync.log

Each worker logs its PID and ends with:
  Background worker finished: PID=12345, exit_status=0
Zero means successful script completion; nonzero means an error or interruption.
The launcher's exit status 0 only means the background command was dispatched,
not that synchronization succeeded. Check the completion line in the log.
If it cannot read configuration or open the log, the launcher fails silently;
immediately use 'echo $?' to inspect its nonzero status. An uncatchable kill or
power loss can leave the log without a completion line.

The worker uses the same LOCK_FILE as foreground runs. A second invocation
cannot synchronize concurrently; a rejected quiet worker records the lock error
in its log. For cron/systemd jobs that need the final exit status, prefer --apply
with output managed by the scheduler instead of detaching with --apply-quiet.

Configuration reference
-----------------------
GITEA_URL: Required base web URL of your own Gitea instance; no default. Include any path prefix,
  for example https://example.org/gitea. Do not append /api/v1.
GITEA_OWNER: Owner to scan; empty means the authenticated token account.
GITEA_TOKEN: Required Gitea API token; distinct from the GitHub token.
GITHUB_TOKEN: Optional for public GitHub sources, required for private sources.
GITHUB_API: GitHub API base, default https://api.github.com. Source discovery
  currently recognizes GitHub.com URLs, not arbitrary enterprise hosts.
GITHUB_API_VERSION: Default 2026-03-10.
LOCK_FILE: Default /var/run/gitea-github-sync.lock; shared by all execution modes.
MAX_PAGES: Default 10000; maximum pages per paginated API listing.
GITHUB_RATE_LIMIT_MAX_WAIT: Default 60; total wait budget in seconds per request.
GITHUB_RATE_LIMIT_RETRIES: Default 2; maximum 10; allowed throttling retries.
QUIET_LOG_FILE: Default /var/log/gitea-github-sync.log; --apply-quiet output.
TMPDIR: Optional temporary-directory base; defaults to /tmp. The script creates
  a private working directory and removes it on normal exit or handled signals.
Legacy GITEA_REPO/GITHUB_OWNER/GITHUB_REPO values do not select a single mirror.

Gitea installed through YunoHost
-------------------------------
In the deployment this script was prepared for, Gitea is installed through
YunoHost. Its managed installation and data directories differ from paths in
generic standalone Gitea guides. Do not assume repositories live in
/var/lib/gitea or /home/git/gitea-repositories.

The YunoHost package's configuration template sets [repository] ROOT to
<data_dir>/repositories and APP_DATA_PATH to <data_dir>/data. The exact data_dir,
install_dir and service name depend on the installed app instance, package
version, and migration history. A second instance can have a different app ID.
Inspect the installed service to find its effective configuration:
  sudo systemctl cat gitea
Use the actual instance's service name if it differs. If ExecStart specifies a
configuration file, inspect that file. The package installs app.ini at
<install_dir>/custom/conf/app.ini; install_dir is the directory containing the
Gitea executable in ExecStart. Read [repository] ROOT in the installed app.ini.
Do not publish the whole configuration; it contains credentials. YunoHost
manages this file and package upgrades may overwrite manual edits.

No local repository path is needed by this script: it operates exclusively
through HTTP APIs and lets Gitea perform Git synchronization. Leave storage
directories and their ownership under YunoHost management. The script's own
/etc/gitea-github-sync.conf and /var/log/gitea-github-sync.log are independent
files, not the YunoHost Gitea application's app.ini or service log.

If YunoHost serves Gitea below /gitea, use that prefix in GITEA_URL. The API must
be reachable through YunoHost's reverse proxy with token authentication. An
SSO redirect or access-denied HTML response prevents API use even with a valid
Gitea token; check app access settings without making private repositories public.

Package references:
https://github.com/YunoHost-Apps/gitea_ynh/blob/master/conf/app.ini
https://github.com/YunoHost-Apps/gitea_ynh/blob/master/manifest.toml
https://github.com/YunoHost-Apps/gitea_ynh/blob/master/scripts/install

Discovery
---------
All pages of /api/v1/users/{owner}/repos are read. Only repositories owned by
that account with mirror=true and a GitHub.com original_url are selected.
Private repositories are included when visible to the token. Restricted token
access can limit discovery; inaccessible repositories cannot be detected.
Collaborator and organization repositories are not implicitly included.

Supported sources: HTTPS/HTTP GitHub URLs, git@github.com:owner/repo.git and
ssh://git@github.com/owner/repo.git, with optional .git suffix and trailing slash.
HTTPS credentials and standard SSH port 22 are supported. Embedded credentials
are not logged or reused; configure GITHUB_TOKEN separately.
Each mirror's source is derived independently; the destination name can differ.
Legacy GITEA_REPO, GITHUB_OWNER and GITHUB_REPO settings are ignored.
Non-mirrors, non-GitHub sources and repositories owned by others are skipped.
Archived GitHub mirrors are reported as failures; remaining repositories run.

Scope
-----
The original enrichment scope is preserved: description, website, default
branch, topics, issue titles/bodies/states and issue comment bodies. Mirrors
without an internal issue tracker receive metadata/topics updates and an
explicit warning that issue/comment synchronization was skipped.

Pull requests, releases/assets, labels, milestones, assignments, reactions,
authorship and original timestamps are not copied. Attachments remain source
links. Records removed from GitHub are not deleted in Gitea. This is enrichment
within the original script's scope, not a complete GitHub migration.

Existing V2.1 github-sync-id and github-comment-id markers are supported.
Unmarked local records remain untouched. Earlier imports without markers need
separate mapping to avoid creating additional records. Local edits to marked
fields are overwritten by GitHub. Marker names are reserved for the script.

Errors and repeated runs
------------------------
Repositories run sequentially with isolated state. A failure stops only the
current repository. The final summary reports discovered, selected, succeeded,
failed and skipped counts. Exit status is 1 if any selected repository fails.
Discovery failures abort before writes. Successful writes are not rolled back.

After a failure, inspect the log, fix the cause, run dry-run and then apply.
POST is never automatically retried after an ambiguous response. Markers are
used to reconcile existing records on subsequent runs. Duplicate markers stop
the affected repository before its write phase.

Mirror-sync is asynchronous. A missing default branch is deferred while other
fields are updated and mirror-sync is queued (unless --no-git is used). The
repository is reported as failed for that run; rerun after Git sync finishes.
Accepted mirror-sync requests do not confirm completion of the background job.
API reads are not a transactional snapshot; concurrent source changes may
require another run.

GitHub HTTP 403 / 429 / 401
-------------------------
The log reports whether a GitHub token is configured and includes the API error
message. Rate limits are recognized from response headers and API messages.
The script respects Retry-After and X-RateLimit-Reset. It retries within the
GITHUB_RATE_LIMIT_MAX_WAIT budget (default 60 seconds per request) and
GITHUB_RATE_LIMIT_RETRIES (default 2, maximum 10). Longer throttling stops the
entire account scan with exit status 1 instead of failing every repository.
HTTP 401 also stops the scan: correct GITHUB_TOKEN before rerunning.
An ordinary permission-related 403 fails only the affected repository.

An anonymous quota exhaustion requires waiting for reset or configuring a valid
GITHUB_TOKEN. An authenticated quota can also be exhausted. Repeating the same
run immediately does not reset a quota. Permission errors require checking
token repository access and applicable organization policies. A proxy/firewall
may return non-JSON errors. Changing the script alone cannot grant API access.

Reference: https://docs.github.com/en/rest/using-the-rest-api/troubleshooting-the-rest-api

Validation
----------
Bash syntax, ShellCheck and local mock API tests cover account pagination,
multiple sources, renamed/private mirrors, isolated issue/comment state,
repeat-run idempotency and continuation after repository failures.
No production API writes were performed during development.

Internal function reference
---------------------------
usage: Prints command-line help.
log: Writes timestamped messages, with the current repository label when set.
die: Logs an error and exits with failure.
on_error: Reports an unexpected failed command's line and exit status.
cleanup: Stops/waits for an active repository worker and removes temporary files.
finish: Runs cleanup at exit and records the quiet worker's final exit status.
response_header: Extracts a response header from the last HTTP response block.
request: Sends authenticated API requests, builds JSON request headers, handles
  HTTP/transport errors and bounded GitHub throttling retries. It never retries
  a write automatically. A shared stop marker halts scanning on GitHub rate-limit
  exhaustion or invalid authentication.
validate: Checks an API response against a jq validation expression.
paginate: Collects every page until an empty page, detects repeated pages and
  enforces MAX_PAGES even when the server caps the requested page size.
marker: Extracts an issue/comment synchronization marker and rejects ambiguity.
sync_repository: Runs the read/validation, comparison and update phases in an
  isolated subshell/directory for one mirror, with per-repository counters.
write_api: Sends a Gitea mutation and counts successful write requests.
github_source: Parses supported GitHub clone URLs into source owner/repository.

The main loop discovers and filters repositories, starts one worker at a time,
waits for its result, continues after repository-specific errors, and prints the
account summary. Quiet launching happens before this loop and reuses the same
foreground synchronization engine in a detached process.

API reference:
https://docs.gitea.com/api/1.23/operations/user-list-repos/
