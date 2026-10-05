#!/usr/bin/env bats
# Cross-module contracts: data passed from one lib/ file to another (PR list
# -> menus -> create_from_pr, worktree lines -> previews), and the behaviors
# that span several files (worktree dir, branch cleanup on delete, shell init).
# fzf, gum, gh and claude are stubs; every repo is a throwaway one.

load 'test_helper/common'

bats_require_minimum_version 1.5.0

setup() {
  isolate_home
  unset WT_EDITOR WT_PLATFORM WT_WORKTREE_DIR WT_AUTO_CD WT_FEATURE_PREFIX \
    WT_AUTO_FETCH WT_CLAUDE_MODE WT_LIST_LIMIT FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE \
    _WT_PLATFORM _WT_DEFAULT_BRANCH _WT_CACHE_REPO _WT_FZF_FOOTER
  git config --global user.email t@example.com
  git config --global user.name t
  git config --global init.defaultBranch main
  load_wt
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  # shellcheck disable=SC2034 # read by lib/menus.sh
  SCRIPT_PATH="$WT_ROOT/wt.sh"
  # shellcheck disable=SC2034
  SCRIPT_DIR="$WT_ROOT"

  STUBS="$TMP/stubs"
  mkdir -p "$STUBS"
  export FZF_QUEUE="$TMP/fzf.queue" GUM_LOG="$TMP/gum.log" CONFIRM_QUEUE="$TMP/confirm.queue"
  : > "$FZF_QUEUE"
  : > "$CONFIRM_QUEUE"
  # fzf: each call pops "<key>\t<grep -E pattern>" ("-" or empty queue = Esc)
  cat > "$STUBS/fzf" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == --filter* ]] && exit 0; done
input=$(cat)
n=$(( $(cat "$FZF_QUEUE.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FZF_QUEUE.n"
printf '%s\n' "$@" > "$FZF_QUEUE.args.$n"
line=$(head -1 "$FZF_QUEUE"); tail -n +2 "$FZF_QUEUE" > "$FZF_QUEUE.tmp"; mv "$FZF_QUEUE.tmp" "$FZF_QUEUE"
key="${line%%$'\t'*}"; pat="${line#*$'\t'}"
[[ -z "$line" || "$pat" == "-" ]] && exit 130
for a in "$@"; do [[ "$a" == --expect* ]] && { printf '%s\n' "$key"; break; }; done
[[ -n "$pat" ]] && printf '%s\n' "$input" | grep -E -- "$pat"
exit 0
EOF
  # gum: input echoes its arguments to $GUM_LOG and answers $GUM_INPUT,
  # confirm pops y/n from $CONFIRM_QUEUE (empty = no) and logs its prompt
  cat > "$STUBS/gum" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  input) printf '%s\n' "$*" >> "$GUM_LOG"; printf '%s\n' "${GUM_INPUT:-}"; exit "${GUM_INPUT_RC:-0}" ;;
  confirm)
    printf 'confirm: %s\n' "${!#}" >> "$GUM_LOG"
    a=$(head -1 "$CONFIRM_QUEUE"); tail -n +2 "$CONFIRM_QUEUE" > "$CONFIRM_QUEUE.tmp"; mv "$CONFIRM_QUEUE.tmp" "$CONFIRM_QUEUE"
    [[ "$a" == y ]] ;;
  spin) while [[ "$1" != "--" ]]; do shift; done; shift; "$@" ;;
  *) shift; printf '%s\n' "$*" >&2 ;;
esac
EOF
  chmod +x "$STUBS/fzf" "$STUBS/gum"
  export PATH="$STUBS:$PATH"
}

# Main repo $TMP/proj (one commit on main) with an origin, cwd = main repo
make_proj() {
  git init -q --bare "$TMP/remote.git"
  make_git_repo "$TMP/proj" >/dev/null
  git -C "$TMP/proj" remote add origin "$TMP/remote.git"
  git -C "$TMP/proj" push -q -u origin main
  git -C "$TMP/proj" fetch -q origin
  git -C "$TMP/proj" remote set-head origin main >/dev/null
  cd "$TMP/proj" || return 1
  MAIN_REPO="$TMP/proj"
  # shellcheck disable=SC2034
  REPO_NAME="proj"
}

