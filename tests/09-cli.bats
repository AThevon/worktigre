#!/usr/bin/env bats
# lib/cli.sh and lib/prompts.sh, with gh/glab replaced by stubs

load 'test_helper/common'

bats_require_minimum_version 1.5.0

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  load_wt
  setup_config
  unset WT_LIST_LIMIT
  export WT_PLATFORM="github"
  _WT_PLATFORM=""

  STUB_DIR="$BATS_TEST_TMPDIR/stubs"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR" "$STUB_BIN"
  export STUB_DIR
  _make_stub gh
  _make_stub glab
  export PATH="$STUB_BIN:$PATH"
  cd "$BATS_TEST_TMPDIR" || return 1
}

teardown() {
  teardown_config
  unset WT_PLATFORM WT_LIST_LIMIT
}

# Stub answering from $STUB_DIR/<tool>_<arg1>_<arg2>.{out,err,rc}
# (non alphanumeric chars become "_") and logging every call to calls.log
_make_stub() {
  cat > "$STUB_BIN/$1" <<'EOF'
#!/usr/bin/env bash
name=${0##*/}
printf '%s\n' "$name $*" >> "$STUB_DIR/calls.log"
key=$(printf '%s_%s_%s' "$name" "$1" "$2" | tr -c 'A-Za-z0-9_' '_')
[[ -f "$STUB_DIR/$key.err" ]] && cat "$STUB_DIR/$key.err" >&2
[[ -f "$STUB_DIR/$key.out" ]] && cat "$STUB_DIR/$key.out"
rc=0
[[ -f "$STUB_DIR/$key.rc" ]] && rc=$(cat "$STUB_DIR/$key.rc")
exit "$rc"
EOF
  chmod +x "$STUB_BIN/$1"
}

# stub_reply <key> <stdout> [rc] [stderr]
stub_reply() {
  printf '%s\n' "$2" > "$STUB_DIR/$1.out"
  [[ -n "${3:-}" ]] && printf '%s\n' "$3" > "$STUB_DIR/$1.rc"
  [[ -n "${4:-}" ]] && printf '%s\n' "$4" > "$STUB_DIR/$1.err"
  return 0
}

use_gitlab() {
  export WT_PLATFORM="gitlab"
  _WT_PLATFORM=""
}

# ---------------------------------------------------------------------------
# Numbers
# ---------------------------------------------------------------------------

@test "cli_bare_num: accepts N, #N, !N and surrounding spaces" {
  run cli_bare_num "12"
  assert_output "12"
  run cli_bare_num "#12"
  assert_output "12"
  run cli_bare_num "!12"
  assert_output "12"
  run cli_bare_num " #7 "
  assert_output "7"
}

# ---------------------------------------------------------------------------
# PR list (GitHub)
# ---------------------------------------------------------------------------

GH_PRS='[
 {"number":1,"title":"Green","headRefName":"feat/a","author":{"login":"alice"},"reviewDecision":"APPROVED","isDraft":false,"isCrossRepository":false,"reviewRequests":[],
  "statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"}]},
 {"number":2,"title":"Statuses green","headRefName":"b","author":{"login":"a"},"reviewDecision":"","isDraft":false,"isCrossRepository":false,"reviewRequests":[],
  "statusCheckRollup":[{"__typename":"StatusContext","context":"ci/jenkins","state":"SUCCESS"},{"__typename":"StatusContext","context":"vercel","state":"SUCCESS"}]},
 {"number":3,"title":"Status failure","headRefName":"c","author":{"login":"a"},"reviewDecision":"","isDraft":false,"isCrossRepository":false,"reviewRequests":[],
  "statusCheckRollup":[{"__typename":"StatusContext","state":"FAILURE"},{"__typename":"StatusContext","state":"SUCCESS"}]},
 {"number":4,"title":"Status error","headRefName":"d","author":{"login":"a"},"reviewDecision":"","isDraft":false,"isCrossRepository":false,"reviewRequests":[],
  "statusCheckRollup":[{"__typename":"StatusContext","state":"ERROR"}]},
 {"number":5,"title":"Status pending","headRefName":"e","author":{"login":"a"},"reviewDecision":"","isDraft":false,"isCrossRepository":false,"reviewRequests":[],
  "statusCheckRollup":[{"__typename":"StatusContext","state":"PENDING"},{"__typename":"StatusContext","state":"SUCCESS"}]},
 {"number":6,"title":"Timed out","headRefName":"f","author":{"login":"a"},"reviewDecision":"","isDraft":false,"isCrossRepository":false,"reviewRequests":[],
  "statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"TIMED_OUT"}]},
 {"number":7,"title":"Cancelled","headRefName":"g","author":{"login":"a"},"reviewDecision":"","isDraft":false,"isCrossRepository":false,"reviewRequests":[],
  "statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"CANCELLED"}]},
 {"number":8,"title":"Action required","headRefName":"h","author":{"login":"a"},"reviewDecision":"","isDraft":false,"isCrossRepository":false,"reviewRequests":[],
  "statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"ACTION_REQUIRED"}]},
 {"number":9,"title":"Startup failure","headRefName":"i","author":{"login":"a"},"reviewDecision":"","isDraft":false,"isCrossRepository":false,"reviewRequests":[],
  "statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"STARTUP_FAILURE"}]},
 {"number":10,"title":"Running","headRefName":"j","author":{"login":"a"},"reviewDecision":"","isDraft":false,"isCrossRepository":false,"reviewRequests":[],
  "statusCheckRollup":[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":""},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]},
 {"number":11,"title":"No checks","headRefName":"k","author":{"login":"a"},"reviewDecision":"","isDraft":false,"isCrossRepository":false,"reviewRequests":[],
  "statusCheckRollup":[]},
 {"number":12,"title":"Draft","headRefName":"l","author":{"login":"a"},"reviewDecision":"","isDraft":true,"isCrossRepository":false,"reviewRequests":[],
  "statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]},
 {"number":13,"title":"Expected","headRefName":"m","author":{"login":"a"},"reviewDecision":"","isDraft":false,"isCrossRepository":false,"reviewRequests":[],
  "statusCheckRollup":[{"__typename":"StatusContext","state":"EXPECTED"}]},
 {"number":14,"title":"Fork, failing while running","headRefName":"main","author":{"login":"stranger"},"reviewDecision":"REVIEW_REQUIRED","isDraft":false,"isCrossRepository":true,"reviewRequests":[{"login":"me"}],
  "statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"CheckRun","status":"QUEUED","conclusion":""}]},
 {"number":15,"title":"Tab\there","headRefName":"n","author":null,"reviewDecision":null,"isDraft":false,"isCrossRepository":false,"reviewRequests":null,
  "statusCheckRollup":null}
]'

@test "cli_pr_list (github): CI state covers CheckRun and StatusContext" {
  stub_reply gh_pr_list "$GH_PRS"
  run --separate-stderr cli_pr_list
  assert_success
  run bash -c 'cut -f1,7 <<< "$1"' _ "$output"
  assert_output "$(printf '%s\n' \
    $'#1\tok' $'#2\tok' $'#3\tfail' $'#4\tfail' $'#5\tpending' \
    $'#6\tfail' $'#7\tfail' $'#8\tfail' $'#9\tfail' $'#10\tpending' \
    $'#11\tnone' $'#12\tdraft' $'#13\tpending' $'#14\tfail' $'#15\tnone')"
}

@test "cli_pr_list (github): 7 TAB fields, cross-repo flag, sanitized title" {
  stub_reply gh_api_user "me"
  stub_reply gh_pr_list "$GH_PRS"
  run --separate-stderr cli_pr_list
  assert_success
  local line14 line15
  line14=$(grep $'^#14\t' <<< "$output")
  line15=$(grep $'^#15\t' <<< "$output")
  [[ "$(awk -F'\t' '{print NF}' <<< "$output" | sort -u)" == "7" ]]
  [[ "$(cut -f5,6 <<< "$line14")" == $'main\t1' ]]
  [[ "$(cut -f6 <<< "$line15")" == "0" ]]
  [[ "$(cut -f3 <<< "$line15")" == "Tab here" ]]
  [[ "$(cut -f4 <<< "$line15")" == *"@ghost"* ]]
  # requested reviewer = current user
  [[ "$(cut -f2 <<< "$line14")" == *"◀"* ]]
  [[ "$(cut -f2 <<< "$line14")" == *"[fail]"* ]]
  grep -q 'isCrossRepository' "$STUB_DIR/calls.log"
}

@test "cli_pr_list (github): empty list is success with no output" {
  stub_reply gh_pr_list "[]"
  run --separate-stderr cli_pr_list
  assert_success
  assert_output ""
}

@test "cli_pr_list (github): gh failure returns non-zero with a short message" {
  stub_reply gh_pr_list "" 1 "none of the git remotes configured for this repository point to a known GitHub host. To tell gh about a new GitHub host, please use \`gh auth login\`"
  run --separate-stderr cli_pr_list
  assert_failure
  assert_output ""
  [[ "$stderr" == *"gh pr list: none of the git remotes configured"* ]]
  [[ "${#stderr_lines[@]}" -eq 1 ]]
}

@test "cli_pr_list: invalid output from gh is an error" {
  stub_reply gh_pr_list "not json"
  run --separate-stderr cli_pr_list
  assert_failure
  [[ "$stderr" == *"gh pr list"* ]]
}

@test "cli_pr_list: jq missing is reported" {
  has_jq() { return 1; }
  run --separate-stderr cli_pr_list
  assert_failure
  [[ "$stderr" == *"jq is required"* ]]
}

@test "cli_pr_list: WT_LIST_LIMIT is sanitized" {
  stub_reply gh_pr_list "[]"
  WT_LIST_LIMIT=0 cli_pr_list
  WT_LIST_LIMIT=abc cli_pr_list
  WT_LIST_LIMIT=08 cli_pr_list
  WT_LIST_LIMIT=250 cli_pr_list
  run grep -o -- '--limit [0-9]*' "$STUB_DIR/calls.log"
  assert_output "$(printf '%s\n' '--limit 20' '--limit 20' '--limit 8' '--limit 250')"
}

# ---------------------------------------------------------------------------
# MR list (GitLab)
# ---------------------------------------------------------------------------

GL_MRS='[
 {"iid":12,"title":"Fix pipeline","draft":false,"sha":"aaa","source_branch":"fix/pipe","source_project_id":1,"target_project_id":1,"author":{"username":"bob"}},
 {"iid":13,"title":"From fork","draft":false,"sha":"bbb","source_branch":"main","source_project_id":2,"target_project_id":1,"author":{"username":"eve"}},
 {"iid":14,"title":"WIP","draft":true,"sha":"ccc","source_branch":"wip","source_project_id":1,"target_project_id":1,"author":{"username":"bob"}},
 {"iid":15,"title":"No pipeline","draft":false,"sha":"ddd","source_branch":"nopipe","source_project_id":1,"target_project_id":1,"author":{"username":"bob"}},
 {"iid":16,"title":"Running","draft":false,"sha":"eee","source_branch":"feat/run","source_project_id":1,"target_project_id":1,"author":{"username":"bob"}}
]'
GL_PIPELINES='[
 {"id":105,"sha":"eee","ref":"feat/run","status":"running"},
 {"id":104,"sha":"zzz","ref":"refs/merge-requests/13/merge","status":"success"},
 {"id":103,"sha":"aaa","ref":"fix/pipe","status":"failed"},
 {"id":102,"sha":"aaa","ref":"fix/pipe","status":"success"},
 {"id":101,"sha":"ccc","ref":"wip","status":"failed"}
]'

@test "cli_pr_list (gitlab): !N refs, cross-repo and CI state from project pipelines" {
  use_gitlab
  stub_reply glab_mr_list "$GL_MRS"
  stub_reply glab_api_projects__id_pipelines_per_page_100 "$GL_PIPELINES"
  run --separate-stderr cli_pr_list
  assert_success
  run bash -c 'cut -f1,5,6,7 <<< "$1"' _ "$output"
  assert_output "$(printf '%s\n' \
    $'!12\tfix/pipe\t0\tfail' \
    $'!13\tmain\t1\tok' \
    $'!14\twip\t0\tdraft' \
    $'!15\tnopipe\t0\tnone' \
    $'!16\tfeat/run\t0\tpending')"
}

@test "cli_pr_list (gitlab): pipelines unavailable gives [--], list still works" {
  use_gitlab
  stub_reply glab_mr_list "$GL_MRS"
  stub_reply glab_api_projects__id_pipelines_per_page_100 '{"message":"403 Forbidden"}' 1
  run --separate-stderr cli_pr_list
  assert_success
  run bash -c 'cut -f7 <<< "$1" | sort -u' _ "$output"
  assert_output "$(printf '%s\n' draft none)"
}

@test "cli_pr_list (gitlab): per-page capped at 100, glab failure reported" {
  use_gitlab
  stub_reply glab_mr_list "" 1 "glab: 401 Unauthorized"
  WT_LIST_LIMIT=500 run --separate-stderr cli_pr_list
  assert_failure
  [[ "$stderr" == *"glab mr list: glab: 401 Unauthorized"* ]]
  grep -q -- '--per-page 100' "$STUB_DIR/calls.log"
}

# ---------------------------------------------------------------------------
# PR preview
# ---------------------------------------------------------------------------

GH_PR_VIEW='{"title":"Rework naming","body":"","labels":[],"reviewDecision":"","additions":12,"deletions":3,"changedFiles":2,
 "files":[{"path":"README.md","additions":10,"deletions":2,"changeType":"MODIFIED"},{"path":"lib/new.sh","additions":2,"deletions":1,"changeType":"ADDED"}]}'

@test "cli_pr_view + cli_pr_diff_stat (github): one request, '#N' accepted, empty fields handled" {
  stub_reply gh_pr_view "$GH_PR_VIEW"
  local out
  out=$(cli_pr_view '#24'; cli_pr_diff_stat '#24')
  [[ "$out" == *"Title: Rework naming"* ]]
  [[ "$out" == *"Review: none"* ]]
  [[ "$out" == *"No description"* ]]
  [[ "$out" == *"Labels: none"* ]]
  [[ "$out" == *"   +10     -2  README.md"* ]]
  [[ "$out" == *"    +2     -1  lib/new.sh"* ]]
  run cat "$STUB_DIR/calls.log"
  assert_output --partial "gh pr view 24 --json"
  refute_output --partial "gh pr diff"
  [[ "$(grep -c '^gh pr view' "$STUB_DIR/calls.log")" -eq 1 ]]
}

@test "cli_pr_view (github): review decision and CRLF body are readable" {
  stub_reply gh_pr_view '{"title":"T","body":"line one\r\nline two","labels":[{"name":"bug"}],"reviewDecision":"CHANGES_REQUESTED","additions":1,"deletions":0,"changedFiles":1,"files":[]}'
  run cli_pr_view 5
  assert_success
  assert_output --partial "Review: changes requested"
  assert_output --partial "Labels: bug"
  assert_output --partial $'Description:\nline one\nline two'
  refute_output --partial $'\r'
}

@test "cli_pr_diff_stat (github): more than 20 files is summarized" {
  local files
  files=$(jq -cn '[range(25) | {path: "f\(.)", additions: 1, deletions: 0}]')
  stub_reply gh_pr_view "{\"changedFiles\":25,\"files\":$files}"
  run cli_pr_diff_stat 3
  assert_success
  [[ "${#lines[@]}" -eq 21 ]]
  assert_output --partial "... 5 more files"
}

@test "cli_pr_view (github): gh failure is shown once, not as an empty preview" {
  stub_reply gh_pr_view "" 1 "GraphQL: Could not resolve to a PullRequest with the number of 999."
  _preview() { cli_pr_view "$1"; cli_pr_diff_stat "$1"; }
  run --separate-stderr _preview 999
  [[ "$stderr" == *"gh pr view: GraphQL: Could not resolve"* ]]
  [[ "${#stderr_lines[@]}" -eq 1 ]]
}

GL_MR_VIEW='{"iid":12,"title":"Fix pipeline","description":"","labels":["ci"],"state":"opened","changes_count":"2",
 "head_pipeline":{"id":103,"status":"failed"},"target_branch":"main","source_branch":"fix/pipe",
 "diff_refs":{"base_sha":"1111111111111111111111111111111111111111","head_sha":"2222222222222222222222222222222222222222"}}'

@test "cli_pr_view + cli_pr_diff_stat (gitlab): '#N' becomes N, files from the API" {
  use_gitlab
  stub_reply glab_mr_view "$GL_MR_VIEW"
  stub_reply glab_api_projects__id_merge_requests_12_diffs_per_page_20 '[{"new_path":"a.txt","diff":"@@ -1 +1,2 @@\n-old\n+new\n+more\n"}]'
  local out
  out=$(cli_pr_view '#12'; cli_pr_diff_stat '#12')
  [[ "$out" == *"Title: Fix pipeline"* ]]
  [[ "$out" == *"No description"* ]]
  [[ "$out" == *"Pipeline: failed"* ]]
  [[ "$out" == *"    +2     -1  a.txt"* ]]
  run cat "$STUB_DIR/calls.log"
  assert_output --partial "glab mr view 12 --output json"
  refute_output --partial "#12"
  [[ "$(grep -c '^glab mr view' "$STUB_DIR/calls.log")" -eq 1 ]]
}

@test "cli_pr_diff_stat (gitlab): uses local objects when diff_refs are present" {
  use_gitlab
  git init -q repo && cd repo || return 1
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  echo hi > file.txt && git add file.txt
  git -c user.email=t@t -c user.name=t commit -q -m head
  local base head
  base=$(git rev-parse HEAD~1)
  head=$(git rev-parse HEAD)
  stub_reply glab_mr_view "{\"diff_refs\":{\"base_sha\":\"$base\",\"head_sha\":\"$head\"},\"target_branch\":\"main\",\"source_branch\":\"x\"}"
  run cli_pr_diff_stat '!12'
  assert_success
  assert_output --partial "file.txt"
  run grep -c 'glab api' "$STUB_DIR/calls.log"
  assert_output "0"
}

# ---------------------------------------------------------------------------
# Issues
# ---------------------------------------------------------------------------

@test "cli_issue_list (github): format unchanged, failure reported" {
  stub_reply gh_issue_list '[{"number":3,"title":"Bug","author":{"login":"zoe"},"labels":[{"name":"bug"},{"name":"help wanted"}]}]'
  run --separate-stderr cli_issue_list
  assert_success
  assert_output $'#3\tBug\t@zoe\tbug,help wanted'

  stub_reply gh_issue_list "" 1 "invalid limit: 0"
  run --separate-stderr cli_issue_list
  assert_failure
  [[ "$stderr" == *"gh issue list: invalid limit: 0"* ]]
}

@test "cli_issue_list (gitlab): #iid lines" {
  use_gitlab
  stub_reply glab_issue_list '[{"iid":4,"title":"Crash","author":{"username":"max"},"labels":[]}]'
  run --separate-stderr cli_issue_list
  assert_success
  assert_output $'#4\tCrash\t@max\t-'
}

@test "cli_issue_view: empty or missing description shows 'No description'" {
  stub_reply gh_issue_view '{"title":"T","body":"","labels":[],"state":"OPEN","comments":[]}'
  run cli_issue_view '#3'
  assert_success
  assert_output --partial "No description"
  assert_output --partial "Comments: 0"
  grep -q '^gh issue view 3 ' "$STUB_DIR/calls.log"

  use_gitlab
  stub_reply glab_issue_view '{"title":"T","description":null,"labels":null,"state":"opened","user_notes_count":2}'
  run cli_issue_view '#4'
  assert_success
  assert_output --partial "No description"
  assert_output --partial "Comments: 2"
}

# ---------------------------------------------------------------------------
# Status and browser
# ---------------------------------------------------------------------------

@test "cli_pr_status (gitlab): merged MRs are found (--all)" {
  use_gitlab
  stub_reply glab_mr_list '[{"iid":12,"state":"merged","title":"Done"}]'
  run cli_pr_status "fix/pipe"
  assert_success
  assert_output --partial "MR !12 MERGED"
  assert_output --partial "Done"
  grep -q -- '--all' "$STUB_DIR/calls.log"
}

@test "cli_pr_status: a number (fork review branch) is looked up by number" {
  use_gitlab
  stub_reply glab_mr_view '{"iid":12,"state":"closed","title":"Old"}'
  run cli_pr_status '12'
  assert_output --partial "MR !12 CLOSED"
  grep -q '^glab mr view 12 --output json$' "$STUB_DIR/calls.log"
  run grep -c 'source-branch' "$STUB_DIR/calls.log"
  assert_output "0"

  export WT_PLATFORM="github"
  _WT_PLATFORM=""
  stub_reply gh_pr_view '{"state":"OPEN","number":7,"title":"Fork PR"}'
  run cli_pr_status '#7'
  assert_output --partial "PR #7 OPEN"
  grep -q '^gh pr view 7 --json' "$STUB_DIR/calls.log"
}

@test "cli_pr_status (github): merged PR, nothing when there is no PR" {
  stub_reply gh_pr_view '{"state":"MERGED","number":24,"title":"Rework"}'
  run cli_pr_status "rework"
  assert_output --partial "PR #24 MERGED"

  stub_reply gh_pr_view "" 1 "no pull requests found for branch"
  run --separate-stderr cli_pr_status "nothing"
  assert_success
  assert_output ""
}

@test "cli_open_pr_in_browser / cli_open_issue_in_browser: refs with prefix" {
  use_gitlab
  cli_open_pr_in_browser '!12'
  cli_open_issue_in_browser '#4'
  grep -q '^glab mr view 12 --web$' "$STUB_DIR/calls.log"
  grep -q '^glab issue view 4 --web$' "$STUB_DIR/calls.log"
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

@test "generate_prompt ci-fix (gitlab): MR ref, non-interactive glab commands" {
  use_gitlab
  run generate_prompt ci-fix '!12'
  assert_success
  assert_output --partial "Merge Request !12"
  assert_output --partial "glab mr view 12 --output json"
  assert_output --partial "glab ci trace <job-id>"
  refute_output --partial "Run 'glab ci view'"
  assert_output --partial "untrusted"
}

@test "generate_prompt ci-fix (github): gh pr checks first, security note" {
  run generate_prompt ci-fix '#24'
  assert_success
  assert_output --partial "Pull Request #24"
  assert_output --partial "gh pr checks 24"
  assert_output --partial "untrusted"
  refute_output --partial "##24"
}

@test "generate_prompt issue-auto: security note, 'an MR' on GitLab" {
  run generate_prompt issue-auto 7
  assert_output --partial "untrusted data"
  assert_output --partial "Create a PR with 'gh pr create'"

  use_gitlab
  run generate_prompt issue-auto '#7'
  assert_output --partial "Issue #7"
  assert_output --partial "Create an MR with 'glab mr create'"
  assert_output --partial "glab issue view 7"
}

@test "generate_prompt pr-review / pr-work (gitlab): !N and bare number in commands" {
  use_gitlab
  run generate_prompt pr-review '!12'
  assert_output --partial "Merge Request !12"
  assert_output --partial "glab mr view 12'"
  assert_output --partial "glab mr diff 12'"
  run generate_prompt pr-work 12
  assert_output --partial "Merge Request !12"
}

@test "lib/cli.sh and lib/prompts.sh: no em dash" {
  run grep -l $'\xe2\x80\x94' "$BATS_TEST_DIRNAME/../lib/cli.sh" "$BATS_TEST_DIRNAME/../lib/prompts.sh"
  assert_failure 1
}
