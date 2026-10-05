#!/usr/bin/env bats
# Entry point (wt.sh), shell function, core config/platform/editor helpers

load 'test_helper/common'

bats_require_minimum_version 1.5.0

WT_SCRIPT="${BATS_TEST_DIRNAME}/../wt.sh"

setup() {
  isolate_home
  REAL_FZF="$(command -v fzf || true)"
  REAL_GIT="$(command -v git)"
  STUBS="${BATS_TEST_TMPDIR}/stubs"
  mkdir -p "$STUBS"
  export FZF_LOG="${BATS_TEST_TMPDIR}/fzf"
  mkdir -p "$FZF_LOG"
  unset WT_EDITOR WT_PLATFORM WT_WORKTREE_DIR WT_AUTO_CD WT_FEATURE_PREFIX \
    WT_AUTO_FETCH WT_CLAUDE_MODE WT_LIST_LIMIT FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE \
    _WT_PLATFORM _WT_DEFAULT_BRANCH _WT_CACHE_REPO _WT_FZF_FOOTER

  # real path: git reports worktree paths with symlinks resolved (/var -> /private/var)
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  PROJECTS="$TMP/projects"
  REPO="$PROJECTS/myapp"
  FEAT="$PROJECTS/myapp-feature-auth"
  make_git_repo "$REPO" >/dev/null
  git -C "$REPO" remote add origin git@github.com:acme/myapp.git
  git -C "$REPO" worktree add -q -b feature/auth "$FEAT"
  cd "$REPO" || return 1
}

# fzf stub: answers the --footer probe and --filter calls, records the other
# calls (args NUL-separated, stdin) and replies from $FZF_LOG/resp.<n>:
#   line 1 exit code, line 2 key, line 3 selection: @id | path:<suffix> | empty | none
install_fzf_stub() {
  cat > "$STUBS/fzf" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == --filter=* ]] && exit 0; done
n=$(cat "$FZF_LOG/count" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FZF_LOG/count"
printf '%s\0' "$@" > "$FZF_LOG/args.$n"
cat > "$FZF_LOG/stdin.$n"
echo "${WT_TEST_MARK:-}" > "$FZF_LOG/mark.$n"
resp="$FZF_LOG/resp.$n"
[[ -f "$resp" ]] || exit 130
rc=$(sed -n 1p "$resp"); key=$(sed -n 2p "$resp"); sel=$(sed -n 3p "$resp")
printf '%s\n' "$key"
case "$sel" in
  @*) awk -F'\t' -v id="$sel" '$2 == id { print; exit }' "$FZF_LOG/stdin.$n" ;;
  path:*) awk -F'\t' -v s="${sel#path:}" 'substr($2, length($2) - length(s) + 1) == s { print; exit }' "$FZF_LOG/stdin.$n" ;;
  empty) echo "" ;;
esac
exit "$rc"
EOF
  chmod +x "$STUBS/fzf"
  export PATH="$STUBS:$PATH"
}

fzf_reply() {  # fzf_reply <n> <rc> <key> <selection>
  printf '%s\n%s\n%s\n' "$2" "$3" "$4" > "$FZF_LOG/resp.$1"
}

fzf_calls() {
  cat "$FZF_LOG/count" 2>/dev/null || echo 0
}

# Value of an --opt=value argument recorded for fzf call <n>
fzf_arg() {
  local a
  while IFS= read -r -d '' a; do
    if [[ "$a" == "$2="* ]]; then
      printf '%s' "${a#"$2="}"
      return 0
    fi
  done < "$FZF_LOG/args.$1"
  return 1
}

# Source wt.sh (functions only, the entry point is skipped) inside $REPO
source_wt() {
  # shellcheck disable=SC1090
  source "$WT_SCRIPT"
  _wt_detect_repo
}

# Shell function harness: <shell> <snippet>, with stubbed wt-core and claude
run_shell_fn() {
  local shell="$1" snippet="$2"
  bash "$WT_SCRIPT" --shell-init > "${BATS_TEST_TMPDIR}/init.sh"
  cat > "$STUBS/wt-core" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --get-pr-term) echo PR; exit 0 ;;
  --generate-prompt) echo "PROMPT($2,$3) in $PWD"; exit 0 ;;
  --version) echo "wt stub-version"; exit 0 ;;
