#!/usr/bin/env bats
# Menus (lib/menus.sh): install/preferences wizards, settings, create, PR/issue
# pickers and delete. fzf, gum and gh are replaced by stubs; every fzf call is
# logged (arguments + stdin) and answered from a queue.

load 'test_helper/common'

setup() {
  # Settings from the developer's environment would win over the config file
  unset WT_CLAUDE_MODE WT_PLATFORM WT_WORKTREE_DIR WT_LIST_LIMIT WT_EDITOR WT_FEATURE_PREFIX
  unset WT_AUTO_CD WT_AUTO_FETCH _WT_FZF_FOOTER _WT_PLATFORM
  load_wt
  setup_config
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export HOME="$TMP/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
  git config --global user.email t@example.com
  git config --global user.name t
  git config --global init.defaultBranch main
  SCRIPT_PATH="$BATS_TEST_DIRNAME/../wt.sh"
  SCRIPT_DIR="$BATS_TEST_DIRNAME/.."

  STUBS="$TMP/stubs"
  mkdir -p "$STUBS"
  export FZF_LOG="$TMP/fzf" FZF_QUEUE="$TMP/fzf.queue"
  export GUM_LOG="$TMP/gum.log" GUM_QUEUE="$TMP/gum.queue"
  : > "$FZF_QUEUE"
  : > "$GUM_QUEUE"

  # fzf: each call pops "<key>\t<grep -E pattern>" from $FZF_QUEUE.
  # Pattern "-" (or an empty queue) = Esc. --filter calls (version probe) pass.
  cat > "$STUBS/fzf" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == --filter* ]] && exit 0; done
input=$(cat)
n=$(( $(cat "$FZF_LOG.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FZF_LOG.n"
printf '%s\n' "$@" > "$FZF_LOG.args.$n"
printf '%s\n' "$input" > "$FZF_LOG.stdin.$n"
line=$(head -1 "$FZF_QUEUE"); tail -n +2 "$FZF_QUEUE" > "$FZF_QUEUE.tmp"; mv "$FZF_QUEUE.tmp" "$FZF_QUEUE"
key="${line%%$'\t'*}"; pat="${line#*$'\t'}"
[[ -z "$line" || "$pat" == "-" ]] && exit 130
for a in "$@"; do [[ "$a" == --expect* ]] && { printf '%s\n' "$key"; break; }; done
[[ -n "$pat" ]] && printf '%s\n' "$input" | grep -E -- "$pat"
exit 0
EOF
  # gum: input pops "<rc>\t<value>" from $GUM_QUEUE, confirm uses $GUM_CONFIRM_RC
  cat > "$STUBS/gum" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  confirm) exit "${GUM_CONFIRM_RC:-0}" ;;
  input)
    printf '%s\n' "$*" >> "$GUM_LOG"
    line=$(head -1 "$GUM_QUEUE"); tail -n +2 "$GUM_QUEUE" > "$GUM_QUEUE.tmp"; mv "$GUM_QUEUE.tmp" "$GUM_QUEUE"
    rc="${line%%$'\t'*}"; [[ -z "$line" ]] && rc=1
    [[ "$rc" == 0 ]] && printf '%s\n' "${line#*$'\t'}"
    exit "$rc" ;;
  log|style) shift; printf '%s\n' "$*" >&2 ;;
  spin) while [[ "$1" != "--" ]]; do shift; done; shift; "$@" ;;
esac
EOF
  printf '#!/usr/bin/env bash\n[[ "$1 $2" == "auth status" ]] && exit 0\nexit 0\n' > "$STUBS/gh"
  chmod +x "$STUBS/fzf" "$STUBS/gum" "$STUBS/gh"
  export PATH="$STUBS:$PATH"
}

teardown() {
  teardown_config
}

# Queue fzf answers, one per line: "<key>\t<pattern>"
fzf_answers() {
  printf '%b\n' "$@" > "$FZF_QUEUE"
}

