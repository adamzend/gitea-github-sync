#!/usr/bin/env bash
# GitHub -> Gitea: metadata, topics, issues and issue comments.
# Linux, Bash >= 4.3, curl, jq >= 1.6, flock (util-linux).
# Worker state is intentionally local to subshells; parent discovery state persists.
# shellcheck disable=SC2030,SC2031
set -Eeuo pipefail
umask 077

CONFIG_FILE="${CONFIG_FILE:-/etc/gitea-github-sync.conf}"
MODE=dry-run
NO_GIT=0
QUIET=0
SELECTED_MODE=
# Silence even launcher/configuration errors when quiet mode was requested.
# Its caller can still inspect the launcher's exit status.
for argument in "$@"; do
    if [[ "$argument" == --apply-quiet ]]; then exec >/dev/null 2>&1; fi
done
usage() {
    cat <<USAGE
Usage: $0 [--config FILE] [--dry-run|--apply|--apply-quiet] [--no-git]
  --dry-run      Report changes without writing to APIs (default).
  --apply        Apply changes in the foreground.
  --apply-quiet  Apply in the background; write output to QUIET_LOG_FILE.
  --config FILE  Read a trusted Bash configuration file.
  --no-git       Skip native Gitea mirror-sync requests.
  --help, -h     Show this help.
USAGE
}
log() { printf '[%s] %s%s\n' "$(date '+%F %T')" "${REPO_LABEL:+[$REPO_LABEL] }" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
on_error() { local rc=$1 line=$2; log "Failure at line $line (exit $rc); synchronization incomplete."; exit "$rc"; }
trap 'on_error "$?" "$LINENO"' ERR
while (($#)); do
    case "$1" in
        --dry-run|--apply|--apply-quiet)
            [[ -z "$SELECTED_MODE" || "$SELECTED_MODE" == "$1" ]] || die "Choose only one execution mode"
            SELECTED_MODE=$1 ;;
    esac
    case "$1" in
        --config) (($# >= 2)) || die "Missing path after --config"; CONFIG_FILE=$2; shift ;;
        --dry-run) MODE=dry-run; QUIET=0 ;;
        --apply) MODE=apply; QUIET=0 ;;
        --apply-quiet) MODE=apply; QUIET=1 ;;
        --no-git) NO_GIT=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done
((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3))) ||
    die "Bash >= 4.3 is required"