esac
[[ -n "${STUB_OUT:-}" ]] && printf '%s\n' "$STUB_OUT"
exit "${STUB_RC:-0}"
EOF
  cat > "$STUBS/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude pwd=$PWD args=$*" >> "$HOME/claude.log"
EOF
  chmod +x "$STUBS/wt-core" "$STUBS/claude"
  local prelude="export PATH=\"$STUBS:\$PATH\"; source \"${BATS_TEST_TMPDIR}/init.sh\"; cd \"$REPO\";"
  case "$shell" in
    bash) run bash --norc --noprofile -c "$prelude $snippet" ;;
    zsh)  run zsh -f -c "$prelude $snippet" ;;
  esac
}

require_zsh() {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
}

# =============================================================================
# CLI contract
# =============================================================================

@test "--version prints the version on stdout" {
  run --separate-stderr bash "$WT_SCRIPT" --version
  assert_success
  assert_output --regexp '^wt [0-9]+\.[0-9]+\.[0-9]+$'
  [[ -z "$stderr" ]]
}

@test "unknown option: error and exit 1, the menu never opens" {
  install_fzf_stub
  run bash "$WT_SCRIPT" --hepl
  assert_failure 1
  assert_output --partial "Unknown option: --hepl"
  assert_equal "$(fzf_calls)" "0"

  run bash "$WT_SCRIPT" -x
  assert_failure 1
  assert_equal "$(fzf_calls)" "0"
}

@test "unknown option outside a repo is reported as such" {
  mkdir -p "${BATS_TEST_TMPDIR}/nogit"
  cd "${BATS_TEST_TMPDIR}/nogit"
  run bash "$WT_SCRIPT" --verison
  assert_failure 1
  assert_output --partial "Unknown option"
}

@test "wt - outside a repo: no git error, accurate message" {
  mkdir -p "${BATS_TEST_TMPDIR}/nogit"
  cd "${BATS_TEST_TMPDIR}/nogit"
  run bash "$WT_SCRIPT" -
  assert_failure 1
  refute_output --partial "fatal:"
  refute_output --partial "--setup"
  assert_output --partial "No previous worktree yet"

  echo "$FEAT" > "$HOME/.wt_prev"
  run --separate-stderr bash "$WT_SCRIPT" -
  assert_success
  assert_output "$FEAT"
  [[ -z "$stderr" ]]
}

@test "wt . returns the main worktree from a linked worktree" {
  cd "$FEAT"
  run --separate-stderr bash "$WT_SCRIPT" .
  assert_success
  assert_output "$REPO"
}

@test "bare layout (proj/.bare): wt . and REPO_NAME skip the bare repo" {
  local proj="$TMP/proj"
  git init -q --bare "$proj/.bare"
  git -C "$proj/.bare" symbolic-ref HEAD refs/heads/main
  git -C "$proj/.bare" worktree add -q --orphan -b main "$proj/main" 2>/dev/null ||
    skip "git too old for worktree add --orphan"
  git -C "$proj/main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$proj/main" worktree add -q -b aaa-first "$proj/aaa-first"

  cd "$proj/aaa-first"
  run --separate-stderr bash "$WT_SCRIPT" .
  assert_success
  assert_output "$proj/main"

  source_wt
  assert_equal "$MAIN_REPO" "$proj/main"
  assert_equal "$REPO_NAME" "proj"
}

@test "bare layout (proj.git next to worktrees): REPO_NAME drops .git" {
  local base="$TMP/b2"
  git init -q --bare "$base/proj2.git"
  git -C "$base/proj2.git" worktree add -q --orphan -b main "$base/proj2-main" 2>/dev/null ||
    skip "git too old for worktree add --orphan"
  cd "$base/proj2-main"
  source_wt
  assert_equal "$MAIN_REPO" "$base/proj2-main"
  assert_equal "$REPO_NAME" "proj2"
}