confirms() {
  printf '%s\n' "$@" > "$CONFIRM_QUEUE"
}

fzf_answers() {
  printf '%b\n' "$@" > "$FZF_QUEUE"
}

# =============================================================================
# ui_input / settings
# =============================================================================

@test "ui_input: the 3rd argument pre-fills the field (gum --value)" {
  export GUM_INPUT="kept"
  run ui_input "Feature prefix:" "feature/" "ticket/"
  assert_success
  assert_output "kept"
  run cat "$GUM_LOG"
  assert_output --partial "--value ticket/"
  : > "$GUM_LOG"
  run ui_input "Branch name:" "feature/..."
  refute_output --partial "--value"
  run cat "$GUM_LOG"
  refute_output --partial "--value"
}

@test "preferences wizard: the platform guess only looks at the remote host" {
  make_git_repo "$TMP/r" >/dev/null
  git -C "$TMP/r" remote add origin git@github.com:acme/gitlab-ci-templates.git
  cd "$TMP/r"
  MAIN_REPO="$TMP/r"
  export WT_CONFIG_FILE="$TMP/cfg"
  fzf_answers 'ctrl-s\t' 'ctrl-s\t'
  sleep() { :; }
  run run_preferences_wizard --standalone
  run cat "$FZF_QUEUE.args.2"
  assert_output --partial "Detected for this repo: github"

  git -C "$TMP/r" remote set-url origin https://gitlab.example.com/acme/app.git
  rm -f "$FZF_QUEUE.n"
  fzf_answers 'ctrl-s\t' 'ctrl-s\t'
  run run_preferences_wizard --standalone
  run cat "$FZF_QUEUE.args.2"
  assert_output --partial "Detected for this repo: gitlab"
}

# =============================================================================
# Worktree directory (core.sh, git.sh and stash.sh agree)
# =============================================================================

@test "get_worktree_base_dir: a relative WT_WORKTREE_DIR is taken from the main repo's parent" {
  MAIN_REPO="/tmp/projects/myrepo"
  WT_WORKTREE_DIR="wts"
  run get_worktree_base_dir
  assert_output "/tmp/projects/wts"
  WT_WORKTREE_DIR="./wts/"
  run get_worktree_base_dir
  assert_output "/tmp/projects/wts/"
  WT_WORKTREE_DIR="."
  run get_worktree_base_dir
  assert_output "/tmp/projects"
  WT_WORKTREE_DIR="/abs/wts"
  run get_worktree_base_dir
  assert_output "/abs/wts"
}

@test "stash worktree: same folder rules as the other creations (relative dir, -2 suffix)" {
  make_proj
  git worktree add -q -b feat "$TMP/proj-feat"
  WT_WORKTREE_DIR="wts"
  mkdir -p "$TMP/wts/proj-wip"   # folder already taken
  cd "$TMP/proj-feat"
  echo x > f.txt
  git stash push -q -u -m wip
  export GUM_INPUT="wip"
  confirms n
  run --separate-stderr _stash_run worktree "$(git rev-parse 'stash@{0}')"
  assert_success
  assert_output "$TMP/wts/proj-wip-2"
  [[ -f "$TMP/wts/proj-wip-2/f.txt" ]] || false
  # nothing created inside the worktree wt was started from
  run git -C "$TMP/proj-feat" status --porcelain
  assert_output ""
}

# =============================================================================
# PR list (cli.sh) -> menus.sh -> create_from_pr (git.sh)
# =============================================================================

# gh stub: auth ok, `pr list` answers $GH_PR_JSON, `api user` answers "me"
stub_gh_prs() {
  cat > "$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth token"|"auth status") exit 0 ;;
  "api user") echo me ;;
  "pr list") cat "$GH_PR_JSON" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$STUBS/gh"
  export GH_PR_JSON="$TMP/prs.json"
  cat > "$GH_PR_JSON" <<'EOF'
