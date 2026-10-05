#!/usr/bin/env bash
# lib/cli.sh - gh/glab CLI abstraction

# =============================================================================
# CLI Abstraction (gh / glab)
# =============================================================================
#
# PR/MR list lines (TAB separated):
#   1 ref (#N GitHub, !N GitLab) | 2 CI + review column | 3 title | 4 @author |
#   5 head branch | 6 cross-repo 1/0 | 7 CI state: fail|pending|ok|none|draft
# Issue list lines: 1 #N | 2 title | 3 @author | 4 labels
# Every function taking a number accepts "N", "#N" or "!N".
# The list functions return non-zero with a short message on stderr when gh/glab
# fails (auth, network, unknown host...), so callers can tell it from "no PRs".

# Strip whitespace and a leading "#" or "!" from a PR/MR/issue number
cli_bare_num() {
  local n="${1//[[:space:]]/}"
  n="${n#\#}"
  n="${n#!}"
  printf '%s' "$n"
}

# WT_LIST_LIMIT as a usable --limit/--per-page value (GitLab caps per_page at 100)
_cli_list_limit() {
  local limit="${WT_LIST_LIMIT:-20}"
  if [[ ! "$limit" =~ ^[0-9]{1,6}$ ]] || (( 10#$limit < 1 )); then
    limit=20
  fi
  limit=$((10#$limit))
  if [[ "$1" == "gitlab" ]] && (( limit > 100 )); then
    limit=100
  fi
  printf '%s' "$limit"
}

# One short error line on stderr: "✗ <what>: <first line of the tool's stderr>"
_cli_error() {
  local what="$1" details="$2" line
  line=$(printf '%s\n' "$details" | sed $'s/\033\\[[0-9;]*[a-zA-Z]//g' | grep -v '^[[:space:]]*$' | head -1 | cut -c1-200)
  printf '%s✗%s %s: %s\n' "${C_RED:-}" "${C_RESET:-}" "$what" "${line:-failed}" >&2
}

# Run a gh/glab command: stdout passes through, stderr is captured and, on
# failure, reduced to one line on stderr. Returns the command's exit code.
_cli_run() {
  local what="$1 $2 $3" err rc
  if ! command -v "$1" >/dev/null 2>&1; then
    _cli_error "$what" "$1 is not installed"
    return 127
  fi
  { err=$("$@" 2>&1 1>&3 3>&-); rc=$?; } 3>&1
  if (( rc != 0 )); then
    _cli_error "$what" "$err"
  fi
  return "$rc"
}

_cli_need_jq() {
  has_jq && return 0
  _cli_error "jq" "jq is required to read $(get_cli_name) output, install it first"
  return 1
}

# Shared jq helpers (jq 1.6+, no regex so builds without oniguruma work too):
# clean = one-line field (control chars become spaces), text = multi-line text
# without \r or escape sequences, lpad = right-align, ci_label = list column
_CLI_JQ_DEFS='
def clean: (. // "") | tostring | explode | map(if . < 32 or . == 127 then 32 else . end) | implode;
def text: (. // "") | tostring | explode | map(select(. == 9 or . == 10 or (. >= 32 and . != 127))) | implode;
def lpad($n): tostring | (if length < $n then (" " * ($n - length)) else "" end) + .;
def labels: (. // []) | map(if type == "object" then .name else . end | clean);
def desc($n): text as $d | if $d != "" then "Description:\n\($d[0:$n])" else "No description" end;
def ci_label:
  if . == "draft" then "\u001b[2m[draft]\u001b[0m"
  elif . == "fail" then "\u001b[31m[fail]\u001b[0m"
  elif . == "pending" then "\u001b[33m[..]\u001b[0m"
  elif . == "ok" then "\u001b[32m[ok]\u001b[0m"
  else "\u001b[2m[--]\u001b[0m" end;
'

cli_pr_list() {
  local platform=$(detect_platform)
  local limit json
  _cli_need_jq || return 1
  limit=$(_cli_list_limit "$platform")

  if [[ "$platform" == "gitlab" ]]; then
    json=$(_cli_run glab mr list --per-page "$limit" --output json) || return 1
    # The MR list endpoint has no pipeline info. One extra request fetches the
    # latest 100 project pipelines, matched to each MR by head sha or MR ref.
    # An MR whose pipeline is older, or only ran in a fork, shows [--].
    local pipelines
    pipelines=$(glab api "projects/:id/pipelines?per_page=100" 2>/dev/null | \
      jq -c 'if type == "array" then [.[] | {sha, ref, status}] else [] end' 2>/dev/null)
    [[ -n "$pipelines" ]] || pipelines='[]'
    printf '%s\n' "$json" | jq -r --argjson pl "$pipelines" "$_CLI_JQ_DEFS"'
      .[] | . as $mr
      | (if (.draft // .work_in_progress // false) then "draft"
         else ([$pl[] | select(.sha == $mr.sha
                  or ((.ref // "") | startswith("refs/merge-requests/\($mr.iid)/")))][0].status // "") as $p
         | if $p == "" or $p == "skipped" then "none"
           elif $p == "success" then "ok"
           elif $p == "failed" or $p == "canceled" then "fail"
           else "pending" end
         end) as $state
      | "!\(.iid)\t\($state | ci_label)  \t\(.title | clean | .[0:50])\t\u001b[2m@\(.author.username // "ghost" | clean)\u001b[0m\t\(.source_branch | clean)\t\(if .source_project_id != .target_project_id then 1 else 0 end)\t\($state)"' \
      2>/dev/null || { _cli_error "glab mr list" "unexpected output"; return 1; }
  else
    local gh_user
    gh_user=$(gh api user --jq .login 2>/dev/null)
    json=$(_cli_run gh pr list --limit "$limit" --json number,title,headRefName,author,reviewDecision,statusCheckRollup,isDraft,reviewRequests,isCrossRepository) || return 1
    # statusCheckRollup mixes CheckRun (status + conclusion) and StatusContext
    # (commit statuses from external CI, state only)
    printf '%s\n' "$json" | jq -r --arg me "$gh_user" "$_CLI_JQ_DEFS"'
      def ci_state:
        if .isDraft then "draft"
        else [(.statusCheckRollup // [])[]
               | if .__typename == "StatusContext" or (.status == null and .state != null)
                 then (.state // "PENDING")
                 elif (.status // "") != "COMPLETED" then "PENDING"
                 else (.conclusion // "") end] as $s
          | if ($s | length) == 0 then "none"
            elif any($s[]; . == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "CANCELLED"
                           or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE") then "fail"
            elif any($s[]; . == "PENDING" or . == "EXPECTED") then "pending"
            else "ok" end
        end;
      .[] | ci_state as $state
      | (([(.reviewRequests // [])[] | select(.login == $me)] | length) > 0) as $needs_my_review
      | (if .reviewDecision == "APPROVED" then "\u001b[32m✓\u001b[0m"
         elif .reviewDecision == "CHANGES_REQUESTED" then "\u001b[31m✗\u001b[0m"
         elif $needs_my_review then "\u001b[35m◀\u001b[0m"
         else " " end) as $review
      | "#\(.number)\t\($state | ci_label) \($review)\t\(.title | clean | .[0:50])\t\u001b[2m@\(.author.login // "ghost" | clean)\u001b[0m\t\(.headRefName | clean)\t\(if .isCrossRepository then 1 else 0 end)\t\($state)"' \
      2>/dev/null || { _cli_error "gh pr list" "unexpected output"; return 1; }
  fi
}

# PR/MR details are fetched once per number: pr_preview calls cli_pr_view then
# cli_pr_diff_stat in the same process, and both read this cache.
_CLI_PR_NUM=""
_CLI_PR_JSON=""
_CLI_PR_RC=1

_cli_pr_fetch() {
  local num="$1"
  if [[ -n "$_CLI_PR_NUM" && "$_CLI_PR_NUM" == "$num" ]]; then
    return "$_CLI_PR_RC"
  fi
  _CLI_PR_NUM="$num"
  if [[ "$(detect_platform)" == "gitlab" ]]; then
    _CLI_PR_JSON=$(_cli_run glab mr view "$num" --output json)
  else
    _CLI_PR_JSON=$(_cli_run gh pr view "$num" --json title,body,labels,reviewDecision,additions,deletions,changedFiles,files)
  fi
  _CLI_PR_RC=$?
  return "$_CLI_PR_RC"
}

cli_pr_view() {
  local num
  num=$(cli_bare_num "$1")
  _cli_need_jq || return 1
  _cli_pr_fetch "$num" || return 1
  if [[ "$(detect_platform)" == "gitlab" ]]; then
    printf '%s\n' "$_CLI_PR_JSON" | jq -r "$_CLI_JQ_DEFS"'
      (.labels | labels) as $l
      | "Title: \(.title | clean)\n\nStats: \(.changes_count // "?") changed files\n\nLabels: \(if ($l | length) > 0 then ($l | join(", ")) else "none" end)\n\nState: \(.state | clean)\n\nPipeline: \(.head_pipeline.status // "none" | clean)\n\n" + (.description | desc(500))'
  else
    printf '%s\n' "$_CLI_PR_JSON" | jq -r "$_CLI_JQ_DEFS"'
      (.labels | labels) as $l
      | (.reviewDecision // "") as $r
      | (if $r == "" then "none"
         elif $r == "APPROVED" then "approved"
         elif $r == "CHANGES_REQUESTED" then "changes requested"
         elif $r == "REVIEW_REQUIRED" then "review required"
         else ($r | clean | ascii_downcase) end) as $review
      | "Title: \(.title | clean)\n\nStats: +\(.additions // 0) -\(.deletions // 0) (\(.changedFiles // 0) files)\n\nLabels: \(if ($l | length) > 0 then ($l | join(", ")) else "none" end)\n\nReview: \($review)\n\n" + (.body | desc(500))'
  fi
}

# Changed files of a PR/MR (20 lines max)
cli_pr_diff_stat() {
  local num
  num=$(cli_bare_num "$1")
  _cli_need_jq || return 1
  _cli_pr_fetch "$num" || return 1
  if [[ "$(detect_platform)" == "gitlab" ]]; then
    local base_sha head_sha target_branch source_branch
    {
      read -r base_sha
      read -r head_sha
      read -r target_branch
      read -r source_branch
    } <<< "$(printf '%s\n' "$_CLI_PR_JSON" | jq -r '.diff_refs.base_sha // "", .diff_refs.head_sha // "", .target_branch // "", .source_branch // ""' 2>/dev/null)"
    local width="${FZF_PREVIEW_COLUMNS:-80}"
    [[ "$width" =~ ^[0-9]+$ ]] || width=80
    # Exact diff from local objects when they are there, then the API, then
    # the (maybe stale) remote-tracking branches
    if [[ -n "$base_sha" && -n "$head_sha" ]] \
        && git cat-file -e "$base_sha^{commit}" 2>/dev/null \
        && git cat-file -e "$head_sha^{commit}" 2>/dev/null; then
      git diff --stat="$width" "$base_sha" "$head_sha" 2>/dev/null | head -20
      return 0
    fi
    local diffs=""
    [[ "$num" =~ ^[0-9]+$ ]] && diffs=$(glab api "projects/:id/merge_requests/$num/diffs?per_page=20" 2>/dev/null | \
      jq -r "$_CLI_JQ_DEFS"'
        if type == "array" then .[] else empty end
        | (.diff // "" | split("\n")) as $lines
        | ([$lines[] | select(startswith("+"))] | length) as $add
        | ([$lines[] | select(startswith("-"))] | length) as $del
        | "\("+\($add)" | lpad(6)) \("-\($del)" | lpad(6))  \(.new_path | clean)"' 2>/dev/null)
    if [[ -n "$diffs" ]]; then
      printf '%s\n' "$diffs"
    elif [[ -n "$target_branch" && -n "$source_branch" ]]; then
      git diff --stat="$width" "origin/$target_branch...origin/$source_branch" 2>/dev/null | head -20
    fi
  else
    printf '%s\n' "$_CLI_PR_JSON" | jq -r "$_CLI_JQ_DEFS"'
      (.files // []) as $f
      | (.changedFiles // ($f | length)) as $total
      | ($f[0:20][] | "\("+\(.additions // 0)" | lpad(6)) \("-\(.deletions // 0)" | lpad(6))  \(.path | clean)"),
        (if $total > 20 then "  ... \($total - 20) more files" else empty end)'
  fi
}

cli_issue_list() {
  local platform=$(detect_platform)
  local limit json
  _cli_need_jq || return 1
  limit=$(_cli_list_limit "$platform")

  if [[ "$platform" == "gitlab" ]]; then
    json=$(_cli_run glab issue list --per-page "$limit" --output json) || return 1
    printf '%s\n' "$json" | jq -r "$_CLI_JQ_DEFS"'
      .[] |
        (.labels | labels) as $l
        | (if ($l | length) > 0 then ($l | join(","))[0:15] else "-" end) as $labels
        | "#\(.iid)\t\(.title | clean | .[0:50])\t@\(.author.username // "ghost" | clean)\t\($labels)"' \
      2>/dev/null || { _cli_error "glab issue list" "unexpected output"; return 1; }
  else
    json=$(_cli_run gh issue list --limit "$limit" --json number,title,author,labels) || return 1
    printf '%s\n' "$json" | jq -r "$_CLI_JQ_DEFS"'
      .[] |
        (.labels | labels) as $l
        | (if ($l | length) > 0 then ($l | join(","))[0:15] else "-" end) as $labels
        | "#\(.number)\t\(.title | clean | .[0:50])\t@\(.author.login // "ghost" | clean)\t\($labels)"' \
      2>/dev/null || { _cli_error "gh issue list" "unexpected output"; return 1; }
  fi
}

cli_issue_view() {
  local num json
  num=$(cli_bare_num "$1")
  _cli_need_jq || return 1
  if [[ "$(detect_platform)" == "gitlab" ]]; then
    json=$(_cli_run glab issue view "$num" --output json) || return 1
    printf '%s\n' "$json" | jq -r "$_CLI_JQ_DEFS"'
      (.labels | labels) as $l
      | "Title: \(.title | clean)\n\nState: \(.state | clean)\n\nLabels: \(if ($l | length) > 0 then ($l | join(", ")) else "none" end)\n\nComments: \(.user_notes_count // 0)\n\n" + (.description | desc(800))'
  else
    json=$(_cli_run gh issue view "$num" --json title,body,labels,state,comments) || return 1
    printf '%s\n' "$json" | jq -r "$_CLI_JQ_DEFS"'
      (.labels | labels) as $l
      | "Title: \(.title | clean)\n\nState: \(.state | clean)\n\nLabels: \(if ($l | length) > 0 then ($l | join(", ")) else "none" end)\n\nComments: \(.comments // [] | length)\n\n" + (.body | desc(800))'
  fi
}

cli_open_pr_in_browser() {
  local num
  num=$(cli_bare_num "$1")
  if [[ "$(detect_platform)" == "gitlab" ]]; then
    glab mr view "$num" --web >/dev/null 2>&1
  else
    gh pr view "$num" --web >/dev/null 2>&1
  fi
}

cli_open_issue_in_browser() {
  local num
  num=$(cli_bare_num "$1")
  if [[ "$(detect_platform)" == "gitlab" ]]; then
    glab issue view "$num" --web >/dev/null 2>&1
  else
    gh issue view "$num" --web >/dev/null 2>&1
  fi
}

# PR/MR (open, merged or closed) of a branch, or of a number (N, #N, !N),
# for the worktree preview. Prints nothing when there is none or when the
# CLI is unavailable.
cli_pr_status() {
  local branch="$1"
  local platform=$(detect_platform)
  local pr_term=$(get_pr_term)
  local pr_prefix; if [[ "$platform" == "gitlab" ]]; then pr_prefix="!"; else pr_prefix="#"; fi
  has_jq || return 0

  local num="" re_num='^[#!]?[0-9]+$'
  [[ "$branch" =~ $re_num ]] && num=$(cli_bare_num "$branch")

  local info=""
  if [[ "$platform" == "gitlab" ]]; then
    command -v glab &>/dev/null || return 0
    if [[ -n "$num" ]]; then
      info=$(glab mr view "$num" --output json 2>/dev/null | \
        jq -r "$_CLI_JQ_DEFS"'(.state | clean | ascii_downcase), .iid, (.title | clean | .[0:50])' 2>/dev/null)
    else
      # Without --all glab only lists open MRs (newest first)
      info=$(glab mr list --all --source-branch "$branch" --per-page 1 --output json 2>/dev/null | \
        jq -r "$_CLI_JQ_DEFS"'.[0] // empty | (.state | clean | ascii_downcase), .iid, (.title | clean | .[0:50])' 2>/dev/null)
    fi
  else
    command -v gh &>/dev/null || return 0
    info=$(gh pr view "${num:-$branch}" --json state,number,title 2>/dev/null | \
      jq -r "$_CLI_JQ_DEFS"'(.state | clean | ascii_downcase), .number, (.title | clean | .[0:50])' 2>/dev/null)
  fi
  [[ -n "$info" ]] || return 0

  local state number title
  {
    read -r state
    read -r number
    read -r title
  } <<< "$info"
  printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
  case "$state" in
    merged) printf '  \033[32m✓ %s %s%s MERGED\033[0m\n' "$pr_term" "$pr_prefix" "$number" ;;
    closed) printf '  \033[31m✗ %s %s%s CLOSED\033[0m\n' "$pr_term" "$pr_prefix" "$number" ;;
    *)      printf '  \033[34m○ %s %s%s OPEN\033[0m\n' "$pr_term" "$pr_prefix" "$number" ;;
  esac
  printf '  %s\n' "$title"
}

# CLI command helpers for Claude prompts
cli_cmd_issue_view() {
  local num; num=$(cli_bare_num "$1")
  if [[ "$(detect_platform)" == "gitlab" ]]; then echo "glab issue view $num"; else echo "gh issue view $num"; fi
}
cli_cmd_pr_create() {
  if [[ "$(detect_platform)" == "gitlab" ]]; then echo "glab mr create"; else echo "gh pr create"; fi
}
cli_cmd_pr_view() {
  local num; num=$(cli_bare_num "$1")
  if [[ "$(detect_platform)" == "gitlab" ]]; then echo "glab mr view $num"; else echo "gh pr view $num"; fi
}
cli_cmd_pr_diff() {
  local num; num=$(cli_bare_num "$1")
  if [[ "$(detect_platform)" == "gitlab" ]]; then echo "glab mr diff $num"; else echo "gh pr diff $num"; fi
}