@test "_wt_repo_name: .git suffix and hidden bare dirs" {
  source_wt
  assert_equal "$(_wt_repo_name /x/proj.git)" "proj"
  assert_equal "$(_wt_repo_name /x/proj/.bare)" "proj"
  assert_equal "$(_wt_repo_name /x/proj/.git)" "proj"
  assert_equal "$(_wt_repo_name /x/myapp/)" "myapp"
}

# =============================================================================
# Quick switch
# =============================================================================

@test "quick switch: matches branch or folder name, returns the absolute path" {
  [[ -n "$REAL_FZF" ]] || skip "fzf not installed"
  git -C "$REPO" worktree add -q -b fix/login "$PROJECTS/myapp-fix login"

  run --separate-stderr bash "$WT_SCRIPT" auth
  assert_success
  assert_output "$FEAT"

  run --separate-stderr bash "$WT_SCRIPT" login
  assert_success
  assert_output "$PROJECTS/myapp-fix login"

  # the parent directory name is not part of the match
  run bash "$WT_SCRIPT" projects
  assert_failure 1
  assert_output --partial "No worktree matching 'projects'"
}

@test "quick switch: user FZF_DEFAULT_OPTS cannot change the result" {
  [[ -n "$REAL_FZF" ]] || skip "fzf not installed"
  FZF_DEFAULT_OPTS="--print-query --exact" run --separate-stderr bash "$WT_SCRIPT" auth
  assert_success
  assert_output "$FEAT"
}

@test "quick switch: no git status and only a handful of git calls" {
  [[ -n "$REAL_FZF" ]] || skip "fzf not installed"
  cat > "$STUBS/git" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${BATS_TEST_TMPDIR}/git.log"
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$STUBS/git"
  PATH="$STUBS:$PATH" run --separate-stderr bash "$WT_SCRIPT" auth
  assert_success
  run grep -c . "${BATS_TEST_TMPDIR}/git.log"
  [[ "$output" -le 4 ]]
  run grep -E '(^| )status( |$)' "${BATS_TEST_TMPDIR}/git.log"
  assert_failure
}

# =============================================================================
# Shell function (--shell-init / --dev)
# =============================================================================

@test "shell function: --shell-init and --dev come from one template" {
  local init dev
  init=$(bash "$WT_SCRIPT" --shell-init)
  dev=$(bash "$WT_SCRIPT" --dev 2>/dev/null)
  assert_equal "$(printf '%s\n' "$init" | grep -v '^_WT_CORE=')" \
               "$(printf '%s\n' "$dev" | grep -v '^_WT_CORE=')"
  [[ "$init" == *"_WT_CORE=wt-core"* ]]
  [[ "$dev" == *"_WT_CORE=$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)/wt.sh"* ]]
}

@test "shell function: bash -n and zsh -n accept the generated code" {
  bash "$WT_SCRIPT" --shell-init > "${BATS_TEST_TMPDIR}/init.sh"
  run bash -n "${BATS_TEST_TMPDIR}/init.sh"
  assert_success
  if command -v zsh >/dev/null 2>&1; then
    run zsh -n "${BATS_TEST_TMPDIR}/init.sh"
    assert_success
  fi
}

shell_fn_claude_nocd() {
  printf 'WT_AUTO_CD="false"\n' > "${BATS_TEST_TMPDIR}/alt.conf"
  run_shell_fn "$1" "export WT_CONFIG_FILE='${BATS_TEST_TMPDIR}/alt.conf';
    STUB_OUT=\$'$FEAT\nCLAUDE:ci-fix:42' wt; echo rc=\$?; echo final=\$PWD"
  assert_success
  assert_output --partial "Worktree: $FEAT"
  assert_output --partial "rc=0"
  assert_output --partial "final=$REPO"
  run cat "$HOME/claude.log"
  assert_output "claude pwd=$FEAT args=--dangerously-skip-permissions PROMPT(ci-fix,42) in $FEAT"
  [[ ! -f "$HOME/.wt_prev" ]]
}

@test "shell function (bash): auto-cd off still runs Claude in the target worktree" {
  shell_fn_claude_nocd bash
}

@test "shell function (zsh): auto-cd off still runs Claude in the target worktree" {
  require_zsh
  shell_fn_claude_nocd zsh
}