# "Press Enter to continue" reads /dev/tty: make it return at once, keep the
# other reads (loops over lines) working
no_tty_read() {
  read() {
    if [[ $# -eq 1 && "$1" == "-r" ]]; then return 0; fi
    builtin read "$@"
  }
}

gum_answers() {
  printf '%b\n' "$@" > "$GUM_QUEUE"
}

fzf_calls() {
  cat "$FZF_LOG.n" 2>/dev/null || echo 0
}

make_repo() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  [[ -n "${2:-}" ]] && git -C "$dir" remote add origin "$2"
  MAIN_REPO="$dir"
  REPO_NAME=$(basename "$dir")
}

# PR lines in the cli_pr_list format (TAB separated, 7 fields)
fake_prs() {
  printf '#1\t[ok]  \tHandle C:\\temp\\new paths\t@a\tfix/paths\t0\tok\n'
  printf '#2\t[ok]  \tShow [fail] badge \\c escape\t@b\tfeat/badge\t1\tok\n'
  printf '#3\t[fail]  \tBroken build\t@c\tfeat/broken\t0\tfail\n'
}

# Box rows of the wizard summary, with each box/emoji character counted once
box_widths() {
  grep -E '║|╔|╚|╠' | sed -e 's/║/X/g' -e 's/╔/X/g' -e 's/╗/X/g' -e 's/╚/X/g' \
    -e 's/╝/X/g' -e 's/╠/X/g' -e 's/╣/X/g' -e 's/═/X/g' -e 's/✓/X/g' -e 's/⚙/X/g' |
    LC_ALL=C awk '{ print length($0) }' | sort -u
}

# --- Install wizard -----------------------------------------------------------

# ln is recorded and redirected so the test never writes outside $TMP,
# even on a machine where /usr/local/bin is writable
_install_with_logged_ln() {
  ln() { printf '%s\n' "$@" > "$TMP/ln.args"; command ln -sf "$2" "$TMP/wt-core-link"; }
  sleep() { :; }
  print_logo() { :; }
  run_install_wizard
}

@test "install wizard: wt-core links to wt.sh (SCRIPT_PATH), not lib/menus.sh" {
  export SHELL=/bin/zsh
  PATH="$STUBS:/usr/bin:/bin"
  touch "$WT_CONFIG_FILE"
  fzf_answers '\tYes'
  run _install_with_logged_ln
  assert_success
  run sed -n 2p "$TMP/ln.args"
  assert_output "$SCRIPT_PATH"
  refute_output --partial "menus.sh"
  run cat "$HOME/.zshrc"
  assert_output --partial 'command -v wt-core >/dev/null 2>&1 && eval "$(wt-core --shell-init)"'
  refute_output --partial '&>'
}

@test "install wizard: warns when the install dir is not in PATH" {
  [[ -w /usr/local/bin ]] && skip "/usr/local/bin is writable here"
  export SHELL=/bin/bash
  PATH="$STUBS:/usr/bin:/bin"
  touch "$WT_CONFIG_FILE"
  fzf_answers '\tYes'
  run _install_with_logged_ln
  assert_success
  assert_output --partial "$HOME/.local/bin is not in your PATH"
  assert_output --partial "export PATH=\"$HOME/.local/bin:\$PATH\""
  refute_output --partial "Installation complete"
  run cat "$HOME/.bashrc"
  assert_output --partial "wt-core --shell-init"
}

@test "install wizard: unknown shell gets instructions, no rc file is written" {
  export SHELL=/usr/bin/fish
  PATH="$STUBS:/usr/bin:/bin"
  touch "$WT_CONFIG_FILE"
  fzf_answers '\tYes'
  run _install_with_logged_ln
  assert_success
  assert_output --partial "supports zsh and bash, not fish"
  assert_output --partial 'eval "$(wt-core --shell-init)"'
  [[ ! -e "$HOME/.profile" && ! -e "$HOME/.zshrc" && ! -e "$HOME/.bashrc" && ! -e "$HOME/.config/fish" ]] || false
}

@test "install wizard: from the Nix store, no symlink and no rc change" {
  export SHELL=/bin/zsh
  PATH="$STUBS:/usr/bin:/bin"
  touch "$WT_CONFIG_FILE"
  SCRIPT_PATH="/nix/store/abc-worktigre-2.2.0/bin/.wt-core-wrapped"
  run _install_with_logged_ln
  assert_success
  assert_output --partial "nix profile install github:AThevon/worktigre"
  [[ ! -e "$TMP/ln.args" ]] || false
  [[ ! -e "$HOME/.zshrc" ]] || false
  [[ "$(fzf_calls)" == 0 ]] || false
}

# --- Preferences wizard -------------------------------------------------------

write_full_config() {
  mkdir -p "$(dirname "$WT_CONFIG_FILE")"
  cat > "$WT_CONFIG_FILE" <<'EOF'
WT_EDITOR=nvim
WT_PLATFORM=gitlab
WT_WORKTREE_DIR=~/worktrees
WT_AUTO_CD=false
WT_FEATURE_PREFIX=feat/
WT_AUTO_FETCH=false
WT_CLAUDE_MODE=plan
WT_LIST_LIMIT=50
EOF
}

_quiet_wizard() {
  sleep() { :; }
  run_preferences_wizard "$@"
}

@test "preferences wizard: ^S on both steps keeps every setting" {
  write_full_config
  load_config
  fzf_answers 'ctrl-s\t' 'ctrl-s\t'
  run _quiet_wizard
  assert_success
  load_config
  [[ "$WT_EDITOR" == nvim && "$WT_PLATFORM" == gitlab && "$WT_AUTO_CD" == false ]] || false
  [[ "$WT_FEATURE_PREFIX" == feat/ && "$WT_AUTO_FETCH" == false ]] || false
  [[ "$WT_CLAUDE_MODE" == plan && "$WT_LIST_LIMIT" == 50 ]] || false
  [[ "$WT_WORKTREE_DIR" == "$HOME/worktrees" || "$WT_WORKTREE_DIR" == "~/worktrees" ]] || false
}

@test "preferences wizard: answers only change editor and platform" {
  write_full_config
  load_config
  fzf_answers '\tcustom' '\t^github'
  gum_answers '0\temacs -nw'
  run _quiet_wizard --standalone
  assert_success
  refute_output --partial "Launching wt"
  load_config
  [[ "$WT_EDITOR" == "emacs -nw" && "$WT_PLATFORM" == github ]] || false
  [[ "$WT_FEATURE_PREFIX" == feat/ && "$WT_LIST_LIMIT" == 50 && "$WT_CLAUDE_MODE" == plan ]] || false
}

@test "preferences wizard: Esc in the custom editor field keeps the editor" {
  write_full_config
  load_config
  fzf_answers '\tcustom' '\t-'
  gum_answers '1\t'
  run _quiet_wizard
  assert_success
  load_config
  [[ "$WT_EDITOR" == nvim && "$WT_PLATFORM" == gitlab ]] || false
}

@test "preferences wizard: fills defaults for missing keys only" {
  rm -f "$WT_CONFIG_FILE"
  mkdir -p "$(dirname "$WT_CONFIG_FILE")"
  printf 'WT_LIST_LIMIT=42\n' > "$WT_CONFIG_FILE"
  fzf_answers 'ctrl-s\t' 'ctrl-s\t'
  run _quiet_wizard
  assert_success
  assert_output --partial "Launching wt"
  run grep -c '^WT_' "$WT_CONFIG_FILE"
  assert_output "8"
  load_config
  [[ "$WT_LIST_LIMIT" == 42 && "$WT_AUTO_CD" == true && "$WT_FEATURE_PREFIX" == feature/ ]] || false
}

@test "preferences wizard: summary box is aligned and shows the real config path" {
  export WT_CONFIG_FILE="$HOME/cfg/wt.conf"
  fzf_answers 'ctrl-s\t' '\t^github'
  run _quiet_wizard --standalone
  assert_success
  assert_output --partial "Config      ~/cfg/wt.conf"
  run box_widths <<< "$output"
  assert_output "42"
}

@test "preferences wizard: a long editor command is cut to fit the box" {
  fzf_answers '\tcustom' 'ctrl-s\t'
  gum_answers '0\t/opt/very/long/path/to/an/editor --wait --new-window'
  run _quiet_wizard --standalone
  assert_success
  assert_output --partial "IDE         ...r --wait --new-window"
  run box_widths <<< "$output"
  assert_output "42"
}

# --- Settings -----------------------------------------------------------------

_settings() {
  sleep() { :; }
  menu_settings
  echo "dir=[${WT_WORKTREE_DIR:-}] limit=[${WT_LIST_LIMIT:-}] platform=[${_WT_PLATFORM:-}]"
}

@test "settings: Esc in the worktree dir field keeps the value" {
  printf 'WT_WORKTREE_DIR=/srv/wt\n' > "$WT_CONFIG_FILE"
  load_config
  fzf_answers '\t^Worktree' '\t-'
  gum_answers '1\t'
  run _settings
  assert_success
  assert_output --partial "dir=[/srv/wt]"
  run grep '^WT_WORKTREE_DIR=' "$WT_CONFIG_FILE"
  assert_output --partial "/srv/wt"
}

@test "settings: worktree dir refuses a relative path, accepts ~ and 'default'" {
  printf 'WT_WORKTREE_DIR=/srv/wt\n' > "$WT_CONFIG_FILE"
  load_config
  fzf_answers '\t^Worktree' '\t^Worktree' '\t-'
  gum_answers '0\tsome/dir' '0\t~/trees'
  run _settings
  assert_success
  assert_output --partial "Not saved"
  assert_output --partial "dir=[~/trees]"
  fzf_answers '\t^Worktree' '\t-'
  gum_answers '0\tdefault'
  run _settings
  assert_output --partial "dir=[]"
}

@test "settings: list limit must be >= 1" {
  printf 'WT_LIST_LIMIT=50\n' > "$WT_CONFIG_FILE"
  load_config
  fzf_answers '\t^PR/Issue' '\t^PR/Issue' '\t-'
  gum_answers '0\t0' '0\t30'
  run _settings
  assert_success
  assert_output --partial "enter a number >= 1"
  assert_output --partial "limit=[30]"
}

@test "settings: Platform auto re-detects instead of caching 'auto'" {
  make_repo "$TMP/gl" "git@gitlab.com:foo/bar.git"
  printf 'WT_PLATFORM=github\n' > "$WT_CONFIG_FILE"
  load_config
  _WT_PLATFORM="github"
  fzf_answers '\t^Platform' '\t^auto' '\t-'
  run _settings
  assert_success
  assert_output --partial "platform=[gitlab]"
}

@test "settings: Reset wipes the config and does not announce a relaunch" {
  write_full_config
  load_config
  fzf_answers 'ctrl-r\t' '\tYes' 'ctrl-s\t' 'ctrl-s\t' '\t-'
  run _settings
  assert_success
  refute_output --partial "Launching wt"
  assert_output --partial "Settings reset to defaults"
  run grep '^WT_LIST_LIMIT=' "$WT_CONFIG_FILE"
  assert_output --partial "20"
}

# --- Create menu --------------------------------------------------------------

@test "create menu: Ctrl+C and Tab are not captured, ^T and ^G are" {
  fzf_answers '\t-'
  run menu_create_worktree
  assert_failure
  run grep -- '--expect=' "$FZF_LOG.args.1"
  assert_output "--expect=ctrl-n,ctrl-b,ctrl-t,ctrl-g,ctrl-p"
  run grep -- '--footer=' "$FZF_LOG.args.1"
  assert_output --partial "^T current"
  assert_output --partial "^G issue"
}

@test "create menu: ^T runs 'From current'" {
  create_from_current() { echo "/tmp/wt-copy"; }
  fzf_answers 'ctrl-t\t'
  run menu_create_worktree
  assert_success
  assert_output "/tmp/wt-copy"
}

@test "create menu: Esc in a sub-step comes back to the Create menu" {
  create_new_branch() { return 1; }
  menu_from_issue() { return 1; }
  fzf_answers '\t^New branch' 'ctrl-g\t' '\t-'
  run menu_create_worktree
  assert_failure
  [[ "$(fzf_calls)" == 3 ]] || false
}

# --- PR picker ----------------------------------------------------------------

_review() {
  has_claude() { return 0; }
  no_tty_read
  create_from_pr() { printf '%s\n' "$@" > "$TMP/create_from_pr.args"; echo "$TMP/review-wt"; }
  menu_review_pr
}

@test "pr action: ^F is only bound when CI failed" {
  fzf_answers 'ctrl-f\t'
  run select_pr_action 12 false
  assert_output ""
  run grep -- '--expect=' "$FZF_LOG.args.1"
  refute_output --partial "ctrl-f"
  fzf_answers 'ctrl-f\t'
  run select_pr_action 12 true
  assert_output "Fix CI issues (auto)"
}

@test "pr list: titles with backslashes reach fzf intact" {
  cli_pr_list() { fake_prs; }
  fzf_answers '\t-'
  run _review
  run cat "$FZF_LOG.stdin.1"
  assert_output "$(fake_prs)"
}

@test "pr list: branch, number and cross-repo flag come from fields 5, 1 and 6" {
  cli_pr_list() { fake_prs; }
  fzf_answers '\t^#2' '\t^Just'
  run _review
  assert_success
  assert_output "$TMP/review-wt"
  run cat "$TMP/create_from_pr.args"
  assert_output "$(printf 'feat/badge\n2\n1')"
}

@test "pr list: Fix CI depends on the CI state field, not on the title" {
  cli_pr_list() { fake_prs; }
  fzf_answers '\t^#2' '\t-' '\t-'
  run _review
  run cat "$FZF_LOG.stdin.2"
  refute_output --partial "Fix CI"
  fzf_answers '\t^#3' '\tFix CI'
  rm -f "$FZF_LOG.n"
  run _review
  assert_success
  assert_line "CLAUDE:ci-fix:3"
  run cat "$FZF_LOG.stdin.2"
  assert_line "Fix CI issues (auto)"
}

@test "pr list: Esc on the Claude mode creates nothing" {
  cli_pr_list() { fake_prs; }
  fzf_answers '\t^#1' '\t^Review' '\t-' '\t-' '\t-'
  run _review
  assert_failure
  [[ ! -e "$TMP/create_from_pr.args" ]] || false
  fzf_answers '\t^#1' '\t^Review' '\t^\?> Ask'
  rm -f "$FZF_LOG.n"
  run _review
  assert_success
  assert_line "CLAUDE:pr-review:1:ask"
}

@test "pr list: a gh failure is reported, not 'No open PRs found'" {
  cli_pr_list() { echo "gh: HTTP 401" >&2; return 1; }
  run _review
  assert_failure
  assert_output --partial "gh: HTTP 401"
  assert_output --partial "Could not list PRs"
  refute_output --partial "No open PRs found"
}

@test "pr preview: accepts #N and !N" {
  cli_pr_view() { echo "view:$1"; }
  cli_pr_diff_stat() { echo "diff:$1"; }
  run pr_preview '#12'
  assert_line "view:12"
  run pr_preview '!12'
  assert_line "diff:12"
}

# --- Issue picker -------------------------------------------------------------

_issue() {
  has_claude() { return 0; }
  no_tty_read
  create_from_issue() { printf '%s\n' "$@" > "$TMP/create_from_issue.args"; echo "$TMP/issue-wt"; }
  menu_from_issue
}

@test "issue list: Esc on the Claude mode goes back, then Just creates the worktree" {
  cli_issue_list() { printf '#7\tFix it\t@z\tbug\n'; }
  fzf_answers '\t^#7' '\t^Launch' '\t-' '\t^Just'
  run _issue
  assert_success
  assert_output "$TMP/issue-wt"
  # list, action, mode (Esc), action again
  [[ "$(fzf_calls)" == 4 ]] || false
  run cat "$TMP/create_from_issue.args"
  assert_output "$(printf '7\nFix it')"
}

# --- Texts --------------------------------------------------------------------

@test "claude mode picker: GitLab wording and the real plan flag" {
  make_repo "$TMP/gl" "git@gitlab.com:foo/bar.git"
  fzf_answers '\t-'
  run select_claude_mode pr-review 12
  run grep -- '--header=' "$FZF_LOG.args.1"
  assert_output --partial "MR !12 review"
  run grep -c -- "--permission-mode=plan" "$FZF_LOG.args.1"
  assert_output "1"
  run grep -c -- "Mode: --plan" "$FZF_LOG.args.1"
  assert_output "0"
}

@test "issue action preview uses WT_FEATURE_PREFIX" {
  WT_FEATURE_PREFIX="it's/"
  fzf_answers '\t-'
  run select_issue_action 7
  run grep -- "Branch:" "$FZF_LOG.args.1"
  assert_output --partial "Branch: it'\\''s/{issue}-{title}"
}

@test "menus.sh has no em dash" {
  run grep -c $'\xe2\x80\x94' "$BATS_TEST_DIRNAME/../lib/menus.sh"
  assert_output "0"
}

# --- Delete -------------------------------------------------------------------

_delete() {
  no_tty_read
  action_delete_worktrees
}

@test "delete: a locked worktree is skipped, the others are removed" {
  make_repo "$TMP/p"
  git -C "$TMP/p" worktree add -q "$TMP/p-locked" -b locked
  git -C "$TMP/p" worktree lock --reason "on usb" "$TMP/p-locked"
  git -C "$TMP/p" worktree add -q "$TMP/p free" -b free
  cd "$TMP/p"
  fzf_answers '\tlocked|free'
  run _delete
  assert_success
  assert_line "$TMP/p"
  assert_output --partial "on usb"
  [[ -d "$TMP/p-locked" && ! -e "$TMP/p free" ]] || false
  run git -C "$TMP/p" worktree list --porcelain
  assert_output --partial "worktree $TMP/p-locked"
  refute_output --partial "worktree $TMP/p free"
  run grep -- '--preview=' "$FZF_LOG.args.1"
  assert_output --partial "--worktree-preview {2}"
}

@test "delete: only locked worktrees selected deletes nothing" {
  make_repo "$TMP/p"
  git -C "$TMP/p" worktree add -q "$TMP/p-locked" -b locked
  git -C "$TMP/p" worktree lock "$TMP/p-locked"
  cd "$TMP/p"
  fzf_answers '\tlocked'
  run _delete
  assert_failure
  [[ -d "$TMP/p-locked" ]] || false
}

@test "delete: a worktree git refuses to remove is cleaned up without a ghost entry" {
  make_repo "$TMP/p"
  git -C "$TMP/p" worktree add -q "$TMP/p-broken" -b broken
  echo "gitdir: /nonexistent/x" > "$TMP/p-broken/.git"
  cd "$TMP/p"
  fzf_answers '\tbroken'
  run _delete
  assert_success
  assert_output --partial "Deleted (manual)"
  [[ ! -e "$TMP/p-broken" ]] || false
  run git -C "$TMP/p" worktree list --porcelain
  refute_output --partial "p-broken"
}