[
 {"number": 42, "title": "Fork\tPR \\c title", "headRefName": "main", "author": {"login": "ext"},
  "reviewDecision": "", "isDraft": false, "reviewRequests": [], "isCrossRepository": true,
  "statusCheckRollup": [{"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "FAILURE"}]},
 {"number": 7, "title": "Same repo", "headRefName": "feat/x", "author": {"login": "me"},
  "reviewDecision": "APPROVED", "isDraft": false, "reviewRequests": [], "isCrossRepository": false,
  "statusCheckRollup": [{"__typename": "StatusContext", "state": "SUCCESS"}]}
]
EOF
}

_review() {
  has_claude() { return 0; }
  read() { if [[ $# -eq 1 && "$1" == "-r" ]]; then return 0; fi; builtin read "$@"; }
  create_from_pr() { printf '%s\n' "$@" > "$TMP/create_from_pr.args"; echo "$TMP/review-wt"; }
  menu_review_pr
}

@test "contract: cli_pr_list fields reach create_from_pr (branch, bare number, cross flag)" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  make_proj
  stub_gh_prs
  fzf_answers '\t^#7' '\t^Just'
  run --separate-stderr _review
  assert_success
  assert_output "$TMP/review-wt"
  run cat "$TMP/create_from_pr.args"
  assert_output "$(printf 'feat/x\n7\n0')"
}

@test "contract: a fork PR in full auto mode asks first, No creates nothing" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  make_proj
  stub_gh_prs
  # Fix CI on #42 (fork, CI failed), refuse, then Esc out of the menus
  fzf_answers '\t^#42' '\tFix CI' '\t-' '\t-'
  confirms n
  run --separate-stderr _review
  assert_failure
  assert_output ""
  [[ ! -e "$TMP/create_from_pr.args" ]] || false
  run cat "$GUM_LOG"
  assert_output --partial "confirm: Run Claude in full auto mode on it anyway?"

  # Accepted: the marker and the cross flag go through
  rm -f "$FZF_QUEUE.n"
  fzf_answers '\t^#42' '\tFix CI'
  confirms y
  run --separate-stderr _review
  assert_success
  assert_line "CLAUDE:ci-fix:42"
  run cat "$TMP/create_from_pr.args"
  assert_output "$(printf 'main\n42\n1')"
}

@test "contract: a same-repo PR in forced mode is not asked again" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  make_proj
  stub_gh_prs
  export WT_CLAUDE_MODE=forced
  fzf_answers '\t^#7' '\t^Review'
  run --separate-stderr _review
  assert_success
  assert_line "CLAUDE:pr-review:7:forced"
  [[ ! -s "$GUM_LOG" ]] || false
}

# =============================================================================
# Worktree lines (git.sh) -> previews (wt.sh)
# =============================================================================

@test "contract: field 2 of a worktree line feeds --worktree-preview, spaces included" {
  make_proj
  git worktree add -q -b "feat/space" "$TMP/proj feat"
  local line path
  line=$(format_all_worktrees | grep 'feat/space')
  path=$(printf '%s\n' "$line" | cut -f2)
  assert_equal "$path" "$TMP/proj feat"
  run bash "$WT_ROOT/wt.sh" --worktree-preview "$path"
  assert_success
  assert_output --partial "Branch: feat/space"
  assert_output --partial "never pushed"
}

# =============================================================================
# Delete: branches left behind
# =============================================================================

_delete() {
  read() { if [[ $# -eq 1 && "$1" == "-r" ]]; then return 0; fi; builtin read "$@"; }
  action_delete_worktrees
}

@test "delete: merged branches and covered temp/* copies are offered, unmerged work is kept" {
  make_proj
  git worktree add -q -b feat/done "$TMP/proj-done"
  git worktree add -q -b feat/wip "$TMP/proj-wip"
  echo wip > "$TMP/proj-wip/wip.txt"
  git -C "$TMP/proj-wip" add wip.txt
  git -C "$TMP/proj-wip" commit -q -m "wip work"
  git worktree add -q -b temp/feat-wip-1 "$TMP/proj-copy" feat/wip
  fzf_answers '\tdone|wip|temp'
  confirms y y
  run --separate-stderr _delete
  assert_success
  assert_output "$TMP/proj"
  run git branch --format='%(refname:short)'
  assert_output "$(printf 'feat/wip\nmain')"
  run cat "$GUM_LOG"
  assert_output --partial "confirm: Also delete 2 branch(es)?"
}

@test "delete: answering No keeps every branch" {
  make_proj
  git worktree add -q -b feat/done "$TMP/proj-done"
  fzf_answers '\tdone'
  confirms y n
  run --separate-stderr _delete
  assert_success
  run git show-ref --verify --quiet refs/heads/feat/done
  assert_success
}

@test "delete: no question when no branch can go" {
  make_proj
  git worktree add -q -b feat/wip "$TMP/proj-wip"
  echo wip > "$TMP/proj-wip/wip.txt"
  git -C "$TMP/proj-wip" add wip.txt
  git -C "$TMP/proj-wip" commit -q -m "wip work"
  fzf_answers '\twip'
  confirms y
  run --separate-stderr _delete
  assert_success
  run grep -c 'confirm:' "$GUM_LOG"
  assert_output "1"
}

# =============================================================================
# Prompts and git.sh branch names
# =============================================================================

@test "prompts: pushes match the branches wt creates (no upstream, fork branch names)" {
  export WT_PLATFORM=github
  run generate_prompt issue-auto 7
  assert_output --partial "git push -u origin HEAD"
  run generate_prompt ci-fix 42
  assert_output --partial 'gh pr view 42 --json headRefName'
  refute_output --partial 'git branch --show-current'
  assert_output --partial "HEAD:<head-branch>"
  export WT_PLATFORM=gitlab
  _WT_PLATFORM=""
  run generate_prompt ci-fix 12
  refute_output --partial 'git branch --show-current'
  assert_output --partial "HEAD:<source_branch>"
}

# =============================================================================
# Entry point
# =============================================================================

@test "--setup: a packaged copy (Homebrew Cellar) is never symlinked" {
  local cellar="$TMP/Cellar/worktigre/9.9.9"
  mkdir -p "$cellar"
  cp -R "$WT_ROOT/wt.sh" "$WT_ROOT/lib" "$cellar/"
  local tools="$TMP/tools"
  mkdir -p "$tools"
  local t
  for t in git fzf gum jq; do
    ln -sf "$(command -v "$t")" "$tools/$t"
  done
  SHELL=/bin/zsh PATH="$tools:/usr/bin:/bin" run bash "$cellar/wt.sh" --setup
  assert_failure
  assert_output --partial "brew shellenv"
  [[ ! -e "$HOME/.local/bin/wt-core" && ! -e "$HOME/.zshrc" ]] || false
}

@test "--shell-init: zsh registers the completion after compinit, bash and plain zsh are untouched" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  run zsh -f -c 'autoload -Uz compinit; compinit -u -d "$2/zcomp"; eval "$(bash "$1" --shell-init)"; print -r -- "$_comps[wt] $_comps[wt-core] ${_wt_comp-unset}"' _ "$WT_ROOT/wt.sh" "$TMP"
  assert_success
  assert_output "_wt _wt unset"
  run zsh -f -c 'eval "$(bash "$1" --shell-init)" && whence -w wt' _ "$WT_ROOT/wt.sh"
  assert_success
  assert_output "wt: function"
  run bash -c 'eval "$(bash "$1" --shell-init)" && type -t wt && echo "${_wt_comp-unset}"' _ "$WT_ROOT/wt.sh"
  assert_success
  assert_output "$(printf 'function\nunset')"
}

@test "no em dash in the tracked sources (README.md and CLAUDE.md aside)" {
  cd "$WT_ROOT"
  run bash -c "git ls-files -co --exclude-standard | grep -v -E '^(README.md|CLAUDE.md)$' | grep -v -E '^tests/(bats|test_helper/bats-)' | while IFS= read -r f; do [[ -f \"\$f\" ]] && grep -l \$'\\xe2\\x80\\x94' \"\$f\"; done"
  assert_output ""
}