shell_fn_cd_noclobber() {
  local noclobber="set -C;"
  [[ "$1" == zsh ]] && noclobber="setopt noclobber;"
  echo /old/prev > "$HOME/.wt_prev"
  run_shell_fn "$1" "$noclobber STUB_OUT=\$'$FEAT\nCLAUDE:pr-review:7:plan' wt; echo rc=\$?; echo final=\$PWD"
  assert_success
  assert_output --partial "Navigated to: $FEAT"
  assert_output --partial "final=$FEAT"
  refute_output --partial "exists"
  refute_output --partial "overwrite"
  assert_equal "$(cat "$HOME/.wt_prev")" "$REPO"
  run cat "$HOME/claude.log"
  assert_output "claude pwd=$FEAT args=--permission-mode=plan PROMPT(pr-review,7) in $FEAT"
}

@test "shell function (bash): cd, ~/.wt_prev written even with noclobber" {
  shell_fn_cd_noclobber bash
}

@test "shell function (zsh): cd, ~/.wt_prev written even with noclobber" {
  require_zsh
  shell_fn_cd_noclobber zsh
}

@test "shell function: WT_AUTO_CD from the environment wins" {
  printf 'WT_AUTO_CD=true\n' > "${BATS_TEST_TMPDIR}/alt.conf"
  run_shell_fn bash "export WT_CONFIG_FILE='${BATS_TEST_TMPDIR}/alt.conf' WT_AUTO_CD=false;
    STUB_OUT='$FEAT' wt; echo final=\$PWD"
  assert_output --partial "final=$REPO"
}

@test "shell function: returns wt-core's exit code when there is no target" {
  run_shell_fn bash "STUB_RC=1 wt nomatch; echo rc=\$?"
  assert_output --partial "rc=1"
  if command -v zsh >/dev/null 2>&1; then
    run_shell_fn zsh "STUB_RC=1 wt nomatch; echo rc=\$?"
    assert_output --partial "rc=1"
  fi
}

@test "shell function: --version and --help are not swallowed" {
  run_shell_fn bash "wt --version"
  assert_output "wt stub-version"
}

# =============================================================================
# --update / --setup
# =============================================================================

@test "--update refuses a git checkout and points to git pull" {
  run bash "$WT_SCRIPT" --update
  assert_failure 1
  assert_output --partial "git checkout"
  assert_output --partial "pull"
}

@test "--update refuses a Homebrew install" {
  local cellar="${BATS_TEST_TMPDIR}/Cellar/worktigre/1.0.0"
  mkdir -p "$cellar/bin" "$cellar/lib/worktigre" "${BATS_TEST_TMPDIR}/brewbin"
  cp "$WT_SCRIPT" "$cellar/bin/wt-core"
  ln -s "$cellar/bin/wt-core" "${BATS_TEST_TMPDIR}/brewbin/wt-core"
  run bash "${BATS_TEST_TMPDIR}/brewbin/wt-core" --update
  assert_failure 1
  assert_output --partial "brew upgrade worktigre"
}

# install.sh-like prefix plus a curl stub serving the release API and an installer
setup_update_prefix() {
  PREFIX="$TMP/share/worktigre"
  mkdir -p "$PREFIX"
  cp -R "${BATS_TEST_DIRNAME}/../wt.sh" "${BATS_TEST_DIRNAME}/../lib" "$PREFIX/"
  cat > "$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
url="" out=""
while [[ $# -gt 0 ]]; do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
case "$url" in
  *releases/latest) body="{\"tag_name\": \"v9.9.9\"}" ;;
  *v9.9.9/install.sh) body="$(cat "$STUB_INSTALLER")" ;;
  *) exit 22 ;;
esac
printf '%s\n' "$body" > "$out"
EOF
  chmod +x "$STUBS/curl"
  export PATH="$STUBS:$PATH"
}

@test "--update: a failing installer is reported, never announced as updated" {
  setup_update_prefix
  printf '#!/bin/bash\nexit 1\n' > "${BATS_TEST_TMPDIR}/inst.sh"
  STUB_INSTALLER="${BATS_TEST_TMPDIR}/inst.sh" run bash "$PREFIX/wt.sh" --update
  assert_failure 1
  assert_output --partial "Update failed"
  refute_output --partial "Updated to"
}