readonly MODE NO_GIT QUIET
[[ -r "$CONFIG_FILE" ]] || die "Configuration not found: $CONFIG_FILE"
# Configuration is trusted shell code; restrict write access to its owner.
# shellcheck disable=SC1090
source "$CONFIG_FILE"
: "${QUIET_LOG_FILE:=/var/log/gitea-github-sync.log}"
if ((QUIET)); then
    command -v nohup >/dev/null || die "Missing command: nohup"
    [[ "$QUIET_LOG_FILE" == /* ]] || die "QUIET_LOG_FILE must be an absolute path"
    # Open before spawning so an inaccessible log produces a failed launch.
    exec >>"$QUIET_LOG_FILE" 2>&1
    chmod 600 "$QUIET_LOG_FILE"
    quiet_args=(--config "$CONFIG_FILE" --apply)
    if ((NO_GIT)); then quiet_args+=(--no-git); fi
    GITEA_SYNC_QUIET_WORKER=1 nohup "$BASH" "$0" "${quiet_args[@]}" </dev/null &
    exit 0
fi
if [[ "${GITEA_SYNC_QUIET_WORKER:-}" == 1 ]]; then
    # Preserve the final worker result, including failures before acquiring a lock.
    trap 'rc=$?; log "Background worker finished: PID=$$, exit_status=$rc"' EXIT
    log "Background worker started: PID=$$"
fi
: "${GITEA_URL:=https://git.an0n.eu}"
: "${GITEA_OWNER:=}"
: "${GITHUB_API:=https://api.github.com}"
: "${GITHUB_API_VERSION:=2026-03-10}"
: "${LOCK_FILE:=/var/run/gitea-github-sync.lock}"
: "${MAX_PAGES:=10000}"
: "${GITHUB_RATE_LIMIT_MAX_WAIT:=60}"
: "${GITHUB_RATE_LIMIT_RETRIES:=2}"
[[ -n "${GITEA_TOKEN:-}" ]] || die "GITEA_TOKEN is missing from the configuration"
[[ "$MAX_PAGES" =~ ^[1-9][0-9]*$ ]] || die "Invalid MAX_PAGES"
for value in "$GITHUB_RATE_LIMIT_MAX_WAIT" "$GITHUB_RATE_LIMIT_RETRIES"; do
    [[ "$value" =~ ^(0|[1-9][0-9]{0,5})$ ]] || die "Invalid GitHub rate limit setting"
done
((GITHUB_RATE_LIMIT_RETRIES <= 10)) || die "GITHUB_RATE_LIMIT_RETRIES must not exceed 10"
for cmd in curl jq flock mktemp rm cmp cat date mkdir awk sleep; do
    command -v "$cmd" >/dev/null || die "Missing command: $cmd"
done
GITEA_URL=${GITEA_URL%/}
GITHUB_API=${GITHUB_API%/}
[[ "$GITEA_URL" == http://* || "$GITEA_URL" == https://* ]] || die "Invalid GITEA_URL"
[[ "$GITHUB_API" == http://* || "$GITHUB_API" == https://* ]] || die "Invalid GITHUB_API"
exec 9>"$LOCK_FILE" || die "Cannot open lock: $LOCK_FILE"
flock -n 9 || die "Another synchronization is running"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gitea-github-sync.XXXXXX")
cleanup() {
    if [[ -n "${worker_pid:-}" ]]; then
        kill -TERM "$worker_pid" 2>/dev/null || true
        wait "$worker_pid" 2>/dev/null || true
    fi
    rm -rf -- "$WORK_DIR"
}
finish() {
    local rc=$?
    cleanup
    if [[ "${GITEA_SYNC_QUIET_WORKER:-}" == 1 ]]; then
        log "Background worker finished: PID=$$, exit_status=$rc"
    fi
    return "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
RUN_DIR=$WORK_DIR
HEADER_DIR=$RUN_DIR

# Keep credentials out of curl's command line. curl >= 7.55 supports -H @file.
printf 'Authorization: token %s\nAccept: application/json\n' "$GITEA_TOKEN" > "$WORK_DIR/gt.headers"
printf 'Accept: application/vnd.github+json\nX-GitHub-Api-Version: %s\n' "$GITHUB_API_VERSION" > "$WORK_DIR/gh.headers"
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" >> "$WORK_DIR/gh.headers"
    log "GitHub authentication: token configured"
else
    log "WARNING: GitHub authentication: anonymous. Set GITHUB_TOKEN in the configuration for a higher API quota"
fi

response_header() {
    awk -v name="$2" '
        /^HTTP\// { value="" }
        tolower($1)==tolower(name ":") {
            sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0
        }
        END { print value }' "$1"
}

# GETs may retry. Never automatically repeat a mutation: a lost response can
# follow a successful POST, and retrying it would create duplicates.
request() {
    local service=$1 method=$2 url=$3 output=$4 payload=${5:-} allow_missing=${6:-0} status
    local headers="$WORK_DIR/response.headers" message remaining reset retry_after wait_seconds
    local attempt=0 waited=0 now reset_wait
    local -a args=(-q --silent --show-error --connect-timeout 15 --max-time 120
        --user-agent 'gitea-github-sync/3.1' -D "$headers"
        -H "@$HEADER_DIR/$service.headers" -X "$method" -o "$output" -w '%{http_code}')
    [[ "$method" == GET || "$MODE" == apply ]] || die "Write request blocked in dry-run"
    # GitHub throttling must be inspected before any retry, including HTTP 429.
    if [[ "$method" == GET && "$service" != gh ]]; then
        args+=(--retry 3 --retry-delay 2 --retry-max-time 180)
    fi
    if [[ -n "$payload" ]]; then
        args+=(-H 'Content-Type: application/json' --data-binary "@$payload")
    fi
    while :; do
        status=$(curl "${args[@]}" "$url") || die "Transport error: $method $url; run dry-run before retrying APPLY"
        if [[ "$status" == 2[0-9][0-9] ]]; then return 0; fi
        if [[ "$status" == 404 && "$allow_missing" == 1 ]]; then return 4; fi
        message=$(jq -r 'if type=="object" and (.message|type)=="string" then
            .message | gsub("[[:cntrl:]]"; " ") | .[:1000]
            else "No JSON error message in response" end' "$output" 2>/dev/null) || message='Non-JSON error response (possibly proxy or firewall)'
        message=${message//"$GITEA_TOKEN"/[REDACTED]}
        if [[ -n "${GITHUB_TOKEN:-}" ]]; then message=${message//"$GITHUB_TOKEN"/[REDACTED]}; fi
        log "HTTP $status: $method $url; API message: $message"
        remaining=$(response_header "$headers" x-ratelimit-remaining)
        reset=$(response_header "$headers" x-ratelimit-reset)
        retry_after=$(response_header "$headers" retry-after)
        if [[ "$service" == gh && ( "$status" == 403 || "$status" == 429 ) ]] &&
           [[ "$remaining" == 0 || "$status" == 429 || -n "$retry_after" || "${message,,}" == *"rate limit"* ]]; then
            log "GitHub rate limit: remaining=${remaining:-unknown}, reset_epoch=${reset:-unknown}, retry_after=${retry_after:-absent}"
            now=$(date +%s)
            wait_seconds=$((60 * (2 ** attempt)))
            if [[ "$retry_after" =~ ^[0-9]{1,9}$ ]]; then
                wait_seconds=$((10#$retry_after))
            elif [[ -n "$retry_after" ]]; then
                reset_wait=$(date -d "$retry_after" +%s 2>/dev/null) || reset_wait=$((now + 60))
                wait_seconds=$((reset_wait - now))
            fi
            if [[ "$remaining" == 0 && "$reset" =~ ^[0-9]{1,12}$ ]]; then
                reset_wait=$((10#$reset - now + 1))
                if [[ -z "$retry_after" ]] || ((reset_wait > wait_seconds)); then wait_seconds=$reset_wait; fi
                log "GitHub quota resets at $(date -u -d "@$reset" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || printf '%s' "$reset")"
            fi
            if ((wait_seconds < 1)); then wait_seconds=1; fi
            if [[ "$method" == GET ]] && ((attempt < GITHUB_RATE_LIMIT_RETRIES && waited + wait_seconds <= GITHUB_RATE_LIMIT_MAX_WAIT)); then
                log "Waiting $wait_seconds seconds before retrying GitHub (attempt $((attempt + 1)))"
                sleep "$wait_seconds"
                waited=$((waited + wait_seconds))
                attempt=$((attempt + 1))
                continue
            fi
            printf '%s\n' 'GitHub rate limit reached; wait for reset or correct GITHUB_TOKEN before rerunning' > "$RUN_DIR/github-stop"
            die "GitHub rate limit wait/retry budget exceeded; stopping account scan"
        fi
        if [[ "$service" == gh && "$status" == 401 ]]; then
            printf '%s\n' 'GitHub authentication failed; replace or correct GITHUB_TOKEN' > "$RUN_DIR/github-stop"
        elif [[ "$service" == gh && "$status" == 403 ]]; then
            log "GitHub access denied without a rate-limit signal. Check token repository access, organization/SSO policy, and any proxy/firewall"
        fi
        die "Request failed; see API message above"
    done
}
validate() { jq -e "$2" "$1" >/dev/null || die "Invalid JSON data: ${1##*/}"; }
paginate() {
    local service=$1 url=$2 output=$3 page count
    : > "$output"
    for ((page=1; page<=MAX_PAGES; page++)); do
        request "$service" GET "$url&page=$page" "$WORK_DIR/page.json"
        validate "$WORK_DIR/page.json" 'type == "array" and all(.[]; type == "object")'
        count=$(jq length "$WORK_DIR/page.json")
        ((count > 0)) || return 0
        if ((page > 1)) && cmp -s "$WORK_DIR/page.json" "$WORK_DIR/previous-page.json"; then
            die "API returned a repeated page: $url"
        fi
        cat "$WORK_DIR/page.json" > "$WORK_DIR/previous-page.json"
        jq -c '.[]' "$WORK_DIR/page.json" >> "$output"
        # Continue to an empty page: servers may cap the requested page size.
    done
    die "MAX_PAGES exceeded for $url"
}
marker() {
    # Existing V2.1 markers are supported. Ambiguous markers stop the run.
    jq -r --arg kind "$2" '
        [(.body // "") | scan("<!-- " + $kind + ":([0-9]+) -->") | .[0]] |
        if length > 1 then error("Multiple markers in one record")
        else .[0] // "" end' "$1"
}
issue_schema='def pos: type == "number" and . > 0 and floor == .;
    all(.[]; (.id|pos) and (.number|pos) and (.title|type=="string") and
    (.body == null or (.body|type=="string")) and (.state=="open" or .state=="closed"))'
comment_schema='def pos: type == "number" and . > 0 and floor == .;
    all(.[]; (.id|pos) and (.body == null or (.body|type=="string")))'

# Run each repository in its own subshell and directory. The parent waits for
# every worker and continues after a failure without disabling worker errexit.
sync_repository() (
set -Eeuo pipefail
local entry=$1 repo_id source current_source
local GITEA_OWNER GITEA_REPO GITHUB_OWNER GITHUB_REPO WORK_DIR
repo_id=$(jq -r .id <<< "$entry")
GITEA_OWNER=$(jq -r .owner.login <<< "$entry")
GITEA_REPO=$(jq -r .name <<< "$entry")
REPO_LABEL="$GITEA_OWNER/$GITEA_REPO"
source=$(github_source "$(jq -r .original_url <<< "$entry")")
IFS=$'\t' read -r GITHUB_OWNER GITHUB_REPO <<< "$source"
WORK_DIR="$RUN_DIR/repo-$repo_id"
mkdir -- "$WORK_DIR"
# The parent owns cleanup; do not remove shared credentials from a worker.
trap - EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
GT="$GITEA_URL/api/v1/repos/$GITEA_OWNER/$GITEA_REPO"
GH="$GITHUB_API/repos/$GITHUB_OWNER/$GITHUB_REPO"
log "GitHub $GITHUB_OWNER/$GITHUB_REPO -> Gitea $GITEA_OWNER/$GITEA_REPO; mode $MODE"
request gt GET "$GT" "$WORK_DIR/gt-repo.json"
request gh GET "$GH" "$WORK_DIR/gh-repo.json"
for service in gt gh; do
    validate "$WORK_DIR/$service-repo.json" 'type=="object" and (.id|type=="number") and
        (.default_branch|type=="string") and (.description==null or (.description|type=="string")) and
        (.website==null or (.website|type=="string")) and (.homepage==null or (.homepage|type=="string"))'
done
validate "$WORK_DIR/gt-repo.json" '.archived != true and .mirror == true'
is_mirror=true
current_source=$(github_source "$(jq -r '.original_url // ""' "$WORK_DIR/gt-repo.json")")
[[ "${current_source,,}" == "${source,,}" ]] || die "Mirror source changed after discovery; rerun discovery"
sync_issues=$(jq -r '.has_issues == true and .external_tracker == null' "$WORK_DIR/gt-repo.json")
if [[ "$sync_issues" != true ]]; then
    log "WARNING: Internal issues are disabled; synchronizing metadata and topics only"
fi
request gh GET "$GH/topics" "$WORK_DIR/gh-topics.json"
request gt GET "$GT/topics" "$WORK_DIR/gt-topics.json"
for service in gh gt; do
    validate "$WORK_DIR/$service-topics.json" '(.topics // .names) | type=="array" and all(.[]; type=="string")'
done
jq '{topics:(.names | sort | unique)}' "$WORK_DIR/gh-topics.json" > "$WORK_DIR/topics-payload.json"
jq '{topics:((.topics // .names) | sort | unique)}' "$WORK_DIR/gt-topics.json" > "$WORK_DIR/topics-old.json"
jq '{description:(.description // ""), website:(.homepage // ""), default_branch}' "$WORK_DIR/gh-repo.json" > "$WORK_DIR/repo-payload.json"
jq '{description:(.description // ""), website:(.website // ""), default_branch}' "$WORK_DIR/gt-repo.json" > "$WORK_DIR/repo-old.json"

# Complete the read/validation phase before any writes.
log "Reading issues and comments (excluding pull requests)..."
if [[ "$sync_issues" == true ]]; then
paginate gh "$GH/issues?state=all&sort=created&direction=asc&per_page=100" "$WORK_DIR/gh-all.jsonl"
paginate gt "$GT/issues?state=all&type=issues&limit=50" "$WORK_DIR/gt-all.jsonl"
else
    : > "$WORK_DIR/gh-all.jsonl"
    : > "$WORK_DIR/gt-all.jsonl"
fi
for service in gh gt; do
    jq -s '[.[] | select(.pull_request == null)] | sort_by(.number)' "$WORK_DIR/$service-all.jsonl" > "$WORK_DIR/$service-issues.json"
    validate "$WORK_DIR/$service-issues.json" "$issue_schema"
    jq -c '.[]' "$WORK_DIR/$service-issues.json" > "$WORK_DIR/$service-issues.jsonl"
done
declare -A gh_numbers=() gt_numbers=() gt_comment_ids=() seen_gh=()
while IFS= read -r record; do
    printf '%s\n' "$record" > "$WORK_DIR/record.json"
    id=$(jq -r .id "$WORK_DIR/record.json")
    number=$(jq -r .number "$WORK_DIR/record.json")
    [[ -z "${seen_gh[$id]+x}" && -z "${gh_numbers[$number]+x}" ]] || die "Duplicate GitHub issue $id"
    seen_gh[$id]=1
    gh_numbers[$number]=$id
done < "$WORK_DIR/gh-issues.jsonl"
while IFS= read -r record; do
    printf '%s\n' "$record" > "$WORK_DIR/record.json"
    id=$(marker "$WORK_DIR/record.json" github-sync-id)
    [[ -n "$id" ]] || continue
    [[ -z "${gt_numbers[$id]+x}" ]] || die "Duplicate github-sync-id:$id in Gitea"
    number=$(jq -r .number "$WORK_DIR/record.json")
    gt_numbers[$id]=$number
    printf '%s\n' "$record" > "$WORK_DIR/gt-issue-$id.json"
    paginate gt "$GT/issues/$number/comments?limit=50" "$WORK_DIR/comments.jsonl"
    jq -s '.' "$WORK_DIR/comments.jsonl" > "$WORK_DIR/comments.json"
    validate "$WORK_DIR/comments.json" "$comment_schema"
    while IFS= read -r comment; do
        printf '%s\n' "$comment" > "$WORK_DIR/record.json"
        cid=$(marker "$WORK_DIR/record.json" github-comment-id)
        [[ -n "$cid" ]] || continue
        key="$number:$cid"
        [[ -z "${gt_comment_ids[$key]+x}" ]] || die "Duplicate github-comment-id:$cid in Gitea #$number"
        gt_comment_ids[$key]=$(jq -r .id "$WORK_DIR/record.json")
        printf '%s\n' "$comment" > "$WORK_DIR/gt-comment-$number-$cid.json"
    done < "$WORK_DIR/comments.jsonl"
done < "$WORK_DIR/gt-issues.jsonl"
if [[ "$sync_issues" == true ]]; then
paginate gh "$GH/issues/comments?sort=created&direction=asc&per_page=100" "$WORK_DIR/gh-comments.jsonl"
else
    : > "$WORK_DIR/gh-comments.jsonl"
fi
jq -s '.' "$WORK_DIR/gh-comments.jsonl" > "$WORK_DIR/gh-comments.json"
validate "$WORK_DIR/gh-comments.json" "$comment_schema and all(.[]; (.issue_url|type==\"string\"))"
declare -A seen_comments=()
while IFS= read -r record; do
    printf '%s\n' "$record" > "$WORK_DIR/record.json"
    number=$(jq -r '.issue_url | split("/") | last' "$WORK_DIR/record.json")
    [[ "$number" =~ ^[1-9][0-9]*$ ]] || die "Invalid issue number in GitHub comment"
    [[ -n "${gh_numbers[$number]+x}" ]] || continue
    cid=$(jq -r .id "$WORK_DIR/record.json")
    [[ -z "${seen_comments[$cid]+x}" ]] || die "Duplicate GitHub comment $cid"
    seen_comments[$cid]=1
    printf '%s\n' "$record" >> "$WORK_DIR/gh-comments-$number.jsonl"
done < "$WORK_DIR/gh-comments.jsonl"

# Payloads are built from files, avoiding shell argument limits and retaining
# Unicode and trailing newlines. Ignore source copies of our reserved markers.
# shellcheck disable=SC2016
body_filter='def marked($kind; $id):
    (. // "" | gsub("<!-- " + $kind + ":[0-9]+ -->"; "")) as $b |
    $b + (if $b=="" then "" else "\n\n" end) + "<!-- " + $kind + ":" + ($id|tostring) + " -->";'
issues_create=0 issues_update=0 issues_same=0
comments_create=0 comments_update=0 comments_same=0
mutations=0
deferred_branch=0
write_api() {
    request gt "$1" "$2" "$WORK_DIR/response.json" "${3:-}"
    mutations=$((mutations + 1))
}
if ! cmp -s "$WORK_DIR/repo-old.json" "$WORK_DIR/repo-payload.json"; then
    log "Repository metadata: update planned"
    # Mirror sync is asynchronous. Do not set a branch that does not exist yet.
    branch=$(jq -r .default_branch "$WORK_DIR/repo-payload.json")
    old_branch=$(jq -r .default_branch "$WORK_DIR/repo-old.json")
    if [[ "$branch" != "$old_branch" ]]; then
        log "Default branch must exist in Gitea: $branch"
        encoded=$(jq -rn --arg v "$branch" '$v|@uri')
        if request gt GET "$GT/branches/$encoded" "$WORK_DIR/branch.json" '' 1; then
            validate "$WORK_DIR/branch.json" '(.name|type=="string")'
        else
            log "Branch is not available in Gitea; deferring default_branch. Retry after mirror-sync completes."
            jq 'del(.default_branch)' "$WORK_DIR/repo-payload.json" > "$WORK_DIR/repo-without-branch.json"
            cat "$WORK_DIR/repo-without-branch.json" > "$WORK_DIR/repo-payload.json"
            deferred_branch=1
        fi
    fi
    if [[ "$MODE" == apply ]]; then write_api PATCH "$GT" "$WORK_DIR/repo-payload.json"; fi
fi
if ! cmp -s "$WORK_DIR/topics-old.json" "$WORK_DIR/topics-payload.json"; then
    log "Repository topics: update planned"
    if [[ "$MODE" == apply ]]; then write_api PUT "$GT/topics" "$WORK_DIR/topics-payload.json"; fi
fi
while IFS= read -r record; do
    printf '%s\n' "$record" > "$WORK_DIR/source.json"
    id=$(jq -r .id "$WORK_DIR/source.json")
    number=$(jq -r .number "$WORK_DIR/source.json")
    target=${gt_numbers[$id]:-}
    jq "$body_filter"'{title, body:(.body | marked("github-sync-id"; $id)), state}' \
        --argjson id "$id" "$WORK_DIR/source.json" > "$WORK_DIR/issue-payload.json"
    if [[ -z "$target" ]]; then
        issues_create=$((issues_create + 1))
        log "CREATE issue GitHub #$number"
        if [[ "$MODE" == apply ]]; then
            jq '{title, body, closed:(.state=="closed")}' "$WORK_DIR/issue-payload.json" > "$WORK_DIR/create.json"
            write_api POST "$GT/issues" "$WORK_DIR/create.json"
            validate "$WORK_DIR/response.json" '(.number|type=="number" and .>0 and floor==.)'
            target=$(jq -r .number "$WORK_DIR/response.json")
            gt_numbers[$id]=$target
        fi
    else
        jq '{title, body:(.body // ""), state}' "$WORK_DIR/gt-issue-$id.json" > "$WORK_DIR/old.json"
        if cmp -s "$WORK_DIR/old.json" "$WORK_DIR/issue-payload.json"; then
            issues_same=$((issues_same + 1))
        else
            issues_update=$((issues_update + 1))
            log "UPDATE issue Gitea #$target <- GitHub #$number"
            if [[ "$MODE" == apply ]]; then write_api PATCH "$GT/issues/$target" "$WORK_DIR/issue-payload.json"; fi
        fi
    fi
    [[ -f "$WORK_DIR/gh-comments-$number.jsonl" ]] || continue
    while IFS= read -r comment; do
        printf '%s\n' "$comment" > "$WORK_DIR/source.json"
        cid=$(jq -r .id "$WORK_DIR/source.json")
        jq "$body_filter"'{body:(.body | marked("github-comment-id"; $id))}' \
            --argjson id "$cid" "$WORK_DIR/source.json" > "$WORK_DIR/comment-payload.json"
        key="$target:$cid"
        existing=${gt_comment_ids[$key]:-}
        if [[ -z "$existing" ]]; then
            comments_create=$((comments_create + 1))
            log "CREATE GitHub comment $cid on issue #$number"
            if [[ "$MODE" == apply ]]; then write_api POST "$GT/issues/$target/comments" "$WORK_DIR/comment-payload.json"; fi
        else
            jq '{body:(.body // "")}' "$WORK_DIR/gt-comment-$target-$cid.json" > "$WORK_DIR/old.json"
            if cmp -s "$WORK_DIR/old.json" "$WORK_DIR/comment-payload.json"; then
                comments_same=$((comments_same + 1))
            else
                comments_update=$((comments_update + 1))
                log "UPDATE Gitea comment $existing <- GitHub $cid"
                if [[ "$MODE" == apply ]]; then write_api PATCH "$GT/issues/comments/$existing" "$WORK_DIR/comment-payload.json"; fi
            fi
        fi
    done < "$WORK_DIR/gh-comments-$number.jsonl"
done < "$WORK_DIR/gh-issues.jsonl"
if ((NO_GIT)); then
    log "Mirror-sync skipped (--no-git)"
elif [[ "$is_mirror" != true ]]; then
    log "Mirror-sync skipped: repository is not a mirror"
elif [[ "$MODE" == apply ]]; then
    write_api POST "$GT/mirror-sync"
    log "Mirror-sync queued; check completion in Gitea"
else
    log "DRY-RUN: mirror-sync would be queued"
fi
log "Issues: create=$issues_create, update=$issues_update, unchanged=$issues_same"
log "Comments: create=$comments_create, update=$comments_update, unchanged=$comments_same"
if [[ "$MODE" == apply ]] && ((deferred_branch)); then
    die "Default branch update pending. Successful writes: $mutations. Wait for Git synchronization and rerun."
fi
log "Completed $MODE; successful write requests: $mutations"

)

# Parse only GitHub.com clone URLs. Do not log original_url: it can contain
# embedded credentials. Destination names may differ from source names.
github_source() {
    jq -rn --arg url "$1" '
        ($url | capture("(?i)^(?:https?://(?:[^/@]+@)?github\\.com(?::443)?/|ssh://(?:git@)?github\\.com(?::22)?/|git@github\\.com:)(?<owner>[a-z0-9_.-]+)/(?<repo>[a-z0-9_.-]+)/?$")?) as $m |
        if $m == null then "" else
            ($m.repo | sub("(?i)\\.git$"; "")) as $repo |
            if $m.owner == "." or $m.owner == ".." or $repo == "" or $repo == "." or $repo == ".."
            then "" else [$m.owner, $repo] | @tsv end
        end'
}

if [[ -n "${GITEA_REPO:-}${GITHUB_OWNER:-}${GITHUB_REPO:-}" ]]; then
    log "Legacy GITEA_REPO/GITHUB_OWNER/GITHUB_REPO settings are ignored; repositories are discovered automatically"
fi
if [[ -z "$GITEA_OWNER" ]]; then
    request gt GET "$GITEA_URL/api/v1/user" "$WORK_DIR/user.json"
    validate "$WORK_DIR/user.json" '(.login|type=="string" and length>0)'
    GITEA_OWNER=$(jq -r .login "$WORK_DIR/user.json")
fi
[[ "$GITEA_OWNER" =~ ^[A-Za-z0-9_.-]+$ && "$GITEA_OWNER" != . && "$GITEA_OWNER" != .. ]] || die "Invalid GITEA_OWNER"
log "Discovering repositories owned by $GITEA_OWNER"
paginate gt "$GITEA_URL/api/v1/users/$GITEA_OWNER/repos?limit=50" "$WORK_DIR/repositories.jsonl"
jq -s '.' "$WORK_DIR/repositories.jsonl" > "$WORK_DIR/repositories.json"
validate "$WORK_DIR/repositories.json" 'all(.[];
    (.id|type=="number" and .>0 and floor==.) and
    (.name|type=="string" and test("^[A-Za-z0-9_.-]+$") and .!="." and .!="..") and
    (.owner.login|type=="string" and test("^[A-Za-z0-9_.-]+$") and .!="." and .!="..") and
    (.mirror|type=="boolean") and (.original_url==null or (.original_url|type=="string")))'
declare -A discovered_ids=()
discovered=0 selected=0 skipped=0 succeeded=0 failed=0
while IFS= read -r entry; do
    repo_id=$(jq -r .id <<< "$entry")
    [[ -z "${discovered_ids[$repo_id]+x}" ]] || continue
    discovered_ids[$repo_id]=1
    discovered=$((discovered + 1))
    full_name=$(jq -r '.owner.login + "/" + .name' <<< "$entry")
    owner=$(jq -r .owner.login <<< "$entry")
    if [[ "${owner,,}" != "${GITEA_OWNER,,}" ]] || [[ $(jq -r .mirror <<< "$entry") != true ]]; then
        skipped=$((skipped + 1))
        log "SKIP $full_name: not a pull mirror owned by $GITEA_OWNER"
        continue
    fi
    source=$(github_source "$(jq -r '.original_url // ""' <<< "$entry")")
    if [[ -z "$source" ]]; then
        skipped=$((skipped + 1))
        log "SKIP $full_name: no supported GitHub.com source URL"
        continue
    fi
    selected=$((selected + 1))
    if [[ $(jq -r '.archived // false' <<< "$entry") == true ]]; then
        failed=$((failed + 1))
        log "FAILED $full_name: archived GitHub mirror cannot be updated"
        continue
    fi
    sync_repository "$entry" &
    worker_pid=$!
    if wait "$worker_pid"; then
        succeeded=$((succeeded + 1))
        log "OK $full_name"
    else
        failed=$((failed + 1))
        log "FAILED $full_name"
    fi
    worker_pid=
    if [[ -f "$RUN_DIR/github-stop" ]]; then
        log "Account scan aborted: $(cat "$RUN_DIR/github-stop"). Remaining repositories were not attempted"
        break
    fi
done < "$WORK_DIR/repositories.jsonl"
log "Repositories: discovered=$discovered, selected=$selected, succeeded=$succeeded, failed=$failed, skipped=$skipped"
((failed == 0)) || exit 1
log "Account synchronization completed ($MODE)"