@test "--update: an installer that changes nothing is not a success" {
  setup_update_prefix
  printf '#!/bin/bash\nexit 0\n' > "${BATS_TEST_TMPDIR}/inst.sh"
  STUB_INSTALLER="${BATS_TEST_TMPDIR}/inst.sh" run bash "$PREFIX/wt.sh" --update
  assert_failure 1
  assert_output --partial "Update incomplete"
  refute_output --partial "Updated to"
}

@test "--update: runs the release installer with the tag and the current prefix" {
  setup_update_prefix
  cat > "${BATS_TEST_TMPDIR}/inst.sh" <<'EOF'
#!/bin/bash
echo "ref=$WT_INSTALL_REF prefix=$WT_INSTALL_PREFIX" > "$HOME/installer.args"
sed -i.bak 's/^VERSION=.*/VERSION="9.9.9"/' "$WT_INSTALL_PREFIX/wt.sh"
EOF
  STUB_INSTALLER="${BATS_TEST_TMPDIR}/inst.sh" run bash "$PREFIX/wt.sh" --update
  assert_success
  assert_output --partial "Updated to v9.9.9"
  assert_equal "$(cat "$HOME/installer.args")" "ref=v9.9.9 prefix=$PREFIX"
}

# PATH with the tools --setup checks, without any wt-core
setup_tools_path() {
  local tools="${BATS_TEST_TMPDIR}/tools" t
  mkdir -p "$tools"
  for t in fzf gum jq; do
    printf '#!/bin/sh\nexit 0\n' > "$tools/$t"
    chmod +x "$tools/$t"
  done
  ln -sf "$REAL_GIT" "$tools/git"
  TOOLS_PATH="$tools:/usr/bin:/bin"
}

@test "--setup: symlink to the real script, POSIX rc line, lib/ found through the link" {
  # --setup prefers /usr/local/bin when writable: never touch it from a test
  [[ -w /usr/local/bin ]] && skip "/usr/local/bin is writable"
  setup_tools_path
  local clone="${BATS_TEST_TMPDIR}/clone"
  mkdir -p "$clone"
  cp -R "${BATS_TEST_DIRNAME}/../wt.sh" "${BATS_TEST_DIRNAME}/../lib" "$clone/"
  ln -s "$clone/wt.sh" "${BATS_TEST_TMPDIR}/wt-link"

  SHELL=/bin/zsh PATH="$TOOLS_PATH" run bash "${BATS_TEST_TMPDIR}/wt-link" --setup
  assert_success
  assert_equal "$(readlink "$HOME/.local/bin/wt-core")" "$(cd "$clone" && pwd -P)/wt.sh"
  assert_equal "$(tail -n 1 "$HOME/.zshrc")" \
    'command -v wt-core >/dev/null 2>&1 && eval "$(wt-core --shell-init)"'

  PATH="$TOOLS_PATH" run --separate-stderr "$HOME/.local/bin/wt-core" --get-pr-term
  assert_success
  assert_output "PR"
}

@test "--setup: unknown shell, nothing is written, instructions shown" {
  [[ -w /usr/local/bin ]] && skip "/usr/local/bin is writable"
  setup_tools_path
  SHELL=/usr/bin/fish PATH="$TOOLS_PATH" run bash "$WT_SCRIPT" --setup
  assert_success
  assert_output --partial "Nothing was written"
  [[ ! -e "$HOME/.profile" && ! -e "$HOME/.bashrc" && ! -e "$HOME/.zshrc" ]]
}

# =============================================================================
# Dependencies and wizard
# =============================================================================

@test "first launch without fzf/gum: fails before any wizard, writes nothing" {
  local tools="${BATS_TEST_TMPDIR}/nofzf"
  mkdir -p "$tools"
  ln -sf "$REAL_GIT" "$tools/git"
  rm -f "$WT_CONFIG_FILE"
  PATH="$tools:/usr/bin:/bin" run bash "$WT_SCRIPT"
  assert_failure 1
  assert_output --partial "Missing required dependencies"
  refute_output --partial "configured"
  [[ ! -f "$WT_CONFIG_FILE" ]]
}

@test "--wizard works outside a git repository" {
  install_fzf_stub
  mkdir -p "${BATS_TEST_TMPDIR}/nogit"
  cd "${BATS_TEST_TMPDIR}/nogit"
  run bash "$WT_SCRIPT" --wizard
  refute_output --partial "Not in a git repository"
}

@test "--wizard keeps the settings it does not ask about" {
  install_fzf_stub
  mkdir -p "$(dirname "$WT_CONFIG_FILE")"
  printf 'WT_LIST_LIMIT="50"\nWT_FEATURE_PREFIX="ticket/"\nWT_EDITOR="nvim"\n' > "$WT_CONFIG_FILE"
  run bash "$WT_SCRIPT" --wizard
  run grep -x 'WT_LIST_LIMIT="50"' "$WT_CONFIG_FILE"
  assert_success
  run grep -x 'WT_FEATURE_PREFIX="ticket/"' "$WT_CONFIG_FILE"
  assert_success
}

# =============================================================================
# Config (C9)
# =============================================================================

@test "config: values with spaces and shell syntax round-trip without running code" {
  load_wt
  local evil='x$(touch "'"$BATS_TEST_TMPDIR"'/pwned")`touch "'"$BATS_TEST_TMPDIR"'/pwned2"`"q\'
  save_config_value WT_EDITOR "code --wait"
  save_config_value WT_WORKTREE_DIR "$HOME/My Worktrees"
  save_config_value WT_FEATURE_PREFIX "$evil"
  unset WT_EDITOR WT_WORKTREE_DIR WT_FEATURE_PREFIX
  load_config
  assert_equal "$WT_EDITOR" "code --wait"
  assert_equal "$WT_WORKTREE_DIR" "$HOME/My Worktrees"
  assert_equal "$WT_FEATURE_PREFIX" "$evil"
  [[ ! -e "$BATS_TEST_TMPDIR/pwned" && ! -e "$BATS_TEST_TMPDIR/pwned2" ]]
  assert_equal "$(get_config_value WT_EDITOR x)" "code --wait"
}

@test "config: unknown keys and code lines are ignored" {
  load_wt
  mkdir -p "$(dirname "$WT_CONFIG_FILE")"
  printf 'PATH=/nope\nWT_LIST_LIMIT=30\ntouch %s/ran\n' "$BATS_TEST_TMPDIR" > "$WT_CONFIG_FILE"
  load_config
  assert_equal "$WT_LIST_LIMIT" "30"
  [[ "$PATH" != "/nope" ]]
  [[ ! -e "$BATS_TEST_TMPDIR/ran" ]]
}

@test "config: older unquoted files still load (export, comment, ~)" {
  load_wt
  mkdir -p "$(dirname "$WT_CONFIG_FILE")"
  printf 'WT_AUTO_FETCH=false\nexport WT_CLAUDE_MODE=plan\nWT_WORKTREE_DIR=~/wts # mine\nWT_EDITOR=\n' > "$WT_CONFIG_FILE"
  load_config
  assert_equal "$WT_AUTO_FETCH" "false"
  assert_equal "$WT_CLAUDE_MODE" "plan"
  assert_equal "$WT_WORKTREE_DIR" "$HOME/wts"
  assert_equal "${WT_EDITOR-unset}" ""
}

@test "config: a variable set in the environment beats the file" {
  mkdir -p "$(dirname "$WT_CONFIG_FILE")"
  printf 'WT_PLATFORM="auto"\nWT_LIST_LIMIT="20"\n' > "$WT_CONFIG_FILE"
  export WT_PLATFORM=gitlab
  load_wt
  load_config
  assert_equal "$WT_PLATFORM" "gitlab"
  assert_equal "$WT_LIST_LIMIT" "20"
  assert_equal "$(get_config_value WT_PLATFORM x)" "gitlab"

  run --separate-stderr bash "$WT_SCRIPT" --get-pr-term
  assert_output "MR"
}

@test "config: save_config_value keeps a symlinked config file a symlink" {
  load_wt
  local real="${BATS_TEST_TMPDIR}/dotfiles/wt.conf"
  mkdir -p "$(dirname "$real")" "$(dirname "$WT_CONFIG_FILE")"
  : > "$real"
  ln -s "$real" "$WT_CONFIG_FILE"
  save_config_value WT_LIST_LIMIT 42
  [[ -L "$WT_CONFIG_FILE" ]]
  run grep -x 'WT_LIST_LIMIT="42"' "$real"
  assert_success
}

# =============================================================================
# Platform, CLI auth, editor, fzf wrapper
# =============================================================================

@test "detect_platform: decided by the remote host only" {
  load_wt
  local url expected repo
  while IFS=' ' read -r url expected; do
    repo=$(make_fake_repo "$url")
    MAIN_REPO="$repo" _WT_PLATFORM="" run detect_platform
    assert_output "$expected"
  done <<'EOF'
git@github.com:foo/gitlab-ci-templates.git github
https://github.com/gitlab-tools/x.git github
git@gitlab.corp.io:team/app.git gitlab
ssh://git@gitlab.example.com:2222/a/b.git gitlab
https://user@GitLab.Example.com/a/b gitlab
https://github.com/a/b@v2 github
EOF
}

@test "has_cli: a valid local token is enough even if gh auth status fails" {
  load_wt
  MAIN_REPO="$REPO"
  stub_command gh 'case "$1 $2" in "auth token") exit 0 ;; "auth status") exit 1 ;; esac; exit 1'
  run has_cli
  assert_success
}

@test "has_cli: false when gh has no token at all" {
  load_wt
  MAIN_REPO="$REPO"
  stub_command gh 'exit 1'
  run has_cli
  assert_failure
}

@test "open_in_editor: GUI editor is detached, never holds stdout" {
  load_wt
  stub_command myed "echo NOISE; echo \"args=\$*\" > '$BATS_TEST_TMPDIR/ed.log'; sleep 3"
  export WT_EDITOR="myed --wait"
  local start=$SECONDS out
  out=$(open_in_editor "$FEAT")
  [[ $((SECONDS - start)) -lt 2 ]]
  assert_equal "$out" ""
  sleep 1
  assert_equal "$(cat "$BATS_TEST_TMPDIR/ed.log")" "args=--wait $FEAT"
}

@test "open_in_editor: missing editor is an error, not a silent no-op" {
  load_wt
  WT_EDITOR="no-such-editor -w" run open_in_editor "$FEAT"
  assert_failure
  assert_output --partial "Editor not found: no-such-editor"
}

@test "wt_fzf: user FZF_DEFAULT_OPTS cannot add a query line or multi-select" {
  [[ -n "$REAL_FZF" ]] || skip "fzf not installed"
  load_wt
  FZF_DEFAULT_OPTS="--print-query --multi" run --separate-stderr \
    bash -c 'source "$1/lib/core.sh"; printf "alpha\nbeta\n" | wt_fzf --filter=alp' _ "$WT_ROOT"
  assert_success
  assert_output "alpha"
}

@test "wt_fzf: the wt theme goes to fzf only, it is not exported" {
  load_wt
  stub_command fzf 'for a in "$@"; do [[ "$a" == --filter=* ]] && exit 0; done; echo "opts=$FZF_DEFAULT_OPTS"'
  run printenv FZF_DEFAULT_OPTS
  assert_failure
  run wt_fzf --height=10%
  assert_output --partial "--color="
}

# =============================================================================
# Main menu
# =============================================================================

@test "main_menu: Esc quits with nothing on stdout" {
  install_fzf_stub
  source_wt
  local out
  out=$(main_menu 2>/dev/null)
  assert_equal "$?" "0"
  assert_equal "$out" ""
  assert_equal "$(fzf_calls)" "1"
}

@test "main_menu: Enter on the separator line stays in the menu" {
  install_fzf_stub
  fzf_reply 1 0 "" empty
  source_wt
  local out
  out=$(main_menu 2>/dev/null)
  assert_equal "$out" ""
  assert_equal "$(fzf_calls)" "2"
}

@test "main_menu: selecting a worktree prints its absolute path" {
  install_fzf_stub
  fzf_reply 1 0 "" "path:/myapp-feature-auth"
  source_wt
  run --separate-stderr main_menu
  assert_success
  assert_output "$FEAT"
}

@test "main_menu: an fzf error is reported instead of quitting silently" {
  install_fzf_stub
  fzf_reply 1 2 "" none
  source_wt
  run --separate-stderr main_menu
  assert_failure 1
  [[ "$stderr" == *"fzf failed"* ]]
}

@test "main_menu: one worktree scan per round" {
  install_fzf_stub
  fzf_reply 1 0 "" empty
  source_wt
  eval "$(declare -f format_all_worktrees | sed '1s/format_all_worktrees/_real_format_all_worktrees/')"
  format_all_worktrees() { echo x >> "$BATS_TEST_TMPDIR/scans"; _real_format_all_worktrees; }
  run --separate-stderr main_menu
  assert_equal "$(fzf_calls)" "2"
  assert_equal "$(wc -l < "$BATS_TEST_TMPDIR/scans" | tr -d ' ')" "2"
}

@test "main_menu: the path printed by menu_stash is used for navigation" {
  install_fzf_stub
  fzf_reply 1 0 "" @stash
  source_wt
  menu_stash() { echo "$FEAT"; }
  run --separate-stderr main_menu
  assert_success
  assert_output "$FEAT"
  assert_equal "$(fzf_calls)" "1"
}

@test "main_menu: Settings keeps its state and never writes to stdout" {
  install_fzf_stub
  fzf_reply 1 0 "" @settings
  source_wt
  menu_settings() { export WT_TEST_MARK=changed; echo NOISE; }
  local out
  out=$(main_menu 2>/dev/null)
  assert_equal "$out" ""
  assert_equal "$(cat "$FZF_LOG/mark.2")" "changed"
}

@test "main_menu: Ctrl+E with a GUI editor does not block or pollute stdout" {
  install_fzf_stub
  fzf_reply 1 0 ctrl-e "path:/myapp-feature-auth"
  stub_command myed "echo NOISE; sleep 3"
  export WT_EDITOR=myed
  source_wt
  local start=$SECONDS out
  out=$(main_menu 2>/dev/null)
  [[ $((SECONDS - start)) -lt 3 ]]
  assert_equal "$out" ""
  assert_equal "$(fzf_calls)" "2"
}

@test "main_menu: worktree lines carry the absolute path, actions an @id" {
  install_fzf_stub
  source_wt
  run --separate-stderr main_menu
  run awk -F'\t' '{ print $2 }' "$FZF_LOG/stdin.1"
  assert_line "$REPO"
  assert_line "$FEAT"
  assert_line "@create"
  assert_line "@stash"
  assert_line "@delete"
  assert_line "@settings"
  assert_line "@quit"
}

@test "main_menu: previews of actions and worktrees" {
  install_fzf_stub
  source_wt
  run --separate-stderr main_menu
  local preview
  preview=$(fzf_arg 1 --preview)
  # fzf replaces {2} with the single-quoted field
  preview_for() { local q="'$1'"; bash -c "${preview//\{2\}/$q}"; }
  run preview_for @create
  assert_output --partial "Review a PR"
  run preview_for @settings
  assert_output --partial "Config: ~/.config/wt/config"
  run preview_for @delete
  assert_output --partial "  - $FEAT"
  refute_line "  - $REPO"
  run preview_for @stash
  assert_output --partial "Current stashes: 0"
  run preview_for ""
  assert_output ""
  run preview_for "$FEAT"
  assert_success
  assert_output --partial "feature/auth"
}

@test "--worktree-preview shows the branch of the given worktree" {
  run --separate-stderr bash "$WT_SCRIPT" --worktree-preview "$FEAT"
  assert_success
  assert_output --partial "feature/auth"
}

@test "caches inherited from a wt started in another repo are ignored" {
  _WT_CACHE_REPO=/elsewhere _WT_PLATFORM=gitlab run --separate-stderr bash "$WT_SCRIPT" --get-pr-term
  assert_output "PR"
  _WT_CACHE_REPO="$REPO" _WT_PLATFORM=gitlab run --separate-stderr bash "$WT_SCRIPT" --get-pr-term
  assert_output "MR"
}
